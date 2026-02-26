import 'dart:async';

import 'package:lalo/call/services/device_state_monitor.dart';
import 'package:lalo/call/webrtc/audio_abr_policy.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';

/// Codec type for video encoding.
enum VideoCodec {
  vp8,
  h264,
}

/// Slow-loop ABR decision result.
class SlowLoopDecision {
  const SlowLoopDecision({
    required this.audioParams,
    required this.videoParams,
    required this.effectiveTier,
    required this.videoCodec,
    required this.reason,
  });

  /// Audio encoding parameters to apply.
  final AudioAbrParams audioParams;

  /// Video encoding parameters to apply.
  final VideoAbrParams videoParams;

  /// Effective quality tier after device state adjustments.
  final QualityTier effectiveTier;

  /// Current video codec preference.
  final VideoCodec videoCodec;

  /// Human-readable reason for the decision.
  final String reason;

  @override
  String toString() =>
      'SlowLoopDecision(tier=$effectiveTier, audio=$audioParams, '
      'video=$videoParams, codec=$videoCodec, reason=$reason)';
}

/// Configuration for the slow-loop ABR controller.
class SlowLoopConfig {
  const SlowLoopConfig({
    this.loopIntervalMs = 5000,
    this.codecChangeCooldownMs = 30000,
  });

  /// Slow-loop interval in milliseconds (5-10s).
  final int loopIntervalMs;

  /// Minimum time between video codec switches in milliseconds.
  /// Spec: max 1 codec change per 30 seconds.
  final int codecChangeCooldownMs;
}

/// Policy override from the server-side policy engine.
class PolicyOverride {
  const PolicyOverride({
    this.maxTier,
    this.forceAudioOnly,
    this.maxBitrateKbps,
    this.forceCodec,
  });

  /// Maximum allowed quality tier (server can cap).
  final QualityTier? maxTier;

  /// Force audio-only mode.
  final bool? forceAudioOnly;

  /// Maximum allowed bitrate in kbps.
  final int? maxBitrateKbps;

  /// Force a specific video codec.
  final VideoCodec? forceCodec;

  /// Creates from signaling message data.
  factory PolicyOverride.fromJson(Map<String, dynamic> json) {
    QualityTier? maxTier;
    final tierStr = json['max_tier'] as String?;
    if (tierStr != null) {
      switch (tierStr) {
        case 'good':
          maxTier = QualityTier.good;
          break;
        case 'fair':
          maxTier = QualityTier.fair;
          break;
        case 'poor':
          maxTier = QualityTier.poor;
          break;
      }
    }

    VideoCodec? forceCodec;
    final codecStr = json['force_codec'] as String?;
    if (codecStr != null) {
      switch (codecStr) {
        case 'vp8':
          forceCodec = VideoCodec.vp8;
          break;
        case 'h264':
          forceCodec = VideoCodec.h264;
          break;
      }
    }

    return PolicyOverride(
      maxTier: maxTier,
      forceAudioOnly: json['force_audio_only'] as bool?,
      maxBitrateKbps: json['max_bitrate_kbps'] as int?,
      forceCodec: forceCodec,
    );
  }

  @override
  String toString() =>
      'PolicyOverride(maxTier=$maxTier, audioOnly=$forceAudioOnly, '
      'maxBitrate=$maxBitrateKbps, codec=$forceCodec)';
}

/// Slow-loop ABR controller (5-10s cycle).
///
/// Handles:
/// - Audio parameter adjustment per quality tier (Spec §5.2)
/// - Video codec switching with 30s cooldown
/// - Battery/thermal tier reduction
/// - Policy engine overrides
///
/// The slow loop runs at a lower frequency than the fast loop and makes
/// heavier adjustments: codec changes, audio FEC/bitrate, tier overrides.
class SlowLoopController {
  SlowLoopController({
    required PeerConnectionManager peerConnectionManager,
    required QualityMonitor qualityMonitor,
    required DeviceStateMonitor deviceStateMonitor,
    AudioAbrPolicy audioPolicy = const AudioAbrPolicy(),
    VideoAbrPolicy videoPolicy = const VideoAbrPolicy(),
    SlowLoopConfig config = const SlowLoopConfig(),
  })  : _peerConnectionManager = peerConnectionManager,
        _qualityMonitor = qualityMonitor,
        _deviceStateMonitor = deviceStateMonitor,
        _audioPolicy = audioPolicy,
        _videoPolicy = videoPolicy,
        _config = config;

  final PeerConnectionManager _peerConnectionManager;
  final QualityMonitor _qualityMonitor;
  final DeviceStateMonitor _deviceStateMonitor;
  final AudioAbrPolicy _audioPolicy;
  final VideoAbrPolicy _videoPolicy;
  final SlowLoopConfig _config;

  Timer? _loopTimer;

  /// Current video codec.
  VideoCodec _currentCodec = VideoCodec.vp8;

  /// Last codec change timestamp for cooldown enforcement.
  DateTime? _lastCodecChange;

  /// Active policy override from server.
  PolicyOverride? _policyOverride;

  /// Last applied audio params.
  AudioAbrParams? _lastAudioParams;

  /// Last applied video params.
  VideoAbrParams? _lastVideoParams;

  /// Stream of slow-loop decisions for observability.
  final StreamController<SlowLoopDecision> _decisionController =
      StreamController<SlowLoopDecision>.broadcast();

  // -- Public API --

  VideoCodec get currentCodec => _currentCodec;
  PolicyOverride? get policyOverride => _policyOverride;
  AudioAbrParams? get lastAudioParams => _lastAudioParams;
  VideoAbrParams? get lastVideoParams => _lastVideoParams;
  Stream<SlowLoopDecision> get onDecision => _decisionController.stream;

  /// Starts the slow ABR loop.
  void start() {
    if (_loopTimer != null) return;

    _loopTimer = Timer.periodic(
      Duration(milliseconds: _config.loopIntervalMs),
      (_) => _runLoop(),
    );
  }

  /// Stops the slow ABR loop.
  void stop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  Future<void> dispose() async {
    stop();
    await _decisionController.close();
  }

  /// Sets a policy override from the server-side policy engine.
  void setPolicyOverride(PolicyOverride? override) {
    _policyOverride = override;
    // Immediately run a loop iteration to apply the override
    _runLoop();
  }

  // -- Internal --

  Future<void> _runLoop() async {
    final stats = _qualityMonitor.latestStats;
    if (stats == null) return;

    final decision = computeDecision(
      networkTier: stats.tier,
      deviceState: _deviceStateMonitor.currentState,
      lossPercent: stats.lossPercent,
    );

    if (!_decisionController.isClosed) {
      _decisionController.add(decision);
    }

    // Apply audio params if changed
    if (decision.audioParams != _lastAudioParams) {
      await _applyAudioParams(decision.audioParams);
      _lastAudioParams = decision.audioParams;
    }

    // Apply video params if changed
    if (decision.videoParams != _lastVideoParams) {
      await _applyVideoParams(decision.videoParams);
      _lastVideoParams = decision.videoParams;
    }
  }

  /// Computes slow-loop decision (pure logic, testable).
  SlowLoopDecision computeDecision({
    required QualityTier networkTier,
    required DeviceState deviceState,
    required double lossPercent,
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now();

    // Step 1: Apply device state tier reduction
    var effectiveTier = networkTier;
    final tierReduction = deviceState.tierReduction;
    if (tierReduction > 0) {
      effectiveTier = _reduceTier(effectiveTier, tierReduction);
    }

    // Step 2: Apply policy override tier cap
    final override = _policyOverride;
    if (override != null) {
      if (override.forceAudioOnly == true) {
        // Policy engine forces audio-only
        return SlowLoopDecision(
          audioParams: _audioPolicy.paramsForTier(QualityTier.poor),
          videoParams: _videoPolicy.paramsForTier(QualityTier.poor),
          effectiveTier: QualityTier.poor,
          videoCodec: _currentCodec,
          reason: 'policy engine: forced audio-only',
        );
      }

      if (override.maxTier != null) {
        final maxRank = _tierRank(override.maxTier!);
        final currentRank = _tierRank(effectiveTier);
        if (currentRank < maxRank) {
          effectiveTier = override.maxTier!;
        }
      }
    }

    // Step 3: Get audio and video params for effective tier
    final audioParams = _audioPolicy.paramsForTier(effectiveTier);
    final videoParams = _videoPolicy.paramsForTier(effectiveTier);

    // Step 4: Determine video codec
    var codec = _currentCodec;
    if (override?.forceCodec != null) {
      codec = override!.forceCodec!;
    } else {
      // Auto codec selection: prefer H.264 on good, VP8 on poor
      final desiredCodec = effectiveTier == QualityTier.poor
          ? VideoCodec.vp8  // VP8 is more resilient at low bitrates
          : VideoCodec.h264; // H.264 is more efficient at higher bitrates

      if (desiredCodec != _currentCodec) {
        // Enforce 30s cooldown
        final canSwitch = _lastCodecChange == null ||
            currentTime.difference(_lastCodecChange!).inMilliseconds >=
                _config.codecChangeCooldownMs;
        if (canSwitch) {
          codec = desiredCodec;
          _lastCodecChange = currentTime;
        }
      }
    }
    _currentCodec = codec;

    // Step 5: Build reason string
    final reasons = <String>[];
    reasons.add('tier=$effectiveTier');
    if (tierReduction > 0) {
      reasons.add('device reduction=$tierReduction');
    }
    if (override != null) {
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

  Future<void> _applyAudioParams(AudioAbrParams params) async {
    await _peerConnectionManager.setAudioEncodingParameters(
      maxBitrateKbps: params.bitrateKbps,
    );
  }

  Future<void> _applyVideoParams(VideoAbrParams params) async {
    await _peerConnectionManager.setVideoEncodingParameters(
      maxBitrateKbps: params.maxBitrateKbps,
      maxFramerate: params.maxFramerate,
      scaleResolutionDownBy: params.scaleResolutionDownBy,
    );
  }
}
