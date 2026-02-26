import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:logging/logging.dart';

/// Network interface type.
enum NetworkType {
  wifi,
  cellular,
  ethernet,
  none,
  other,
}

/// Describes a change in network interface.
class NetworkChange {
  const NetworkChange({
    required this.previousType,
    required this.currentType,
    required this.timestamp,
  });

  final NetworkType previousType;
  final NetworkType currentType;
  final DateTime timestamp;

  /// True when switching between wifi and cellular (in either direction).
  bool get isHandover =>
      (previousType == NetworkType.wifi &&
          currentType == NetworkType.cellular) ||
      (previousType == NetworkType.cellular && currentType == NetworkType.wifi);

  /// True when the network was lost entirely.
  bool get isDisconnect => currentType == NetworkType.none;

  /// True when the network was restored from none.
  bool get isReconnect =>
      previousType == NetworkType.none && currentType != NetworkType.none;

  @override
  String toString() =>
      'NetworkChange($previousType -> $currentType, handover=$isHandover)';
}

/// Monitors device network interface changes using connectivity_plus.
///
/// Detects WiFi ↔ Cellular handovers, connection loss, and recovery.
/// Uses debouncing to avoid rapid-fire events during interface transitions.
class NetworkMonitor {
  NetworkMonitor({
    Duration debounce = const Duration(milliseconds: 500),
  }) : _debounceDuration = debounce;

  static final Logger _log = Logger('NetworkMonitor');

  final Duration _debounceDuration;
  final Connectivity _connectivity = Connectivity();

  final StreamController<NetworkChange> _changeController =
      StreamController<NetworkChange>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounceTimer;

  NetworkType _currentType = NetworkType.none;
  bool _isMonitoring = false;
  bool _disposed = false;

  /// Stream of network interface changes (debounced).
  Stream<NetworkChange> get onNetworkChange => _changeController.stream;

  /// Current known network type.
  NetworkType get currentType => _currentType;

  /// Whether the monitor is actively listening.
  bool get isMonitoring => _isMonitoring;

  /// Start monitoring network changes.
  Future<void> start() async {
    if (_disposed) throw StateError('NetworkMonitor is disposed');
    if (_isMonitoring) return;
    _isMonitoring = true;

    // Get initial state
    final results = await _connectivity.checkConnectivity();
    _currentType = _mapConnectivityResult(results);
    _log.fine('Initial network type: $_currentType');

    // Subscribe to changes
    _subscription = _connectivity.onConnectivityChanged.listen(
      _handleConnectivityChange,
    );
  }

  /// Stop monitoring network changes.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _isMonitoring = false;
  }

  /// Dispose all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    await _changeController.close();
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final newType = _mapConnectivityResult(results);

    // Skip if no actual change
    if (newType == _currentType) return;

    // Debounce to avoid rapid-fire events during transitions
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      final previous = _currentType;
      _currentType = newType;

      final change = NetworkChange(
        previousType: previous,
        currentType: newType,
        timestamp: DateTime.now(),
      );

      _log.info('Network change: $change');
      if (!_changeController.isClosed) {
        _changeController.add(change);
      }
    });
  }

  /// Maps connectivity_plus results to our NetworkType.
  /// Prioritizes wifi > cellular > ethernet > other > none.
  NetworkType _mapConnectivityResult(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return NetworkType.none;
    }
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkType.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkType.cellular;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkType.ethernet;
    }
    return NetworkType.other;
  }
}
