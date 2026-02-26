import 'package:lalo/core/config/app_config.dart';
import 'package:test/test.dart';

void main() {
  group('AppConfig', () {
    test('development() factory has correct defaults', () {
      // arrange

      // act
      final config = AppConfig.development();

      // assert
      expect(config.signalingUrl, 'wss://localhost/ws');
      expect(config.apiBaseUrl, 'https://localhost/api/v1');
      expect(config.maxReconnectAttempts, 3);
      expect(config.reconnectBackoff, const [0, 1000, 3000]);
      expect(config.statsIntervalMs, 5000);
    });

    test('production() factory has correct values', () {
      // arrange

      // act
      final config = AppConfig.production();

      // assert
      expect(config.signalingUrl, 'wss://localhost/ws');
      expect(config.apiBaseUrl, 'https://localhost/api/v1');
      expect(config.iceServers.length, 3);
      expect(config.iceServers[1]['urls'], ['turn:turn.example.com:3478?transport=udp']);
      expect(config.iceServers[2]['urls'], ['turns:turn.example.com:5349?transport=tcp']);
    });

    test('ICE servers include STUN', () {
      // arrange
      final dev = AppConfig.development();
      final prod = AppConfig.production();

      bool hasStun(List<Map<String, dynamic>> servers) {
        for (final server in servers) {
          final urls = server['urls'];
          if (urls is List && urls.any((u) => u.toString().startsWith('stun:'))) {
            return true;
          }
        }
        return false;
      }

      // act/assert
      expect(hasStun(dev.iceServers), isTrue);
      expect(hasStun(prod.iceServers), isTrue);
    });

    test('timeout values match spec (ring=45s, ice=15s)', () {
      // arrange
      final dev = AppConfig.development();
      final prod = AppConfig.production();

      // act/assert
      expect(dev.ringTimeoutSeconds, 45);
      expect(dev.iceTimeoutSeconds, 15);
      expect(prod.ringTimeoutSeconds, 45);
      expect(prod.iceTimeoutSeconds, 15);
    });
  });
}
