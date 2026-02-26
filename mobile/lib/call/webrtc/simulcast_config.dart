/// Simulcast layer identifiers matching SFU RID values.
enum SimulcastLayer {
  /// 720p/30fps (~1.5 Mbps), rid="h", scaleDown=1
  high,

  /// 360p/20fps (~500 kbps), rid="m", scaleDown=2
  medium,

  /// 180p/10fps (~150 kbps), rid="l", scaleDown=4
  low,
}

/// Extension helpers for [SimulcastLayer].
extension SimulcastLayerExt on SimulcastLayer {
  /// SFU RID string for this layer.
  String get rid {
    switch (this) {
      case SimulcastLayer.high:
        return 'h';
      case SimulcastLayer.medium:
        return 'm';
      case SimulcastLayer.low:
        return 'l';
    }
  }

  /// Ordered index (0=high, 1=medium, 2=low).
  int get order {
    switch (this) {
      case SimulcastLayer.high:
        return 0;
      case SimulcastLayer.medium:
        return 1;
      case SimulcastLayer.low:
        return 2;
    }
  }

  /// Parses a RID string back to [SimulcastLayer].
  static SimulcastLayer fromRid(String rid) {
    switch (rid) {
      case 'h':
        return SimulcastLayer.high;
      case 'm':
        return SimulcastLayer.medium;
      case 'l':
        return SimulcastLayer.low;
      default:
        throw ArgumentError('Unknown simulcast RID: $rid');
    }
  }

  /// Parses a layer name string (case-insensitive).
  static SimulcastLayer fromName(String name) {
    switch (name.toLowerCase()) {
      case 'high':
      case 'h':
        return SimulcastLayer.high;
      case 'medium':
      case 'mid':
      case 'm':
        return SimulcastLayer.medium;
      case 'low':
      case 'l':
        return SimulcastLayer.low;
      default:
        throw ArgumentError('Unknown simulcast layer name: $name');
    }
  }
}

/// Encoding parameters for a single simulcast layer.
class SimulcastEncoding {
  const SimulcastEncoding({
    required this.layer,
    required this.maxBitrateKbps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    this.active = true,
  });

  /// Which simulcast layer this encoding represents.
  final SimulcastLayer layer;

  /// Maximum bitrate in kbps.
  final int maxBitrateKbps;

  /// Maximum framerate.
  final int maxFramerate;

  /// Resolution downscale factor (1.0 = original capture resolution).
  final double scaleResolutionDownBy;

  /// Whether this layer is actively being sent.
  final bool active;

  /// RID for this encoding (delegates to layer).
  String get rid => layer.rid;

  /// Creates a copy with the given fields replaced.
  SimulcastEncoding copyWith({
    SimulcastLayer? layer,
    int? maxBitrateKbps,
    int? maxFramerate,
    double? scaleResolutionDownBy,
    bool? active,
  }) {
    return SimulcastEncoding(
      layer: layer ?? this.layer,
      maxBitrateKbps: maxBitrateKbps ?? this.maxBitrateKbps,
      maxFramerate: maxFramerate ?? this.maxFramerate,
      scaleResolutionDownBy:
          scaleResolutionDownBy ?? this.scaleResolutionDownBy,
      active: active ?? this.active,
    );
  }

  /// Converts to WebRTC RTCRtpEncoding-compatible map.
  Map<String, dynamic> toRtpEncoding() {
    return <String, dynamic>{
      'rid': rid,
      'active': active,
      'maxBitrate': maxBitrateKbps * 1000, // WebRTC uses bps
      'maxFramerate': maxFramerate,
      'scaleResolutionDownBy': scaleResolutionDownBy,
    };
  }

  @override
  String toString() =>
      'SimulcastEncoding(${layer.name}, ${maxBitrateKbps}kbps, '
      '${maxFramerate}fps, scale=$scaleResolutionDownBy, '
      'active=$active)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SimulcastEncoding &&
          layer == other.layer &&
          maxBitrateKbps == other.maxBitrateKbps &&
          maxFramerate == other.maxFramerate &&
          scaleResolutionDownBy == other.scaleResolutionDownBy &&
          active == other.active;

  @override
  int get hashCode => Object.hash(
        layer,
        maxBitrateKbps,
        maxFramerate,
        scaleResolutionDownBy,
        active,
      );
}

/// Full simulcast configuration with all 3 layers.
class SimulcastConfig {
  const SimulcastConfig({
    required this.encodings,
  });

  /// The 3 simulcast encodings ordered [high, medium, low].
  final List<SimulcastEncoding> encodings;

  /// Default 3-layer simulcast config matching PB-02 spec:
  /// - High: 720p/30fps (~1.5 Mbps)
  /// - Medium: 360p/20fps (~500 kbps)
  /// - Low: 180p/10fps (~150 kbps)
  static const SimulcastConfig defaultConfig = SimulcastConfig(
    encodings: <SimulcastEncoding>[
      SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      ),
      SimulcastEncoding(
        layer: SimulcastLayer.medium,
        maxBitrateKbps: 500,
        maxFramerate: 20,
        scaleResolutionDownBy: 2.0,
      ),
      SimulcastEncoding(
        layer: SimulcastLayer.low,
        maxBitrateKbps: 150,
        maxFramerate: 10,
        scaleResolutionDownBy: 4.0,
      ),
    ],
  );

  /// Returns encoding for a specific layer.
  SimulcastEncoding? getEncoding(SimulcastLayer layer) {
    for (final encoding in encodings) {
      if (encoding.layer == layer) return encoding;
    }
    return null;
  }

  /// Returns only active encodings.
  List<SimulcastEncoding> get activeEncodings =>
      encodings.where((e) => e.active).toList(growable: false);

  /// Total estimated bitrate across all active layers.
  int get totalBitrateKbps =>
      activeEncodings.fold(0, (sum, e) => sum + e.maxBitrateKbps);

  /// Converts all encodings to WebRTC-compatible init params.
  List<Map<String, dynamic>> toRtpEncodings() =>
      encodings.map((e) => e.toRtpEncoding()).toList(growable: false);
}
