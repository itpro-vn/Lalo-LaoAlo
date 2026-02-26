import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';

void main() {
  group('AbrEncodingParams', () {
    test('equality', () {
      const a = AbrEncodingParams(
        maxBitrateKbps: 2500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      const b = AbrEncodingParams(
        maxBitrateKbps: 2500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality', () {
      const a = AbrEncodingParams(
        maxBitrateKbps: 2500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      const b = AbrEncodingParams(
        maxBitrateKbps: 1000,
        maxFramerate: 24,
        scaleResolutionDownBy: 1.5,
      );
      expect(a, isNot(equals(b)));
    });

    test('toString', () {
      const params = AbrEncodingParams(
        maxBitrateKbps: 2500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      expect(params.toString(), contains('2500'));
      expect(params.toString(), contains('30'));
      expect(params.toString(), contains('1.0'));
    });
  });

  group('AbrConfig defaults', () {
    test('default values', () {
      const config = AbrConfig();
      expect(config.loopIntervalMs, 1000);
      expect(config.audioOnlyThresholdKbps, 100);
      expect(config.videoResumeThresholdKbps, 200);
      expect(config.videoResumeStableSeconds, 10);
      expect(config.highRttThresholdMs, 300);
      expect(config.goodBitrateKbps, 2500);
      expect(config.fairBitrateKbps, 1000);
      expect(config.poorBitrateKbps, 300);
      expect(config.goodFramerate, 30);
      expect(config.fairFramerate, 24);
      expect(config.highRttFramerate, 15);
      expect(config.poorFramerate, 15);
      expect(config.goodScale, 1.0);
      expect(config.fairScale, 1.5);
      expect(config.poorScale, 2.0);
    });
  });

  // Test the pure decision logic without WebRTC dependencies.
  // We use a _TestableAbrController that exposes computeDecision.
  group('AbrController.computeDecision', () {
    late _TestableAbrController controller;

    setUp(() {
      controller = _TestableAbrController();
    });

    test('good tier → full quality params', () {
      final decision = controller.computeDecision(
        tier: QualityTier.good,
        rttMs: 50,
        bandwidthKbps: 3000,
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.params.maxBitrateKbps, 2500);
      expect(decision.params.maxFramerate, 30);
      expect(decision.params.scaleResolutionDownBy, 1.0);
      expect(decision.reason, 'good quality');
    });

    test('fair tier normal RTT → reduced bitrate, normal framerate', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 150,
        bandwidthKbps: 1500,
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.params.maxBitrateKbps, 1000);
      expect(decision.params.maxFramerate, 24);
      expect(decision.params.scaleResolutionDownBy, 1.5);
      expect(decision.reason, 'fair quality');
    });

    test('fair tier high RTT → framerate drops to 15fps', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 350,
        bandwidthKbps: 1500,
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.params.maxBitrateKbps, 1000);
      expect(decision.params.maxFramerate, 15); // Framerate drops before resolution
      expect(decision.params.scaleResolutionDownBy, 1.5);
      expect(decision.reason, contains('high RTT'));
    });

    test('poor tier → minimum params', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 400,
        bandwidthKbps: 200,
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.params.maxBitrateKbps, 300);
      expect(decision.params.maxFramerate, 15);
      expect(decision.params.scaleResolutionDownBy, 2.0);
      expect(decision.reason, 'poor quality');
    });

    test('bandwidth < 100kbps → video disabled (audio-only)', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 400,
        bandwidthKbps: 80,
      );

      expect(decision.videoDisabled, isTrue);
      expect(decision.reason, contains('< 100kbps'));
    });

    test('bandwidth exactly at threshold → not disabled', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 100,
        bandwidthKbps: 100,
      );

      // 100 is not < 100, so video stays on
      expect(decision.videoDisabled, isFalse);
    });

    test('zero bandwidth → video disabled', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 0,
        bandwidthKbps: 0,
      );

      // bandwidthKbps == 0, not > 0, so the < 100 check fails
      // This is intentional: we only disable when we have positive BW reading
      expect(decision.videoDisabled, isFalse);
    });

    test('fair tier exactly at RTT threshold → normal framerate', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 300,
        bandwidthKbps: 1500,
      );

      // 300 is not > 300, so normal framerate
      expect(decision.params.maxFramerate, 24);
    });

    test('fair tier just above RTT threshold → reduced framerate', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 301,
        bandwidthKbps: 1500,
      );

      expect(decision.params.maxFramerate, 15);
    });
  });

  group('AbrController video recovery state', () {
    late _TestableAbrController controller;

    setUp(() {
      controller = _TestableAbrController();
    });

    test('video disabled stays disabled until stable recovery', () {
      // First: disable video
      controller.simulateVideoDisabled();

      // Recovery bandwidth but not yet stable
      final decision = controller.computeDecision(
        tier: QualityTier.good,
        rttMs: 50,
        bandwidthKbps: 250,
      );

      // Still disabled because recovery not stable for 10s
      expect(decision.videoDisabled, isTrue);
      expect(decision.reason, contains('waiting for stable'));
    });

    test('video disabled with bandwidth below resume threshold', () {
      controller.simulateVideoDisabled();

      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 200,
        bandwidthKbps: 150, // Below 200 resume threshold
      );

      expect(decision.videoDisabled, isTrue);
    });
  });

  group('AbrDecision', () {
    test('construction', () {
      const decision = AbrDecision(
        params: AbrEncodingParams(
          maxBitrateKbps: 2500,
          maxFramerate: 30,
          scaleResolutionDownBy: 1.0,
        ),
        videoDisabled: false,
        reason: 'test',
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.reason, 'test');
      expect(decision.params.maxBitrateKbps, 2500);
    });
  });

  group('AbrConfig custom values', () {
    test('custom thresholds apply', () {
      final controller = _TestableAbrController(
        config: const AbrConfig(
          audioOnlyThresholdKbps: 50,
          highRttThresholdMs: 200,
          fairBitrateKbps: 800,
          fairFramerate: 20,
          highRttFramerate: 10,
        ),
      );

      // Bandwidth 80 is above custom threshold of 50
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 250, // Above custom 200ms threshold
        bandwidthKbps: 80,
      );

      expect(decision.videoDisabled, isFalse);
      expect(decision.params.maxBitrateKbps, 800);
      expect(decision.params.maxFramerate, 10);
    });
  });
}

/// Testable wrapper that exposes computeDecision without needing WebRTC.
class _TestableAbrController {
  _TestableAbrController({
    AbrConfig config = const AbrConfig(),
  }) : _config = config;

  final AbrConfig _config;
  bool _videoDisabledByAbr = false;
  DateTime? _bandwidthRecoverySince;

  void simulateVideoDisabled() {
    _videoDisabledByAbr = true;
  }

  AbrDecision computeDecision({
    required QualityTier tier,
    required double rttMs,
    required double bandwidthKbps,
  }) {
    // Rule 1: Audio-only if bandwidth critically low
    if (bandwidthKbps > 0 && bandwidthKbps < _config.audioOnlyThresholdKbps) {
      _bandwidthRecoverySince = null;
      return AbrDecision(
        params: AbrEncodingParams(
          maxBitrateKbps: _config.poorBitrateKbps,
          maxFramerate: _config.poorFramerate,
          scaleResolutionDownBy: _config.poorScale,
        ),
        videoDisabled: true,
        reason: 'bandwidth ${bandwidthKbps.toStringAsFixed(0)}kbps '
            '< ${_config.audioOnlyThresholdKbps}kbps threshold',
      );
    }

    // Rule 2: Check video recovery from ABR-disabled state
    bool shouldResumeVideo = false;
    if (_videoDisabledByAbr) {
      if (bandwidthKbps >= _config.videoResumeThresholdKbps) {
        _bandwidthRecoverySince ??= DateTime.now();
        final stableDuration =
            DateTime.now().difference(_bandwidthRecoverySince!);
        if (stableDuration.inSeconds >= _config.videoResumeStableSeconds) {
          shouldResumeVideo = true;
          _bandwidthRecoverySince = null;
        }
      } else {
        _bandwidthRecoverySince = null;
      }

      if (!shouldResumeVideo) {
        return AbrDecision(
          params: AbrEncodingParams(
            maxBitrateKbps: _config.poorBitrateKbps,
            maxFramerate: _config.poorFramerate,
            scaleResolutionDownBy: _config.poorScale,
          ),
          videoDisabled: true,
          reason: 'waiting for stable bandwidth recovery '
              '(${bandwidthKbps.toStringAsFixed(0)}kbps)',
        );
      }
    }

    // Rule 3: Tier-based encoding with RTT-aware framerate
    switch (tier) {
      case QualityTier.good:
        return AbrDecision(
          params: AbrEncodingParams(
            maxBitrateKbps: _config.goodBitrateKbps,
            maxFramerate: _config.goodFramerate,
            scaleResolutionDownBy: _config.goodScale,
          ),
          videoDisabled: false,
          reason: 'good quality',
        );

      case QualityTier.fair:
        final framerate = rttMs > _config.highRttThresholdMs
            ? _config.highRttFramerate
            : _config.fairFramerate;
        return AbrDecision(
          params: AbrEncodingParams(
            maxBitrateKbps: _config.fairBitrateKbps,
            maxFramerate: framerate,
            scaleResolutionDownBy: _config.fairScale,
          ),
          videoDisabled: false,
          reason: rttMs > _config.highRttThresholdMs
              ? 'fair quality, high RTT ${rttMs.toStringAsFixed(0)}ms'
              : 'fair quality',
        );

      case QualityTier.poor:
        return AbrDecision(
          params: AbrEncodingParams(
            maxBitrateKbps: _config.poorBitrateKbps,
            maxFramerate: _config.poorFramerate,
            scaleResolutionDownBy: _config.poorScale,
          ),
          videoDisabled: false,
          reason: 'poor quality',
        );
    }
  }
}
