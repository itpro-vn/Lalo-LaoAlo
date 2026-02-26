import 'dart:async';

import 'package:lalo/call/models/group_call_models.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/signaling_client.dart';

/// Reconnection state for a group call room.
enum GroupCallReconnectionState {
  /// No active reconnection.
  idle,

  /// WebSocket reconnected, re-joining room for fresh credentials.
  rejoining,

  /// Successfully re-joined room after reconnection.
  rejoined,

  /// Reconnection failed.
  failed,
}

/// Orchestrates group-call room lifecycle across API and signaling layers.
class GroupCallService {
  /// Creates a [GroupCallService].
  GroupCallService({
    required SignalingClient signalingClient,
    required ApiClient apiClient,
    required MediaManager mediaManager,
  })  : _signalingClient = signalingClient,
        _apiClient = apiClient,
        _mediaManager = mediaManager {
    _messageSubscription =
        _signalingClient.onMessage.listen(_handleSignalMessage);
    _connectionSubscription =
        _signalingClient.onConnectionState.listen(_handleConnectionState);
  }

  final SignalingClient _signalingClient;
  final ApiClient _apiClient;
  final MediaManager _mediaManager;

  /// The currently active room ID, or null if not in a room.
  String? _activeRoomId;

  /// Whether we are currently reconnecting.
  var _reconnectionState = GroupCallReconnectionState.idle;

  final StreamController<RoomCreatedEvent> _roomCreatedController =
      StreamController<RoomCreatedEvent>.broadcast();
  final StreamController<RoomInvitationEvent> _roomInvitationController =
      StreamController<RoomInvitationEvent>.broadcast();
  final StreamController<RoomClosedEvent> _roomClosedController =
      StreamController<RoomClosedEvent>.broadcast();
  final StreamController<ParticipantEvent> _participantJoinedController =
      StreamController<ParticipantEvent>.broadcast();
  final StreamController<ParticipantEvent> _participantLeftController =
      StreamController<ParticipantEvent>.broadcast();
  final StreamController<LayerUpdateEvent> _layerUpdateController =
      StreamController<LayerUpdateEvent>.broadcast();
  final StreamController<PolicyUpdateEvent> _policyUpdateController =
      StreamController<PolicyUpdateEvent>.broadcast();
  final StreamController<GroupCallReconnectionState>
      _reconnectionStateController =
      StreamController<GroupCallReconnectionState>.broadcast();

  StreamSubscription<SignalingMessage>? _messageSubscription;
  StreamSubscription<ConnectionState>? _connectionSubscription;

  /// Emits parsed `room_created` events from signaling.
  Stream<RoomCreatedEvent> get onRoomCreated => _roomCreatedController.stream;

  /// Emits parsed `room_invitation` events from signaling.
  Stream<RoomInvitationEvent> get onRoomInvitation =>
      _roomInvitationController.stream;

  /// Emits parsed `room_closed` events from signaling.
  Stream<RoomClosedEvent> get onRoomClosed => _roomClosedController.stream;

  /// Emits parsed `participant_joined` events from signaling.
  Stream<ParticipantEvent> get onParticipantJoined =>
      _participantJoinedController.stream;

  /// Emits parsed `participant_left` events from signaling.
  Stream<ParticipantEvent> get onParticipantLeft =>
      _participantLeftController.stream;

  /// Emits parsed `layer_update` events from signaling.
  Stream<LayerUpdateEvent> get onLayerUpdate => _layerUpdateController.stream;

  /// Emits parsed `policy_update` events from signaling.
  Stream<PolicyUpdateEvent> get onPolicyUpdate =>
      _policyUpdateController.stream;

  /// Emits group call reconnection state changes.
  Stream<GroupCallReconnectionState> get onReconnectionState =>
      _reconnectionStateController.stream;

  /// The currently active room ID, or null if not in a room.
  String? get activeRoomId => _activeRoomId;

  /// Current reconnection state.
  GroupCallReconnectionState get reconnectionState => _reconnectionState;

  /// Creates room via API and joins via signaling.
  Future<RoomCreatedEvent> createRoom(
    List<String> participants,
    String callType,
  ) async {
    final payload = await _apiClient.createRoom(participants, callType);
    final event = RoomCreatedEvent.fromJson(payload);

    if (event.roomId.isEmpty) {
      throw StateError('createRoom response missing roomId');
    }

    _activeRoomId = event.roomId;
    _signalingClient.joinRoom(event.roomId);
    return event;
  }

  /// Joins room via API and then signaling.
  Future<RoomCreatedEvent> joinRoom(String roomId) async {
    final payload = await _apiClient.joinRoom(roomId);
    final event = RoomCreatedEvent.fromJson(<String, dynamic>{
      ...payload,
      if (!payload.containsKey('room_id') && !payload.containsKey('roomId'))
        'room_id': roomId,
    });

    await _mediaManager.initialize();
    _activeRoomId = roomId;
    _signalingClient.joinRoom(roomId);
    return event;
  }

  /// Leaves room in signaling and API.
  Future<void> leaveRoom(String roomId) async {
    _signalingClient.leaveRoom(roomId);
    await _apiClient.leaveRoom(roomId);
    if (_activeRoomId == roomId) {
      _activeRoomId = null;
    }
  }

  /// Invites additional participants via signaling.
  Future<void> inviteToRoom(String roomId, List<String> invitees) async {
    _signalingClient.inviteToRoom(roomId, invitees);
  }

  /// Requests a specific simulcast layer for a track from the SFU.
  ///
  /// [roomId] — target room.
  /// [trackSid] — publisher's track SID.
  /// [layer] — desired layer RID ('h', 'm', 'l').
  void requestLayer(String roomId, String trackSid, String layer) {
    _signalingClient.requestLayer(roomId, trackSid, layer);
  }

  /// Sends quality metrics to the server for policy engine evaluation.
  ///
  /// [callId] — call/room identifier.
  /// [samples] — list of quality metric samples.
  void sendQualityMetrics(
    String callId,
    List<Map<String, dynamic>> samples,
  ) {
    _signalingClient.sendQualityMetrics(callId, samples);
  }

  void _handleConnectionState(ConnectionState state) {
    if (state == ConnectionState.connected && _activeRoomId != null) {
      _handleSignalingReconnected();
    }
  }

  /// Re-joins the active room after signaling reconnection to get fresh
  /// LiveKit credentials. The backend's room grace period keeps us "in room"
  /// during the transient disconnect, so other participants don't see churn.
  Future<void> _handleSignalingReconnected() async {
    final roomId = _activeRoomId;
    if (roomId == null) return;

    _setReconnectionState(GroupCallReconnectionState.rejoining);

    try {
      // Re-join via signaling to get fresh LiveKit credentials.
      // The backend handles this as a re-join (user still tracked in room).
      _signalingClient.joinRoom(roomId);
      _setReconnectionState(GroupCallReconnectionState.rejoined);

      // Auto-reset to idle after state is consumed.
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (_reconnectionState == GroupCallReconnectionState.rejoined) {
          _setReconnectionState(GroupCallReconnectionState.idle);
        }
      });
    } on Object {
      _setReconnectionState(GroupCallReconnectionState.failed);
    }
  }

  void _setReconnectionState(GroupCallReconnectionState state) {
    _reconnectionState = state;
    _reconnectionStateController.add(state);
  }

  void _handleSignalMessage(SignalingMessage message) {
    switch (message.type) {
      case msgRoomCreated:
        _roomCreatedController.add(RoomCreatedEvent.fromJson(message.data));
        return;
      case msgRoomInvitation:
        _roomInvitationController
            .add(RoomInvitationEvent.fromJson(message.data));
        return;
      case msgRoomClosed:
        _roomClosedController.add(RoomClosedEvent.fromJson(message.data));
        // Room is closed — clear active room
        final event = RoomClosedEvent.fromJson(message.data);
        if (event.roomId == _activeRoomId) {
          _activeRoomId = null;
        }
        return;
      case msgParticipantJoined:
        _participantJoinedController
            .add(ParticipantEvent.fromJson(message.data));
        return;
      case msgParticipantLeft:
        _participantLeftController.add(ParticipantEvent.fromJson(message.data));
        return;
      case msgLayerUpdate:
        _layerUpdateController.add(LayerUpdateEvent.fromJson(message.data));
        return;
      case msgPolicyUpdate:
        _policyUpdateController
            .add(PolicyUpdateEvent.fromJson(message.data));
        return;
      case msgParticipantMediaChanged:
      case msgIncomingCall:
      case msgCallAccepted:
      case msgCallRejected:
      case msgCallEnded:
      case msgCallCancelled:
      case msgPong:
      case msgError:
      case msgCallInitiate:
      case msgCallAccept:
      case msgCallReject:
      case msgCallEnd:
      case msgCallCancel:
      case msgIceCandidate:
      case msgQualityMetrics:
      case msgPing:
      case msgRoomCreate:
      case msgRoomInvite:
      case msgRoomJoin:
      case msgRoomLeave:
      case msgLayerRequest:
        return;
    }
  }

  /// Releases stream and subscription resources.
  Future<void> dispose() async {
    _activeRoomId = null;
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    await _roomCreatedController.close();
    await _roomInvitationController.close();
    await _roomClosedController.close();
    await _participantJoinedController.close();
    await _participantLeftController.close();
    await _layerUpdateController.close();
    await _policyUpdateController.close();
    await _reconnectionStateController.close();
  }
}
