import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/core/network/reconnection_manager.dart';

void main() {
  group('ReconnectionState', () {
    test('all states are distinct', () {
      const states = ReconnectionState.values;
      final names = states.map((s) => s.name).toSet();
      expect(names.length, equals(states.length));
    });

    test('has expected states', () {
      expect(ReconnectionState.values, containsAll(<ReconnectionState>[
        ReconnectionState.idle,
        ReconnectionState.reconnectingSignaling,
        ReconnectionState.restartingIce,
        ReconnectionState.reconnected,
        ReconnectionState.failed,
      ]),);
    });
  });

  group('ReconnectionAttempt', () {
    test('construction', () {
      const attempt = ReconnectionAttempt(
        attempt: 1,
        maxAttempts: 3,
        reason: 'network_lost',
        succeeded: false,
        error: 'timeout',
      );
      expect(attempt.attempt, equals(1));
      expect(attempt.maxAttempts, equals(3));
      expect(attempt.reason, equals('network_lost'));
      expect(attempt.succeeded, isFalse);
      expect(attempt.error, equals('timeout'));
    });

    test('successful attempt has no error', () {
      const attempt = ReconnectionAttempt(
        attempt: 2,
        maxAttempts: 3,
        reason: 'ice_failed',
        succeeded: true,
      );
      expect(attempt.succeeded, isTrue);
      expect(attempt.error, isNull);
    });
  });

  group('ReconnectionConfig', () {
    test('defaults', () {
      const config = ReconnectionConfig();
      expect(config.maxAttempts, equals(3));
      expect(config.backoffMs, equals([0, 1000, 3000]));
      expect(config.iceRestartTimeoutMs, equals(5000));
      expect(config.signalingReconnectTimeoutMs, equals(10000));
      expect(config.graceWindowMs, equals(30000));
    });

    test('custom config', () {
      const config = ReconnectionConfig(
        maxAttempts: 5,
        backoffMs: [0, 500, 1000, 2000, 4000],
        iceRestartTimeoutMs: 3000,
        signalingReconnectTimeoutMs: 8000,
        graceWindowMs: 45000,
      );
      expect(config.maxAttempts, equals(5));
      expect(config.backoffMs.length, equals(5));
    });

    test('backoff values match spec', () {
      const config = ReconnectionConfig();
      // Spec: 0s → 1s → 3s
      expect(config.backoffMs[0], equals(0));
      expect(config.backoffMs[1], equals(1000));
      expect(config.backoffMs[2], equals(3000));
    });
  });
}
