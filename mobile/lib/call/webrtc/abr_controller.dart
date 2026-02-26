import 'dart:async';

import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';

/// Encoding parameters applied by the ABR controller.
class AbrEncodingParams {
  const AbrEncodingParams({
    required this.maxBitrateKbps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
  });

  final int maxBitrateKbps;
  final int maxFramerate;
  final double scaleResolutionDownBy;

  @override
  String toString() =>
      'AbrEncodingParams(bitrate=${maxBitrateKbps}kbps, '
      'fps=$maxFramerate, scale=$scaleResolutionDownBy)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AbrEncodingParams &&
          maxBitrateKbps == other.maxBitrateKbps &&
          maxFramerate == other.maxFramerate &&
          scaleResolutionDownBy == other.scaleResolutionDownBy;

  @override
  int get hashCode =>
      Object.hash(maxBitrateKbps, maxFramerate, scaleResolutionDownBy);
}

/// ABR decision result including whether video should be disabled.
class AbrDecision {
  const AbrDecision({
    required this.params,
    required this.videoDisabled,
    required this.reason,
  });

  final AbrEncodingParams params;
  final bool videoDisabled;
  final String reason;
}

/// Configuration for ABR behavior.
class AbrConfig {
  const AbrConfig({
    this.loopIntervalMs = 1000,
    this.audioOnlyThresholdKbps = 100,
    this.videoResumeThresholdKbps = 200,
    this.videoResumeStableSeconds = 10,
    this.highRttThresholdMs = 300,
    this.goodBitrateKbps = 2500,
    this.fairBitrateKbps = 1000,
    this.poorBitrateKbps = 300,
    this.goodFramerate = 30,
    this.fairFramerate = 24,
    this.highRttFramerate = 15,
    this.poorFramerate = 15,
    this.goodScale = 1.0,
    this.fairScale = 1.5,
    this.poorScale = 2.0,
  });

  /// Fast-loop interval in milliseconds.
  final int loopIntervalMs;

  /// Below this bandwidth, video is turned off (audio-only mode).
  final int audioOnlyThresholdKbps;

  /// Above this bandwidth for [videoResumeStableSeconds], video resumes.
  final int videoResumeThresholdKbps;

  /// How long bandwidth must stay above resume threshold before re-enabling.
  final int videoResumeStableSeconds;

  /// RTT threshold in ms above which framerate is aggressively reduced.
  final int highRttThresholdMs;

  // -- Encoding targets per tier --
  final int goodBitrateKbps;
  final int fairBitrateKbps;
  final int poorBitrateKbps;

  final int goodFramerate;
  final int fairFramerate;
  final int highRttFramerate;
  final int poorFramerate;

  final double goodScale;
  final double fairScale;
  final double poorScale;
}

/// Client-side ABR fast-loop controller.
///
/// Observes [QualityMonitor] stats every [AbrConfig.loopIntervalMs] and adjusts
/// video encoding parameters on [PeerConnectionManager]:
///
/// 1. **Bitrate** reduces as quality degrades.
/// 2. **Framerate** drops before resolution when RTT > 300ms.
/// 3. **Resolution** downscales as last resort.
/// 4. **Audio-only**: if bandwidth < 100kbps, video OFF; auto-ON > 200kbps
///    stable for 10s.
class AbrController {
  AbrController({
    required PeerConnectionManager peerConnectionManager,
    required QualityMonitor qualityMonitor,
    required MediaManager mediaManager,
    AbrConfig config = const AbrConfig(),
  })  : _peerConnectionManager = peerConnectionManager,
        _qualityMonitor = qualityMonitor,
        _mediaManager = mediaManager,
        _config = config;

  final PeerConnectionManager _peerConnectionManager;
  final QualityMonitor _qualityMonitor;
  final MediaManager _mediaManager;
  final AbrConfig _config;

  Timer? _loopTimer;
  StreamSubscription<QualityStats>? _statsSubscription;

  /// Whether video was disabled by ABR (not by user).
  bool _videoDisabledByAbr = false;

  /// When bandwidth first exceeded resume threshold.
  DateTime? _bandwidthRecoverySince;

  /// Last applied encoding parameters (to avoid redundant updates).
  AbrEncodingParams? _lastAppliedParams;

  /// Previous stats for bandwidth estimation (delta-based).
  QualityStats? _previousStats;

  /// Estimated send bandwidth in kbps.
  double _estimatedBandwidthKbps = 0;

  /// Stream of ABR decisions for observability/testing.
  final StreamController<AbrDecision> _decisionController =
      StreamController<AbrDecision>.broadcast();

  // -- Public API --

  bool get isVideoDisabledByAbr => _videoDisabledByAbr;
  double get estimatedBandwidthKbps => _estimatedBandwidthKbps;
  AbrEncodingParams? get lastAppliedParams => _lastAppliedParams;
  Stream<AbrDecision> get onDecision => _decisionController.stream;

  /// Starts the ABR fast loop.
  void start() {
    if (_loopTimer != null) return;

    // Subscribe to quality stats for bandwidth estimation
    _statsSubscription = _qualityMonitor.onQualityStats.listen(_updateBandwidth);

    // Run ABR loop at configured interval
    _loopTimer = Timer.periodic(
      Duration(milliseconds: _config.loopIntervalMs),
      (_) => _runLoop(),
    );
  }

  /// Stops the ABR fast loop and resets state.
  void stop() {
    _loopTimer?.cancel();
    _loopTimer = null;
    _statsSubscription?.cancel();
    _statsSubscription = null;
    _previousStats = null;
    _lastAppliedParams = null;
    _bandwidthRecoverySince = null;
  }

  Future<void> dispose() async {
    stop();
    await _decisionController.close();
  }

  // -- Internal --

  void _updateBandwidth(QualityStats stats) {
    final prev = _previousStats;
    if (prev != null) {
      final elapsed =
          stats.timestamp.difference(prev.timestamp).inMilliseconds;
      if (elapsed > 0) {
        final deltaBytes = stats.bytesSent - prev.bytesSent;
        // bytes / ms * 1000 = bytes/s, then / 125 = kbps
        _estimatedBandwidthKbps =
            (deltaBytes / elapsed * 1000 / 125).clamp(0, double.infinity);
      }
    }
    _previousStats = stats;
  }

  Future<void> _runLoop() async {
    final stats = _qualityMonitor.latestStats;
    if (stats == null) return;

    final decision = computeDecision(
      tier: stats.tier,
      rttMs: stats.roundTripTimeMs ?? 0,
      bandwidthKbps: _estimatedBandwidthKbps,
    );

    if (!_decisionController.isClosed) {
      _decisionController.add(decision);
    }

    // Handle video on/off
    if (decision.videoDisabled && !_videoDisabledByAbr) {
      _disableVideo();
    } else if (!decision.videoDisabled && _videoDisabledByAbr) {
      _enableVideo();
    }

    // Apply encoding params if changed
    if (!decision.videoDisabled &&
        decision.params != _lastAppliedParams) {
      final applied = await _peerConnectionManager.setVideoEncodingParameters(
        maxBitrateKbps: decision.params.maxBitrateKbps,
        maxFramerate: decision.params.maxFramerate,
        scaleResolutionDownBy: decision.params.scaleResolutionDownBy,
      );
      if (applied) {
        _lastAppliedParams = decision.params;
      }
    }
  }

  /// Computes ABR decision (pure logic, testable without WebRTC).
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
        // Framerate drops before resolution when RTT is high
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

  void _disableVideo() {
    _videoDisabledByAbr = true;
    _mediaManager.toggleCamera(); // Turns video track off
  }

  void _enableVideo() {
    _videoDisabledByAbr = false;
    _bandwidthRecoverySince = null;
    _mediaManager.toggleCamera(); // Turns video track back on
  }
}

// ---------------------------------------------------------------------------
// Simulcast ABR Controller
// ---------------------------------------------------------------------------

/// ABR decision for simulcast — specifies which layers should be active.
class SimulcastAbrDecision {
  const SimulcastAbrDecision({
    required this.activeLayers,
    required this.videoDisabled,
    required this.reason,
  });

  /// Which simulcast layers should be actively sending.
  final Set<SimulcastLayer> activeLayers;

  /// Whether all video is disabled (audio-only mode).
  final bool videoDisabled;

  /// Human-readable reason for the decision.
  final String reason;

  @override
  String toString() =>
      'SimulcastAbrDecision(layers=${activeLayers.map((l) => l.rid).join(",")}, '
      'videoOff=$videoDisabled, reason=$reason)';
}

/// Simulcast-aware ABR controller.
///
/// Instead of adjusting single-stream encoding parameters, this controller
/// enables/disables simulcast layers based on quality tier:
///
/// - **Good**: All 3 layers active (h, m, l)
/// - **Fair**: Medium + Low active (h disabled)
/// - **Poor**: Low only (h, m disabled)
/// - **Audio-only**: All layers disabled (bandwidth < threshold)
///
/// The SFU selects which active layer to forward to each subscriber
/// based on their bandwidth and viewport size.
class SimulcastAbrController {
  SimulcastAbrController({
    required PeerConnectionManager peerConnectionManager,
    required QualityMonitor qualityMonitor,
    required MediaManager mediaManager,
    AbrConfig config = const AbrConfig(),
  })  : _peerConnectionManager = peerConnectionManager,
        _qualityMonitor = qualityMonitor,
        _mediaManager = mediaManager,
        _config = config;

  final PeerConnectionManager _peerConnectionManager;
  final QualityMonitor _qualityMonitor;
  final MediaManager _mediaManager;
  final AbrConfig _config;

  Timer? _loopTimer;
  StreamSubscription<QualityStats>? _statsSubscription;

  /// Whether video was disabled by ABR (not by user).
  bool _videoDisabledByAbr = false;

  /// When bandwidth first exceeded resume threshold.
  DateTime? _bandwidthRecoverySince;

  /// Last applied layer set (to avoid redundant updates).
  Set<SimulcastLayer>? _lastActiveLayers;

  /// Previous stats for bandwidth estimation (delta-based).
  QualityStats? _previousStats;

  /// Estimated send bandwidth in kbps.
  double _estimatedBandwidthKbps = 0;

  /// Stream of simulcast ABR decisions for observability/testing.
  final StreamController<SimulcastAbrDecision> _decisionController =
      StreamController<SimulcastAbrDecision>.broadcast();

  // -- Public API --

  bool get isVideoDisabledByAbr => _videoDisabledByAbr;
  double get estimatedBandwidthKbps => _estimatedBandwidthKbps;
  Set<SimulcastLayer>? get lastActiveLayers => _lastActiveLayers;
  Stream<SimulcastAbrDecision> get onDecision => _decisionController.stream;

  /// Starts the simulcast ABR loop.
  void start() {
    if (_loopTimer != null) return;

    _statsSubscription =
        _qualityMonitor.onQualityStats.listen(_updateBandwidth);

    _loopTimer = Timer.periodic(
      Duration(milliseconds: _config.loopIntervalMs),
      (_) => _runLoop(),
    );
  }

  /// Stops the simulcast ABR loop and resets state.
  void stop() {
    _loopTimer?.cancel();
    _loopTimer = null;
    _statsSubscription?.cancel();
    _statsSubscription = null;
    _previousStats = null;
    _lastActiveLayers = null;
    _bandwidthRecoverySince = null;
  }

  Future<void> dispose() async {
    stop();
    await _decisionController.close();
  }

  // -- Internal --

  void _updateBandwidth(QualityStats stats) {
    final prev = _previousStats;
    if (prev != null) {
      final elapsed =
          stats.timestamp.difference(prev.timestamp).inMilliseconds;
      if (elapsed > 0) {
        final deltaBytes = stats.bytesSent - prev.bytesSent;
        _estimatedBandwidthKbps =
            (deltaBytes / elapsed * 1000 / 125).clamp(0, double.infinity);
      }
    }
    _previousStats = stats;
  }

  Future<void> _runLoop() async {
    final stats = _qualityMonitor.latestStats;
    if (stats == null) return;

    final decision = computeDecision(
      tier: stats.tier,
      rttMs: stats.roundTripTimeMs ?? 0,
      bandwidthKbps: _estimatedBandwidthKbps,
    );

    if (!_decisionController.isClosed) {
      _decisionController.add(decision);
    }

    // Handle video on/off
    if (decision.videoDisabled && !_videoDisabledByAbr) {
      _disableVideo();
    } else if (!decision.videoDisabled && _videoDisabledByAbr) {
      _enableVideo();
    }

    // Apply layer changes if needed
    if (!decision.videoDisabled &&
        !_setEquals(decision.activeLayers, _lastActiveLayers)) {
      await _applyLayerDecision(decision.activeLayers);
      _lastActiveLayers = Set<SimulcastLayer>.from(decision.activeLayers);
    }
  }

  /// Computes simulcast ABR decision (pure logic, testable).
  SimulcastAbrDecision computeDecision({
    required QualityTier tier,
    required double rttMs,
    required double bandwidthKbps,
  }) {
    // Rule 1: Audio-only if bandwidth critically low
    if (bandwidthKbps > 0 && bandwidthKbps < _config.audioOnlyThresholdKbps) {
      _bandwidthRecoverySince = null;
      return const SimulcastAbrDecision(
        activeLayers: <SimulcastLayer>{},
        videoDisabled: true,
        reason: 'bandwidth below audio-only threshold',
      );
    }

    // Rule 2: Check video recovery from ABR-disabled state
    if (_videoDisabledByAbr) {
      if (bandwidthKbps >= _config.videoResumeThresholdKbps) {
        _bandwidthRecoverySince ??= DateTime.now();
        final stableDuration =
            DateTime.now().difference(_bandwidthRecoverySince!);
        if (stableDuration.inSeconds < _config.videoResumeStableSeconds) {
          return const SimulcastAbrDecision(
            activeLayers: <SimulcastLayer>{},
            videoDisabled: true,
            reason: 'waiting for stable bandwidth recovery',
          );
        }
        _bandwidthRecoverySince = null;
        // Fall through to tier-based decision
      } else {
        _bandwidthRecoverySince = null;
        return const SimulcastAbrDecision(
          activeLayers: <SimulcastLayer>{},
          videoDisabled: true,
          reason: 'bandwidth still below resume threshold',
        );
      }
    }

    // Rule 3: Tier-based layer selection
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
        // High RTT → only send low to reduce congestion
        if (rttMs > _config.highRttThresholdMs) {
          return const SimulcastAbrDecision(
            activeLayers: <SimulcastLayer>{
              SimulcastLayer.low,
            },
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
          activeLayers: <SimulcastLayer>{
            SimulcastLayer.low,
          },
          videoDisabled: false,
          reason: 'poor quality — low layer only',
        );
    }
  }

  /// Applies the layer enable/disable decision to the peer connection.
  Future<void> _applyLayerDecision(Set<SimulcastLayer> activeLayers) async {
    for (final layer in SimulcastLayer.values) {
      final shouldBeActive = activeLayers.contains(layer);
      await _peerConnectionManager.setSimulcastLayerEnabled(
        layer.rid,
        shouldBeActive,
      );
    }
  }

  void _disableVideo() {
    _videoDisabledByAbr = true;
    _mediaManager.toggleCamera();
  }

  void _enableVideo() {
    _videoDisabledByAbr = false;
    _bandwidthRecoverySince = null;
    _mediaManager.toggleCamera();
  }

  /// Set equality helper.
  bool _setEquals(Set<SimulcastLayer> a, Set<SimulcastLayer>? b) {
    if (b == null) return false;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}
