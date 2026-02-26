import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:test/test.dart';

class _FakePeerConnectionManager extends PeerConnectionManager {
  _FakePeerConnectionManager(this._reports) : super(const []);

  final List<webrtc.StatsReport> _reports;

  @override
  Future<List<webrtc.StatsReport>> getStats() async => _reports;
}

webrtc.StatsReport _report(Map<String, dynamic> values) {
  return webrtc.StatsReport('id', 'candidate-pair', 0, values);
}

void main() {
  group('QualityTier classification via QualityMonitor stats extraction', () {
    test('good thresholds: rtt<=120, loss<=2, jitter<=20', () async {
      // arrange
      final manager = _FakePeerConnectionManager([
        _report({
          'roundTripTime': 0.12,
          'packetsLost': 2,
          'packetsReceived': 198,
          'jitter': 0.02,
        }),
      ]);
      final monitor = QualityMonitor(manager);

      // act
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = monitor.latestStats;

      // assert
      expect(stats, isNotNull);
      expect(stats!.roundTripTimeMs, closeTo(120, 0.001));
      expect(stats.lossPercent, closeTo(1, 0.001));
      expect(stats.jitterMs, closeTo(20, 0.001));
      expect(stats.tier, QualityTier.good);

      await monitor.dispose();
    });

    test('fair thresholds classification', () async {
      // arrange
      final manager = _FakePeerConnectionManager([
        _report({
          'roundTripTime': 0.2,
          'packetsLost': 4,
          'packetsReceived': 96,
          'jitter': 0.03,
        }),
      ]);
      final monitor = QualityMonitor(manager);

      // act
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = monitor.latestStats;

      // assert
      expect(stats, isNotNull);
      expect(stats!.tier, QualityTier.fair);
      expect(stats.roundTripTimeMs, closeTo(200, 0.001));
      expect(stats.lossPercent, closeTo(4, 0.001));
      expect(stats.jitterMs, closeTo(30, 0.001));

      await monitor.dispose();
    });

    test('poor thresholds classification', () async {
      // arrange
      final manager = _FakePeerConnectionManager([
        _report({
          'roundTripTime': 0.5,
          'packetsLost': 10,
          'packetsReceived': 90,
          'jitter': 0.07,
        }),
      ]);
      final monitor = QualityMonitor(manager);

      // act
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = monitor.latestStats;

      // assert
      expect(stats, isNotNull);
      expect(stats!.tier, QualityTier.poor);

      await monitor.dispose();
    });
  });

  group('QualityStats', () {
    test('construction with all metrics', () {
      // arrange
      final timestamp = DateTime.utc(2026, 1, 1);

      // act
      final stats = QualityStats(
        timestamp: timestamp,
        roundTripTimeMs: 100,
        packetsLost: 5,
        packetsReceived: 95,
        lossPercent: 5,
        jitterMs: 12,
        bytesSent: 1000,
        bytesReceived: 1200,
        audioLevel: 0.8,
        frameWidth: 1280,
        frameHeight: 720,
        framesPerSecond: 30,
        tier: QualityTier.fair,
        mosScore: 3.2,
      );

      // assert
      expect(stats.timestamp, timestamp);
      expect(stats.roundTripTimeMs, 100);
      expect(stats.packetsLost, 5);
      expect(stats.packetsReceived, 95);
      expect(stats.lossPercent, 5);
      expect(stats.jitterMs, 12);
      expect(stats.bytesSent, 1000);
      expect(stats.bytesReceived, 1200);
      expect(stats.audioLevel, 0.8);
      expect(stats.frameWidth, 1280);
      expect(stats.frameHeight, 720);
      expect(stats.framesPerSecond, 30);
      expect(stats.tier, QualityTier.fair);
      expect(stats.mosScore, 3.2);
    });

    test('tier is computed correctly from collected metrics', () async {
      // arrange
      final manager = _FakePeerConnectionManager([
        _report({
          'currentRoundTripTime': 0.08,
          'packetsLost': 1,
          'packetsReceived': 199,
          'jitter': 0.01,
          'bytesSent': 2048,
          'bytesReceived': 4096,
          'audioLevel': 0.5,
          'frameWidth': 640,
          'frameHeight': 480,
          'framesPerSecond': 24,
        }),
      ]);
      final monitor = QualityMonitor(manager);

      // act
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = monitor.latestStats;

      // assert
      expect(stats, isNotNull);
      expect(stats!.tier, QualityTier.good);
      expect(stats.bytesSent, 2048);
      expect(stats.bytesReceived, 4096);
      expect(stats.frameWidth, 640);
      expect(stats.frameHeight, 480);

      await monitor.dispose();
    });
  });
}
