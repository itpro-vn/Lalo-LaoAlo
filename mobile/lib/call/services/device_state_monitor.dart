import 'dart:async';

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

  static const BatteryState normal = BatteryState(level: 1.0, isCharging: false);

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
  bool get isCritical =>
      battery.isCritical || thermal == ThermalLevel.critical;

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
  String toString() =>
      'DeviceState(battery=$battery, thermal=$thermal)';
}

/// Monitors device battery and thermal state.
///
/// In Flutter, this would use platform channels or plugins like
/// `battery_plus` and platform-specific thermal APIs.
/// This implementation provides a polling-based interface with
/// manual state injection for testing and platform bridge.
class DeviceStateMonitor {
  DeviceStateMonitor({
    this.pollIntervalMs = 10000,
  });

  final int pollIntervalMs;

  Timer? _pollTimer;

  DeviceState _currentState = DeviceState.normal;

  final StreamController<DeviceState> _stateController =
      StreamController<DeviceState>.broadcast();

  // -- Public API --

  DeviceState get currentState => _currentState;
  Stream<DeviceState> get onStateChanged => _stateController.stream;

  /// Starts polling for device state changes.
  void start() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(
      Duration(milliseconds: pollIntervalMs),
      (_) => _poll(),
    );
  }

  /// Stops polling.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> dispose() async {
    stop();
    await _stateController.close();
  }

  /// Updates battery state from platform.
  ///
  /// Called by platform channel handler or battery_plus listener.
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
  ///
  /// Called by platform channel handler.
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

  void _poll() {
    // In production, this would query platform APIs.
    // State updates come via updateBattery() and updateThermal()
    // from platform channel listeners.
  }

  void _emitState() {
    if (!_stateController.isClosed) {
      _stateController.add(_currentState);
    }
  }
}
