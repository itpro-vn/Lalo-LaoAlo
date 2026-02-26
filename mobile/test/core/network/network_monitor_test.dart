import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/core/network/network_monitor.dart';

void main() {
  group('NetworkType', () {
    test('all types are distinct', () {
      const types = NetworkType.values;
      final names = types.map((t) => t.name).toSet();
      expect(names.length, equals(types.length));
    });
  });

  group('NetworkChange', () {
    test('wifi to cellular is handover', () {
      final change = NetworkChange(
        previousType: NetworkType.wifi,
        currentType: NetworkType.cellular,
        timestamp: DateTime.now(),
      );
      expect(change.isHandover, isTrue);
      expect(change.isDisconnect, isFalse);
      expect(change.isReconnect, isFalse);
    });

    test('cellular to wifi is handover', () {
      final change = NetworkChange(
        previousType: NetworkType.cellular,
        currentType: NetworkType.wifi,
        timestamp: DateTime.now(),
      );
      expect(change.isHandover, isTrue);
      expect(change.isDisconnect, isFalse);
    });

    test('wifi to none is disconnect', () {
      final change = NetworkChange(
        previousType: NetworkType.wifi,
        currentType: NetworkType.none,
        timestamp: DateTime.now(),
      );
      expect(change.isDisconnect, isTrue);
      expect(change.isHandover, isFalse);
      expect(change.isReconnect, isFalse);
    });

    test('none to wifi is reconnect', () {
      final change = NetworkChange(
        previousType: NetworkType.none,
        currentType: NetworkType.wifi,
        timestamp: DateTime.now(),
      );
      expect(change.isReconnect, isTrue);
      expect(change.isDisconnect, isFalse);
      expect(change.isHandover, isFalse);
    });

    test('none to cellular is reconnect', () {
      final change = NetworkChange(
        previousType: NetworkType.none,
        currentType: NetworkType.cellular,
        timestamp: DateTime.now(),
      );
      expect(change.isReconnect, isTrue);
    });

    test('wifi to ethernet is not handover', () {
      final change = NetworkChange(
        previousType: NetworkType.wifi,
        currentType: NetworkType.ethernet,
        timestamp: DateTime.now(),
      );
      expect(change.isHandover, isFalse);
      expect(change.isDisconnect, isFalse);
      expect(change.isReconnect, isFalse);
    });

    test('toString includes type info', () {
      final change = NetworkChange(
        previousType: NetworkType.wifi,
        currentType: NetworkType.cellular,
        timestamp: DateTime.now(),
      );
      final str = change.toString();
      expect(str, contains('wifi'));
      expect(str, contains('cellular'));
      expect(str, contains('handover=true'));
    });

    test('cellular to cellular is not handover', () {
      final change = NetworkChange(
        previousType: NetworkType.cellular,
        currentType: NetworkType.cellular,
        timestamp: DateTime.now(),
      );
      expect(change.isHandover, isFalse);
    });
  });

  group('NetworkMonitor', () {
    test('initial state is not monitoring', () {
      final monitor = NetworkMonitor();
      expect(monitor.isMonitoring, isFalse);
      expect(monitor.currentType, equals(NetworkType.none));
    });

    test('custom debounce is accepted', () {
      final monitor = NetworkMonitor(
        debounce: const Duration(seconds: 2),
      );
      expect(monitor, isNotNull);
    });

    test('dispose prevents further start', () async {
      final monitor = NetworkMonitor();
      await monitor.dispose();
      expect(() => monitor.start(), throwsStateError);
    });
  });
}
