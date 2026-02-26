import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/core/network/network_monitor.dart';
import 'package:lalo/core/network/reconnection_manager.dart';
import 'package:lalo/core/network/signaling_client.dart';

class MockNetworkMonitor implements NetworkMonitor {
  final StreamController<NetworkChange> _controller =
      StreamController<NetworkChange>.broadcast();

  @override
  Stream<NetworkChange> get onNetworkChange => _controller.stream;

  void emit(NetworkChange change) => _controller.add(change);

  Future<void> close() => _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockSignalingClient implements SignalingClient {
  final StreamController<ConnectionState> _connectionStateController =
      StreamController<ConnectionState>.broadcast();
  final StreamController<SignalingMessage> _messageController =
      StreamController<SignalingMessage>.broadcast();

  final List<String> reconnectCallIds = <String>[];
  bool throwOnSendReconnect = false;

  @override
  Stream<ConnectionState> get onConnectionState =>
      _connectionStateController.stream;

  @override
  Stream<SignalingMessage> get onMessage => _messageController.stream;

  @override
  void sendReconnect(String callId) {
    if (throwOnSendReconnect) {
      throw StateError('sendReconnect failed');
    }
    reconnectCallIds.add(callId);
  }

  void emitConnectionState(ConnectionState state) {
    _connectionStateController.add(state);
  }

  void emitMessage(SignalingMessage message) {
    _messageController.add(message);
  }

  Future<void> close() async {
    await _connectionStateController.close();
    await _messageController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockPeerConnectionManager implements PeerConnectionManager {
  int restartIceCallCount = 0;
  Object? restartIceError;

  @override
  Future<void> restartIce() {
    restartIceCallCount++;
    final error = restartIceError;
    if (error != null) {
      return Future<void>.error(error);
    }
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NetworkChange _change(NetworkType previous, NetworkType current) {
  return NetworkChange(
    previousType: previous,
    currentType: current,
    timestamp: DateTime.now(),
  );
}

void main() {
  group('ReconnectionManager behavior', () {
    late MockNetworkMonitor networkMonitor;
    late MockSignalingClient signalingClient;
    late MockPeerConnectionManager peerConnectionManager;
    late ReconnectionManager manager;

    Future<void> flush() => Future<void>.delayed(Duration.zero);

    setUp(() {
      networkMonitor = MockNetworkMonitor();
      signalingClient = MockSignalingClient();
      peerConnectionManager = MockPeerConnectionManager();
      manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-123',
      );
      manager.start();
    });

    tearDown(() async {
      await manager.dispose();
      await networkMonitor.close();
      await signalingClient.close();
    });

    test('network handover (WiFi→Cellular) triggers ICE restart', () async {
      final attempts = <ReconnectionAttempt>[];
      final sub = manager.onAttempt.listen(attempts.add);

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);
      expect(attempts, hasLength(1));
      expect(attempts.single.reason, 'network_handover');
      expect(attempts.single.succeeded, isTrue);

      await sub.cancel();
    });

    test(
        'network disconnect triggers signaling reconnect + resume + ICE restart',
        () async {
      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.none));
      await flush();

      expect(manager.state, ReconnectionState.reconnectingSignaling);

      signalingClient.emitConnectionState(ConnectionState.connected);
      await flush();
      expect(signalingClient.reconnectCallIds, <String>['call-123']);

      signalingClient.emitMessage(
        const SignalingMessage(
          type: msgSessionResumed,
          data: <String, dynamic>{'call_id': 'call-123'},
        ),
      );
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);
    });

    test('network reconnect (none→wifi) triggers ICE restart', () async {
      networkMonitor.emit(_change(NetworkType.none, NetworkType.wifi));
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);
    });

    test('max reconnection attempts reached transitions to failed state',
        () async {
      await manager.dispose();
      manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-123',
        config: const ReconnectionConfig(
          maxAttempts: 2,
          backoffMs: <int>[
            0,
            0,
            0,
          ], // No backoff so rapid events execute immediately
        ),
      );
      manager.start();

      final attempts = <ReconnectionAttempt>[];
      final sub = manager.onAttempt.listen(attempts.add);

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
      networkMonitor.emit(_change(NetworkType.cellular, NetworkType.wifi));
      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 2);
      expect(manager.state, ReconnectionState.failed);
      expect(attempts.last.succeeded, isFalse);
      expect(attempts.last.error, contains('Max attempts (2) reached'));

      await sub.cancel();
    });

    test('session resumed message triggers ICE restart', () async {
      final attempts = <ReconnectionAttempt>[];
      final sub = manager.onAttempt.listen(attempts.add);

      signalingClient.emitMessage(
        const SignalingMessage(
          type: msgSessionResumed,
          data: <String, dynamic>{'call_id': 'call-123'},
        ),
      );
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);
      expect(attempts.single.reason, 'session_resumed');

      await sub.cancel();
    });

    test('successful ICE connection transitions to reconnected then idle', () {
      return () async {
        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();
        expect(manager.state, ReconnectionState.restartingIce);

        manager.onIceConnected();
        expect(manager.state, ReconnectionState.reconnected);

        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(manager.state, ReconnectionState.idle);
      }();
    });

    test('grace window expiry transitions to failed state', () async {
      manager.stop();
      manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-123',
        config: const ReconnectionConfig(graceWindowMs: 100),
      );
      manager.start();

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.none));
      await flush();
      expect(manager.state, ReconnectionState.reconnectingSignaling);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await flush();

      expect(manager.state, ReconnectionState.failed);
    });

    test('backoff timing config matches [0, 1000, 3000]ms', () {
      expect(manager.config.backoffMs, <int>[0, 1000, 3000]);
    });

    test(
        'state transitions: idle → reconnectingSignaling → restartingIce → reconnected → idle',
        () {
      return () async {
        final transitions = <ReconnectionState>[];
        final sub = manager.onStateChange.listen(transitions.add);

        expect(manager.state, ReconnectionState.idle);

        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.none));
        await flush();

        signalingClient.emitMessage(
          const SignalingMessage(
            type: msgSessionResumed,
            data: <String, dynamic>{'call_id': 'call-123'},
          ),
        );
        await flush();

        manager.onIceConnected();
        await flush();

        await Future<void>.delayed(const Duration(milliseconds: 2100));

        expect(
          transitions,
          <ReconnectionState>[
            ReconnectionState.reconnectingSignaling,
            ReconnectionState.restartingIce,
            ReconnectionState.reconnected,
            ReconnectionState.idle,
          ],
        );

        await sub.cancel();
      }();
    });

    test('dispose cleans up subscriptions and closes streams', () async {
      final stateDone = expectLater(manager.onStateChange, emitsDone);
      final attemptDone = expectLater(manager.onAttempt, emitsDone);

      await manager.dispose();
      await stateDone;
      await attemptDone;

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
      signalingClient.emitConnectionState(ConnectionState.connected);
      signalingClient.emitMessage(
        const SignalingMessage(
          type: msgSessionResumed,
          data: <String, dynamic>{},
        ),
      );
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 0);
      expect(signalingClient.reconnectCallIds, isEmpty);
    });

    group('backoff timing', () {
      test('first attempt (backoff=0ms) executes immediately', () async {
        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();

        // backoff[0] = 0ms, so should execute synchronously
        expect(peerConnectionManager.restartIceCallCount, 1);
        expect(manager.state, ReconnectionState.restartingIce);
      });

      test('second attempt waits for backoff delay', () async {
        await manager.dispose();
        manager = ReconnectionManager(
          signalingClient: signalingClient,
          peerConnectionManager: peerConnectionManager,
          networkMonitor: networkMonitor,
          activeCallId: 'call-123',
          config: const ReconnectionConfig(
            maxAttempts: 3,
            backoffMs: <int>[0, 50, 100], // Short delays for test
            iceRestartTimeoutMs: 999999, // Disable ICE timeout
          ),
        );
        manager.start();

        // First attempt: immediate
        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();
        expect(peerConnectionManager.restartIceCallCount, 1);

        // Second handover during ICE restart: 50ms backoff
        networkMonitor.emit(_change(NetworkType.cellular, NetworkType.wifi));
        await flush();
        // Not yet executed (50ms backoff pending)
        expect(peerConnectionManager.restartIceCallCount, 1);

        // Wait for backoff to fire
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(peerConnectionManager.restartIceCallCount, 2);
      });
    });

    group('auto-retry on ICE restart failure', () {
      test('auto-retries with backoff after ICE restart failure', () async {
        await manager.dispose();
        peerConnectionManager.restartIceError = StateError('ICE failed');
        manager = ReconnectionManager(
          signalingClient: signalingClient,
          peerConnectionManager: peerConnectionManager,
          networkMonitor: networkMonitor,
          activeCallId: 'call-123',
          config: const ReconnectionConfig(
            maxAttempts: 3,
            backoffMs: <int>[0, 10, 20],
          ),
        );
        manager.start();

        final attempts = <ReconnectionAttempt>[];
        final sub = manager.onAttempt.listen(attempts.add);

        // Trigger first attempt (fails immediately, auto-retries)
        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();

        // First attempt fired + failed → auto-retry with 10ms backoff
        expect(peerConnectionManager.restartIceCallCount, 1);
        expect(attempts, hasLength(1));
        expect(attempts[0].succeeded, isFalse);

        // Wait for second attempt (10ms backoff)
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(peerConnectionManager.restartIceCallCount, 2);
        expect(attempts, hasLength(2));

        // Wait for third attempt (20ms backoff)
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(peerConnectionManager.restartIceCallCount, 3);
        expect(attempts, hasLength(3));

        // All 3 attempts exhausted → failed
        expect(manager.state, ReconnectionState.failed);

        await sub.cancel();
      });
    });

    group('ICE timeout', () {
      test('ICE timeout triggers retry', () async {
        await manager.dispose();
        manager = ReconnectionManager(
          signalingClient: signalingClient,
          peerConnectionManager: peerConnectionManager,
          networkMonitor: networkMonitor,
          activeCallId: 'call-123',
          config: const ReconnectionConfig(
            maxAttempts: 3,
            backoffMs: <int>[0, 0, 0],
            iceRestartTimeoutMs: 50,
          ),
        );
        manager.start();

        // First attempt succeeds (ICE restart initiated, but no onIceConnected)
        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();
        expect(peerConnectionManager.restartIceCallCount, 1);
        expect(manager.state, ReconnectionState.restartingIce);

        // Wait for ICE timeout → auto-retry
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(peerConnectionManager.restartIceCallCount, 2);
      });

      test('ICE timeout cancelled on successful connection', () async {
        await manager.dispose();
        manager = ReconnectionManager(
          signalingClient: signalingClient,
          peerConnectionManager: peerConnectionManager,
          networkMonitor: networkMonitor,
          activeCallId: 'call-123',
          config: const ReconnectionConfig(
            maxAttempts: 3,
            backoffMs: <int>[0, 0, 0],
            iceRestartTimeoutMs: 50,
          ),
        );
        manager.start();

        networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
        await flush();
        expect(peerConnectionManager.restartIceCallCount, 1);

        // ICE connects before timeout
        manager.onIceConnected();
        expect(manager.state, ReconnectionState.reconnected);

        // Wait past timeout — no retry should fire
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(peerConnectionManager.restartIceCallCount, 1);
      });
    });
  });
}
