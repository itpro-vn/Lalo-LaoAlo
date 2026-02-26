import 'package:lalo/call/models/call_state.dart';
import 'package:test/test.dart';

void main() {
  group('CallStateMachine', () {
    late CallStateMachine machine;

    setUp(() {
      machine = CallStateMachine();
    });

    tearDown(() async {
      await machine.dispose();
    });

    test('initial state is idle', () {
      // arrange

      // act
      final current = machine.currentState;

      // assert
      expect(current, CallState.idle);
    });

    test('valid transitions are allowed and update current state', () async {
      // arrange
      const validPaths = <List<CallState>>[
        [CallState.idle, CallState.outgoing],
        [CallState.idle, CallState.incoming],
        [CallState.incoming, CallState.connecting],
        [CallState.connecting, CallState.active],
        [CallState.active, CallState.ended],
        [CallState.active, CallState.reconnecting],
        [CallState.reconnecting, CallState.active],
        [CallState.reconnecting, CallState.ended],
      ];

      for (final path in validPaths) {
        final local = CallStateMachine(initialState: path.first);

        // act
        final transition = local.transition(path.last, reason: 'test');

        // assert
        expect(local.currentState, path.last);
        expect(transition.fromState, path.first);
        expect(transition.toState, path.last);
        expect(transition.reason, 'test');

        await local.dispose();
      }
    });

    test('invalid transitions throw StateError', () async {
      // arrange
      final idle = CallStateMachine(initialState: CallState.idle);
      final active = CallStateMachine(initialState: CallState.active);
      final ended = CallStateMachine(initialState: CallState.ended);

      // act + assert
      expect(() => idle.transition(CallState.active), throwsStateError);
      expect(() => idle.transition(CallState.connecting), throwsStateError);
      expect(() => active.transition(CallState.incoming), throwsStateError);
      expect(() => ended.transition(CallState.active), throwsStateError);

      await idle.dispose();
      await active.dispose();
      await ended.dispose();
    });

    test('isTerminal only returns true for ended', () {
      // arrange
      const allStates = CallState.values;

      // act + assert
      for (final state in allStates) {
        expect(machine.isTerminal(state), state == CallState.ended);
      }
    });

    test('canTransition returns expected booleans', () async {
      // arrange
      final expected = <CallState, Set<CallState>>{
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
        CallState.ended: <CallState>{},
      };

      for (final from in CallState.values) {
        final local = CallStateMachine(initialState: from);

        // act + assert
        for (final to in CallState.values) {
          expect(local.canTransition(to), expected[from]!.contains(to));
        }

        await local.dispose();
      }
    });

    test('onStateChanged emits transition events', () async {
      // arrange
      final future = machine.onStateChanged.first;

      // act
      machine.transition(CallState.outgoing, reason: 'dialing');
      final emitted = await future;

      // assert
      expect(emitted.fromState, CallState.idle);
      expect(emitted.toState, CallState.outgoing);
      expect(emitted.reason, 'dialing');
      expect(emitted.timestamp.isUtc, isTrue);
    });

    test('multiple rapid transitions emit in order', () async {
      // arrange
      final emitted = <CallStateTransition>[];
      final sub = machine.onStateChanged.listen(emitted.add);

      // act
      machine.transition(CallState.outgoing);
      machine.transition(CallState.connecting);
      machine.transition(CallState.active);
      machine.transition(CallState.reconnecting);
      machine.transition(CallState.ended);
      await Future<void>.delayed(Duration.zero);

      // assert
      expect(emitted.length, 5);
      expect(
        emitted.map((e) => [e.fromState, e.toState]).toList(),
        const [
          [CallState.idle, CallState.outgoing],
          [CallState.outgoing, CallState.connecting],
          [CallState.connecting, CallState.active],
          [CallState.active, CallState.reconnecting],
          [CallState.reconnecting, CallState.ended],
        ],
      );

      await sub.cancel();
    });
  });
}
