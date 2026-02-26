import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/services/group_call_service.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/signaling_client.dart';

class MockSignalingClient implements SignalingClient {
  final StreamController<SignalingMessage> messageController =
      StreamController<SignalingMessage>.broadcast();
  final StreamController<ConnectionState> connectionController =
      StreamController<ConnectionState>.broadcast();

  String? lastJoinedRoomId;
  final List<String> joinedRoomIds = <String>[];
  final List<String> leftRoomIds = <String>[];
  var joinRoomCallCount = 0;
  bool throwOnJoinRoom = false;

  @override
  Stream<SignalingMessage> get onMessage => messageController.stream;

  @override
  Stream<ConnectionState> get onConnectionState => connectionController.stream;

  @override
  void joinRoom(String roomId) {
    if (throwOnJoinRoom) {
      throw StateError('joinRoom failed');
    }
    lastJoinedRoomId = roomId;
    joinedRoomIds.add(roomId);
    joinRoomCallCount += 1;
  }

  @override
  void leaveRoom(String roomId) {
    leftRoomIds.add(roomId);
  }

  @override
  void inviteToRoom(String roomId, List<String> invitees) {}

  @override
  void requestLayer(String roomId, String trackSid, String layer) {}

  @override
  void sendQualityMetrics(String callId, List<Map<String, dynamic>> samples) {}

  @override
  Future<void> dispose() async {
    await messageController.close();
    await connectionController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockApiClient implements ApiClient {
  Map<String, dynamic> createRoomResponse = <String, dynamic>{
    'room_id': 'test-room',
    'livekit_token': 'tok',
    'livekit_url': 'url',
  };

  Map<String, dynamic> joinRoomResponse = <String, dynamic>{
    'room_id': 'test-room',
    'livekit_token': 'tok',
    'livekit_url': 'url',
  };

  String? lastJoinedRoomId;
  String? lastLeftRoomId;

  @override
  Future<Map<String, dynamic>> createRoom(
    List<String> participants,
    String callType,
  ) async {
    return createRoomResponse;
  }

  @override
  Future<Map<String, dynamic>> joinRoom(String roomId) async {
    lastJoinedRoomId = roomId;
    return joinRoomResponse;
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    lastLeftRoomId = roomId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockMediaManager implements MediaManager {
  var initializeCallCount = 0;

  @override
  Future<void> initialize() async {
    initializeCallCount += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('GroupCallService reconnection', () {
    late MockSignalingClient signalingClient;
    late MockApiClient apiClient;
    late MockMediaManager mediaManager;
    late GroupCallService service;
    var serviceDisposed = false;

    setUp(() {
      signalingClient = MockSignalingClient();
      apiClient = MockApiClient();
      mediaManager = MockMediaManager();
      service = GroupCallService(
        signalingClient: signalingClient,
        apiClient: apiClient,
        mediaManager: mediaManager,
      );
      serviceDisposed = false;
    });

    tearDown(() async {
      if (service.reconnectionState == GroupCallReconnectionState.rejoined) {
        // Allow delayed rejoined -> idle transition to fire before dispose.
        await Future<void>.delayed(const Duration(milliseconds: 2100));
      }
      if (!serviceDisposed) {
        await service.dispose();
      }
      await signalingClient.dispose();
    });

    test('tracks activeRoomId on joinRoom', () async {
      apiClient.joinRoomResponse = <String, dynamic>{
        'room_id': 'room-join',
        'livekit_token': 'tok',
        'livekit_url': 'url',
      };

      expect(service.activeRoomId, isNull);

      await service.joinRoom('room-join');

      expect(service.activeRoomId, 'room-join');
      expect(signalingClient.lastJoinedRoomId, 'room-join');
      expect(signalingClient.joinRoomCallCount, 1);
      expect(mediaManager.initializeCallCount, 1);
    });

    test('tracks activeRoomId on createRoom', () async {
      apiClient.createRoomResponse = <String, dynamic>{
        'room_id': 'room-create',
        'livekit_token': 'tok',
        'livekit_url': 'url',
      };

      expect(service.activeRoomId, isNull);

      await service.createRoom(<String>['u1', 'u2'], 'video');

      expect(service.activeRoomId, 'room-create');
      expect(signalingClient.lastJoinedRoomId, 'room-create');
      expect(signalingClient.joinRoomCallCount, 1);
    });

    test('clears activeRoomId on leaveRoom', () async {
      await service.joinRoom('room-leave');
      expect(service.activeRoomId, 'room-leave');

      await service.leaveRoom('room-leave');

      expect(service.activeRoomId, isNull);
      expect(apiClient.lastLeftRoomId, 'room-leave');
      expect(signalingClient.leftRoomIds, contains('room-leave'));
    });

    test('clears activeRoomId on room_closed event', () async {
      await service.joinRoom('room-closed');
      expect(service.activeRoomId, 'room-closed');

      signalingClient.messageController.add(
        const SignalingMessage(
          type: msgRoomClosed,
          data: <String, dynamic>{
            'room_id': 'room-closed',
            'reason': 'host_ended',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.activeRoomId, isNull);
    });

    test('no reconnect attempt when not in room', () async {
      final states = <GroupCallReconnectionState>[];
      final sub = service.onReconnectionState.listen(states.add);

      signalingClient.connectionController.add(ConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(service.activeRoomId, isNull);
      expect(service.reconnectionState, GroupCallReconnectionState.idle);
      expect(signalingClient.joinRoomCallCount, 0);
      expect(states, isEmpty);

      await sub.cancel();
    });

    test('reconnects when signaling reconnects with active room', () async {
      await service.joinRoom('room-reconnect');
      expect(signalingClient.joinRoomCallCount, 1);

      signalingClient.connectionController.add(ConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(signalingClient.joinRoomCallCount, 2);
      expect(signalingClient.lastJoinedRoomId, 'room-reconnect');
      expect(service.reconnectionState, GroupCallReconnectionState.rejoined);
    });

    test('emits rejoining then rejoined states', () async {
      final emittedStates = <GroupCallReconnectionState>[];
      final sub = service.onReconnectionState.listen(emittedStates.add);

      await service.joinRoom('room-states');
      signalingClient.connectionController.add(ConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        emittedStates.take(2).toList(),
        <GroupCallReconnectionState>[
          GroupCallReconnectionState.rejoining,
          GroupCallReconnectionState.rejoined,
        ],
      );

      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(emittedStates.last, GroupCallReconnectionState.idle);
      expect(service.reconnectionState, GroupCallReconnectionState.idle);

      await sub.cancel();
    });

    test('re-sends joinRoom on reconnection', () async {
      await service.joinRoom('room-resend');
      expect(signalingClient.joinedRoomIds, <String>['room-resend']);

      signalingClient.connectionController.add(ConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(
        signalingClient.joinedRoomIds,
        <String>['room-resend', 'room-resend'],
      );
    });

    test('dispose clears activeRoomId', () async {
      await service.joinRoom('room-dispose');
      expect(service.activeRoomId, 'room-dispose');

      await service.dispose();
      serviceDisposed = true;

      expect(service.activeRoomId, isNull);
    });
  });
}
