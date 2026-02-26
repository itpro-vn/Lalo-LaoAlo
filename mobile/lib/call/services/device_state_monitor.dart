import 'dart:async';

import 'package:battery_plus/battery_plus.dart' as bp;
import 'package:flutter/services.dart';

/// Battery state information.
class BatteryState {
  const BatteryState({
    required this.level,
    required this.isCharging,
  });

  /// Battery level from 0.0 to 1.0.
  final double level;

  /// Whether the device is currently charging.
  final bool isCharging;

  /// Whether battery is considered low (<20%).
  bool get isLow => level < 0.20 && !isCharging;

  /// Whether battery is critically low (<10%).
  bool get isCritical => level < 0.10 && !isCharging;

  static const BatteryState normal =
      BatteryState(level: 1.0, isCharging: false);

  @override
  String toString() =>
      'BatteryState(level=${(level * 100).toStringAsFixed(0)}%, '
      'charging=$isCharging)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BatteryState &&
          level == other.level &&
          isCharging == other.isCharging;

  @override
  int get hashCode => Object.hash(level, isCharging);
}

/// Thermal state levels matching Apple's ProcessInfo.thermalState.
enum ThermalLevel {
  /// Normal operating conditions.
  nominal,

  /// Slightly elevated temperature. Minor impact possible.
  fair,

  /// Significant thermal pressure. Should reduce workload.
  serious,

  /// Critical thermal state. Must reduce workload immediately.
  critical,
}

/// Device state combining battery and thermal information.
class DeviceState {
  const DeviceState({
    required this.battery,
    required this.thermal,
  });

  final BatteryState battery;
  final ThermalLevel thermal;

  static const DeviceState normal = DeviceState(
    battery: BatteryState.normal,
    thermal: ThermalLevel.nominal,
  );

  /// Whether device conditions require quality reduction.
  bool get shouldReduceQuality =>
      battery.isLow ||
      thermal == ThermalLevel.serious ||
      thermal == ThermalLevel.critical;

  /// Whether device is in critical state requiring aggressive reduction.
  bool get isCritical => battery.isCritical || thermal == ThermalLevel.critical;

  /// Number of quality tiers to reduce based on device state.
  ///
  /// - Battery low (<20%): reduce 1 tier
  /// - Thermal serious: reduce 1 tier
  /// - Thermal critical: reduce 2 tiers
  /// - Battery critical + thermal serious: reduce 2 tiers
  int get tierReduction {
    int reduction = 0;

    if (battery.isLow) reduction += 1;
    if (thermal == ThermalLevel.serious) reduction += 1;
    if (thermal == ThermalLevel.critical) reduction += 2;

    // Cap at 2 (good → poor is max)
    return reduction.clamp(0, 2);
  }

  @override
  String toString() => 'DeviceState(battery=$battery, thermal=$thermal)';
}

/// Monitors device battery and thermal state using `battery_plus`.
///
/// Battery level and charging state come from the `battery_plus` Flutter
/// plugin. Thermal state uses a platform channel (`lalo/device_state`)
/// because no cross-platform Flutter plugin exists for thermal readings.
class DeviceStateMonitor {
  DeviceStateMonitor({
    this.pollIntervalMs = 10000,
    bp.Battery? battery,
  }) : _battery = battery ?? bp.Battery();

  /// Platform channel for thermal state only (no Flutter plugin available).
  static const MethodChannel _thermalChannel =
      MethodChannel('lalo/device_state');

  final bp.Battery _battery;
  final int pollIntervalMs;

  Timer? _pollTimer;
  StreamSubscription<bp.BatteryState>? _batteryStateSub;

  DeviceState _currentState = DeviceState.normal;

  final StreamController<DeviceState> _stateController =
      StreamController<DeviceState>.broadcast();

  // -- Public API --

  DeviceState get currentState => _currentState;
  Stream<DeviceState> get onStateChanged => _stateController.stream;

  /// Starts monitoring battery via `battery_plus` and polling thermal state.
  void start() {
    if (_pollTimer != null) return;

    // Read initial battery level (safe if platform unavailable).
    unawaited(_readBattery());

    // Listen to battery state changes (charging/discharging).
    // Wrapped in try-catch: onBatteryStateChanged needs ServicesBinding
    // which is unavailable in pure unit tests.
    if (_batteryStateSub == null) {
      try {
        _batteryStateSub = _battery.onBatteryStateChanged.listen((_) {
          unawaited(_readBattery());
        });
      } catch (_) {
        // Platform channel unavailable (e.g. unit tests).
      }
    }

    // Poll thermal state periodically (no reactive API available).
    _pollTimer = Timer.periodic(
      Duration(milliseconds: pollIntervalMs),
      (_) => unawaited(_pollThermal()),
    );

    // Read thermal once on start.
    unawaited(_pollThermal());
  }

  /// Stops monitoring.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _batteryStateSub?.cancel();
    _batteryStateSub = null;
  }

  Future<void> dispose() async {
    stop();
    await _stateController.close();
  }

  /// Updates battery state from platform.
  ///
  /// Called internally from battery_plus or externally for testing.
  void updateBattery({required double level, required bool isCharging}) {
    final newBattery = BatteryState(level: level, isCharging: isCharging);
    if (newBattery != _currentState.battery) {
      _currentState = DeviceState(
        battery: newBattery,
        thermal: _currentState.thermal,
      );
      _emitState();
    }
  }

  /// Updates thermal state from platform.
  void updateThermal(ThermalLevel level) {
    if (level != _currentState.thermal) {
      _currentState = DeviceState(
        battery: _currentState.battery,
        thermal: level,
      );
      _emitState();
    }
  }

  /// Sets full device state directly (for testing).
  void setState(DeviceState state) {
    if (state != _currentState) {
      _currentState = state;
      _emitState();
    }
  }

  // -- Internal --

  /// Reads battery level and state via `battery_plus`.
  Future<void> _readBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final batteryState = await _battery.batteryState;

      final isCharging = batteryState == bp.BatteryState.charging ||
          batteryState == bp.BatteryState.full;

      final normalizedLevel = (level / 100.0).clamp(0.0, 1.0);

      updateBattery(level: normalizedLevel, isCharging: isCharging);
    } catch (_) {
      // battery_plus unavailable (e.g. simulator without battery support).
    }
  }

  /// Polls thermal state via platform channel (no Flutter plugin available).
  Future<void> _pollThermal() async {
    try {
      final thermalRaw =
          await _thermalChannel.invokeMethod<dynamic>('getThermalState');
      if (thermalRaw != null) {
        updateThermal(_parseThermalLevel(thermalRaw));
      }
    } catch (_) {
      // Platform channel unavailable or method not implemented.
    }
  }

  ThermalLevel _parseThermalLevel(dynamic value) {
    if (value is int) {
      return switch (value) {
        <= 0 => ThermalLevel.nominal,
        1 => ThermalLevel.fair,
        2 => ThermalLevel.serious,
        _ => ThermalLevel.critical,
      };
    }

    if (value is String) {
      return switch (value.toLowerCase()) {
        'nominal' || 'normal' => ThermalLevel.nominal,
        'fair' || 'moderate' => ThermalLevel.fair,
        'serious' || 'high' => ThermalLevel.serious,
        'critical' => ThermalLevel.critical,
        _ => ThermalLevel.nominal,
      };
    }

    return ThermalLevel.nominal;
  }

  void _emitState() {
    if (!_stateController.isClosed) {
      _stateController.add(_currentState);
    }
  }
}
