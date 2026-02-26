import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/group_call_models.dart';

void main() {
  group('PolicyUpdateEvent', () {
    test('fromJson parses all fields', () {
      final json = {
        'room_id': 'room-123',
        'max_tier': 'fair',
        'force_audio_only': true,
        'max_bitrate_kbps': 500,
        'force_codec': 'vp8',
        'reason': 'high loss detected',
      };
      final event = PolicyUpdateEvent.fromJson(json);
      expect(event.roomId, 'room-123');
      expect(event.maxTier, 'fair');
      expect(event.forceAudioOnly, true);
      expect(event.maxBitrateKbps, 500);
      expect(event.forceCodec, 'vp8');
      expect(event.reason, 'high loss detected');
    });

    test('fromJson handles minimal payload', () {
      final json = {'room_id': 'room-456'};
      final event = PolicyUpdateEvent.fromJson(json);
      expect(event.roomId, 'room-456');
      expect(event.maxTier, null);
      expect(event.forceAudioOnly, null);
      expect(event.maxBitrateKbps, null);
      expect(event.forceCodec, null);
      expect(event.reason, null);
    });

    test('toJson round-trips', () {
      const event = PolicyUpdateEvent(
        roomId: 'room-789',
        maxTier: 'poor',
        forceAudioOnly: false,
        maxBitrateKbps: 300,
        forceCodec: 'h264',
        reason: 'server policy',
      );
      final json = event.toJson();
      final restored = PolicyUpdateEvent.fromJson(json);
      expect(restored.roomId, event.roomId);
      expect(restored.maxTier, event.maxTier);
      expect(restored.forceAudioOnly, event.forceAudioOnly);
      expect(restored.maxBitrateKbps, event.maxBitrateKbps);
      expect(restored.forceCodec, event.forceCodec);
    });

    test('toJson omits null fields', () {
      const event = PolicyUpdateEvent(roomId: 'room-abc');
      final json = event.toJson();
      expect(json.containsKey('room_id'), true);
      expect(json.containsKey('max_tier'), false);
      expect(json.containsKey('force_audio_only'), false);
      expect(json.containsKey('max_bitrate_kbps'), false);
      expect(json.containsKey('force_codec'), false);
      expect(json.containsKey('reason'), false);
    });

    test('equatable props', () {
      const a = PolicyUpdateEvent(
        roomId: 'room-1',
        maxTier: 'fair',
      );
      const b = PolicyUpdateEvent(
        roomId: 'room-1',
        maxTier: 'fair',
      );
      expect(a, equals(b));
    });
  });
}
