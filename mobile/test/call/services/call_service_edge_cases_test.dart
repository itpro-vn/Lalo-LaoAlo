import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/models/call_session.dart';
import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/models/signaling_edge_events.dart';
import 'package:lalo/call/services/call_service.dart';
import 'package:lalo/core/network/signaling_client.dart';

CallSession _testSession({
  String callId = 'call-1',
  String callerId = 'user-A',
  String calleeId = 'user-B',
  bool hasVideo = false,
}) {
  return CallSession(
    callId: callId,
    callerId: callerId,
    calleeId: calleeId,
    callType: CallType.oneToOne,
    state: CallState.idle,
    topology: CallTopology.peerToPeer,
    hasVideo: hasVideo,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  late CallService service;

  setUp(() {
    service = CallService();
  });

  tearDown(() async {
    await service.dispose();
  });

  group('call_glare handling', () {
    test('emits CallGlareEvent on glare message', () async {
      final future = service.onGlare.first;

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallGlare,
          data: {
            'cancelled_call_id': 'call-1',
            'winning_call_id': 'call-2',
            'winner_user_id': 'user-A',
          },
        ),
      );

      final event = await future;
      expect(event.cancelledCallId, 'call-1');
      expect(event.winningCallId, 'call-2');
      expect(event.winnerUserId, 'user-A');
    });

    test('ends current session if callId matches cancelled call', () async {
      service.setCurrentSessionForTest(
        _testSession(callId: 'call-1'),
      );

      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallGlare,
          data: {
            'cancelled_call_id': 'call-1',
            'winning_call_id': 'call-2',
            'winner_user_id': 'user-A',
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, contains(CallState.ended));
      expect(service.currentSession, isNull);
    });

    test('does not end session if callId does not match', () async {
      service.setCurrentSessionForTest(
        _testSession(callId: 'call-99'),
      );

      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallGlare,
          data: {
            'cancelled_call_id': 'call-1',
            'winning_call_id': 'call-2',
            'winner_user_id': 'user-A',
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, isNot(contains(CallState.ended)));
      expect(service.currentSession, isNotNull);
    });

    test('emits glare event even when no current session', () async {
      final future = service.onGlare.first;

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallGlare,
          data: {
            'cancelled_call_id': 'call-1',
            'winning_call_id': 'call-2',
            'winner_user_id': 'user-A',
          },
        ),
      );

      final event = await future;
      expect(event.cancelledCallId, 'call-1');
    });
  });

  group('call_accepted_elsewhere handling', () {
    test('emits CallAcceptedElsewhereEvent on message', () async {
      final future = service.onAcceptedElsewhere.first;

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallAcceptedElsewhere,
          data: {
            'call_id': 'call-5',
            'accepted_by_device_id': 'device-xyz',
          },
        ),
      );

      final event = await future;
      expect(event.callId, 'call-5');
      expect(event.acceptedByDeviceId, 'device-xyz');
    });

    test('ends current session if callId matches', () async {
      service.setCurrentSessionForTest(
        _testSession(callId: 'call-5', hasVideo: true),
      );

      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallAcceptedElsewhere,
          data: {
            'call_id': 'call-5',
            'accepted_by_device_id': 'device-xyz',
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, contains(CallState.ended));
      expect(service.currentSession, isNull);
    });

    test('does not end session if callId does not match', () async {
      service.setCurrentSessionForTest(
        _testSession(callId: 'call-99', hasVideo: true),
      );

      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgCallAcceptedElsewhere,
          data: {
            'call_id': 'call-5',
            'accepted_by_device_id': 'device-xyz',
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, isNot(contains(CallState.ended)));
      expect(service.currentSession, isNotNull);
    });
  });

  group('state_sync handling', () {
    test('emits StateSyncEvent with active calls', () async {
      final future = service.onStateSync.first;

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgStateSync,
          data: {
            'active_calls': [
              {
                'call_id': 'c1',
                'caller_id': 'a',
                'callee_id': 'b',
                'state': 'active',
                'has_video': true,
                'created_at': 1000,
              },
            ],
          },
        ),
      );

      final event = await future;
      expect(event.activeCalls, hasLength(1));
      expect(event.activeCalls[0].callId, 'c1');
      expect(event.activeCalls[0].state, 'active');
    });

    test('emits empty activeCalls when no calls present', () async {
      final future = service.onStateSync.first;

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgStateSync,
          data: {},
        ),
      );

      final event = await future;
      expect(event.activeCalls, isEmpty);
    });

    test('does not affect current session', () async {
      service.setCurrentSessionForTest(
        _testSession(callId: 'existing-call'),
      );

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgStateSync,
          data: {
            'active_calls': [
              {
                'call_id': 'c1',
                'caller_id': 'a',
                'callee_id': 'b',
                'state': 'active',
                'has_video': false,
                'created_at': 0,
              },
            ],
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(service.currentSession?.callId, 'existing-call');
    });
  });

  group('existing reconnect messages still work', () {
    test('peer_reconnecting emits reconnecting state', () async {
      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgPeerReconnecting,
          data: {},
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, contains(CallState.reconnecting));
    });

    test('peer_reconnected emits active state', () async {
      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgPeerReconnected,
          data: {},
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, contains(CallState.active));
    });

    test('session_resumed emits active state', () async {
      final states = <CallState>[];
      service.onCallState.listen(states.add);

      service.handleSignalingMessageForTest(
        const SignalingMessage(
          type: msgSessionResumed,
          data: {},
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(states, contains(CallState.active));
    });
  });

  group('SignalingMessage seq and msgId', () {
    test('fromJson parses seq and msgId', () {
      final msg = SignalingMessage.fromJson({
        'type': 'test',
        'data': {},
        'seq': 42,
        'msg_id': 'abc-123',
      });
      expect(msg.seq, 42);
      expect(msg.msgId, 'abc-123');
    });

    test('fromJson with no seq/msgId defaults to null', () {
      final msg = SignalingMessage.fromJson({
        'type': 'test',
        'data': {},
      });
      expect(msg.seq, isNull);
      expect(msg.msgId, isNull);
    });

    test('toJson includes seq and msgId when set', () {
      const msg = SignalingMessage(
        type: 'test',
        data: {},
        seq: 10,
        msgId: 'x-1',
      );
      final json = msg.toJson();
      expect(json['seq'], 10);
      expect(json['msg_id'], 'x-1');
    });

    test('toJson excludes seq and msgId when null', () {
      const msg = SignalingMessage(
        type: 'test',
        data: {},
      );
      final json = msg.toJson();
      expect(json.containsKey('seq'), isFalse);
      expect(json.containsKey('msg_id'), isFalse);
    });
  });
}
