import 'package:lalo/call/models/call_session.dart';
import 'package:lalo/call/models/call_state.dart';
import 'package:test/test.dart';

void main() {
  group('CallSession', () {
    final createdAt = DateTime.utc(2026, 1, 1, 10, 0, 0);
    final answeredAt = DateTime.utc(2026, 1, 1, 10, 0, 5);
    final endedAt = DateTime.utc(2026, 1, 1, 10, 2, 5);

    final participant = CallParticipant(
      userId: 'user-a',
      role: ParticipantRole.caller,
      audioEnabled: true,
      videoEnabled: false,
      joinedAt: createdAt,
    );

    final session = CallSession(
      callId: 'call-1',
      callerId: 'caller-1',
      calleeId: 'callee-1',
      callType: CallType.oneToOne,
      state: CallState.active,
      topology: CallTopology.peerToPeer,
      hasVideo: true,
      createdAt: createdAt,
      answeredAt: answeredAt,
      endedAt: endedAt,
      endReason: 'hangup',
      localSdp: 'local-sdp',
      remoteSdp: 'remote-sdp',
      participants: [participant],
    );

    test('construction with all fields sets values correctly', () {
      // arrange done above

      // act/assert
      expect(session.callId, 'call-1');
      expect(session.callerId, 'caller-1');
      expect(session.calleeId, 'callee-1');
      expect(session.callType, CallType.oneToOne);
      expect(session.state, CallState.active);
      expect(session.topology, CallTopology.peerToPeer);
      expect(session.hasVideo, isTrue);
      expect(session.createdAt, createdAt);
      expect(session.answeredAt, answeredAt);
      expect(session.endedAt, endedAt);
      expect(session.endReason, 'hangup');
      expect(session.localSdp, 'local-sdp');
      expect(session.remoteSdp, 'remote-sdp');
      expect(session.participants, [participant]);
    });

    test('copyWith preserves unchanged fields', () {
      // act
      final copied = session.copyWith();

      // assert
      expect(copied, session);
      expect(identical(copied, session), isFalse);
    });

    test('copyWith overrides specified fields', () {
      // arrange
      final updatedParticipant = participant.copyWith(videoEnabled: true);
      final newEndedAt = DateTime.utc(2026, 1, 1, 10, 3, 0);

      // act
      final updated = session.copyWith(
        state: CallState.ended,
        endReason: 'network_error',
        endedAt: newEndedAt,
        participants: [updatedParticipant],
      );

      // assert
      expect(updated.state, CallState.ended);
      expect(updated.endReason, 'network_error');
      expect(updated.endedAt, newEndedAt);
      expect(updated.participants, [updatedParticipant]);
      expect(updated.callId, session.callId);
      expect(updated.callerId, session.callerId);
    });

    test('duration is answeredAt to endedAt', () {
      // act
      final duration = session.duration;

      // assert
      expect(duration, const Duration(minutes: 2));
    });

    test('duration is zero when not answered yet', () {
      // arrange
      final notAnswered = session.copyWith(clearAnsweredAt: true);

      // act
      final duration = notAnswered.duration;

      // assert
      expect(duration, Duration.zero);
    });
  });

  group('CallParticipant', () {
    test('equality uses equatable props', () {
      // arrange
      final joinedAt = DateTime.utc(2026, 1, 1, 9, 0, 0);
      final a = CallParticipant(
        userId: 'u1',
        role: ParticipantRole.callee,
        audioEnabled: true,
        videoEnabled: false,
        joinedAt: joinedAt,
      );
      final b = CallParticipant(
        userId: 'u1',
        role: ParticipantRole.callee,
        audioEnabled: true,
        videoEnabled: false,
        joinedAt: joinedAt,
      );
      final c = b.copyWith(videoEnabled: true);

      // act/assert
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('Enums', () {
    test('CallType values are available', () {
      // act/assert
      expect(CallType.values, [CallType.oneToOne, CallType.group]);
    });

    test('CallTopology values are available', () {
      // act/assert
      expect(CallTopology.values, [
        CallTopology.peerToPeer,
        CallTopology.sfu,
        CallTopology.mcu,
      ]);
    });
  });
}
