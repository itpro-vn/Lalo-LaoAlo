import 'dart:async';

import 'peer_connection_manager.dart';

enum QualityTier {
  good,
  fair,
  poor,
}

class QualityStats {
  const QualityStats({
    required this.timestamp,
    required this.roundTripTimeMs,
    required this.packetsLost,
    required this.packetsReceived,
    required this.lossPercent,
    required this.jitterMs,
    required this.bytesSent,
    required this.bytesReceived,
    required this.audioLevel,
    required this.frameWidth,
    required this.frameHeight,
    required this.framesPerSecond,
    required this.mosScore,
    required this.tier,
  });

  final DateTime timestamp;
  final double? roundTripTimeMs;
  final int packetsLost;
  final int packetsReceived;
  final double lossPercent;
  final double? jitterMs;
  final int bytesSent;
  final int bytesReceived;
  final double? audioLevel;
  final int? frameWidth;
  final int? frameHeight;
  final double? framesPerSecond;

  /// Estimated Mean Opinion Score (1.0 to 4.5).
  final double mosScore;
  final QualityTier tier;
}

/// Monitors call quality via periodic [PeerConnectionManager.getStats] polling.
class QualityMonitor {
  QualityMonitor(
    this._peerConnectionManager, {
    this.statsIntervalMs = 5000,
  });

  final PeerConnectionManager _peerConnectionManager;
  final int statsIntervalMs;

  final StreamController<QualityStats> _qualityStatsController =
      StreamController<QualityStats>.broadcast();
  final StreamController<QualityTier> _tierChangedController =
      StreamController<QualityTier>.broadcast();

  Timer? _pollTimer;
  bool _isPolling = false;

  QualityTier _currentTier = QualityTier.good;
  QualityStats? _latestStats;

  DateTime? _upgradeCandidateSince;
  QualityTier? _upgradeCandidateTier;
  DateTime? _downgradeCandidateSince;
  QualityTier? _downgradeCandidateTier;

  Stream<QualityStats> get onQualityStats => _qualityStatsController.stream;

  Stream<QualityTier> get onTierChanged => _tierChangedController.stream;

  QualityTier get currentTier => _currentTier;

  double get currentMos => _latestStats?.mosScore ?? 4.5;

  QualityStats? get latestStats => _latestStats;

  void start() {
    if (_pollTimer != null) return;

    _collectStats();
    _pollTimer = Timer.periodic(
      Duration(milliseconds: statsIntervalMs),
      (_) => _collectStats(),
    );
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> dispose() async {
    stop();
    await _qualityStatsController.close();
    await _tierChangedController.close();
  }

  Future<void> _collectStats() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      final reports = await _peerConnectionManager.getStats();
      final stats = _extractQualityStats(reports);
      _latestStats = stats;

      if (!_qualityStatsController.isClosed) {
        _qualityStatsController.add(stats);
      }

      _applyTierWithHysteresis(stats);
    } catch (_) {
      // Ignore transient stats read errors; next interval will retry.
    } finally {
      _isPolling = false;
    }
  }

  QualityStats _extractQualityStats(List<dynamic> reports) {
    double? roundTripTimeMs;
    int packetsLost = 0;
    int packetsReceived = 0;
    double? jitterMs;
    int bytesSent = 0;
    int bytesReceived = 0;
    double? audioLevel;
    int? frameWidth;
    int? frameHeight;
    double? framesPerSecond;

    for (final report in reports) {
      final values = _extractValues(report);

      final rttCandidate = _extractDouble(values, const [
        'roundTripTime',
        'currentRoundTripTime',
      ]);
      if (rttCandidate != null) {
        final ms = rttCandidate <= 10 ? rttCandidate * 1000 : rttCandidate;
        roundTripTimeMs = _pickMax(roundTripTimeMs, ms);
      }

      final jitterCandidate = _extractDouble(values, const ['jitter']);
      if (jitterCandidate != null) {
        final ms =
            jitterCandidate <= 10 ? jitterCandidate * 1000 : jitterCandidate;
        jitterMs = _pickMax(jitterMs, ms);
      }

      final lost = _extractInt(values, const ['packetsLost']);
      if (lost != null && lost > 0) {
        packetsLost += lost;
      }

      final received = _extractInt(values, const [
        'packetsReceived',
        'packetsReceivedTotal',
      ]);
      if (received != null && received > 0) {
        packetsReceived += received;
      }

      final sent = _extractInt(values, const ['bytesSent']);
      if (sent != null && sent > bytesSent) {
        bytesSent = sent;
      }

      final receivedBytes = _extractInt(values, const ['bytesReceived']);
      if (receivedBytes != null && receivedBytes > bytesReceived) {
        bytesReceived = receivedBytes;
      }

      final level = _extractDouble(values, const ['audioLevel']);
      if (level != null) {
        audioLevel = _pickMax(audioLevel, level);
      }

      final width = _extractInt(values, const ['frameWidth']);
      if (width != null && width > 0) {
        frameWidth = frameWidth == null
            ? width
            : (width > frameWidth ? width : frameWidth);
      }

      final height = _extractInt(values, const ['frameHeight']);
      if (height != null && height > 0) {
        frameHeight = frameHeight == null
            ? height
            : (height > frameHeight ? height : frameHeight);
      }

      final fps = _extractDouble(values, const ['framesPerSecond']);
      if (fps != null) {
        framesPerSecond = _pickMax(framesPerSecond, fps);
      }
    }

    final totalPackets = packetsLost + packetsReceived;
    final lossPercent =
        totalPackets > 0 ? (packetsLost * 100 / totalPackets).toDouble() : 0.0;

    final mosScore = _calculateMos(
      rttMs: roundTripTimeMs,
      lossPercent: lossPercent,
      jitterMs: jitterMs,
    );

    final tier = _classifyTier(
      rttMs: roundTripTimeMs,
      lossPercent: lossPercent,
      jitterMs: jitterMs,
      mosScore: mosScore,
    );

    return QualityStats(
      timestamp: DateTime.now(),
      roundTripTimeMs: roundTripTimeMs,
      packetsLost: packetsLost,
      packetsReceived: packetsReceived,
      lossPercent: lossPercent,
      jitterMs: jitterMs,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      audioLevel: audioLevel,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      framesPerSecond: framesPerSecond,
      mosScore: mosScore,
      tier: tier,
    );
  }

  Map<String, dynamic> _extractValues(dynamic report) {
    if (report is Map<String, dynamic>) {
      return report;
    }

    try {
      final values = report.values;
      if (values is Map<String, dynamic>) {
        return values;
      }
      if (values is Map) {
        return values.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {
      // ignore
    }

    return const <String, dynamic>{};
  }

  double? _extractDouble(Map<String, dynamic> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  int? _extractInt(Map<String, dynamic> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
        final parsedDouble = double.tryParse(value);
        if (parsedDouble != null) return parsedDouble.toInt();
      }
    }
    return null;
  }

  double? _pickMax(double? current, double candidate) {
    if (candidate.isNaN || candidate.isInfinite) return current;
    if (current == null) return candidate;
    return candidate > current ? candidate : current;
  }

  QualityTier _classifyTier({
    required double? rttMs,
    required double lossPercent,
    required double? jitterMs,
    double? mosScore,
  }) {
    final safeRtt = rttMs ?? 0;
    final safeJitter = jitterMs ?? 0;

    final isGood = safeRtt <= 120 && lossPercent <= 2 && safeJitter <= 20;
    if (isGood) {
      final mosTier = _tierFromMos(mosScore);
      if (mosTier != QualityTier.good) return mosTier;
      return QualityTier.good;
    }

    final isFair = safeRtt <= 250 && lossPercent <= 6 && safeJitter <= 50;
    if (isFair) return QualityTier.fair;

    return QualityTier.poor;
  }

  /// Calculates estimated MOS using the E-model simplified formula.
  ///
  /// R = 93.2 - (delay/40) - (2.5 * lossPercent) - (jitter/10)
  /// MOS = 1 + 0.035*R + R*(R-60)*(100-R)*7e-6
  /// Clamped to [1.0, 4.5] range.
  double _calculateMos({
    required double? rttMs,
    required double lossPercent,
    required double? jitterMs,
  }) {
    final delay = rttMs ?? 0;
    final jitter = jitterMs ?? 0;

    double r = 93.2 - (delay / 40.0) - (2.5 * lossPercent) - (jitter / 10.0);
    r = r.clamp(0.0, 100.0);

    final double mos = 1.0 + 0.035 * r + r * (r - 60.0) * (100.0 - r) * 7e-6;
    return mos.clamp(1.0, 4.5);
  }

  QualityTier _tierFromMos(double? mosScore) {
    final mos = mosScore ?? 4.5;
    if (mos >= 4.0) return QualityTier.good;
    if (mos >= 3.0) return QualityTier.fair;
    return QualityTier.poor;
  }

  void _applyTierWithHysteresis(QualityStats stats) {
    final now = stats.timestamp;
    final nextTier = stats.tier;

    if (nextTier == _currentTier) {
      _upgradeCandidateSince = null;
      _upgradeCandidateTier = null;
      _downgradeCandidateSince = null;
      _downgradeCandidateTier = null;
      return;
    }

    final isUpgrade = _tierRank(nextTier) < _tierRank(_currentTier);
    if (isUpgrade) {
      if (_upgradeCandidateTier != nextTier) {
        _upgradeCandidateTier = nextTier;
        _upgradeCandidateSince = now;
        return;
      }

      final since = _upgradeCandidateSince;
      if (since != null &&
          now.difference(since) >= const Duration(seconds: 10)) {
        _setTier(nextTier);
      }
      return;
    }

    final requiredDowngradeWindow = nextTier == QualityTier.poor
        ? const Duration(seconds: 1)
        : const Duration(seconds: 2);

    if (_downgradeCandidateTier != nextTier) {
      _downgradeCandidateTier = nextTier;
      _downgradeCandidateSince = now;
      return;
    }

    final since = _downgradeCandidateSince;
    if (since != null && now.difference(since) >= requiredDowngradeWindow) {
      _setTier(nextTier);
    }
  }

  void _setTier(QualityTier tier) {
    if (tier == _currentTier) return;

    _currentTier = tier;
    _upgradeCandidateSince = null;
    _upgradeCandidateTier = null;
    _downgradeCandidateSince = null;
    _downgradeCandidateTier = null;

    if (!_tierChangedController.isClosed) {
      _tierChangedController.add(tier);
    }
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
}
