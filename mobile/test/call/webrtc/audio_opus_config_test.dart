import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';

void main() {
  group('AudioOpusConfig', () {
    test('defaults to FEC enabled, DTX disabled, ptime 20', () {
      const config = AudioOpusConfig();
      expect(config.fecEnabled, true);
      expect(config.dtxEnabled, false);
      expect(config.packetTimeMs, 20);
    });

    test('equality', () {
      const a = AudioOpusConfig();
      const b = AudioOpusConfig();
      expect(a, equals(b));

      const c = AudioOpusConfig(fecEnabled: false);
      expect(a, isNot(equals(c)));
    });

    test('toString', () {
      const config = AudioOpusConfig(fecEnabled: false, packetTimeMs: 40);
      expect(config.toString(), contains('fec=false'));
      expect(config.toString(), contains('ptime=40ms'));
    });
  });

  group('SDP munging', () {
    // Minimal SDP with Opus fmtp line.
    const baseSdp = 'v=0\r\n'
        'o=- 12345 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111 103\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
        'a=rtpmap:103 ISAC/16000\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=rtpmap:96 VP8/90000\r\n';

    test('sets useinbandfec=0 when FEC disabled', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(fecEnabled: false),
      );
      expect(result, contains('useinbandfec=0'));
      expect(result, isNot(contains('useinbandfec=1')));
    });

    test('sets useinbandfec=1 when FEC enabled', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(fecEnabled: true),
      );
      expect(result, contains('useinbandfec=1'));
    });

    test('adds usedtx=1 when DTX enabled', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(dtxEnabled: true),
      );
      expect(result, contains('usedtx=1'));
    });

    test('inserts ptime line', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(packetTimeMs: 40),
      );
      expect(result, contains('a=ptime:40'));
    });

    test('replaces existing ptime line', () {
      const sdpWithPtime = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n'
          'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
          'a=ptime:20\r\n';

      final result = PeerConnectionManager.mungeOpusSdpForTest(
        sdpWithPtime,
        const AudioOpusConfig(packetTimeMs: 40),
      );
      expect(result, contains('a=ptime:40'));
      expect(result, isNot(contains('a=ptime:20')));
    });

    test('handles SDP without Opus', () {
      const noOpusSdp = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 103\r\n'
          'a=rtpmap:103 ISAC/16000\r\n';

      // Should not crash, SDP returned unchanged (no Opus fmtp to munge).
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        noOpusSdp,
        const AudioOpusConfig(fecEnabled: false),
      );
      expect(result, isNot(contains('useinbandfec')));
    });

    test('poor tier config: FEC ON, ptime 40', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(fecEnabled: true, packetTimeMs: 40),
      );
      expect(result, contains('useinbandfec=1'));
      expect(result, contains('a=ptime:40'));
    });

    test('good tier config: FEC OFF, ptime 20', () {
      final result = PeerConnectionManager.mungeOpusSdpForTest(
        baseSdp,
        const AudioOpusConfig(fecEnabled: false, packetTimeMs: 20),
      );
      expect(result, contains('useinbandfec=0'));
      expect(result, contains('a=ptime:20'));
    });
  });
}
