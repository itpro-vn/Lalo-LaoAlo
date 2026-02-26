import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/models/group_call_models.dart';

void main() {
  group('LayerUpdateEvent', () {
    test('fromJson parses standard keys', () {
      final event = LayerUpdateEvent.fromJson(<String, dynamic>{
        'room_id': 'room-1',
        'track_sid': 'TR_abc',
        'layer': 'h',
        'publisher_id': 'user-42',
        'reason': 'bandwidth',
      });
      expect(event.roomId, 'room-1');
      expect(event.trackSid, 'TR_abc');
      expect(event.layer, 'h');
      expect(event.publisherId, 'user-42');
      expect(event.reason, 'bandwidth');
    });

    test('fromJson handles camelCase keys', () {
      final event = LayerUpdateEvent.fromJson(<String, dynamic>{
        'roomId': 'room-2',
        'trackSid': 'TR_xyz',
        'layer': 'm',
      });
      expect(event.roomId, 'room-2');
      expect(event.trackSid, 'TR_xyz');
      expect(event.layer, 'm');
      expect(event.publisherId, isNull);
      expect(event.reason, isNull);
    });

    test('fromJson handles missing optional fields', () {
      final event = LayerUpdateEvent.fromJson(<String, dynamic>{
        'room_id': 'room-3',
        'track_sid': 'TR_123',
        'layer': 'l',
      });
      expect(event.publisherId, isNull);
      expect(event.reason, isNull);
    });

    test('toJson produces correct output', () {
      const event = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'h',
        publisherId: 'user-42',
        reason: 'manual',
      );
      final json = event.toJson();
      expect(json['room_id'], 'room-1');
      expect(json['track_sid'], 'TR_abc');
      expect(json['layer'], 'h');
      expect(json['publisher_id'], 'user-42');
      expect(json['reason'], 'manual');
    });

    test('toJson omits empty optional fields', () {
      const event = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'm',
      );
      final json = event.toJson();
      expect(json.containsKey('publisher_id'), false);
      expect(json.containsKey('reason'), false);
    });

    test('equality', () {
      const a = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'h',
      );
      const b = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'h',
      );
      expect(a, equals(b));
    });

    test('inequality', () {
      const a = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'h',
      );
      const b = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'm',
      );
      expect(a, isNot(equals(b)));
    });

    test('fromJson round-trips via toJson', () {
      const original = LayerUpdateEvent(
        roomId: 'room-1',
        trackSid: 'TR_abc',
        layer: 'l',
        publisherId: 'user-99',
        reason: 'speaker',
      );
      final json = original.toJson();
      final decoded = LayerUpdateEvent.fromJson(json);
      expect(decoded, equals(original));
    });
  });
}
