import 'dart:async';

import 'package:logging/logging.dart';

import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/core/network/network_monitor.dart';
import 'package:lalo/core/network/signaling_client.dart';

/// Reconnection state.
enum ReconnectionState {
  /// Normal operation, no reconnection in progress.
  idle,

  /// Reconnecting signaling WebSocket.
  reconnectingSignaling,

  /// Restarting ICE to recover media path.
  restartingIce,

  /// Successfully reconnected.
  reconnected,

  /// All reconnection attempts failed.
  failed,
}

/// Describes a reconnection attempt result.
class ReconnectionAttempt {
  const ReconnectionAttempt({
    required this.attempt,
    required this.maxAttempts,
    required this.reason,
    required this.succeeded,
    this.error,
  });

  final int attempt;
  final int maxAttempts;
  final String reason;
  final bool succeeded;
  final String? error;
}

/// Configuration for reconnection behavior.
class ReconnectionConfig {
  const ReconnectionConfig({
    this.maxAttempts = 3,
    this.backoffMs = const <int>[0, 1000, 3000],
    this.iceRestartTimeoutMs = 5000,
    this.signalingReconnectTimeoutMs = 10000,
    this.graceWindowMs = 30000,
  });

  final int maxAttempts;
  final List<int> backoffMs;
  final int iceRestartTimeoutMs;
  final int signalingReconnectTimeoutMs;
  final int graceWindowMs;
}

/// Coordinates reconnection across multiple layers:
/// network change → signaling reconnect → ICE restart → session resume.
///
/// This is the single point of coordination for reconnection logic.
/// It listens to network changes and signaling state, and orchestrates
/// ICE restarts and session recovery.
class ReconnectionManager {
  ReconnectionManager({
    required this.signalingClient,
    required this.peerConnectionManager,
    required this.networkMonitor,
    this.config = const ReconnectionConfig(),
    this.activeCallId,
  });

  final SignalingClient signalingClient;
  final PeerConnectionManager peerConnectionManager;
  final NetworkMonitor networkMonitor;
  final ReconnectionConfig config;

  /// The call ID of the currently active call. Must be set before start().
  String? activeCallId;

  static final Logger _log = Logger('ReconnectionManager');

  final StreamController<ReconnectionState> _stateController =
      StreamController<ReconnectionState>.broadcast();
  final StreamController<ReconnectionAttempt> _attemptController =
      StreamController<ReconnectionAttempt>.broadcast();

  StreamSubscription<NetworkChange>? _networkSub;
  StreamSubscription<ConnectionState>? _signalingSub;
  StreamSubscription<SignalingMessage>? _messageSub;

  ReconnectionState _state = ReconnectionState.idle;
  int _currentAttempt = 0;
  Timer? _graceTimer;
  bool _disposed = false;

  /// Stream of reconnection state changes.
  Stream<ReconnectionState> get onStateChange => _stateController.stream;

  /// Stream of individual reconnection attempts.
  Stream<ReconnectionAttempt> get onAttempt => _attemptController.stream;

  /// Current reconnection state.
  ReconnectionState get state => _state;

  /// Start listening for network changes and signaling state.
  void start() {
    if (_disposed) throw StateError('ReconnectionManager is disposed');

    // Listen for network interface changes (WiFi ↔ Cellular)
    _networkSub = networkMonitor.onNetworkChange.listen(_handleNetworkChange);

    // Listen for signaling connection state
    _signalingSub =
        signalingClient.onConnectionState.listen(_handleSignalingState);

    // Listen for reconnect-related server messages
    _messageSub = signalingClient.onMessage.listen(_handleServerMessage);
  }

  /// Stop the reconnection manager.
  void stop() {
    _networkSub?.cancel();
    _networkSub = null;
    _signalingSub?.cancel();
    _signalingSub = null;
    _messageSub?.cancel();
    _messageSub = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _currentAttempt = 0;
    _setState(ReconnectionState.idle);
  }

  /// Dispose all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    await _stateController.close();
    await _attemptController.close();
  }

  /// Handle a network interface change (WiFi ↔ Cellular handover).
  void _handleNetworkChange(NetworkChange change) {
    if (activeCallId == null) return;

    if (change.isDisconnect) {
      _log.warning('Network lost during active call');
      _beginReconnection('network_lost');
      return;
    }

    if (change.isHandover || change.isReconnect) {
      _log.info('Network handover detected: $change');
      // Proactive ICE restart on network change
      _triggerIceRestart('network_handover');
    }
  }

  /// Handle signaling WebSocket state changes.
  void _handleSignalingState(ConnectionState state) {
    if (activeCallId == null) return;

    switch (state) {
      case ConnectionState.connected:
        // WebSocket reconnected — send session resume
        if (_state == ReconnectionState.reconnectingSignaling) {
          _sendSessionResume();
        }
      case ConnectionState.reconnecting:
        if (_state == ReconnectionState.idle) {
          _setState(ReconnectionState.reconnectingSignaling);
        }
      case ConnectionState.disconnected:
        if (_state != ReconnectionState.failed) {
          _beginReconnection('signaling_lost');
        }
      case ConnectionState.connecting:
      case ConnectionState.error:
        break; // Handled by reconnect logic
    }
  }

  /// Handle reconnect-related messages from server.
  void _handleServerMessage(SignalingMessage message) {
    switch (message.type) {
      case msgSessionResumed:
        _handleSessionResumed(message.data);
      case msgPeerReconnecting:
        _log.info('Peer is reconnecting');
        // UI can listen to the message stream directly
      case msgPeerReconnected:
        _log.info('Peer has reconnected');
      default:
        break;
    }
  }

  void _handleSessionResumed(Map<String, dynamic> data) {
    _log.info('Session resumed: $data');
    _graceTimer?.cancel();
    _currentAttempt = 0;

    // Trigger ICE restart to establish new media path
    _triggerIceRestart('session_resumed');
  }

  /// Begin the reconnection process.
  void _beginReconnection(String reason) {
    if (_state == ReconnectionState.failed) return;

    _log.info('Beginning reconnection: $reason');
    _setState(ReconnectionState.reconnectingSignaling);

    // Start grace window timer
    _graceTimer?.cancel();
    _graceTimer = Timer(
      Duration(milliseconds: config.graceWindowMs),
      () {
        if (_state != ReconnectionState.idle &&
            _state != ReconnectionState.reconnected) {
          _log.warning('Grace window expired');
          _setState(ReconnectionState.failed);
          _emitAttempt(
            reason: reason,
            succeeded: false,
            error: 'Grace window expired',
          );
        }
      },
    );
  }

  /// Trigger ICE restart with attempt tracking.
  void _triggerIceRestart(String reason) {
    if (_currentAttempt >= config.maxAttempts) {
      _log.warning('Max ICE restart attempts reached');
      _setState(ReconnectionState.failed);
      _emitAttempt(
        reason: reason,
        succeeded: false,
        error: 'Max attempts (${ config.maxAttempts}) reached',
      );
      return;
    }

    _currentAttempt++;
    _setState(ReconnectionState.restartingIce);
    _log.info(
      'ICE restart attempt $_currentAttempt/${config.maxAttempts}: $reason',
    );

    peerConnectionManager.restartIce().then((_) {
      _log.info('ICE restart initiated successfully');
      _emitAttempt(reason: reason, succeeded: true);

      // Wait for ICE to reconnect, handled by ICE state callback
      // The peer_connection_manager will emit connected/completed state
    }).catchError((Object error) {
      _log.warning('ICE restart failed', error);
      _emitAttempt(
        reason: reason,
        succeeded: false,
        error: error.toString(),
      );

      if (_currentAttempt >= config.maxAttempts) {
        _setState(ReconnectionState.failed);
      }
    });
  }

  /// Send a session resume message to the server after WSS reconnect.
  void _sendSessionResume() {
    final callId = activeCallId;
    if (callId == null) return;

    try {
      signalingClient.sendReconnect(callId);
      _log.info('Sent reconnect for call=$callId');
    } catch (e) {
      _log.warning('Failed to send reconnect: $e');
    }
  }

  /// Called externally when ICE connection state becomes connected/completed.
  void onIceConnected() {
    if (_state == ReconnectionState.restartingIce ||
        _state == ReconnectionState.reconnectingSignaling) {
      _graceTimer?.cancel();
      _currentAttempt = 0;
      _setState(ReconnectionState.reconnected);

      // Transition back to idle after a brief delay
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (_state == ReconnectionState.reconnected) {
          _setState(ReconnectionState.idle);
        }
      });
    }
  }

  /// Called externally when ICE connection fails.
  void onIceFailed() {
    if (_state == ReconnectionState.idle && activeCallId != null) {
      _triggerIceRestart('ice_failed');
    }
  }

  void _setState(ReconnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void _emitAttempt({
    required String reason,
    required bool succeeded,
    String? error,
  }) {
    if (!_attemptController.isClosed) {
      _attemptController.add(
        ReconnectionAttempt(
          attempt: _currentAttempt,
          maxAttempts: config.maxAttempts,
          reason: reason,
          succeeded: succeeded,
          error: error,
        ),
      );
    }
  }
}
