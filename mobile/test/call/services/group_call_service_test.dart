import 'package:lalo/call/models/group_call_models.dart';
import 'package:lalo/core/network/signaling_client.dart';
import 'package:test/test.dart';

void main() {
  group('Group signaling message types', () {
    test('are unique and do not collide with one-to-one types', () {
      const oneToOneTypes = <String>{
        msgCallInitiate,
        msgCallAccept,
        msgCallReject,
        msgCallEnd,
        msgCallCancel,
        msgIceCandidate,
        msgQualityMetrics,
        msgPing,
        msgIncomingCall,
        msgCallAccepted,
        msgCallRejected,
        msgCallEnded,
        msgCallCancelled,
        msgError,
        msgPong,
      };

      const groupTypes = <String>{
        msgRoomCreate,
        msgRoomInvite,
        msgRoomJoin,
        msgRoomLeave,
        msgRoomCreated,
        msgRoomInvitation,
        msgRoomClosed,
        msgParticipantJoined,
        msgParticipantLeft,
        msgParticipantMediaChanged,
      };

      expect(groupTypes.length, 10);
      expect(groupTypes.intersection(oneToOneTypes), isEmpty);
    });
  });

  group('Group call models serialization', () {
    test('RoomCreatedEvent fromJson/toJson', () {
      final json = <String, dynamic>{
        'room_id': 'room-1',
        'livekit_token': 'lk-token',
        'livekit_url': 'wss://livekit.example/ws',
      };

      final event = RoomCreatedEvent.fromJson(json);

      expect(event.roomId, 'room-1');
      expect(event.liveKitToken, 'lk-token');
      expect(event.liveKitUrl, 'wss://livekit.example/ws');
      expect(event.toJson(), json);
    });

    test('RoomInvitationEvent fromJson/toJson', () {
      final json = <String, dynamic>{
        'room_id': 'room-2',
        'inviter_id': 'user-1',
        'call_type': 'video',
        'participants': <String>['user-1', 'user-2', 'user-3'],
      };

      final event = RoomInvitationEvent.fromJson(json);

      expect(event.roomId, 'room-2');
      expect(event.inviterId, 'user-1');
      expect(event.callType, 'video');
      expect(event.participants, <String>['user-1', 'user-2', 'user-3']);
      expect(event.toJson(), json);
    });

    test('RoomClosedEvent fromJson/toJson', () {
      final json = <String, dynamic>{
        'room_id': 'room-3',
        'reason': 'host_ended',
      };

      final event = RoomClosedEvent.fromJson(json);

      expect(event.roomId, 'room-3');
      expect(event.reason, 'host_ended');
      expect(event.toJson(), json);
    });

    test('ParticipantEvent fromJson/toJson', () {
      final json = <String, dynamic>{
        'room_id': 'room-4',
        'user_id': 'user-9',
        'role': 'guest',
      };

      final event = ParticipantEvent.fromJson(json);

      expect(event.roomId, 'room-4');
      expect(event.userId, 'user-9');
      expect(event.role, 'guest');
      expect(event.toJson(), json);
    });

    test('ParticipantMediaEvent fromJson/toJson', () {
      final json = <String, dynamic>{
        'room_id': 'room-5',
        'user_id': 'user-11',
        'audio': true,
        'video': false,
      };

      final event = ParticipantMediaEvent.fromJson(json);

      expect(event.roomId, 'room-5');
      expect(event.userId, 'user-11');
      expect(event.audio, isTrue);
      expect(event.video, isFalse);
      expect(event.toJson(), json);
    });
  });

  group('Signaling event parsing', () {
    test('parses room_created payload', () {
      final message = SignalingMessage.fromJson(<String, dynamic>{
        'type': msgRoomCreated,
        'data': <String, dynamic>{
          'room_id': 'room-created',
          'livekit_token': 'token-a',
          'livekit_url': 'wss://lk',
        },
      });

      final event = RoomCreatedEvent.fromJson(message.data);

      expect(message.type, msgRoomCreated);
      expect(event.roomId, 'room-created');
      expect(event.liveKitToken, 'token-a');
    });

    test('parses room_invitation payload', () {
      final message = SignalingMessage.fromJson(<String, dynamic>{
        'type': msgRoomInvitation,
        'data': <String, dynamic>{
          'room_id': 'room-invite',
          'inviter_id': 'user-host',
          'call_type': 'audio',
          'participants': <String>['user-host', 'user-x'],
        },
      });

      final event = RoomInvitationEvent.fromJson(message.data);

      expect(message.type, msgRoomInvitation);
      expect(event.inviterId, 'user-host');
      expect(event.participants.length, 2);
    });

    test('parses participant events payload', () {
      final joinedMessage = SignalingMessage.fromJson(<String, dynamic>{
        'type': msgParticipantJoined,
        'data': <String, dynamic>{
          'room_id': 'room-p',
          'user_id': 'user-a',
          'role': 'guest',
        },
      });

      final leftMessage = SignalingMessage.fromJson(<String, dynamic>{
        'type': msgParticipantLeft,
        'data': <String, dynamic>{
          'room_id': 'room-p',
          'user_id': 'user-a',
        },
      });

      final joined = ParticipantEvent.fromJson(joinedMessage.data);
      final left = ParticipantEvent.fromJson(leftMessage.data);

      expect(joinedMessage.type, msgParticipantJoined);
      expect(leftMessage.type, msgParticipantLeft);
      expect(joined.roomId, 'room-p');
      expect(left.userId, 'user-a');
    });
  });
}
