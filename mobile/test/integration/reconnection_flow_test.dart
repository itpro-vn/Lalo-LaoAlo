import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/call_state.dart';
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
    if (throwOnSendReconnect) throw StateError('sendReconnect failed');
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
    if (restartIceError != null) {
      return Future<void>.error(restartIceError!);
    }
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

NetworkChange _change(NetworkType previous, NetworkType current) {
  return NetworkChange(
    previousType: previous,
    currentType: current,
    timestamp: DateTime.now(),
  );
}

void main() {
  group('PB-07 reconnection flow', () {
    test('WiFi → 4G handover (1:1 + group) triggers ICE restart', () async {
      final oneToOneNetwork = MockNetworkMonitor();
      final oneToOneSignaling = MockSignalingClient();
      final oneToOnePeer = MockPeerConnectionManager();
      final oneToOneManager = ReconnectionManager(
        signalingClient: oneToOneSignaling,
        peerConnectionManager: oneToOnePeer,
        networkMonitor: oneToOneNetwork,
        activeCallId: 'call-1to1',
        config: const ReconnectionConfig(
          maxAttempts: 3,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await oneToOneManager.dispose();
        await oneToOneSignaling.close();
        await oneToOneNetwork.close();
      });

      final groupNetwork = MockNetworkMonitor();
      final groupSignaling = MockSignalingClient();
      final groupPeer = MockPeerConnectionManager();
      final groupManager = ReconnectionManager(
        signalingClient: groupSignaling,
        peerConnectionManager: groupPeer,
        networkMonitor: groupNetwork,
        activeCallId: 'group-room-01',
        config: const ReconnectionConfig(
          maxAttempts: 3,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await groupManager.dispose();
        await groupSignaling.close();
        await groupNetwork.close();
      });

      oneToOneNetwork.emit(_change(NetworkType.wifi, NetworkType.cellular));
      groupNetwork.emit(_change(NetworkType.wifi, NetworkType.cellular));
      await flush();

      expect(oneToOnePeer.restartIceCallCount, 1);
      expect(groupPeer.restartIceCallCount, 1);
      expect(oneToOneManager.state, ReconnectionState.restartingIce);
      expect(groupManager.state, ReconnectionState.restartingIce);
    });

    test('4G → WiFi handover triggers ICE restart', () async {
      final networkMonitor = MockNetworkMonitor();
      final signalingClient = MockSignalingClient();
      final peerConnectionManager = MockPeerConnectionManager();
      final manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-4g-to-wifi',
        config: const ReconnectionConfig(
          maxAttempts: 3,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await manager.dispose();
        await signalingClient.close();
        await networkMonitor.close();
      });

      networkMonitor.emit(_change(NetworkType.cellular, NetworkType.wifi));
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);
    });

    test('Airplane mode toggle: disconnect -> reconnect -> ICE restart', () async {
      final networkMonitor = MockNetworkMonitor();
      final signalingClient = MockSignalingClient();
      final peerConnectionManager = MockPeerConnectionManager();
      final manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-airplane',
        config: const ReconnectionConfig(
          maxAttempts: 3,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await manager.dispose();
        await signalingClient.close();
        await networkMonitor.close();
      });

      final machine = CallStateMachine(initialState: CallState.active);
      addTearDown(machine.dispose);

      final callTransitions = <CallStateTransition>[];
      final callSub = machine.onStateChanged.listen(callTransitions.add);
      addTearDown(callSub.cancel);

      final reconnectionSub = manager.onStateChange.listen((state) {
        if ((state == ReconnectionState.reconnectingSignaling ||
                state == ReconnectionState.restartingIce) &&
            machine.currentState == CallState.active &&
            machine.canTransition(CallState.reconnecting)) {
          machine.transition(CallState.reconnecting, reason: state.name);
        }

        if (state == ReconnectionState.reconnected &&
            machine.currentState == CallState.reconnecting &&
            machine.canTransition(CallState.active)) {
          machine.transition(CallState.active, reason: 'reconnection_success');
        }
      });
      addTearDown(reconnectionSub.cancel);

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.none));
      await flush();
      expect(manager.state, ReconnectionState.reconnectingSignaling);
      expect(machine.currentState, CallState.reconnecting);

      signalingClient.emitConnectionState(ConnectionState.connected);
      await flush();
      expect(signalingClient.reconnectCallIds, <String>['call-airplane']);

      signalingClient.emitMessage(
        const SignalingMessage(
          type: msgSessionResumed,
          data: <String, dynamic>{'call_id': 'call-airplane'},
        ),
      );
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.restartingIce);

      manager.onIceConnected();
      await flush();

      expect(manager.state, ReconnectionState.reconnected);
      expect(machine.currentState, CallState.active);
      expect(
        callTransitions.map((t) => t.toState).toList(),
        <CallState>[CallState.reconnecting, CallState.active],
      );
    });

    test('CallStateMachine failure path: active -> reconnecting -> ended',
        () async {
      final networkMonitor = MockNetworkMonitor();
      final signalingClient = MockSignalingClient();
      final peerConnectionManager = MockPeerConnectionManager()
        ..restartIceError = StateError('forced ICE failure');

      final manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-fail',
        config: const ReconnectionConfig(
          maxAttempts: 1,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await manager.dispose();
        await signalingClient.close();
        await networkMonitor.close();
      });

      final machine = CallStateMachine(initialState: CallState.active);
      addTearDown(machine.dispose);

      final callTransitions = <CallStateTransition>[];
      final callSub = machine.onStateChanged.listen(callTransitions.add);
      addTearDown(callSub.cancel);

      final reconnectionSub = manager.onStateChange.listen((state) {
        if ((state == ReconnectionState.reconnectingSignaling ||
                state == ReconnectionState.restartingIce) &&
            machine.currentState == CallState.active &&
            machine.canTransition(CallState.reconnecting)) {
          machine.transition(CallState.reconnecting, reason: state.name);
        }

        if (state == ReconnectionState.failed &&
            machine.currentState == CallState.reconnecting &&
            machine.canTransition(CallState.ended)) {
          machine.transition(CallState.ended, reason: 'reconnection_failed');
        }
      });
      addTearDown(reconnectionSub.cancel);

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.cellular));
      await flush();

      expect(peerConnectionManager.restartIceCallCount, 1);
      expect(manager.state, ReconnectionState.failed);
      expect(machine.currentState, CallState.ended);
      expect(
        callTransitions.map((t) => t.toState).toList(),
        <CallState>[CallState.reconnecting, CallState.ended],
      );
    });

    test('Multi-reconnect stress: rapid network changes do not corrupt state',
        () async {
      final networkMonitor = MockNetworkMonitor();
      final signalingClient = MockSignalingClient();
      final peerConnectionManager = MockPeerConnectionManager();
      final manager = ReconnectionManager(
        signalingClient: signalingClient,
        peerConnectionManager: peerConnectionManager,
        networkMonitor: networkMonitor,
        activeCallId: 'call-stress',
        config: const ReconnectionConfig(
          maxAttempts: 3,
          backoffMs: <int>[0, 0, 0],
        ),
      )..start();

      addTearDown(() async {
        await manager.dispose();
        await signalingClient.close();
        await networkMonitor.close();
      });

      final states = <ReconnectionState>[];
      final stateSub = manager.onStateChange.listen(states.add);
      addTearDown(stateSub.cancel);

      final attempts = <ReconnectionAttempt>[];
      final attemptSub = manager.onAttempt.listen(attempts.add);
      addTearDown(attemptSub.cancel);

      for (var i = 0; i < 6; i++) {
        final previous = i.isEven ? NetworkType.wifi : NetworkType.cellular;
        final current = i.isEven ? NetworkType.cellular : NetworkType.wifi;

        networkMonitor.emit(_change(previous, current));
        await flush();

        manager.onIceConnected();
        await flush();
      }

      networkMonitor.emit(_change(NetworkType.wifi, NetworkType.none));
      await flush();
      signalingClient.emitConnectionState(ConnectionState.connected);
      signalingClient.emitMessage(
        const SignalingMessage(
          type: msgSessionResumed,
          data: <String, dynamic>{'call_id': 'call-stress'},
        ),
      );
      await flush();
      manager.onIceConnected();
      await flush();

      expect(peerConnectionManager.restartIceCallCount, greaterThanOrEqualTo(7));
      expect(manager.state, isNot(ReconnectionState.failed));
      expect(states.where((s) => s == ReconnectionState.failed), isEmpty);
      expect(attempts, isNotEmpty);
      expect(
        attempts.map((a) => a.reason).toSet(),
        containsAll(<String>['network_handover', 'session_resumed']),
      );
    });
  });
}
