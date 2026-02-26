import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/services/device_state_monitor.dart';

void main() {
  group('BatteryState', () {
    test('normal battery is not low', () {
      const state = BatteryState(level: 0.80, isCharging: false);
      expect(state.isLow, false);
      expect(state.isCritical, false);
    });

    test('low battery at 15%', () {
      const state = BatteryState(level: 0.15, isCharging: false);
      expect(state.isLow, true);
      expect(state.isCritical, false);
    });

    test('critical battery at 8%', () {
      const state = BatteryState(level: 0.08, isCharging: false);
      expect(state.isLow, true);
      expect(state.isCritical, true);
    });

    test('charging battery is never low', () {
      const state = BatteryState(level: 0.05, isCharging: true);
      expect(state.isLow, false);
      expect(state.isCritical, false);
    });

    test('equality', () {
      const a = BatteryState(level: 0.50, isCharging: false);
      const b = BatteryState(level: 0.50, isCharging: false);
      expect(a, equals(b));
    });
  });

  group('DeviceState', () {
    test('normal state does not reduce quality', () {
      const state = DeviceState.normal;
      expect(state.shouldReduceQuality, false);
      expect(state.isCritical, false);
      expect(state.tierReduction, 0);
    });

    test('low battery reduces by 1 tier', () {
      const state = DeviceState(
        battery: BatteryState(level: 0.15, isCharging: false),
        thermal: ThermalLevel.nominal,
      );
      expect(state.shouldReduceQuality, true);
      expect(state.tierReduction, 1);
    });

    test('serious thermal reduces by 1 tier', () {
      const state = DeviceState(
        battery: BatteryState.normal,
        thermal: ThermalLevel.serious,
      );
      expect(state.shouldReduceQuality, true);
      expect(state.tierReduction, 1);
    });

    test('critical thermal reduces by 2 tiers', () {
      const state = DeviceState(
        battery: BatteryState.normal,
        thermal: ThermalLevel.critical,
      );
      expect(state.shouldReduceQuality, true);
      expect(state.isCritical, true);
      expect(state.tierReduction, 2);
    });

    test('low battery + serious thermal reduces by 2 tiers', () {
      const state = DeviceState(
        battery: BatteryState(level: 0.15, isCharging: false),
        thermal: ThermalLevel.serious,
      );
      expect(state.tierReduction, 2);
    });

    test('tier reduction capped at 2', () {
      const state = DeviceState(
        battery: BatteryState(level: 0.05, isCharging: false),
        thermal: ThermalLevel.critical,
      );
      // 1 (battery) + 2 (critical thermal) = 3, capped at 2
      expect(state.tierReduction, 2);
    });

    test('fair thermal does not reduce quality', () {
      const state = DeviceState(
        battery: BatteryState.normal,
        thermal: ThermalLevel.fair,
      );
      expect(state.shouldReduceQuality, false);
      expect(state.tierReduction, 0);
    });
  });

  group('DeviceStateMonitor', () {
    late DeviceStateMonitor monitor;

    setUp(() {
      monitor = DeviceStateMonitor(pollIntervalMs: 100);
    });

    tearDown(() async {
      await monitor.dispose();
    });

    test('initial state is normal', () {
      expect(monitor.currentState, DeviceState.normal);
    });

    test('updateBattery emits new state', () async {
      final states = <DeviceState>[];
      final sub = monitor.onStateChanged.listen(states.add);

      monitor.updateBattery(level: 0.15, isCharging: false);
      await Future.delayed(Duration.zero);

      expect(states.length, 1);
      expect(states[0].battery.isLow, true);
      expect(monitor.currentState.battery.level, 0.15);

      await sub.cancel();
    });

    test('updateThermal emits new state', () async {
      final states = <DeviceState>[];
      final sub = monitor.onStateChanged.listen(states.add);

      monitor.updateThermal(ThermalLevel.serious);
      await Future.delayed(Duration.zero);

      expect(states.length, 1);
      expect(states[0].thermal, ThermalLevel.serious);

      await sub.cancel();
    });

    test('same state does not re-emit', () async {
      final states = <DeviceState>[];
      final sub = monitor.onStateChanged.listen(states.add);

      monitor.updateBattery(level: 0.50, isCharging: false);
      await Future.delayed(Duration.zero);
      monitor.updateBattery(level: 0.50, isCharging: false);
      await Future.delayed(Duration.zero);

      expect(states.length, 1);

      await sub.cancel();
    });

    test('setState directly', () {
      const custom = DeviceState(
        battery: BatteryState(level: 0.10, isCharging: false),
        thermal: ThermalLevel.critical,
      );
      monitor.setState(custom);
      expect(monitor.currentState, custom);
    });

    test('start and stop do not crash', () {
      monitor.start();
      monitor.start(); // double start is safe
      monitor.stop();
      monitor.stop(); // double stop is safe
    });
  });
}
