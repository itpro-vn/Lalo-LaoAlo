import 'package:lalo/core/network/signaling_client.dart';
import 'package:test/test.dart';

void main() {
  group('SignalingMessage', () {
    test('fromJson parses correctly', () {
      // arrange
      final json = <String, dynamic>{
        'type': msgCallInitiate,
        'data': <String, dynamic>{
          'callee_id': 'user-2',
          'has_video': true,
        },
      };

      // act
      final message = SignalingMessage.fromJson(json);

      // assert
      expect(message.type, msgCallInitiate);
      expect(message.data, {
        'callee_id': 'user-2',
        'has_video': true,
      });
    });

    test('toJson serializes correctly', () {
      // arrange
      const message = SignalingMessage(
        type: msgCallAccept,
        data: <String, dynamic>{
          'call_id': 'call-123',
          'sdp_answer': 'answer-sdp',
        },
      );

      // act
      final json = message.toJson();

      // assert
      expect(json, {
        'type': msgCallAccept,
        'data': {
          'call_id': 'call-123',
          'sdp_answer': 'answer-sdp',
        },
      });
    });

    test('roundtrip preserves payload', () {
      // arrange
      final source = <String, dynamic>{
        'type': msgIceCandidate,
        'data': <String, dynamic>{
          'call_id': 'c-1',
          'candidate': 'cand',
          'sdp_mid': '0',
          'sdp_mline_index': 0,
        },
      };

      // act
      final parsed = SignalingMessage.fromJson(source);
      final serialized = parsed.toJson();

      // assert
      expect(serialized, source);
    });

    test('all message type constants are unique', () {
      // arrange
      const allTypes = <String>[
        msgCallInitiate,
        msgCallAccept,
        msgCallReject,
        msgCallEnd,
        msgCallCancel,
        msgIceCandidate,
        msgQualityMetrics,
        msgPing,
        msgReconnect,
        msgIncomingCall,
        msgCallAccepted,
        msgCallRejected,
        msgCallEnded,
        msgCallCancelled,
        msgError,
        msgPong,
        msgSessionResumed,
        msgPeerReconnecting,
        msgPeerReconnected,
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
      ];

      // act
      final unique = allTypes.toSet();

      // assert
      expect(unique.length, allTypes.length);
    });

    test('group call message constants are present', () {
      // act/assert
      expect(msgRoomCreate, isNotEmpty);
      expect(msgRoomInvite, isNotEmpty);
      expect(msgRoomJoin, isNotEmpty);
      expect(msgRoomLeave, isNotEmpty);
      expect(msgRoomCreated, isNotEmpty);
      expect(msgRoomInvitation, isNotEmpty);
      expect(msgRoomClosed, isNotEmpty);
      expect(msgParticipantJoined, isNotEmpty);
      expect(msgParticipantLeft, isNotEmpty);
      expect(msgParticipantMediaChanged, isNotEmpty);
    });
  });

  group('SignalingError', () {
    test('fromData parses error payload', () {
      // arrange
      final data = <String, dynamic>{
        'code': 'invalid_sdp',
        'message': 'SDP is invalid',
      };

      // act
      final error = SignalingError.fromData(data);

      // assert
      expect(error.code, 'invalid_sdp');
      expect(error.message, 'SDP is invalid');
    });

    test('fromData falls back to defaults for missing data', () {
      // arrange
      final data = <String, dynamic>{};

      // act
      final error = SignalingError.fromData(data);

      // assert
      expect(error.code, 'unknown_error');
      expect(error.message, 'Unknown signaling error');
    });
  });

  group('ConnectionState', () {
    test('enum values exist', () {
      // act/assert
      expect(ConnectionState.values, [
        ConnectionState.disconnected,
        ConnectionState.connecting,
        ConnectionState.connected,
        ConnectionState.reconnecting,
        ConnectionState.error,
      ]);
    });
  });
}
