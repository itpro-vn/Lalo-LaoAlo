import 'dart:async';

/// Canonical call lifecycle states.
enum CallState {
  idle,
  outgoing,
  incoming,
  connecting,
  active,
  reconnecting,
  ended,
}

/// Immutable transition record for call-state changes.
class CallStateTransition {
  /// Creates a [CallStateTransition].
  const CallStateTransition({
    required this.fromState,
    required this.toState,
    required this.timestamp,
    this.reason,
  });

  /// Previous state.
  final CallState fromState;

  /// Next state.
  final CallState toState;

  /// Transition timestamp.
  final DateTime timestamp;

  /// Optional human-readable reason.
  final String? reason;
}

/// Enforces legal transitions and publishes state-change events.
class CallStateMachine {
  /// Creates a machine initialized to [initialState].
  CallStateMachine({CallState initialState = CallState.idle})
    : _currentState = initialState;

  static const Map<CallState, Set<CallState>> _validTransitions = {
    CallState.idle: {CallState.outgoing, CallState.incoming},
    CallState.outgoing: {CallState.connecting, CallState.ended},
    CallState.incoming: {CallState.connecting, CallState.ended},
    CallState.connecting: {
      CallState.active,
      CallState.reconnecting,
      CallState.ended,
    },
    CallState.active: {CallState.reconnecting, CallState.ended},
    CallState.reconnecting: {CallState.active, CallState.ended},
    CallState.ended: {},
  };

  final StreamController<CallStateTransition> _controller =
      StreamController<CallStateTransition>.broadcast();

  CallState _currentState;

  /// Current state.
  CallState get currentState => _currentState;

  /// Emits each successful transition.
  Stream<CallStateTransition> get onStateChanged => _controller.stream;

  /// Returns `true` when [newState] is valid from [currentState].
  bool canTransition(CallState newState) {
    final allowed = _validTransitions[_currentState];
    return allowed != null && allowed.contains(newState);
  }

  /// Returns `true` when [state] is terminal and cannot transition.
  bool isTerminal(CallState state) => state == CallState.ended;

  /// Performs state transition and emits a [CallStateTransition] event.
  ///
  /// Throws [StateError] if transition is not allowed.
  CallStateTransition transition(CallState newState, {String? reason}) {
    if (!canTransition(newState)) {
      throw StateError(
        'Invalid call-state transition: $_currentState -> $newState',
      );
    }

    final transition = CallStateTransition(
      fromState: _currentState,
      toState: newState,
      timestamp: DateTime.now().toUtc(),
      reason: reason,
    );

    _currentState = newState;
    _controller.add(transition);
    return transition;
  }

  /// Releases stream resources.
  Future<void> dispose() async {
    await _controller.close();
  }
}
