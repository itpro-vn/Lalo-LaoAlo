import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/group_call_models.dart';
import 'package:lalo/call/services/group_call_service.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/signaling_client.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

class MockSignalingClient implements SignalingClient {
  MockSignalingClient({required this.userId});

  final String userId;

  final StreamController<ConnectionState> _connectionStateController =
      StreamController<ConnectionState>.broadcast();
  final StreamController<SignalingMessage> _messageController =
      StreamController<SignalingMessage>.broadcast();

  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];

  Future<void> Function(String roomId)? onJoinRoom;
  Future<void> Function(String roomId)? onLeaveRoom;
  Future<void> Function(String roomId, List<String> invitees)? onInviteToRoom;

  @override
  Stream<ConnectionState> get onConnectionState =>
      _connectionStateController.stream;

  @override
  Stream<SignalingMessage> get onMessage => _messageController.stream;

  void emitMessage(SignalingMessage message) => _messageController.add(message);

  @override
  void joinRoom(String roomId) {
    sentMessages.add(<String, dynamic>{
      'type': msgRoomJoin,
      'room_id': roomId,
      'user_id': userId,
    });
    unawaited(onJoinRoom?.call(roomId));
  }

  @override
  void leaveRoom(String roomId) {
    sentMessages.add(<String, dynamic>{
      'type': msgRoomLeave,
      'room_id': roomId,
      'user_id': userId,
    });
    unawaited(onLeaveRoom?.call(roomId));
  }

  @override
  void inviteToRoom(String roomId, List<String> invitees) {
    sentMessages.add(<String, dynamic>{
      'type': msgRoomInvite,
      'room_id': roomId,
      'invitees': invitees,
      'user_id': userId,
    });
    unawaited(onInviteToRoom?.call(roomId, invitees));
  }

  Future<void> close() async {
    await _connectionStateController.close();
    await _messageController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockApiClient implements ApiClient {
  MockApiClient({required this.userId});

  final String userId;

  Future<Map<String, dynamic>> Function(
      List<String> participants, String callType)? createRoomHandler;
  Future<Map<String, dynamic>> Function(String roomId)? joinRoomHandler;
  Future<void> Function(String roomId)? leaveRoomHandler;

  @override
  Future<Map<String, dynamic>> createRoom(
    List<String> participants,
    String callType,
  ) async {
    final handler = createRoomHandler;
    if (handler == null) {
      throw StateError('createRoomHandler is not configured for $userId');
    }
    return handler(participants, callType);
  }

  @override
  Future<Map<String, dynamic>> joinRoom(String roomId) async {
    final handler = joinRoomHandler;
    if (handler == null) {
      throw StateError('joinRoomHandler is not configured for $userId');
    }
    return handler(roomId);
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    final handler = leaveRoomHandler;
    if (handler == null) {
      throw StateError('leaveRoomHandler is not configured for $userId');
    }
    return handler(roomId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockMediaManager implements MediaManager {
  var initializeCount = 0;

  @override
  Future<void> initialize() async {
    initializeCount += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RoomState {
  _RoomState({
    required this.roomId,
    required this.callType,
    required this.hostId,
    required this.invited,
  });

  final String roomId;
  final String callType;
  final Set<String> invited;
  final Set<String> joined = <String>{};
  String hostId;
}

class _FakeGroupCallServer {
  final Map<String, _ParticipantHarness> _participants =
      <String, _ParticipantHarness>{};
  final Map<String, _RoomState> _rooms = <String, _RoomState>{};
  var _roomSeq = 0;

  void register(_ParticipantHarness participant) {
    _participants[participant.userId] = participant;

    participant.apiClient.createRoomHandler =
        (List<String> participants, String callType) {
      return createRoom(
        creatorId: participant.userId,
        participants: participants,
        callType: callType,
      );
    };

    participant.apiClient.joinRoomHandler = (String roomId) {
      return joinRoom(userId: participant.userId, roomId: roomId);
    };

    participant.apiClient.leaveRoomHandler = (String roomId) {
      return leaveRoom(userId: participant.userId, roomId: roomId);
    };

    participant.signalingClient.onJoinRoom = (String roomId) {
      return signalingJoinRoom(userId: participant.userId, roomId: roomId);
    };

    participant.signalingClient.onLeaveRoom = (String roomId) {
      return signalingLeaveRoom(userId: participant.userId, roomId: roomId);
    };

    participant.signalingClient.onInviteToRoom = (
      String roomId,
      List<String> invitees,
    ) {
      return inviteToRoom(
        inviterId: participant.userId,
        roomId: roomId,
        invitees: invitees,
      );
    };
  }

  Future<Map<String, dynamic>> createRoom({
    required String creatorId,
    required List<String> participants,
    required String callType,
  }) async {
    final deduped = <String>{...participants};
    if (!deduped.contains(creatorId)) {
      deduped.add(creatorId);
    }

    if (deduped.length > GroupCallService.maxParticipants) {
      throw StateError('room_full');
    }

    _roomSeq += 1;
    final roomId = 'room-$_roomSeq';
    _rooms[roomId] = _RoomState(
      roomId: roomId,
      callType: callType,
      hostId: creatorId,
      invited: deduped,
    );

    return <String, dynamic>{
      'room_id': roomId,
      'livekit_token': 'token-$creatorId-$roomId',
      'livekit_url': 'wss://livekit.test/$roomId',
      'host_id': creatorId,
    };
  }

  Future<Map<String, dynamic>> joinRoom({
    required String userId,
    required String roomId,
  }) async {
    final room = _requireRoom(roomId);

    if (!room.joined.contains(userId) &&
        room.joined.length >= GroupCallService.maxParticipants) {
      throw StateError('room_full');
    }

    room.invited.add(userId);
    final isNewJoin = room.joined.add(userId);

    if (isNewJoin) {
      _broadcastToJoined(
        room,
        SignalingMessage(
          type: msgParticipantJoined,
          data: <String, dynamic>{
            'room_id': roomId,
            'user_id': userId,
            'role': userId == room.hostId ? 'host' : 'guest',
          },
        ),
      );
    }

    return <String, dynamic>{
      'room_id': roomId,
      'livekit_token': 'token-$userId-$roomId',
      'livekit_url': 'wss://livekit.test/$roomId',
      'host_id': room.hostId,
    };
  }

  Future<void> leaveRoom({
    required String userId,
    required String roomId,
  }) async {
    final room = _requireRoom(roomId);
    final removed = room.joined.remove(userId);
    if (!removed) {
      return;
    }

    final wasHost = room.hostId == userId;
    if (wasHost && room.joined.isNotEmpty) {
      room.hostId = room.joined.first;
    }

    if (room.joined.isNotEmpty) {
      _broadcastToJoined(
        room,
        SignalingMessage(
          type: msgParticipantLeft,
          data: <String, dynamic>{
            'room_id': roomId,
            'user_id': userId,
            'role': wasHost ? 'host' : 'guest',
          },
        ),
      );
      return;
    }

    _rooms.remove(roomId);
  }

  Future<void> signalingJoinRoom({
    required String userId,
    required String roomId,
  }) async {
    final room = _rooms[roomId];
    if (room == null) {
      return;
    }

    if (room.joined.contains(userId)) {
      return;
    }

    if (room.joined.length >= GroupCallService.maxParticipants) {
      throw StateError('room_full');
    }

    room.joined.add(userId);
    _broadcastToJoined(
      room,
      SignalingMessage(
        type: msgParticipantJoined,
        data: <String, dynamic>{
          'room_id': roomId,
          'user_id': userId,
          'role': userId == room.hostId ? 'host' : 'guest',
        },
      ),
    );
  }

  Future<void> signalingLeaveRoom({
    required String userId,
    required String roomId,
  }) async {
    // Keep leave semantics in API flow to mirror current service implementation.
    _requireRoomOrNull(roomId);
    userId.isNotEmpty;
  }

  Future<void> inviteToRoom({
    required String inviterId,
    required String roomId,
    required List<String> invitees,
  }) async {
    final room = _requireRoom(roomId);
    room.invited.addAll(invitees);

    for (final invitee in invitees) {
      final participant = _participants[invitee];
      if (participant == null) {
        continue;
      }

      participant.signalingClient.emitMessage(
        SignalingMessage(
          type: msgRoomInvitation,
          data: <String, dynamic>{
            'room_id': roomId,
            'inviter_id': inviterId,
            'call_type': room.callType,
            'participants': room.invited.toList(growable: false),
          },
        ),
      );
    }
  }

  int joinedCount(String roomId) => _requireRoom(roomId).joined.length;

  String? hostId(String roomId) => _requireRoomOrNull(roomId)?.hostId;

  _RoomState _requireRoom(String roomId) {
    final room = _rooms[roomId];
    if (room == null) {
      throw StateError('Room not found: $roomId');
    }
    return room;
  }

  _RoomState? _requireRoomOrNull(String roomId) => _rooms[roomId];

  void _broadcastToJoined(_RoomState room, SignalingMessage message) {
    for (final userId in room.joined) {
      final participant = _participants[userId];
      participant?.signalingClient.emitMessage(message);
    }
  }
}

class _ParticipantHarness {
  _ParticipantHarness(
      {required this.userId, required _FakeGroupCallServer server}) {
    signalingClient = MockSignalingClient(userId: userId);
    apiClient = MockApiClient(userId: userId);
    mediaManager = MockMediaManager();
    service = GroupCallService(
      signalingClient: signalingClient,
      apiClient: apiClient,
      mediaManager: mediaManager,
    );

    server.register(this);
  }

  final String userId;
  late MockSignalingClient signalingClient;
  late MockApiClient apiClient;
  late MockMediaManager mediaManager;
  late GroupCallService service;

  Future<void> dispose() async {
    await service.dispose();
    await signalingClient.close();
  }
}

void main() {
  group('PB-07 group call flow integration', () {
    test(
      '3 participants: create -> invite -> join -> talk -> leave full lifecycle',
      () async {
        final server = _FakeGroupCallServer();
        final host = _ParticipantHarness(userId: 'u1', server: server);
        final guest2 = _ParticipantHarness(userId: 'u2', server: server);
        final guest3 = _ParticipantHarness(userId: 'u3', server: server);

        addTearDown(() async {
          await host.dispose();
          await guest2.dispose();
          await guest3.dispose();
        });

        final hostJoined = <ParticipantEvent>[];
        final hostLeft = <ParticipantEvent>[];
        final guest2Invites = <RoomInvitationEvent>[];
        final guest3Invites = <RoomInvitationEvent>[];

        final subJoined =
            host.service.onParticipantJoined.listen(hostJoined.add);
        final subLeft = host.service.onParticipantLeft.listen(hostLeft.add);
        final subInvite2 = guest2.service.onRoomInvitation.listen(
          guest2Invites.add,
        );
        final subInvite3 = guest3.service.onRoomInvitation.listen(
          guest3Invites.add,
        );

        addTearDown(() async {
          await subJoined.cancel();
          await subLeft.cancel();
          await subInvite2.cancel();
          await subInvite3.cancel();
        });

        final created =
            await host.service.createRoom(<String>['u1', 'u2', 'u3'], 'video');
        expect(created.roomId, isNotEmpty);
        expect(host.service.activeRoomId, created.roomId);
        expect(host.service.isUserHost('u1'), isTrue);

        await host.service.inviteToRoom(created.roomId, <String>['u2', 'u3']);
        await flush();

        expect(guest2Invites, hasLength(1));
        expect(guest3Invites, hasLength(1));

        await guest2.service.joinRoom(created.roomId);
        await guest3.service.joinRoom(created.roomId);
        await flush();

        expect(hostJoined.map((event) => event.userId),
            containsAll(<String>['u2', 'u3']));
        expect(host.service.activeRoomId, created.roomId);
        expect(guest2.service.activeRoomId, created.roomId);
        expect(guest3.service.activeRoomId, created.roomId);

        // "Talk" phase: everyone remains active in the room.
        expect(server.joinedCount(created.roomId), 3);

        await guest3.service.leaveRoom(created.roomId);
        await flush();
        expect(hostLeft.map((event) => event.userId), contains('u3'));

        await guest2.service.leaveRoom(created.roomId);
        await flush();
        expect(hostLeft.map((event) => event.userId), contains('u2'));

        await host.service.leaveRoom(created.roomId);
        await flush();

        expect(host.service.activeRoomId, isNull);
        expect(guest2.service.activeRoomId, isNull);
        expect(guest3.service.activeRoomId, isNull);
      },
    );

    test('8 participants: room accepts max capacity', () async {
      final server = _FakeGroupCallServer();
      final users = List<_ParticipantHarness>.generate(
        8,
        (index) => _ParticipantHarness(userId: 'u${index + 1}', server: server),
      );
      final host = users.first;

      addTearDown(() async {
        for (final user in users) {
          await user.dispose();
        }
      });

      final room = await host.service.createRoom(
        users.map((user) => user.userId).toList(growable: false),
        'video',
      );

      for (final user in users.skip(1)) {
        await user.service.joinRoom(room.roomId);
      }
      await flush();

      expect(server.joinedCount(room.roomId), 8);
      for (final user in users) {
        expect(user.service.activeRoomId, room.roomId);
      }
    });

    test('9th participant: join attempt is rejected', () async {
      final server = _FakeGroupCallServer();
      final users = List<_ParticipantHarness>.generate(
        9,
        (index) => _ParticipantHarness(userId: 'u${index + 1}', server: server),
      );
      final host = users.first;
      final ninth = users.last;

      addTearDown(() async {
        for (final user in users) {
          await user.dispose();
        }
      });

      final room = await host.service.createRoom(
        users.take(8).map((user) => user.userId).toList(growable: false),
        'video',
      );

      for (final user in users.skip(1).take(7)) {
        await user.service.joinRoom(room.roomId);
      }
      await flush();

      expect(server.joinedCount(room.roomId), 8);

      await expectLater(
        ninth.service.joinRoom(room.roomId),
        throwsA(isA<StateError>()),
      );
      expect(ninth.service.activeRoomId, isNull);
      expect(server.joinedCount(room.roomId), 8);
    });

    test('mid-call join: new participant joins ongoing room', () async {
      final server = _FakeGroupCallServer();
      final host = _ParticipantHarness(userId: 'u1', server: server);
      final guest2 = _ParticipantHarness(userId: 'u2', server: server);
      final guest3 = _ParticipantHarness(userId: 'u3', server: server);

      addTearDown(() async {
        await host.dispose();
        await guest2.dispose();
        await guest3.dispose();
      });

      final hostJoined = <ParticipantEvent>[];
      final sub = host.service.onParticipantJoined.listen(hostJoined.add);
      addTearDown(sub.cancel);

      final room = await host.service.createRoom(<String>['u1', 'u2'], 'audio');
      await guest2.service.joinRoom(room.roomId);
      await flush();

      expect(server.joinedCount(room.roomId), 2);

      await host.service.inviteToRoom(room.roomId, <String>['u3']);
      await guest3.service.joinRoom(room.roomId);
      await flush();

      expect(server.joinedCount(room.roomId), 3);
      expect(hostJoined.where((event) => event.userId == 'u3').length, 1);
      expect(host.service.activeRoomId, room.roomId);
      expect(guest2.service.activeRoomId, room.roomId);
      expect(guest3.service.activeRoomId, room.roomId);
    });

    test('mid-call leave: one participant leaves, others continue', () async {
      final server = _FakeGroupCallServer();
      final host = _ParticipantHarness(userId: 'u1', server: server);
      final guest2 = _ParticipantHarness(userId: 'u2', server: server);
      final guest3 = _ParticipantHarness(userId: 'u3', server: server);

      addTearDown(() async {
        await host.dispose();
        await guest2.dispose();
        await guest3.dispose();
      });

      final hostLeft = <ParticipantEvent>[];
      final guest3Left = <ParticipantEvent>[];
      final subHost = host.service.onParticipantLeft.listen(hostLeft.add);
      final subGuest3 = guest3.service.onParticipantLeft.listen(guest3Left.add);
      addTearDown(() async {
        await subHost.cancel();
        await subGuest3.cancel();
      });

      final room =
          await host.service.createRoom(<String>['u1', 'u2', 'u3'], 'video');
      await guest2.service.joinRoom(room.roomId);
      await guest3.service.joinRoom(room.roomId);
      await flush();

      await guest2.service.leaveRoom(room.roomId);
      await flush();

      expect(hostLeft.map((event) => event.userId), contains('u2'));
      expect(guest3Left.map((event) => event.userId), contains('u2'));
      expect(server.joinedCount(room.roomId), 2);
      expect(host.service.activeRoomId, room.roomId);
      expect(guest3.service.activeRoomId, room.roomId);
    });

    test('host leave: first remaining participant is promoted to host',
        () async {
      final server = _FakeGroupCallServer();
      final host = _ParticipantHarness(userId: 'u1', server: server);
      final guest2 = _ParticipantHarness(userId: 'u2', server: server);
      final guest3 = _ParticipantHarness(userId: 'u3', server: server);

      addTearDown(() async {
        await host.dispose();
        await guest2.dispose();
        await guest3.dispose();
      });

      final room =
          await host.service.createRoom(<String>['u1', 'u2', 'u3'], 'video');
      await guest2.service.joinRoom(room.roomId);
      await guest3.service.joinRoom(room.roomId);
      await flush();

      await host.service.leaveRoom(room.roomId);
      await flush();

      expect(server.hostId(room.roomId), 'u2');
      // Service host tracking updates on join/create payloads.
      await guest2.service.joinRoom(room.roomId);
      await flush();
      expect(guest2.service.hostId, 'u2');
      expect(guest2.service.isUserHost('u2'), isTrue);
      expect(guest3.service.isUserHost('u3'), isFalse);
    });
  });
}
