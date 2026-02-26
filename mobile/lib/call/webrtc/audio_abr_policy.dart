import 'package:lalo/call/webrtc/quality_monitor.dart';

/// Audio encoding parameters applied by the slow-loop ABR.
///
/// Maps to Spec §5.2 audio parameter tiers.
class AudioAbrParams {
  const AudioAbrParams({
    required this.bitrateKbps,
    required this.fecEnabled,
    required this.packetTimeMs,
    required this.opusComplexity,
  });

  /// Target audio bitrate in kbps (Opus).
  final int bitrateKbps;

  /// Whether Forward Error Correction is enabled.
  final bool fecEnabled;

  /// Opus packet time in milliseconds (20 or 40).
  final int packetTimeMs;

  /// Opus encoder complexity (0-10). Higher = better quality, more CPU.
  final int opusComplexity;

  @override
  String toString() =>
      'AudioAbrParams(bitrate=${bitrateKbps}kbps, fec=$fecEnabled, '
      'packetTime=${packetTimeMs}ms, complexity=$opusComplexity)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioAbrParams &&
          bitrateKbps == other.bitrateKbps &&
          fecEnabled == other.fecEnabled &&
          packetTimeMs == other.packetTimeMs &&
          opusComplexity == other.opusComplexity;

  @override
  int get hashCode =>
      Object.hash(bitrateKbps, fecEnabled, packetTimeMs, opusComplexity);
}

/// Audio ABR policy — maps quality tiers to audio encoding parameters.
///
/// Spec §5.2:
/// - Good: 24-32 kbps, FEC OFF, packet time 20ms, complexity 10
/// - Fair: 16-24 kbps, FEC ON, packet time 20ms, complexity 7
/// - Poor: 12-16 kbps, FEC ON, packet time 40ms, complexity 5
class AudioAbrPolicy {
  const AudioAbrPolicy({
    this.goodParams = const AudioAbrParams(
      bitrateKbps: 32,
      fecEnabled: false,
      packetTimeMs: 20,
      opusComplexity: 10,
    ),
    this.fairParams = const AudioAbrParams(
      bitrateKbps: 20,
      fecEnabled: true,
      packetTimeMs: 20,
      opusComplexity: 7,
    ),
    this.poorParams = const AudioAbrParams(
      bitrateKbps: 14,
      fecEnabled: true,
      packetTimeMs: 40,
      opusComplexity: 5,
    ),
  });

  final AudioAbrParams goodParams;
  final AudioAbrParams fairParams;
  final AudioAbrParams poorParams;

  /// Returns audio parameters for the given quality tier.
  AudioAbrParams paramsForTier(QualityTier tier) {
    switch (tier) {
      case QualityTier.good:
        return goodParams;
      case QualityTier.fair:
        return fairParams;
      case QualityTier.poor:
        return poorParams;
    }
  }
}

/// Video encoding parameters for the slow-loop ABR.
///
/// Spec §5.3:
/// - Good: 720p/30fps, 1.2-2.0 Mbps
/// - Fair: 360-480p/15-20fps, 400-900 kbps
/// - Poor: 180-360p/12-15fps, 150-350 kbps
class VideoAbrParams {
  const VideoAbrParams({
    required this.maxBitrateKbps,
    required this.minBitrateKbps,
    required this.maxFramerate,
    required this.maxResolutionHeight,
    required this.scaleResolutionDownBy,
  });

  final int maxBitrateKbps;
  final int minBitrateKbps;
  final int maxFramerate;
  final int maxResolutionHeight;
  final double scaleResolutionDownBy;

  @override
  String toString() =>
      'VideoAbrParams(bitrate=$minBitrateKbps-${maxBitrateKbps}kbps, '
      'fps=$maxFramerate, res=${maxResolutionHeight}p, '
      'scale=$scaleResolutionDownBy)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoAbrParams &&
          maxBitrateKbps == other.maxBitrateKbps &&
          minBitrateKbps == other.minBitrateKbps &&
          maxFramerate == other.maxFramerate &&
          maxResolutionHeight == other.maxResolutionHeight &&
          scaleResolutionDownBy == other.scaleResolutionDownBy;

  @override
  int get hashCode => Object.hash(
        maxBitrateKbps,
        minBitrateKbps,
        maxFramerate,
        maxResolutionHeight,
        scaleResolutionDownBy,
      );
}

/// Video ABR policy — maps quality tiers to video encoding parameters.
class VideoAbrPolicy {
  const VideoAbrPolicy({
    this.goodParams = const VideoAbrParams(
      maxBitrateKbps: 2000,
      minBitrateKbps: 1200,
      maxFramerate: 30,
      maxResolutionHeight: 720,
      scaleResolutionDownBy: 1.0,
    ),
    this.fairParams = const VideoAbrParams(
      maxBitrateKbps: 900,
      minBitrateKbps: 400,
      maxFramerate: 20,
      maxResolutionHeight: 480,
      scaleResolutionDownBy: 1.5,
    ),
    this.poorParams = const VideoAbrParams(
      maxBitrateKbps: 350,
      minBitrateKbps: 150,
      maxFramerate: 15,
      maxResolutionHeight: 360,
      scaleResolutionDownBy: 2.0,
    ),
  });

  final VideoAbrParams goodParams;
  final VideoAbrParams fairParams;
  final VideoAbrParams poorParams;

  /// Returns video parameters for the given quality tier.
  VideoAbrParams paramsForTier(QualityTier tier) {
    switch (tier) {
      case QualityTier.good:
        return goodParams;
      case QualityTier.fair:
        return fairParams;
      case QualityTier.poor:
        return poorParams;
    }
  }
}
