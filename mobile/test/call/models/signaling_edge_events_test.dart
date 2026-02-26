import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/signaling_edge_events.dart';

void main() {
  group('CallGlareEvent', () {
    test('fromJson creates event with all fields', () {
      final event = CallGlareEvent.fromJson({
        'cancelled_call_id': 'call-123',
        'winning_call_id': 'call-456',
        'winner_user_id': 'user-A',
      });
      expect(event.cancelledCallId, 'call-123');
      expect(event.winningCallId, 'call-456');
      expect(event.winnerUserId, 'user-A');
    });

    test('fromJson handles camelCase keys', () {
      final event = CallGlareEvent.fromJson({
        'cancelledCallId': 'c1',
        'winningCallId': 'c2',
        'winnerUserId': 'u1',
      });
      expect(event.cancelledCallId, 'c1');
      expect(event.winningCallId, 'c2');
      expect(event.winnerUserId, 'u1');
    });

    test('fromJson handles missing keys gracefully', () {
      final event = CallGlareEvent.fromJson({});
      expect(event.cancelledCallId, '');
      expect(event.winningCallId, '');
      expect(event.winnerUserId, '');
    });

    test('toJson produces snake_case keys', () {
      const event = CallGlareEvent(
        cancelledCallId: 'c1',
        winningCallId: 'c2',
        winnerUserId: 'u1',
      );
      final json = event.toJson();
      expect(json['cancelled_call_id'], 'c1');
      expect(json['winning_call_id'], 'c2');
      expect(json['winner_user_id'], 'u1');
    });

    test('equality via Equatable', () {
      const a = CallGlareEvent(
        cancelledCallId: 'c1',
        winningCallId: 'c2',
        winnerUserId: 'u1',
      );
      const b = CallGlareEvent(
        cancelledCallId: 'c1',
        winningCallId: 'c2',
        winnerUserId: 'u1',
      );
      const c = CallGlareEvent(
        cancelledCallId: 'c1',
        winningCallId: 'c2',
        winnerUserId: 'u2',
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('roundtrip toJson/fromJson preserves data', () {
      const original = CallGlareEvent(
        cancelledCallId: 'c1',
        winningCallId: 'c2',
        winnerUserId: 'u1',
      );
      final roundTrip = CallGlareEvent.fromJson(original.toJson());
      expect(roundTrip, equals(original));
    });
  });

  group('CallAcceptedElsewhereEvent', () {
    test('fromJson creates event with all fields', () {
      final event = CallAcceptedElsewhereEvent.fromJson({
        'call_id': 'call-789',
        'accepted_by_device_id': 'device-abc',
      });
      expect(event.callId, 'call-789');
      expect(event.acceptedByDeviceId, 'device-abc');
    });

    test('fromJson handles camelCase keys', () {
      final event = CallAcceptedElsewhereEvent.fromJson({
        'callId': 'c1',
        'acceptedByDeviceId': 'd1',
      });
      expect(event.callId, 'c1');
      expect(event.acceptedByDeviceId, 'd1');
    });

    test('fromJson handles missing keys gracefully', () {
      final event = CallAcceptedElsewhereEvent.fromJson({});
      expect(event.callId, '');
      expect(event.acceptedByDeviceId, '');
    });

    test('toJson produces snake_case keys', () {
      const event = CallAcceptedElsewhereEvent(
        callId: 'c1',
        acceptedByDeviceId: 'd1',
      );
      final json = event.toJson();
      expect(json['call_id'], 'c1');
      expect(json['accepted_by_device_id'], 'd1');
    });

    test('equality via Equatable', () {
      const a = CallAcceptedElsewhereEvent(
        callId: 'c1',
        acceptedByDeviceId: 'd1',
      );
      const b = CallAcceptedElsewhereEvent(
        callId: 'c1',
        acceptedByDeviceId: 'd1',
      );
      const c = CallAcceptedElsewhereEvent(
        callId: 'c2',
        acceptedByDeviceId: 'd1',
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('roundtrip toJson/fromJson preserves data', () {
      const original = CallAcceptedElsewhereEvent(
        callId: 'c1',
        acceptedByDeviceId: 'd1',
      );
      final roundTrip =
          CallAcceptedElsewhereEvent.fromJson(original.toJson());
      expect(roundTrip, equals(original));
    });
  });

  group('StateSyncCall', () {
    test('fromJson creates call with all fields', () {
      final call = StateSyncCall.fromJson({
        'call_id': 'call-1',
        'caller_id': 'user-A',
        'callee_id': 'user-B',
        'state': 'active',
        'has_video': true,
        'created_at': 1708300000000,
      });
      expect(call.callId, 'call-1');
      expect(call.callerId, 'user-A');
      expect(call.calleeId, 'user-B');
      expect(call.state, 'active');
      expect(call.hasVideo, true);
      expect(call.createdAt, 1708300000000);
    });

    test('fromJson handles defaults for missing fields', () {
      final call = StateSyncCall.fromJson({});
      expect(call.callId, '');
      expect(call.callerId, '');
      expect(call.calleeId, '');
      expect(call.state, '');
      expect(call.hasVideo, false);
      expect(call.createdAt, 0);
    });

    test('toJson produces expected output', () {
      const call = StateSyncCall(
        callId: 'c1',
        callerId: 'a',
        calleeId: 'b',
        state: 'ringing',
        hasVideo: false,
        createdAt: 1000,
      );
      final json = call.toJson();
      expect(json['call_id'], 'c1');
      expect(json['caller_id'], 'a');
      expect(json['callee_id'], 'b');
      expect(json['state'], 'ringing');
      expect(json['has_video'], false);
      expect(json['created_at'], 1000);
    });

    test('equality via Equatable', () {
      const a = StateSyncCall(
        callId: 'c1',
        callerId: 'a',
        calleeId: 'b',
        state: 'active',
        hasVideo: true,
        createdAt: 1000,
      );
      const b = StateSyncCall(
        callId: 'c1',
        callerId: 'a',
        calleeId: 'b',
        state: 'active',
        hasVideo: true,
        createdAt: 1000,
      );
      expect(a, equals(b));
    });
  });

  group('StateSyncEvent', () {
    test('fromJson with active calls', () {
      final event = StateSyncEvent.fromJson({
        'active_calls': [
          {
            'call_id': 'c1',
            'caller_id': 'a',
            'callee_id': 'b',
            'state': 'active',
            'has_video': true,
            'created_at': 1000,
          },
          {
            'call_id': 'c2',
            'caller_id': 'c',
            'callee_id': 'd',
            'state': 'ringing',
            'has_video': false,
            'created_at': 2000,
          },
        ],
      });
      expect(event.activeCalls, hasLength(2));
      expect(event.activeCalls[0].callId, 'c1');
      expect(event.activeCalls[1].callId, 'c2');
    });

    test('fromJson with camelCase key', () {
      final event = StateSyncEvent.fromJson({
        'activeCalls': [
          {
            'call_id': 'c1',
            'caller_id': 'a',
            'callee_id': 'b',
            'state': 'active',
            'has_video': false,
            'created_at': 0,
          },
        ],
      });
      expect(event.activeCalls, hasLength(1));
    });

    test('fromJson with no calls returns empty list', () {
      final event = StateSyncEvent.fromJson({});
      expect(event.activeCalls, isEmpty);
    });

    test('fromJson with null active_calls returns empty list', () {
      final event = StateSyncEvent.fromJson({'active_calls': null});
      expect(event.activeCalls, isEmpty);
    });

    test('fromJson filters out non-map entries', () {
      final event = StateSyncEvent.fromJson({
        'active_calls': [
          {
            'call_id': 'c1',
            'caller_id': 'a',
            'callee_id': 'b',
            'state': 'active',
            'has_video': false,
            'created_at': 0,
          },
          'not a map',
          42,
        ],
      });
      expect(event.activeCalls, hasLength(1));
    });

    test('toJson roundtrip preserves data', () {
      const original = StateSyncEvent(
        activeCalls: [
          StateSyncCall(
            callId: 'c1',
            callerId: 'a',
            calleeId: 'b',
            state: 'active',
            hasVideo: true,
            createdAt: 1000,
          ),
        ],
      );
      final roundTrip = StateSyncEvent.fromJson(original.toJson());
      expect(roundTrip, equals(original));
    });

    test('equality via Equatable', () {
      const a = StateSyncEvent(activeCalls: []);
      const b = StateSyncEvent(activeCalls: []);
      expect(a, equals(b));
    });
  });
}
