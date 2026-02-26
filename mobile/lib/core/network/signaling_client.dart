import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Client -> Server message types.
const String msgCallInitiate = 'call_initiate';
const String msgCallAccept = 'call_accept';
const String msgCallReject = 'call_reject';
const String msgCallEnd = 'call_end';
const String msgCallCancel = 'call_cancel';
const String msgIceCandidate = 'ice_candidate';
const String msgQualityMetrics = 'quality_metrics';
const String msgPing = 'ping';
const String msgReconnect = 'reconnect';
const String msgRoomCreate = 'room_create';
const String msgRoomInvite = 'room_invite';
const String msgRoomJoin = 'room_join';
const String msgRoomLeave = 'room_leave';
const String msgLayerRequest = 'layer_request';

/// Server -> Client message types.
const String msgIncomingCall = 'incoming_call';
const String msgCallAccepted = 'call_accepted';
const String msgCallRejected = 'call_rejected';
const String msgCallEnded = 'call_ended';
const String msgCallCancelled = 'call_cancelled';
const String msgError = 'error';
const String msgPong = 'pong';
const String msgSessionResumed = 'session_resumed';
const String msgPeerReconnecting = 'peer_reconnecting';
const String msgPeerReconnected = 'peer_reconnected';
const String msgRoomCreated = 'room_created';
const String msgRoomInvitation = 'room_invitation';
const String msgRoomClosed = 'room_closed';
const String msgParticipantJoined = 'participant_joined';
const String msgParticipantLeft = 'participant_left';
const String msgParticipantMediaChanged = 'participant_media_changed';
const String msgLayerUpdate = 'layer_update';
const String msgPolicyUpdate = 'policy_update';

/// Connection state for signaling WebSocket lifecycle.
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

/// Standard signaling envelope:
/// `{"type": "...", "data": {...}}`.
class SignalingMessage {
  const SignalingMessage({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    if (rawType is! String || rawType.isEmpty) {
      throw const FormatException(
        'Signaling message must include non-empty type',
      );
    }

    final rawData = json['data'];
    if (rawData == null) {
      return SignalingMessage(type: rawType, data: const <String, dynamic>{});
    }

    if (rawData is! Map) {
      throw const FormatException('Signaling message data must be an object');
    }

    return SignalingMessage(
      type: rawType,
      data: Map<String, dynamic>.from(rawData),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': type,
      'data': data,
    };
  }
}

/// Structured error parsed from server `error` messages.
class SignalingError {
  const SignalingError({required this.code, required this.message});

  final String code;
  final String message;

  factory SignalingError.fromData(Map<String, dynamic> data) {
    final code = data['code']?.toString();
    final message = data['message']?.toString();

    return SignalingError(
      code: (code == null || code.isEmpty) ? 'unknown_error' : code,
      message: (message == null || message.isEmpty)
          ? 'Unknown signaling error'
          : message,
    );
  }

  @override
  String toString() => 'SignalingError(code: $code, message: $message)';
}

/// WebSocket signaling client for voice/video call control messages.
class SignalingClient {
  SignalingClient({
    required this.url,
    required this.tokenProvider,
  });

  final String url;
  final Future<String?> Function() tokenProvider;

  static final Logger _log = Logger('SignalingClient');

  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _pongTimeout = Duration(seconds: 10);
  static const List<int> _reconnectDelaysMs = <int>[0, 1000, 3000];

  final StreamController<SignalingMessage> _messageController =
      StreamController<SignalingMessage>.broadcast();
  final StreamController<ConnectionState> _connectionStateController =
      StreamController<ConnectionState>.broadcast();
  final StreamController<SignalingError> _errorController =
      StreamController<SignalingError>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;

  Timer? _heartbeatTimer;
  Timer? _pongTimeoutTimer;
  Timer? _reconnectTimer;

  bool _awaitingPong = false;
  bool _manuallyDisconnected = false;
  bool _disposed = false;
  bool _handlingTermination = false;

  int _reconnectAttempt = 0;
  ConnectionState _state = ConnectionState.disconnected;

  /// Message buffer for queuing messages during reconnect.
  final List<SignalingMessage> _messageBuffer = <SignalingMessage>[];

  /// Maximum number of messages to buffer during reconnect.
  static const int _maxBufferSize = 50;

  /// Incoming signaling messages stream.
  Stream<SignalingMessage> get onMessage => _messageController.stream;

  /// Connection state stream.
  Stream<ConnectionState> get onConnectionState =>
      _connectionStateController.stream;

  /// Parsed signaling server errors stream.
  Stream<SignalingError> get onError => _errorController.stream;

  /// Current in-memory connection state.
  ConnectionState get connectionState => _state;

  /// Opens a WebSocket connection using JWT from [tokenProvider].
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('SignalingClient is disposed');
    }

    if (_state == ConnectionState.connected ||
        _state == ConnectionState.connecting) {
      _log.fine('Ignoring connect() in state: $_state');
      return;
    }

    _manuallyDisconnected = false;
    _reconnectTimer?.cancel();

    _emitConnectionState(
      _reconnectAttempt > 0
          ? ConnectionState.reconnecting
          : ConnectionState.connecting,
    );

    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      _emitConnectionState(ConnectionState.error);
      _errorController.add(
        const SignalingError(
          code: 'unauthorized',
          message: 'Missing signaling JWT token',
        ),
      );
      _scheduleReconnect();
      return;
    }

    final uri = _buildUriWithToken(token);
    _log.fine('Connecting signaling WebSocket: $uri');

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _channelSubscription = channel.stream.listen(
        _handleIncomingRaw,
        onError: (Object error, StackTrace stackTrace) {
          _log.warning('WebSocket stream error', error, stackTrace);
          _handleConnectionTermination(error: error, stackTrace: stackTrace);
        },
        onDone: () {
          _log.info('WebSocket closed by remote');
          _handleConnectionTermination();
        },
        cancelOnError: false,
      );

      _reconnectAttempt = 0;
      _handlingTermination = false;
      _emitConnectionState(ConnectionState.connected);
      _startHeartbeat();
      _flushMessageBuffer();
    } catch (error, stackTrace) {
      _log.warning('WebSocket connect failed', error, stackTrace);
      _emitConnectionState(ConnectionState.error);
      _scheduleReconnect();
    }
  }

  /// Closes WebSocket and disables reconnect behavior.
  Future<void> disconnect() async {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _stopHeartbeat();
    await _closeActiveChannel();
    _emitConnectionState(ConnectionState.disconnected);
  }

  /// Disposes all resources and closes streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await disconnect();

    await _messageController.close();
    await _connectionStateController.close();
    await _errorController.close();
  }

  /// Sends a signaling envelope to server.
  /// Throws [StateError] if disconnected and not reconnecting.
  void send(SignalingMessage message) {
    final channel = _channel;
    if (channel == null || _state != ConnectionState.connected) {
      throw StateError('Cannot send signaling message while disconnected');
    }

    final payload = jsonEncode(message.toJson());
    channel.sink.add(payload);
    _log.fine('Sent signaling message type=${message.type}');
  }

  /// Sends a message if connected, or buffers it for later delivery
  /// during reconnection. Silently drops if buffer is full.
  void sendOrBuffer(SignalingMessage message) {
    if (_state == ConnectionState.connected) {
      send(message);
    } else if (_state == ConnectionState.reconnecting ||
        _state == ConnectionState.connecting) {
      if (_messageBuffer.length < _maxBufferSize) {
        _messageBuffer.add(message);
        _log.fine('Buffered message type=${message.type} '
            '(${_messageBuffer.length}/$_maxBufferSize)');
      } else {
        _log.warning('Message buffer full, dropping type=${message.type}');
      }
    }
  }

  /// Sends `reconnect` message to resume an active call session.
  void sendReconnect(String callId) {
    send(
      SignalingMessage(
        type: msgReconnect,
        data: <String, dynamic>{
          'call_id': callId,
        },
      ),
    );
  }

  /// Sends `call_initiate` with SDP offer.
  void initiateCall(
    String calleeId,
    String callType,
    String sdpOffer,
    bool hasVideo,
  ) {
    send(
      SignalingMessage(
        type: msgCallInitiate,
        data: <String, dynamic>{
          'callee_id': calleeId,
          'call_type': callType,
          'sdp_offer': sdpOffer,
          'has_video': hasVideo,
        },
      ),
    );
  }

  /// Sends `call_accept` with SDP answer.
  void acceptCall(String callId, String sdpAnswer) {
    send(
      SignalingMessage(
        type: msgCallAccept,
        data: <String, dynamic>{
          'call_id': callId,
          'sdp_answer': sdpAnswer,
        },
      ),
    );
  }

  /// Sends `call_reject` with optional reason.
  void rejectCall(String callId, String reason) {
    send(
      SignalingMessage(
        type: msgCallReject,
        data: <String, dynamic>{
          'call_id': callId,
          'reason': reason,
        },
      ),
    );
  }

  /// Sends `call_end`.
  void endCall(String callId, [String? reason]) {
    send(
      SignalingMessage(
        type: msgCallEnd,
        data: <String, dynamic>{
          'call_id': callId,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        },
      ),
    );
  }

  /// Sends `call_cancel`.
  void cancelCall(String callId) {
    send(
      SignalingMessage(
        type: msgCallCancel,
        data: <String, dynamic>{
          'call_id': callId,
        },
      ),
    );
  }

  /// Sends `ice_candidate` update.
  void sendIceCandidate(
    String callId,
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) {
    send(
      SignalingMessage(
        type: msgIceCandidate,
        data: <String, dynamic>{
          'call_id': callId,
          'candidate': candidate,
          if (sdpMid != null) 'sdp_mid': sdpMid,
          if (sdpMLineIndex != null) 'sdp_mline_index': sdpMLineIndex,
        },
      ),
    );
  }

  /// Sends batched `quality_metrics` to the server.
  void sendQualityMetrics(
    String callId,
    List<Map<String, dynamic>> samples,
  ) {
    if (samples.isEmpty) return;
    send(
      SignalingMessage(
        type: msgQualityMetrics,
        data: <String, dynamic>{
          'call_id': callId,
          'samples': samples,
        },
      ),
    );
  }

  /// Sends `room_create`.
  void createRoom(List<String> participants, String callType) {
    send(
      SignalingMessage(
        type: msgRoomCreate,
        data: <String, dynamic>{
          'participants': participants,
          'call_type': callType,
        },
      ),
    );
  }

  /// Sends `room_invite`.
  void inviteToRoom(String roomId, List<String> invitees) {
    send(
      SignalingMessage(
        type: msgRoomInvite,
        data: <String, dynamic>{
          'room_id': roomId,
          'invitees': invitees,
        },
      ),
    );
  }

  /// Sends `room_join`.
  void joinRoom(String roomId) {
    send(
      SignalingMessage(
        type: msgRoomJoin,
        data: <String, dynamic>{
          'room_id': roomId,
        },
      ),
    );
  }

  /// Sends `room_leave`.
  void leaveRoom(String roomId) {
    send(
      SignalingMessage(
        type: msgRoomLeave,
        data: <String, dynamic>{
          'room_id': roomId,
        },
      ),
    );
  }

  /// Sends `layer_request` to request a specific simulcast layer for a track.
  ///
  /// [roomId] — target room.
  /// [trackSid] — the publisher's track SID.
  /// [layer] — desired quality layer ('h', 'm', 'l').
  void requestLayer(String roomId, String trackSid, String layer) {
    send(
      SignalingMessage(
        type: msgLayerRequest,
        data: <String, dynamic>{
          'room_id': roomId,
          'track_sid': trackSid,
          'layer': layer,
        },
      ),
    );
  }

  Uri _buildUriWithToken(String token) {
    final base = Uri.parse(url);
    final query = Map<String, String>.from(base.queryParameters);
    query['token'] = token;
    return base.replace(queryParameters: query);
  }

  void _handleIncomingRaw(dynamic raw) {
    try {
      final dynamic decoded;
      if (raw is String) {
        decoded = jsonDecode(raw);
      } else if (raw is List<int>) {
        decoded = jsonDecode(utf8.decode(raw));
      } else {
        _log.warning(
          'Ignoring unsupported ws payload type: ${raw.runtimeType}',
        );
        return;
      }

      if (decoded is! Map<String, dynamic>) {
        _log.warning('Ignoring malformed signaling payload: $decoded');
        return;
      }

      final message = SignalingMessage.fromJson(decoded);
      _messageController.add(message);

      if (message.type == msgPong) {
        _handlePong();
      } else if (message.type == msgError) {
        final signalingError = SignalingError.fromData(message.data);
        _errorController.add(signalingError);
        _log.warning('Signaling server error: $signalingError');
      }
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to decode incoming signaling payload',
        error,
        stackTrace,
      );
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_state != ConnectionState.connected) {
        return;
      }

      try {
        send(const SignalingMessage(type: msgPing, data: <String, dynamic>{}));
        _awaitingPong = true;
        _pongTimeoutTimer?.cancel();
        _pongTimeoutTimer = Timer(_pongTimeout, () {
          if (_awaitingPong) {
            _log.warning('Pong timeout, reconnecting signaling socket');
            _forceReconnect();
          }
        });
      } catch (error, stackTrace) {
        _log.warning('Heartbeat ping failed', error, stackTrace);
        _forceReconnect();
      }
    });
  }

  void _handlePong() {
    _awaitingPong = false;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
    _log.fine('Received signaling pong');
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;

    _awaitingPong = false;
  }

  void _forceReconnect() {
    if (_manuallyDisconnected || _disposed) {
      return;
    }

    _stopHeartbeat();
    _closeActiveChannel();
    _scheduleReconnect();
  }

  void _handleConnectionTermination({Object? error, StackTrace? stackTrace}) {
    if (_handlingTermination || _manuallyDisconnected || _disposed) {
      return;
    }

    _handlingTermination = true;

    _stopHeartbeat();
    _closeActiveChannel();

    if (error != null) {
      _emitConnectionState(ConnectionState.error);
      _log.warning('Signaling terminated with error', error, stackTrace);
    }

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manuallyDisconnected || _disposed) {
      return;
    }

    if (_reconnectAttempt >= _reconnectDelaysMs.length) {
      _log.warning(
        'Reconnect attempts exhausted (${_reconnectDelaysMs.length})',
      );
      _emitConnectionState(ConnectionState.disconnected);
      return;
    }

    final delayMs = _reconnectDelaysMs[_reconnectAttempt];
    _reconnectAttempt += 1;

    _emitConnectionState(ConnectionState.reconnecting);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      _handlingTermination = false;
      await connect();
    });
  }

  Future<void> _closeActiveChannel() async {
    final subscription = _channelSubscription;
    _channelSubscription = null;

    if (subscription != null) {
      await subscription.cancel();
    }

    final channel = _channel;
    _channel = null;

    if (channel != null) {
      await channel.sink.close(ws_status.goingAway);
    }
  }

  void _emitConnectionState(ConnectionState state) {
    if (_state == state) return;
    _state = state;
    _connectionStateController.add(state);
    _log.fine('Signaling state changed: $state');
  }

  /// Flushes buffered messages that were queued during reconnection.
  void _flushMessageBuffer() {
    if (_messageBuffer.isEmpty) return;

    final buffered = List<SignalingMessage>.from(_messageBuffer);
    _messageBuffer.clear();

    _log.info('Flushing ${buffered.length} buffered messages');
    for (final message in buffered) {
      try {
        send(message);
      } catch (e) {
        _log.warning('Failed to flush buffered message: $e');
      }
    }
  }
}
