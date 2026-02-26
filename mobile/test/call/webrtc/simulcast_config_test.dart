import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/webrtc/simulcast_config.dart';

void main() {
  group('SimulcastLayer', () {
    test('rid values match spec', () {
      expect(SimulcastLayer.high.rid, 'h');
      expect(SimulcastLayer.medium.rid, 'm');
      expect(SimulcastLayer.low.rid, 'l');
    });

    test('order values', () {
      expect(SimulcastLayer.high.order, 0);
      expect(SimulcastLayer.medium.order, 1);
      expect(SimulcastLayer.low.order, 2);
    });

    test('fromRid round-trips', () {
      for (final layer in SimulcastLayer.values) {
        expect(SimulcastLayerExt.fromRid(layer.rid), layer);
      }
    });

    test('fromRid throws on unknown', () {
      expect(
        () => SimulcastLayerExt.fromRid('x'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fromName parses various formats', () {
      expect(SimulcastLayerExt.fromName('high'), SimulcastLayer.high);
      expect(SimulcastLayerExt.fromName('h'), SimulcastLayer.high);
      expect(SimulcastLayerExt.fromName('HIGH'), SimulcastLayer.high);
      expect(SimulcastLayerExt.fromName('medium'), SimulcastLayer.medium);
      expect(SimulcastLayerExt.fromName('mid'), SimulcastLayer.medium);
      expect(SimulcastLayerExt.fromName('m'), SimulcastLayer.medium);
      expect(SimulcastLayerExt.fromName('low'), SimulcastLayer.low);
      expect(SimulcastLayerExt.fromName('l'), SimulcastLayer.low);
    });

    test('fromName throws on unknown', () {
      expect(
        () => SimulcastLayerExt.fromName('ultra'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SimulcastEncoding', () {
    test('equality', () {
      const a = SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      const b = SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality', () {
      const a = SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      const b = SimulcastEncoding(
        layer: SimulcastLayer.low,
        maxBitrateKbps: 150,
        maxFramerate: 10,
        scaleResolutionDownBy: 4.0,
      );
      expect(a, isNot(equals(b)));
    });

    test('copyWith preserves unchanged fields', () {
      const original = SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      final copy = original.copyWith(active: false);
      expect(copy.layer, SimulcastLayer.high);
      expect(copy.maxBitrateKbps, 1500);
      expect(copy.maxFramerate, 30);
      expect(copy.scaleResolutionDownBy, 1.0);
      expect(copy.active, false);
    });

    test('toRtpEncoding converts correctly', () {
      const encoding = SimulcastEncoding(
        layer: SimulcastLayer.medium,
        maxBitrateKbps: 500,
        maxFramerate: 20,
        scaleResolutionDownBy: 2.0,
        active: true,
      );
      final rtp = encoding.toRtpEncoding();
      expect(rtp['rid'], 'm');
      expect(rtp['active'], true);
      expect(rtp['maxBitrate'], 500000); // kbps → bps
      expect(rtp['maxFramerate'], 20);
      expect(rtp['scaleResolutionDownBy'], 2.0);
    });

    test('rid delegates to layer', () {
      const encoding = SimulcastEncoding(
        layer: SimulcastLayer.low,
        maxBitrateKbps: 150,
        maxFramerate: 10,
        scaleResolutionDownBy: 4.0,
      );
      expect(encoding.rid, 'l');
    });

    test('toString contains key info', () {
      const encoding = SimulcastEncoding(
        layer: SimulcastLayer.high,
        maxBitrateKbps: 1500,
        maxFramerate: 30,
        scaleResolutionDownBy: 1.0,
      );
      final s = encoding.toString();
      expect(s, contains('high'));
      expect(s, contains('1500'));
      expect(s, contains('30'));
    });
  });

  group('SimulcastConfig', () {
    test('defaultConfig has 3 layers', () {
      expect(SimulcastConfig.defaultConfig.encodings.length, 3);
    });

    test('defaultConfig layers match PB-02 spec', () {
      const config = SimulcastConfig.defaultConfig;

      final high = config.getEncoding(SimulcastLayer.high)!;
      expect(high.maxBitrateKbps, 1500);
      expect(high.maxFramerate, 30);
      expect(high.scaleResolutionDownBy, 1.0);
      expect(high.rid, 'h');

      final medium = config.getEncoding(SimulcastLayer.medium)!;
      expect(medium.maxBitrateKbps, 500);
      expect(medium.maxFramerate, 20);
      expect(medium.scaleResolutionDownBy, 2.0);
      expect(medium.rid, 'm');

      final low = config.getEncoding(SimulcastLayer.low)!;
      expect(low.maxBitrateKbps, 150);
      expect(low.maxFramerate, 10);
      expect(low.scaleResolutionDownBy, 4.0);
      expect(low.rid, 'l');
    });

    test('all default encodings are active', () {
      final active = SimulcastConfig.defaultConfig.activeEncodings;
      expect(active.length, 3);
    });

    test('getEncoding returns null for missing layer', () {
      const config = SimulcastConfig(encodings: <SimulcastEncoding>[]);
      expect(config.getEncoding(SimulcastLayer.high), isNull);
    });

    test('totalBitrateKbps sums all active layers', () {
      expect(
        SimulcastConfig.defaultConfig.totalBitrateKbps,
        1500 + 500 + 150,
      );
    });

    test('totalBitrateKbps excludes inactive layers', () {
      final config = SimulcastConfig(
        encodings: <SimulcastEncoding>[
          SimulcastConfig.defaultConfig.encodings[0], // high: 1500
          SimulcastConfig.defaultConfig.encodings[1]
              .copyWith(active: false), // medium: inactive
          SimulcastConfig.defaultConfig.encodings[2], // low: 150
        ],
      );
      expect(config.totalBitrateKbps, 1500 + 150);
    });

    test('toRtpEncodings returns list of maps', () {
      final encodings = SimulcastConfig.defaultConfig.toRtpEncodings();
      expect(encodings.length, 3);
      expect(encodings[0]['rid'], 'h');
      expect(encodings[1]['rid'], 'm');
      expect(encodings[2]['rid'], 'l');
    });
  });
}
