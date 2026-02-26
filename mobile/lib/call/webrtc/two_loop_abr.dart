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
/// This class owns both loops and coordinates their interactions.
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
  })  : _fastLoop = SimulcastAbrController(
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

  bool _running = false;

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

  /// Last audio params applied by the slow loop.
  AudioAbrParams? get lastAudioParams => _slowLoop.lastAudioParams;

  /// Last video params applied by the slow loop.
  VideoAbrParams? get lastVideoParams => _slowLoop.lastVideoParams;

  /// Fast-loop simulcast decisions stream.
  Stream<SimulcastAbrDecision> get onFastLoopDecision => _fastLoop.onDecision;

  /// Slow-loop decisions stream.
  Stream<SlowLoopDecision> get onSlowLoopDecision => _slowLoop.onDecision;

  /// Starts both ABR loops.
  void start() {
    if (_running) return;
    _running = true;
    _fastLoop.start();
    _slowLoop.start();
  }

  /// Stops both ABR loops.
  void stop() {
    if (!_running) return;
    _running = false;
    _fastLoop.stop();
    _slowLoop.stop();
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
}
