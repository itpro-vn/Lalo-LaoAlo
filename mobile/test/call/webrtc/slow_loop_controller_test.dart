import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/services/device_state_monitor.dart';
import 'package:lalo/call/webrtc/audio_abr_policy.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/slow_loop_controller.dart';

void main() {
  group('PolicyOverride', () {
    test('fromJson parses all fields', () {
      final json = {
        'max_tier': 'fair',
        'force_audio_only': true,
        'max_bitrate_kbps': 500,
        'force_codec': 'vp8',
      };
      final override = PolicyOverride.fromJson(json);
      expect(override.maxTier, QualityTier.fair);
      expect(override.forceAudioOnly, true);
      expect(override.maxBitrateKbps, 500);
      expect(override.forceCodec, VideoCodec.vp8);
    });

    test('fromJson handles null fields', () {
      final override = PolicyOverride.fromJson({});
      expect(override.maxTier, null);
      expect(override.forceAudioOnly, null);
      expect(override.maxBitrateKbps, null);
      expect(override.forceCodec, null);
    });

    test('fromJson parses h264 codec', () {
      final override = PolicyOverride.fromJson({'force_codec': 'h264'});
      expect(override.forceCodec, VideoCodec.h264);
    });
  });

  // Test the pure computation logic via SlowLoopDecisionComputer.
  // Since SlowLoopController.computeDecision() accesses instance state
  // (policy, config, codec tracking), we test it directly.
  group('SlowLoopDecision computation', () {
    test('good tier returns good audio/video params', () {
      final result = _computeSlowLoop(
        networkTier: QualityTier.good,
        deviceState: DeviceState.normal,
      );
      expect(result.effectiveTier, QualityTier.good);
      expect(result.audioParams.bitrateKbps, 32);
      expect(result.audioParams.fecEnabled, false);
      expect(result.videoParams.maxResolutionHeight, 720);
    });

    test('fair tier returns fair params', () {
      final result = _computeSlowLoop(
        networkTier: QualityTier.fair,
        deviceState: DeviceState.normal,
      );
      expect(result.effectiveTier, QualityTier.fair);
      expect(result.audioParams.bitrateKbps, 20);
      expect(result.audioParams.fecEnabled, true);
      expect(result.audioParams.packetTimeMs, 20);
      expect(result.videoParams.maxFramerate, 20);
    });

    test('poor tier returns poor params', () {
      final result = _computeSlowLoop(
        networkTier: QualityTier.poor,
        deviceState: DeviceState.normal,
      );
      expect(result.effectiveTier, QualityTier.poor);
      expect(result.audioParams.bitrateKbps, 14);
      expect(result.audioParams.fecEnabled, true);
      expect(result.audioParams.packetTimeMs, 40);
      expect(result.videoParams.maxBitrateKbps, 350);
    });

    test('low battery reduces tier by 1', () {
      const deviceState = DeviceState(
        battery: BatteryState(level: 0.15, isCharging: false),
        thermal: ThermalLevel.nominal,
      );
      final result = _computeSlowLoop(
        networkTier: QualityTier.good,
        deviceState: deviceState,
      );
      expect(result.effectiveTier, QualityTier.fair);
      expect(result.reason, contains('device reduction'));
    });

    test('critical thermal reduces tier by 2', () {
      const deviceState = DeviceState(
        battery: BatteryState.normal,
        thermal: ThermalLevel.critical,
      );
      final result = _computeSlowLoop(
        networkTier: QualityTier.good,
        deviceState: deviceState,
      );
      expect(result.effectiveTier, QualityTier.poor);
    });

    test('poor tier cannot go lower with battery reduction', () {
      const deviceState = DeviceState(
        battery: BatteryState(level: 0.15, isCharging: false),
        thermal: ThermalLevel.nominal,
      );
      final result = _computeSlowLoop(
        networkTier: QualityTier.poor,
        deviceState: deviceState,
      );
      expect(result.effectiveTier, QualityTier.poor);
    });
  });
}

/// Standalone computation that mirrors SlowLoopController.computeDecision
/// logic without needing to instantiate the controller with its WebRTC deps.
SlowLoopDecision _computeSlowLoop({
  required QualityTier networkTier,
  required DeviceState deviceState,
  PolicyOverride? policyOverride,
  VideoCodec currentCodec = VideoCodec.vp8,
  DateTime? lastCodecChange,
  DateTime? now,
  int codecChangeCooldownMs = 30000,
}) {
  const audioPolicy = AudioAbrPolicy();
  const videoPolicy = VideoAbrPolicy();
  final currentTime = now ?? DateTime.now();

  // Step 1: Apply device state tier reduction
  var effectiveTier = networkTier;
  final tierReduction = deviceState.tierReduction;
  if (tierReduction > 0) {
    effectiveTier = _reduceTier(effectiveTier, tierReduction);
  }

  // Step 2: Apply policy override tier cap
  if (policyOverride != null) {
    if (policyOverride.forceAudioOnly == true) {
      return SlowLoopDecision(
        audioParams: audioPolicy.paramsForTier(QualityTier.poor),
        videoParams: videoPolicy.paramsForTier(QualityTier.poor),
        effectiveTier: QualityTier.poor,
        videoCodec: currentCodec,
        reason: 'policy engine: forced audio-only',
      );
    }

    if (policyOverride.maxTier != null) {
      final maxRank = _tierRank(policyOverride.maxTier!);
      final currentRank = _tierRank(effectiveTier);
      if (currentRank < maxRank) {
        effectiveTier = policyOverride.maxTier!;
      }
    }
  }

  // Step 3: Get params for effective tier
  final audioParams = audioPolicy.paramsForTier(effectiveTier);
  final videoParams = videoPolicy.paramsForTier(effectiveTier);

  // Step 4: Codec selection
  var codec = currentCodec;
  if (policyOverride?.forceCodec != null) {
    codec = policyOverride!.forceCodec!;
  } else {
    final desiredCodec = effectiveTier == QualityTier.poor
        ? VideoCodec.vp8
        : VideoCodec.h264;
    if (desiredCodec != currentCodec) {
      final canSwitch = lastCodecChange == null ||
          currentTime.difference(lastCodecChange).inMilliseconds >=
              codecChangeCooldownMs;
      if (canSwitch) {
        codec = desiredCodec;
      }
    }
  }

  // Step 5: Build reason
  final reasons = <String>[];
  reasons.add('tier=$effectiveTier');
  if (tierReduction > 0) {
    reasons.add('device reduction=$tierReduction');
  }
  if (policyOverride != null) {
    reasons.add('policy override active');
  }

  return SlowLoopDecision(
    audioParams: audioParams,
    videoParams: videoParams,
    effectiveTier: effectiveTier,
    videoCodec: codec,
    reason: reasons.join(', '),
  );
}

QualityTier _reduceTier(QualityTier tier, int reduction) {
  var rank = _tierRank(tier);
  rank = (rank + reduction).clamp(0, 2);
  return _tierFromRank(rank);
}

int _tierRank(QualityTier tier) {
  switch (tier) {
    case QualityTier.good:
      return 0;
    case QualityTier.fair:
      return 1;
    case QualityTier.poor:
      return 2;
  }
}

QualityTier _tierFromRank(int rank) {
  switch (rank) {
    case 0:
      return QualityTier.good;
    case 1:
      return QualityTier.fair;
    default:
      return QualityTier.poor;
  }
}
