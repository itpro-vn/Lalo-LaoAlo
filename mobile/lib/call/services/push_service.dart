import 'dart:async';
import 'dart:io';

import 'package:callkeep/callkeep.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:lalo/call/services/callkit_service.dart';
import 'package:lalo/core/network/api_client.dart';

/// Global callback for handling FCM data messages when app is background/killed.
@pragma('vm:entry-point')
Future<void> laloFirebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  final data = message.data;
  if (data.isEmpty) return;

  final callId = data['call_id']?.toString();
  final callerName = data['caller_name']?.toString() ?? 'Unknown';
  final hasVideo = _asBool(data['has_video']);

  if (callId == null || callId.isEmpty) return;

  final callKeep = FlutterCallkeep();
  await callKeep.setup(
    backgroundMode: true,
    options: <String, dynamic>{
      'ios': <String, dynamic>{
        'appName': 'Lalo',
        'imageName': 'AppIcon',
        'ringtoneSound': 'ringtone.caf',
        'supportsVideo': true,
        'supportsDTMF': false,
        'supportsHolding': true,
      },
      'android': <String, dynamic>{
        'imageName': 'ic_launcher',
        'additionalPermissions': <String>[
          'android.permission.CALL_PHONE',
          'android.permission.READ_PHONE_NUMBERS',
        ],
        'foregroundService': <String, dynamic>{
          'channelId': 'com.lalo.calling',
          'channelName': 'Lalo calling service',
          'notificationTitle': 'Incoming Lalo call',
          'notificationIcon': 'mipmap/ic_launcher',
        },
      },
    },
  );

  // Android background/killed: trigger full-screen native incoming UI.
  if (Platform.isAndroid) {
    await callKeep.displayIncomingCall(
      uuid: callId,
      handle: data['caller_id']?.toString() ?? 'unknown',
      callerName: callerName,
      hasVideo: hasVideo,
      additionalData: Map<String, dynamic>.from(data),
    );
  }
}

/// Push-notification service for call signaling delivery.
class PushService {
  PushService(this._apiClient, this._callKitService);

  final ApiClient _apiClient;
  final CallKitService _callKitService;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  final StreamController<Map<String, dynamic>> _incomingCallPayloadController =
      StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription<String>? _pushKitTokenSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;

  String? _fcmToken;
  String? _voipToken;
  String? _deviceId;
  String? _platform;
  bool _initialized = false;

  Stream<Map<String, dynamic>> get onIncomingCallPayload =>
      _incomingCallPayloadController.stream;

  Future<void> initialize() async {
    if (_initialized) return;

    await Firebase.initializeApp();

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      announcement: false,
      criticalAlert: true,
      carPlay: false,
    );

    FirebaseMessaging.onBackgroundMessage(laloFirebaseBackgroundHandler);

    _fcmToken = await _messaging.getToken();

    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((token) async {
      _fcmToken = token;
      await _tryRegisterLatestTokens();
    });

    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen(
      _handleForegroundMessage,
    );

    _pushKitTokenSubscription = _callKitService.onPushKitToken.listen((token) async {
      _voipToken = token;
      await _tryRegisterLatestTokens();
    });

    _initialized = true;
  }

  /// Handles iOS VoIP push payload and immediately reports incoming call.
  ///
  /// CRITICAL: invoke this as soon as payload arrives to avoid iOS kill.
  Future<void> handleVoipPushPayload(Map<String, dynamic> payload) async {
    final parsed = _parsePayload(payload);
    if (parsed == null) return;

    await _callKitService.reportIncomingCall(
      parsed.callId,
      parsed.callerName,
      parsed.hasVideo,
      handle: parsed.callerId,
      metadata: parsed.raw,
    );

    if (!_incomingCallPayloadController.isClosed) {
      _incomingCallPayloadController.add(parsed.raw);
    }
  }

  Future<void> registerTokens(String deviceId, String platform) async {
    _deviceId = deviceId;
    _platform = platform;
    await _tryRegisterLatestTokens();
  }

  Future<void> unregisterTokens(String deviceId) async {
    await _apiClient.unregisterPushToken(deviceId);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final parsed = _parsePayload(message.data);
    if (parsed == null) return;

    // iOS VoIP path: trigger native incoming call UI immediately.
    if (Platform.isIOS &&
        (parsed.raw['push_type'] == 'voip' || parsed.raw['is_voip'] == 'true')) {
      unawaited(
        _callKitService.reportIncomingCall(
          parsed.callId,
          parsed.callerName,
          parsed.hasVideo,
          handle: parsed.callerId,
          metadata: parsed.raw,
        ),
      );
    }

    // Foreground: hand payload to app for in-app incoming-call screen.
    if (!_incomingCallPayloadController.isClosed) {
      _incomingCallPayloadController.add(parsed.raw);
    }
  }

  Future<void> _tryRegisterLatestTokens() async {
    final deviceId = _deviceId;
    final platform = _platform;
    if (deviceId == null || platform == null) return;

    final fcm = _fcmToken;
    if (fcm == null || fcm.isEmpty) return;

    await _apiClient.registerPushToken(
      deviceId,
      platform,
      fcm,
      voipToken: _voipToken,
    );
  }

  _IncomingPayload? _parsePayload(Map<String, dynamic> data) {
    final callId = data['call_id']?.toString();
    final callerId = data['caller_id']?.toString() ?? 'unknown';
    final callerName = data['caller_name']?.toString() ?? 'Unknown';

    if (callId == null || callId.isEmpty) return null;

    final normalized = <String, dynamic>{
      'call_id': callId,
      'caller_id': callerId,
      'caller_name': callerName,
      'has_video': _asBool(data['has_video']).toString(),
      'call_type': data['call_type']?.toString() ?? 'one_to_one',
      ...data,
    };

    return _IncomingPayload(
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      hasVideo: _asBool(data['has_video']),
      raw: normalized,
    );
  }

  Future<void> dispose() async {
    await _pushKitTokenSubscription?.cancel();
    await _tokenRefreshSubscription?.cancel();
    await _foregroundMessageSubscription?.cancel();
    await _incomingCallPayloadController.close();
  }
}

class _IncomingPayload {
  const _IncomingPayload({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.hasVideo,
    required this.raw,
  });

  final String callId;
  final String callerId;
  final String callerName;
  final bool hasVideo;
  final Map<String, dynamic> raw;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final v = value.trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'yes';
  }
  return false;
}
