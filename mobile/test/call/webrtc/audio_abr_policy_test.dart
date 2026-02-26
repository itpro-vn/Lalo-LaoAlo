import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/webrtc/audio_abr_policy.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';

void main() {
  group('AudioAbrParams', () {
    test('equality', () {
      const a = AudioAbrParams(
        bitrateKbps: 32,
        fecEnabled: false,
        packetTimeMs: 20,
        opusComplexity: 10,
      );
      const b = AudioAbrParams(
        bitrateKbps: 32,
        fecEnabled: false,
        packetTimeMs: 20,
        opusComplexity: 10,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality on different fields', () {
      const a = AudioAbrParams(
        bitrateKbps: 32,
        fecEnabled: false,
        packetTimeMs: 20,
        opusComplexity: 10,
      );
      const b = AudioAbrParams(
        bitrateKbps: 20,
        fecEnabled: true,
        packetTimeMs: 20,
        opusComplexity: 7,
      );
      expect(a, isNot(equals(b)));
    });

    test('toString contains all fields', () {
      const p = AudioAbrParams(
        bitrateKbps: 14,
        fecEnabled: true,
        packetTimeMs: 40,
        opusComplexity: 5,
      );
      final s = p.toString();
      expect(s, contains('14'));
      expect(s, contains('true'));
      expect(s, contains('40'));
      expect(s, contains('5'));
    });
  });

  group('AudioAbrPolicy', () {
    const policy = AudioAbrPolicy();

    test('good tier returns high bitrate, FEC off, 20ms', () {
      final params = policy.paramsForTier(QualityTier.good);
      expect(params.bitrateKbps, 32);
      expect(params.fecEnabled, false);
      expect(params.packetTimeMs, 20);
      expect(params.opusComplexity, 10);
    });

    test('fair tier returns mid bitrate, FEC on, 20ms', () {
      final params = policy.paramsForTier(QualityTier.fair);
      expect(params.bitrateKbps, 20);
      expect(params.fecEnabled, true);
      expect(params.packetTimeMs, 20);
      expect(params.opusComplexity, 7);
    });

    test('poor tier returns low bitrate, FEC on, 40ms', () {
      final params = policy.paramsForTier(QualityTier.poor);
      expect(params.bitrateKbps, 14);
      expect(params.fecEnabled, true);
      expect(params.packetTimeMs, 40);
      expect(params.opusComplexity, 5);
    });

    test('custom policy values', () {
      const custom = AudioAbrPolicy(
        goodParams: AudioAbrParams(
          bitrateKbps: 48,
          fecEnabled: false,
          packetTimeMs: 10,
          opusComplexity: 10,
        ),
      );
      expect(custom.paramsForTier(QualityTier.good).bitrateKbps, 48);
      expect(custom.paramsForTier(QualityTier.good).packetTimeMs, 10);
      // Fair/poor should still use defaults.
      expect(custom.paramsForTier(QualityTier.fair).bitrateKbps, 20);
    });
  });

  group('VideoAbrParams', () {
    test('equality', () {
      const a = VideoAbrParams(
        maxBitrateKbps: 2000,
        minBitrateKbps: 1200,
        maxFramerate: 30,
        maxResolutionHeight: 720,
        scaleResolutionDownBy: 1.0,
      );
      const b = VideoAbrParams(
        maxBitrateKbps: 2000,
        minBitrateKbps: 1200,
        maxFramerate: 30,
        maxResolutionHeight: 720,
        scaleResolutionDownBy: 1.0,
      );
      expect(a, equals(b));
    });

    test('toString contains resolution', () {
      const p = VideoAbrParams(
        maxBitrateKbps: 900,
        minBitrateKbps: 400,
        maxFramerate: 20,
        maxResolutionHeight: 480,
        scaleResolutionDownBy: 1.5,
      );
      expect(p.toString(), contains('480'));
      expect(p.toString(), contains('900'));
    });
  });

  group('VideoAbrPolicy', () {
    const policy = VideoAbrPolicy();

    test('good tier returns 720p params', () {
      final params = policy.paramsForTier(QualityTier.good);
      expect(params.maxResolutionHeight, 720);
      expect(params.maxFramerate, 30);
      expect(params.maxBitrateKbps, 2000);
    });

    test('fair tier returns 480p params', () {
      final params = policy.paramsForTier(QualityTier.fair);
      expect(params.maxResolutionHeight, 480);
      expect(params.maxFramerate, 20);
    });

    test('poor tier returns 360p params', () {
      final params = policy.paramsForTier(QualityTier.poor);
      expect(params.maxResolutionHeight, 360);
      expect(params.maxFramerate, 15);
    });
  });
}
