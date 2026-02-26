import 'dart:async';

import 'package:lalo/call/services/device_state_monitor.dart';
import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/audio_abr_policy.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/slow_loop_controller.dart';

/// Two-loop ABR coordinator combining fast loop + slow loop.
///
/// - **Fast loop** (500ms-1s): adjusts simulcast layers and per-layer
///   bitrate/framerate based on real-time network stats.
/// - **Slow loop** (5-10s): adjusts audio params, video codec,
///   tier reclassification, battery/thermal overrides, policy engine.
///
/// **Tier coordination**: the slow loop computes an *effective tier* that
/// accounts for device state (battery/thermal) and policy overrides. This
/// effective tier is forwarded to the fast loop via [setTierOverride] so
/// both loops stay in sync.
///
/// **Metrics reporting**: when [metricsReporter] is provided, the coordinator
/// periodically forwards quality stats to the backend policy engine.
class TwoLoopAbr {
  TwoLoopAbr({
    required PeerConnectionManager peerConnectionManager,
    required QualityMonitor qualityMonitor,
    required MediaManager mediaManager,
    required DeviceStateMonitor deviceStateMonitor,
    AbrConfig fastLoopConfig = const AbrConfig(),
    SlowLoopConfig slowLoopConfig = const SlowLoopConfig(),
    AudioAbrPolicy audioPolicy = const AudioAbrPolicy(),
    VideoAbrPolicy videoPolicy = const VideoAbrPolicy(),
    MetricsReporter? metricsReporter,
  })  : _qualityMonitor = qualityMonitor,
        _metricsReporter = metricsReporter,
        _fastLoop = SimulcastAbrController(
          peerConnectionManager: peerConnectionManager,
          qualityMonitor: qualityMonitor,
          mediaManager: mediaManager,
          config: fastLoopConfig,
        ),
        _slowLoop = SlowLoopController(
          peerConnectionManager: peerConnectionManager,
          qualityMonitor: qualityMonitor,
          deviceStateMonitor: deviceStateMonitor,
          audioPolicy: audioPolicy,
          videoPolicy: videoPolicy,
          config: slowLoopConfig,
        );

  final SimulcastAbrController _fastLoop;
  final SlowLoopController _slowLoop;
  final QualityMonitor _qualityMonitor;
  final MetricsReporter? _metricsReporter;

  bool _running = false;

  StreamSubscription<SlowLoopDecision>? _slowLoopSubscription;
  Timer? _metricsTimer;

  /// The effective tier determined by the slow loop (with device/policy
  /// adjustments). Null until the first slow-loop decision fires.
  QualityTier? _effectiveTier;

  // -- Public API --

  /// Whether the two-loop system is running.
  bool get isRunning => _running;

  /// Access the fast loop for direct observation.
  SimulcastAbrController get fastLoop => _fastLoop;

  /// Access the slow loop for direct observation.
  SlowLoopController get slowLoop => _slowLoop;

  /// Whether video was disabled by the fast loop ABR.
  bool get isVideoDisabledByAbr => _fastLoop.isVideoDisabledByAbr;

  /// Current estimated bandwidth from the fast loop.
  double get estimatedBandwidthKbps => _fastLoop.estimatedBandwidthKbps;

  /// Current video codec from the slow loop.
  VideoCodec get currentCodec => _slowLoop.currentCodec;

  /// The effective tier after slow-loop adjustments (battery/thermal/policy).
  QualityTier? get effectiveTier => _effectiveTier;

  /// Last audio params applied by the slow loop.
  AudioAbrParams? get lastAudioParams => _slowLoop.lastAudioParams;

  /// Last video params applied by the slow loop.
  VideoAbrParams? get lastVideoParams => _slowLoop.lastVideoParams;

  /// Fast-loop simulcast decisions stream.
  Stream<SimulcastAbrDecision> get onFastLoopDecision => _fastLoop.onDecision;

  /// Slow-loop decisions stream.
  Stream<SlowLoopDecision> get onSlowLoopDecision => _slowLoop.onDecision;

  /// Starts both ABR loops with tier coordination.
  void start() {
    if (_running) return;
    _running = true;
    _fastLoop.start();
    _slowLoop.start();

    // Subscribe to slow-loop decisions to coordinate tier with fast loop.
    _slowLoopSubscription = _slowLoop.onDecision.listen(_onSlowLoopDecision);

    // Start periodic metrics reporting if reporter is available.
    if (_metricsReporter != null) {
      _metricsTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _reportMetrics(),
      );
    }
  }

  /// Stops both ABR loops.
  void stop() {
    if (!_running) return;
    _running = false;
    _fastLoop.stop();
    _slowLoop.stop();
    _slowLoopSubscription?.cancel();
    _slowLoopSubscription = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _effectiveTier = null;
    _fastLoop.setTierOverride(null);
  }

  /// Applies a policy override from the server-side policy engine.
  void setPolicyOverride(PolicyOverride? override) {
    _slowLoop.setPolicyOverride(override);
  }

  /// Disposes all resources.
  Future<void> dispose() async {
    stop();
    await _fastLoop.dispose();
    await _slowLoop.dispose();
  }

  // -- Internal --

  /// Called when the slow loop emits a decision.
  ///
  /// Forwards the effective tier to the fast loop so it respects
  /// battery/thermal/policy tier reductions.
  void _onSlowLoopDecision(SlowLoopDecision decision) {
    _effectiveTier = decision.effectiveTier;
    _fastLoop.setTierOverride(decision.effectiveTier);
  }

  /// Sends current quality stats to the backend policy engine.
  void _reportMetrics() {
    final reporter = _metricsReporter;
    if (reporter == null) return;

    final stats = _qualityMonitor.latestStats;
    if (stats == null) return;

    reporter.reportQualityMetrics(<String, dynamic>{
      'rtt_ms': stats.roundTripTimeMs ?? 0,
      'loss_percent': stats.lossPercent,
      'jitter_ms': stats.jitterMs ?? 0,
      'bandwidth_kbps': _fastLoop.estimatedBandwidthKbps,
      'tier': stats.tier.name,
      'audio_level': stats.audioLevel ?? 0,
      'frame_width': stats.frameWidth ?? 0,
      'frame_height': stats.frameHeight ?? 0,
      'fps': stats.framesPerSecond ?? 0,
      'mos_score': stats.mosScore,
      'timestamp': stats.timestamp.toIso8601String(),
    });
  }
}

/// Abstraction for reporting quality metrics to the backend policy engine.
///
/// Implemented by the provider layer to decouple [TwoLoopAbr] from
/// network/signaling concerns.
abstract class MetricsReporter {
  /// Sends a quality metrics sample to the backend.
  void reportQualityMetrics(Map<String, dynamic> sample);
}
