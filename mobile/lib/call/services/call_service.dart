import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'package:lalo/call/models/call_session.dart';
import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/core/network/network_monitor.dart';
import 'package:lalo/core/network/reconnection_manager.dart';
import 'package:lalo/core/network/signaling_client.dart';

/// Application-level call orchestrator.
///
/// Manages call lifecycle, quality monitoring, ABR, and reconnection.
class CallService {
  CallService({
    MediaManager? mediaManager,
    SignalingClient? signalingClient,
  })  : _mediaManager = mediaManager ?? MediaManager(),
        _signalingClient = signalingClient;

  final MediaManager _mediaManager;
  final SignalingClient? _signalingClient;

  final StreamController<CallSession> _incomingCallController =
      StreamController<CallSession>.broadcast();
  final StreamController<CallState> _callStateController =
      StreamController<CallState>.broadcast();
  final StreamController<webrtc.MediaStream?> _remoteStreamController =
      StreamController<webrtc.MediaStream?>.broadcast();
  final StreamController<QualityStats> _qualityStatsController =
      StreamController<QualityStats>.broadcast();
  final StreamController<ReconnectionState> _reconnectionStateController =
      StreamController<ReconnectionState>.broadcast();

  CallSession? _currentSession;
  bool _isMuted = false;
  bool _isOnHold = false;
  bool _isSpeakerOn = false;

  QualityMonitor? qualityMonitor;
  AbrController? abrController;
  StreamSubscription<QualityStats>? _qualityStatsSubscription;
  final List<Map<String, dynamic>> _metricsBatch = [];
  static const int _metricsBatchSize = 5;

  // Reconnection
  NetworkMonitor? _networkMonitor;
  ReconnectionManager? _reconnectionManager;
  StreamSubscription<ReconnectionState>? _reconnectionStateSub;
  StreamSubscription<SignalingMessage>? _reconnectMessageSub;

  Stream<CallSession> get onIncomingCall => _incomingCallController.stream;
  Stream<CallState> get onCallState => _callStateController.stream;
  Stream<webrtc.MediaStream?> get onRemoteStream =>
      _remoteStreamController.stream;
  Stream<QualityStats> get onQualityStats => _qualityStatsController.stream;
  Stream<ReconnectionState> get onReconnectionState =>
      _reconnectionStateController.stream;

  /// Whether video was disabled by ABR due to low bandwidth.
  bool get isVideoDisabledByAbr =>
      abrController?.isVideoDisabledByAbr ?? false;

  /// Whether the call is currently reconnecting.
  bool get isReconnecting =>
      _reconnectionManager?.state == ReconnectionState.reconnectingSignaling ||
      _reconnectionManager?.state == ReconnectionState.restartingIce;

  CallSession? get currentSession => _currentSession;
  String? get currentCallId => _currentSession?.callId;
  bool get isMuted => _isMuted;
  bool get isOnHold => _isOnHold;
  bool get isSpeakerOn => _isSpeakerOn;
  webrtc.MediaStream? get localStream => _mediaManager.localStream;

  Future<CallSession> startCall({
    required String callId,
    required String callerId,
    required String calleeId,
    required bool hasVideo,
    CallType callType = CallType.oneToOne,
  }) async {
    _currentSession = CallSession(
      callId: callId,
      callerId: callerId,
      calleeId: calleeId,
      callType: callType,
      state: CallState.outgoing,
      topology: CallTopology.peerToPeer,
      hasVideo: hasVideo,
      createdAt: DateTime.now().toUtc(),
    );
    _callStateController.add(CallState.outgoing);
    return _currentSession!;
  }

  Future<void> acceptCall(String callId) async {
    if (_currentSession == null || _currentSession!.callId != callId) {
      _currentSession = CallSession(
        callId: callId,
        callerId: '',
        calleeId: '',
        callType: CallType.oneToOne,
        state: CallState.connecting,
        topology: CallTopology.peerToPeer,
        createdAt: DateTime.now().toUtc(),
      );
    }
    _callStateController.add(CallState.connecting);
  }

  /// Starts quality monitoring once call becomes active.
  void startQualityMonitoring(PeerConnectionManager peerConnectionManager) {
    qualityMonitor = QualityMonitor(peerConnectionManager);
    qualityMonitor!.start();

    _qualityStatsSubscription =
        qualityMonitor!.onQualityStats.listen(_handleQualityStats);

    // Start ABR fast loop for adaptive encoding
    abrController = AbrController(
      peerConnectionManager: peerConnectionManager,
      qualityMonitor: qualityMonitor!,
      mediaManager: _mediaManager,
    );
    abrController!.start();

    // Start reconnection monitoring
    _startReconnectionMonitoring(peerConnectionManager);
  }

  /// Starts the reconnection manager for network resilience.
  void _startReconnectionMonitoring(
      PeerConnectionManager peerConnectionManager,
  ) {
    final sigClient = _signalingClient;
    if (sigClient == null) return;

    _networkMonitor = NetworkMonitor();
    _networkMonitor!.start();

    _reconnectionManager = ReconnectionManager(
      signalingClient: sigClient,
      peerConnectionManager: peerConnectionManager,
      networkMonitor: _networkMonitor!,
      activeCallId: _currentSession?.callId,
    );
    _reconnectionManager!.start();

    // Listen to reconnection state changes
    _reconnectionStateSub =
        _reconnectionManager!.onStateChange.listen(_handleReconnectionState);

    // Listen to reconnect-related signaling messages
    _reconnectMessageSub = sigClient.onMessage.listen(_handleReconnectMessage);

    // Forward ICE state events to the reconnection manager
    peerConnectionManager.onIceConnectionState.listen((state) {
      if (state == webrtc.RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == webrtc.RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _reconnectionManager?.onIceConnected();
      } else if (state == webrtc.RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _reconnectionManager?.onIceFailed();
      }
    });
  }

  void _handleReconnectionState(ReconnectionState state) {
    _reconnectionStateController.add(state);

    switch (state) {
      case ReconnectionState.reconnectingSignaling:
      case ReconnectionState.restartingIce:
        _callStateController.add(CallState.reconnecting);
      case ReconnectionState.reconnected:
        _callStateController.add(CallState.active);
      case ReconnectionState.failed:
        // End the call gracefully after reconnection failure
        final callId = _currentSession?.callId;
        if (callId != null) {
          endCall(callId, reason: 'reconnect_failed');
        }
      case ReconnectionState.idle:
        break;
    }
  }

  void _handleReconnectMessage(SignalingMessage message) {
    switch (message.type) {
      case msgPeerReconnecting:
        // Peer is reconnecting — UI can show "Peer reconnecting..." overlay
        _callStateController.add(CallState.reconnecting);
      case msgPeerReconnected:
        // Peer reconnected — resume active state
        _callStateController.add(CallState.active);
      case msgSessionResumed:
        // Session resumed after our own reconnect
        _callStateController.add(CallState.active);
      default:
        break;
    }
  }

  void _stopReconnectionMonitoring() {
    _reconnectionStateSub?.cancel();
    _reconnectionStateSub = null;
    _reconnectMessageSub?.cancel();
    _reconnectMessageSub = null;
    _reconnectionManager?.dispose();
    _reconnectionManager = null;
    _networkMonitor?.dispose();
    _networkMonitor = null;
  }

  void _handleQualityStats(QualityStats stats) {
    _qualityStatsController.add(stats);

    // Batch and send via signaling
    final callId = _currentSession?.callId;
    if (callId == null) return;

    final resolution = (stats.frameWidth != null && stats.frameHeight != null)
        ? '${stats.frameWidth}x${stats.frameHeight}'
        : '';

    _metricsBatch.add(<String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'direction': 'send',
      'rtt_ms': (stats.roundTripTimeMs ?? 0).toInt(),
      'loss_pct': stats.lossPercent,
      'jitter_ms': stats.jitterMs ?? 0.0,
      'bitrate_kbps': (stats.bytesSent > 0)
          ? stats.bytesSent ~/ 125 // rough bytes/s to kbps
          : 0,
      'framerate': (stats.framesPerSecond ?? 0).toInt(),
      'resolution': resolution,
      'network_tier': stats.tier.name,
    });

    if (_metricsBatch.length >= _metricsBatchSize) {
      _flushMetrics(callId);
    }
  }

  void _flushMetrics(String callId) {
    if (_metricsBatch.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(_metricsBatch);
    _metricsBatch.clear();

    _signalingClient?.sendQualityMetrics(callId, batch);
  }

  void _stopQualityMonitoring() {
    // Flush remaining metrics before stopping
    final callId = _currentSession?.callId;
    if (callId != null) {
      _flushMetrics(callId);
    }

    _qualityStatsSubscription?.cancel();
    _qualityStatsSubscription = null;
    abrController?.stop();
    abrController = null;
    qualityMonitor?.stop();
    qualityMonitor = null;
  }

  Future<void> rejectCall(String callId) async {
    if (_currentSession?.callId == callId) {
      _currentSession = _currentSession!.copyWith(
        state: CallState.ended,
        endedAt: DateTime.now().toUtc(),
        endReason: 'rejected',
      );
    }
    _callStateController.add(CallState.ended);
  }

  Future<void> endCall(String callId, {String? reason}) async {
    _stopQualityMonitoring();
    _stopReconnectionMonitoring();
    if (_currentSession?.callId == callId) {
      _currentSession = _currentSession!.copyWith(
        state: CallState.ended,
        endedAt: DateTime.now().toUtc(),
        endReason: reason,
      );
    }
    _callStateController.add(CallState.ended);
  }

  Future<void> setMuted(bool muted) async {
    if (_isMuted == muted) return;
    _isMuted = muted;
    if (_mediaManager.isMicrophoneMuted != muted) {
      _mediaManager.toggleMicrophone();
    }
  }

  Future<void> toggleMute() async {
    _isMuted = _mediaManager.toggleMicrophone();
  }

  Future<void> toggleHold(bool onHold) async {
    _isOnHold = onHold;
  }

  Future<void> toggleCamera() async {
    _mediaManager.toggleCamera();
  }

  Future<void> switchCamera() async {
    await _mediaManager.switchCamera();
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await _mediaManager.setAudioOutput(
      _isSpeakerOn ? AudioOutput.speaker : AudioOutput.earpiece,
    );
  }

  Future<void> setRemoteStream(webrtc.MediaStream? stream) async {
    _remoteStreamController.add(stream);
  }

  Future<void> setCallState(CallState state) async {
    _callStateController.add(state);
  }

  Future<void> emitIncomingCall(CallSession session) async {
    _currentSession = session;
    _incomingCallController.add(session);
    _callStateController.add(CallState.incoming);
  }

  Future<void> dispose() async {
    _stopQualityMonitoring();
    _stopReconnectionMonitoring();
    await _incomingCallController.close();
    await _callStateController.close();
    await _remoteStreamController.close();
    await _qualityStatsController.close();
    await _reconnectionStateController.close();
  }
}

