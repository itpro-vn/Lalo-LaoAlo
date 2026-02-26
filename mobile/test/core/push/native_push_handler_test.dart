import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/core/push/native_push_handler.dart';

void main() {
  // Ensure Flutter binding is initialized for MethodChannel tests
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IncomingCallPushData', () {
    test('constructs with all fields', () {
      const data = IncomingCallPushData(
        callId: 'call-123',
        callerName: 'Alice',
        callerId: 'user-456',
        hasVideo: true,
      );

      expect(data.callId, 'call-123');
      expect(data.callerName, 'Alice');
      expect(data.callerId, 'user-456');
      expect(data.hasVideo, true);
    });

    test('defaults hasVideo to false', () {
      const data = IncomingCallPushData(
        callId: 'call-123',
        callerName: 'Bob',
        callerId: 'user-789',
        hasVideo: false,
      );

      expect(data.hasVideo, false);
    });
  });

  group('VoIPTokenData', () {
    test('constructs with token', () {
      const token = VoIPTokenData(token: 'abc-def-123');
      expect(token.token, 'abc-def-123');
    });
  });

  group('NativePushHandler', () {
    late NativePushHandler handler;

    setUp(() {
      handler = NativePushHandler();
    });

    tearDown(() {
      handler.dispose();
    });

    test('isCallAlreadyReported returns false for unknown call', () {
      expect(handler.isCallAlreadyReported('unknown-call'), false);
    });

    test('markCallReported marks call as reported', () {
      handler.markCallReported('call-123');
      expect(handler.isCallAlreadyReported('call-123'), true);
    });

    test('dedup window works for markCallReported', () {
      handler.markCallReported('call-abc');
      // Within window — should be reported
      expect(handler.isCallAlreadyReported('call-abc'), true);
    });
  });
}
