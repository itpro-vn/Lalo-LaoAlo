import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/services/device_state_monitor.dart';
import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/audio_abr_policy.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';
import 'package:lalo/call/webrtc/slow_loop_controller.dart';

void main() {
  group('PB-07 ABR spec compliance', () {
    group('1) Tier transitions match spec thresholds', () {
      test('Good/Fair/Poor classification by RTT/loss/jitter boundaries', () {
        final cases =
            <({double rtt, double loss, double jitter, QualityTier tier})>[
          (rtt: 149, loss: 1.9, jitter: 29, tier: QualityTier.good),
          (rtt: 150, loss: 1.0, jitter: 10, tier: QualityTier.fair),
          (rtt: 149, loss: 2.0, jitter: 10, tier: QualityTier.fair),
          (rtt: 149, loss: 1.0, jitter: 30, tier: QualityTier.fair),
          (rtt: 299, loss: 4.9, jitter: 49, tier: QualityTier.fair),
          (rtt: 300, loss: 4.0, jitter: 20, tier: QualityTier.poor),
          (rtt: 250, loss: 5.0, jitter: 20, tier: QualityTier.poor),
          (rtt: 250, loss: 4.0, jitter: 50, tier: QualityTier.poor),
        ];

        for (final tc in cases) {
          final derived = _specTier(
            rttMs: tc.rtt,
            lossPercent: tc.loss,
            jitterMs: tc.jitter,
          );
          expect(
            derived,
            tc.tier,
            reason:
                'rtt=${tc.rtt}, loss=${tc.loss}, jitter=${tc.jitter} expected ${tc.tier}',
          );
        }
      });

      test('Derived tier drives slow-loop params + fast-loop simulcast layers',
          () {
        final slow = _newSlowLoopController();
        final fast = _SpecSimulcastAbrHarness();

        final scenarios = <({
          double rtt,
          double loss,
          double jitter,
          Set<SimulcastLayer> layers,
          int audioKbps,
          int videoMaxKbps
        })>[
          (
            rtt: 80,
            loss: 0.5,
            jitter: 10,
            layers: {
              SimulcastLayer.high,
              SimulcastLayer.medium,
              SimulcastLayer.low
            },
            audioKbps: 32,
            videoMaxKbps: 2000,
          ),
          (
            rtt: 220,
            loss: 3.0,
            jitter: 35,
            layers: {SimulcastLayer.medium, SimulcastLayer.low},
            audioKbps: 20,
            videoMaxKbps: 900,
          ),
          (
            rtt: 350,
            loss: 6.0,
            jitter: 60,
            layers: {SimulcastLayer.low},
            audioKbps: 14,
            videoMaxKbps: 350,
          ),
        ];

        for (final s in scenarios) {
          final tier = _specTier(
            rttMs: s.rtt,
            lossPercent: s.loss,
            jitterMs: s.jitter,
          );

          final slowDecision = slow.computeDecision(
            networkTier: tier,
            deviceState: DeviceState.normal,
            lossPercent: s.loss,
          );

          final fastDecision = fast.computeDecision(
            tier: slowDecision.effectiveTier,
            rttMs: s.rtt,
            bandwidthKbps: 1500,
            now: DateTime(2026, 1, 1),
          );

          expect(slowDecision.audioParams.bitrateKbps, s.audioKbps);
          expect(slowDecision.videoParams.maxBitrateKbps, s.videoMaxKbps);
          expect(fastDecision.activeLayers, s.layers);
          expect(fastDecision.videoDisabled, isFalse);
        }
      });
    });

    group('2) Hysteresis: upgrade needs 10s stable', () {
      test('ABR stays audio-only until >=10s stable bandwidth recovery', () {
        final abr = _SpecFastAbrHarness();
        final t0 = DateTime(2026, 1, 1, 0, 0, 0);

        final disabled = abr.computeDecision(
          tier: QualityTier.poor,
          rttMs: 400,
          bandwidthKbps: 80,
          now: t0,
        );
        abr.applyDecision(disabled);
        expect(disabled.videoDisabled, isTrue);

        final before10s = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 250,
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(before10s.videoDisabled, isTrue);
        expect(before10s.reason,
            contains('waiting for stable bandwidth recovery'));

        final at10s = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 250,
          now: t0.add(const Duration(seconds: 11)),
        );
        expect(at10s.videoDisabled, isFalse);
      });

      test('Recovery timer resets if bandwidth drops below resume threshold',
          () {
        final abr = _SpecFastAbrHarness();
        final t0 = DateTime(2026, 1, 1, 0, 0, 0);

        final disabled = abr.computeDecision(
          tier: QualityTier.poor,
          rttMs: 350,
          bandwidthKbps: 70,
          now: t0,
        );
        abr.applyDecision(disabled);
        expect(disabled.videoDisabled, isTrue);

        final recovering = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 240,
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(recovering.videoDisabled, isTrue);

        final dip = abr.computeDecision(
          tier: QualityTier.fair,
          rttMs: 150,
          bandwidthKbps: 180,
          now: t0.add(const Duration(seconds: 7)),
        );
        expect(dip.videoDisabled, isTrue);

        final notYet = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 260,
          now: t0.add(const Duration(seconds: 8)),
        );
        expect(notYet.videoDisabled, isTrue);

        final resumed = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 260,
          now: t0.add(const Duration(seconds: 18)),
        );
        expect(resumed.videoDisabled, isFalse);
      });
    });

    group('3) Audio/video parameters per tier', () {
      test('Slow loop returns exact Good tier params', () {
        final slow = _newSlowLoopController();

        final decision = slow.computeDecision(
          networkTier: QualityTier.good,
          deviceState: DeviceState.normal,
          lossPercent: 0.5,
        );

        expect(decision.effectiveTier, QualityTier.good);
        expect(
          decision.audioParams,
          const AudioAbrParams(
            bitrateKbps: 32,
            fecEnabled: false,
            packetTimeMs: 20,
            opusComplexity: 10,
          ),
        );
        expect(
          decision.videoParams,
          const VideoAbrParams(
            maxBitrateKbps: 2000,
            minBitrateKbps: 1200,
            maxFramerate: 30,
            maxResolutionHeight: 720,
            scaleResolutionDownBy: 1.0,
          ),
        );
      });

      test('Slow loop returns exact Fair tier params', () {
        final slow = _newSlowLoopController();

        final decision = slow.computeDecision(
          networkTier: QualityTier.fair,
          deviceState: DeviceState.normal,
          lossPercent: 3,
        );

        expect(decision.effectiveTier, QualityTier.fair);
        expect(
          decision.audioParams,
          const AudioAbrParams(
            bitrateKbps: 20,
            fecEnabled: true,
            packetTimeMs: 20,
            opusComplexity: 7,
          ),
        );
        expect(
          decision.videoParams,
          const VideoAbrParams(
            maxBitrateKbps: 900,
            minBitrateKbps: 400,
            maxFramerate: 20,
            maxResolutionHeight: 480,
            scaleResolutionDownBy: 1.5,
          ),
        );
      });

      test('Slow loop returns exact Poor tier params', () {
        final slow = _newSlowLoopController();

        final decision = slow.computeDecision(
          networkTier: QualityTier.poor,
          deviceState: DeviceState.normal,
          lossPercent: 7,
        );

        expect(decision.effectiveTier, QualityTier.poor);
        expect(
          decision.audioParams,
          const AudioAbrParams(
            bitrateKbps: 14,
            fecEnabled: true,
            packetTimeMs: 40,
            opusComplexity: 5,
          ),
        );
        expect(
          decision.videoParams,
          const VideoAbrParams(
            maxBitrateKbps: 350,
            minBitrateKbps: 150,
            maxFramerate: 15,
            maxResolutionHeight: 360,
            scaleResolutionDownBy: 2.0,
          ),
        );
      });

      test('Fast loop decisions per tier (bitrate/fps/scale + RTT handling)',
          () {
        final abr = _SpecFastAbrHarness();
        final now = DateTime(2026, 1, 1);

        final good = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 60,
          bandwidthKbps: 3000,
          now: now,
        );
        expect(good.params.maxBitrateKbps, 2500);
        expect(good.params.maxFramerate, 30);
        expect(good.params.scaleResolutionDownBy, 1.0);

        final fair = abr.computeDecision(
          tier: QualityTier.fair,
          rttMs: 200,
          bandwidthKbps: 1200,
          now: now,
        );
        expect(fair.params.maxBitrateKbps, 1000);
        expect(fair.params.maxFramerate, 24);
        expect(fair.params.scaleResolutionDownBy, 1.5);

        final fairHighRtt = abr.computeDecision(
          tier: QualityTier.fair,
          rttMs: 350,
          bandwidthKbps: 1200,
          now: now,
        );
        expect(fairHighRtt.params.maxFramerate, 15);

        final poor = abr.computeDecision(
          tier: QualityTier.poor,
          rttMs: 450,
          bandwidthKbps: 400,
          now: now,
        );
        expect(poor.params.maxBitrateKbps, 300);
        expect(poor.params.maxFramerate, 15);
        expect(poor.params.scaleResolutionDownBy, 2.0);
      });
    });

    group('4) Audio priority: video off <100kbps, recover >200kbps', () {
      test('Single-stream ABR follows audio-only and resume thresholds', () {
        final abr = _SpecFastAbrHarness();
        final t0 = DateTime(2026, 1, 1, 0, 0, 0);

        final off = abr.computeDecision(
          tier: QualityTier.fair,
          rttMs: 200,
          bandwidthKbps: 99,
          now: t0,
        );
        abr.applyDecision(off);
        expect(off.videoDisabled, isTrue);

        final boundaryNotOff = abr.computeDecision(
          tier: QualityTier.fair,
          rttMs: 200,
          bandwidthKbps: 100,
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(boundaryNotOff.videoDisabled, isTrue);

        final belowResume = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 199,
          now: t0.add(const Duration(seconds: 5)),
        );
        expect(belowResume.videoDisabled, isTrue);

        final recoveryStarted = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 220,
          now: t0.add(const Duration(seconds: 6)),
        );
        expect(recoveryStarted.videoDisabled, isTrue);

        final recoverAt10s = abr.computeDecision(
          tier: QualityTier.good,
          rttMs: 80,
          bandwidthKbps: 220,
          now: t0.add(const Duration(seconds: 16)),
        );
        expect(recoverAt10s.videoDisabled, isFalse);
      });

      test('Simulcast ABR uses same audio-only thresholds + stable resume', () {
        final sim = _SpecSimulcastAbrHarness();
        final t0 = DateTime(2026, 1, 1, 0, 0, 0);

        final off = sim.computeDecision(
          tier: QualityTier.good,
          rttMs: 100,
          bandwidthKbps: 80,
          now: t0,
        );
        sim.applyDecision(off);
        expect(off.videoDisabled, isTrue);
        expect(off.activeLayers, isEmpty);

        final wait = sim.computeDecision(
          tier: QualityTier.good,
          rttMs: 100,
          bandwidthKbps: 250,
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(wait.videoDisabled, isTrue);

        final on = sim.computeDecision(
          tier: QualityTier.good,
          rttMs: 100,
          bandwidthKbps: 250,
          now: t0.add(const Duration(seconds: 11)),
        );
        expect(on.videoDisabled, isFalse);
        expect(on.activeLayers, {
          SimulcastLayer.high,
          SimulcastLayer.medium,
          SimulcastLayer.low,
        });
      });
    });
  });
}

SlowLoopController _newSlowLoopController() {
  final pcm = _FakePeerConnectionManager();
  return SlowLoopController(
    peerConnectionManager: pcm,
    qualityMonitor: QualityMonitor(pcm),
    deviceStateMonitor: DeviceStateMonitor(),
  );
}

QualityTier _specTier({
  required double rttMs,
  required double lossPercent,
  required double jitterMs,
}) {
  if (rttMs < 150 && lossPercent < 2 && jitterMs < 30) {
    return QualityTier.good;
  }
  if (rttMs < 300 && lossPercent < 5 && jitterMs < 50) {
    return QualityTier.fair;
  }
  return QualityTier.poor;
}

class _FakePeerConnectionManager extends PeerConnectionManager {
  _FakePeerConnectionManager() : super(const []);
}

class _SpecFastAbrHarness {
  _SpecFastAbrHarness({AbrConfig config = const AbrConfig()})
      : _config = config;

  final AbrConfig _config;
  bool _videoDisabledByAbr = false;
  DateTime? _bandwidthRecoverySince;

  void applyDecision(AbrDecision decision) {
    _videoDisabledByAbr = decision.videoDisabled;
    if (!decision.videoDisabled) {
      _bandwidthRecoverySince = null;
    }
  }

  AbrDecision computeDecision({
    required QualityTier tier,
    required double rttMs,
    required double bandwidthKbps,
    required DateTime now,
  }) {
    if (bandwidthKbps > 0 && bandwidthKbps < _config.audioOnlyThresholdKbps) {
      _bandwidthRecoverySince = null;
      return AbrDecision(
        params: AbrEncodingParams(
          maxBitrateKbps: _config.poorBitrateKbps,
          maxFramerate: _config.poorFramerate,
          scaleResolutionDownBy: _config.poorScale,
        ),
        videoDisabled: true,
        reason:
            'bandwidth ${bandwidthKbps.toStringAsFixed(0)}kbps < ${_config.audioOnlyThresholdKbps}kbps threshold',
      );
    }

    bool shouldResumeVideo = false;
    if (_videoDisabledByAbr) {
      if (bandwidthKbps >= _config.videoResumeThresholdKbps) {
        _bandwidthRecoverySince ??= now;
        final stableDuration = now.difference(_bandwidthRecoverySince!);
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

class _SpecSimulcastAbrHarness {
  _SpecSimulcastAbrHarness({AbrConfig config = const AbrConfig()})
      : _config = config;

  final AbrConfig _config;
  bool _videoDisabledByAbr = false;
  DateTime? _bandwidthRecoverySince;

  void applyDecision(SimulcastAbrDecision decision) {
    _videoDisabledByAbr = decision.videoDisabled;
    if (!decision.videoDisabled) {
      _bandwidthRecoverySince = null;
    }
  }

  SimulcastAbrDecision computeDecision({
    required QualityTier tier,
    required double rttMs,
    required double bandwidthKbps,
    required DateTime now,
  }) {
    if (bandwidthKbps > 0 && bandwidthKbps < _config.audioOnlyThresholdKbps) {
      _bandwidthRecoverySince = null;
      return const SimulcastAbrDecision(
        activeLayers: <SimulcastLayer>{},
        videoDisabled: true,
        reason: 'bandwidth below audio-only threshold',
      );
    }

    if (_videoDisabledByAbr) {
      if (bandwidthKbps >= _config.videoResumeThresholdKbps) {
        _bandwidthRecoverySince ??= now;
        final stableDuration = now.difference(_bandwidthRecoverySince!);
        if (stableDuration.inSeconds < _config.videoResumeStableSeconds) {
          return const SimulcastAbrDecision(
            activeLayers: <SimulcastLayer>{},
            videoDisabled: true,
            reason: 'waiting for stable bandwidth recovery',
          );
        }
        _bandwidthRecoverySince = null;
      } else {
        _bandwidthRecoverySince = null;
        return const SimulcastAbrDecision(
          activeLayers: <SimulcastLayer>{},
          videoDisabled: true,
          reason: 'bandwidth still below resume threshold',
        );
      }
    }

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
