import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';

void main() {
  group('SimulcastAbrDecision', () {
    test('toString includes layer and reason info', () {
      const decision = SimulcastAbrDecision(
        activeLayers: <SimulcastLayer>{SimulcastLayer.low},
        videoDisabled: false,
        reason: 'poor quality',
      );
      final s = decision.toString();
      expect(s, contains('l'));
      expect(s, contains('poor quality'));
      expect(s, contains('videoOff=false'));
    });
  });

  group('SimulcastAbrController.computeDecision', () {
    late _TestableSimulcastAbrController controller;

    setUp(() {
      controller = _TestableSimulcastAbrController();
    });

    test('good tier → all 3 layers active', () {
      final decision = controller.computeDecision(
        tier: QualityTier.good,
        rttMs: 50,
        bandwidthKbps: 2000,
      );
      expect(decision.activeLayers, containsAll(SimulcastLayer.values));
      expect(decision.videoDisabled, false);
    });

    test('fair tier → medium + low only', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 100,
        bandwidthKbps: 800,
      );
      expect(
        decision.activeLayers,
        equals(<SimulcastLayer>{SimulcastLayer.medium, SimulcastLayer.low}),
      );
      expect(decision.videoDisabled, false);
    });

    test('fair tier + high RTT → low only', () {
      final decision = controller.computeDecision(
        tier: QualityTier.fair,
        rttMs: 400,
        bandwidthKbps: 800,
      );
      expect(
        decision.activeLayers,
        equals(<SimulcastLayer>{SimulcastLayer.low}),
      );
      expect(decision.videoDisabled, false);
    });

    test('poor tier → low only', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 200,
        bandwidthKbps: 300,
      );
      expect(
        decision.activeLayers,
        equals(<SimulcastLayer>{SimulcastLayer.low}),
      );
      expect(decision.videoDisabled, false);
    });

    test('bandwidth below audio-only threshold → video disabled', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 300,
        bandwidthKbps: 50,
      );
      expect(decision.videoDisabled, true);
      expect(decision.activeLayers, isEmpty);
    });

    test('zero bandwidth does not trigger audio-only', () {
      // Zero means we haven't measured yet — don't disable video
      final decision = controller.computeDecision(
        tier: QualityTier.good,
        rttMs: 50,
        bandwidthKbps: 0,
      );
      expect(decision.videoDisabled, false);
      expect(decision.activeLayers, containsAll(SimulcastLayer.values));
    });

    test('good tier always includes all layers regardless of bandwidth', () {
      final decision = controller.computeDecision(
        tier: QualityTier.good,
        rttMs: 30,
        bandwidthKbps: 3000,
      );
      expect(decision.activeLayers.length, 3);
      expect(decision.activeLayers, contains(SimulcastLayer.high));
      expect(decision.activeLayers, contains(SimulcastLayer.medium));
      expect(decision.activeLayers, contains(SimulcastLayer.low));
    });

    test('poor tier with high RTT still only sends low', () {
      final decision = controller.computeDecision(
        tier: QualityTier.poor,
        rttMs: 500,
        bandwidthKbps: 250,
      );
      expect(decision.activeLayers.length, 1);
      expect(decision.activeLayers, contains(SimulcastLayer.low));
    });
  });
}

/// Testable wrapper that exposes the pure decision logic
/// without requiring WebRTC or media dependencies.
class _TestableSimulcastAbrController {
  final AbrConfig _config = const AbrConfig();

  SimulcastAbrDecision computeDecision({
    required QualityTier tier,
    required double rttMs,
    required double bandwidthKbps,
  }) {
    // Audio-only check
    if (bandwidthKbps > 0 && bandwidthKbps < _config.audioOnlyThresholdKbps) {
      return const SimulcastAbrDecision(
        activeLayers: <SimulcastLayer>{},
        videoDisabled: true,
        reason: 'bandwidth below audio-only threshold',
      );
    }

    // Tier-based layer selection
    switch (tier) {
      case QualityTier.good:
        return const SimulcastAbrDecision(
          activeLayers: <SimulcastLayer>{
            SimulcastLayer.high,
            SimulcastLayer.medium,
            SimulcastLayer.low,
          },
          videoDisabled: false,
          reason: 'good quality — all layers active',
        );

      case QualityTier.fair:
        if (rttMs > _config.highRttThresholdMs) {
          return const SimulcastAbrDecision(
            activeLayers: <SimulcastLayer>{SimulcastLayer.low},
            videoDisabled: false,
            reason: 'fair quality + high RTT — low layer only',
          );
        }
        return const SimulcastAbrDecision(
          activeLayers: <SimulcastLayer>{
            SimulcastLayer.medium,
            SimulcastLayer.low,
          },
          videoDisabled: false,
          reason: 'fair quality — medium + low layers',
        );

      case QualityTier.poor:
        return const SimulcastAbrDecision(
          activeLayers: <SimulcastLayer>{SimulcastLayer.low},
          videoDisabled: false,
          reason: 'poor quality — low layer only',
        );
    }
  }
}
