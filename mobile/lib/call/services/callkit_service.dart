import 'dart:async';

import 'package:callkeep/callkeep.dart';
import 'package:flutter/foundation.dart';

import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/services/call_service.dart';

/// Integrates iOS CallKit and Android ConnectionService via `callkeep`.
class CallKitService {
  CallKitService(this._callService);

  final CallService _callService;
  final FlutterCallkeep _callKeep = FlutterCallkeep();

  final StreamController<String> _pushKitTokenController =
      StreamController<String>.broadcast();

  StreamSubscription<CallState>? _callStateSubscription;
  bool _initialized = false;

  Stream<String> get onPushKitToken => _pushKitTokenController.stream;

  Future<void> initialize() async {
    if (_initialized) return;

    await _callKeep.setup(
      options: <String, dynamic>{
        'ios': <String, dynamic>{
          'appName': 'Lalo',
          'imageName': 'AppIcon',
          'ringtoneSound': 'ringtone.caf',
          'supportsVideo': true,
          'supportsDTMF': false,
          'supportsHolding': true,
          'supportsGrouping': false,
          'supportsUngrouping': false,
          'includesCallsInRecents': true,
        },
        'android': <String, dynamic>{
          'alertTitle': 'Permissions required',
          'alertDescription': 'Lalo needs phone account access for calls.',
          'cancelButton': 'Cancel',
          'okButton': 'Allow',
          'imageName': 'ic_launcher',
          'additionalPermissions': <String>[
            'android.permission.CALL_PHONE',
            'android.permission.READ_PHONE_NUMBERS',
          ],
          'foregroundService': <String, dynamic>{
            'channelId': 'com.lalo.calling',
            'channelName': 'Lalo calling service',
            'notificationTitle': 'Lalo call in progress',
            'notificationIcon': 'mipmap/ic_launcher',
          },
        },
      },
    );

    _bindSystemEvents();
    _bindCallServiceEvents();

    _initialized = true;
  }

  /// CRITICAL: must be called immediately after VoIP push receipt on iOS.
  Future<void> reportIncomingCall(
    String callId,
    String callerName,
    bool hasVideo, {
    String handle = 'unknown',
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _callKeep.displayIncomingCall(
      uuid: callId,
      handle: handle,
      callerName: callerName,
      hasVideo: hasVideo,
      additionalData: metadata,
    );
  }

  Future<void> reportOutgoingCall(
    String callId,
    String calleeName,
    bool hasVideo, {
    String handle = 'unknown',
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _callKeep.startCall(
      uuid: callId,
      handle: handle,
      callerName: calleeName,
      hasVideo: hasVideo,
      additionalData: metadata,
    );

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _callKeep.reportStartedCallWithUUID(callId);
    } else {
      await _callKeep.reportConnectingOutgoingCallWithUUID(callId);
    }
  }

  Future<void> reportCallConnected(String callId) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _callKeep.reportConnectedOutgoingCallWithUUID(callId);
    } else {
      await _callKeep.setCurrentCallActive(callId);
    }
  }

  Future<void> reportCallEnded(String callId, String reason) async {
    await _callKeep.reportEndCallWithUUID(
      uuid: callId,
      reason: _toCallKeepEndReason(reason),
      notify: true,
    );
  }

  Future<void> reportCallHeld(String callId, bool isOnHold) async {
    await _callKeep.setOnHold(uuid: callId, shouldHold: isOnHold);
  }

  void _bindSystemEvents() {
    _callKeep.on<CallKeepPerformAnswerCallAction>(_onAnswerCall);
    _callKeep.on<CallKeepPerformEndCallAction>(_onEndCall);
    _callKeep.on<CallKeepDidPerformSetMutedCallAction>(_onToggleMute);
    _callKeep.on<CallKeepDidToggleHoldAction>(_onToggleHold);
    _callKeep.on<CallKeepDidPerformDTMFAction>(_onDtmf);
    _callKeep.on<CallKeepPushKitToken>(_onPushKitToken);
  }

  void _bindCallServiceEvents() {
    _callStateSubscription = _callService.onCallState.listen((state) async {
      final callId = _callService.currentCallId;
      if (callId == null || callId.isEmpty) return;

      switch (state) {
        case CallState.active:
          await reportCallConnected(callId);
          break;
        case CallState.ended:
          final endReason = _callService.currentSession?.endReason ?? 'ended';
          await reportCallEnded(callId, endReason);
          break;
        case CallState.reconnecting:
        case CallState.connecting:
        case CallState.idle:
        case CallState.outgoing:
        case CallState.incoming:
          break;
      }
    });
  }

  Future<void> _onAnswerCall(CallKeepPerformAnswerCallAction event) async {
    final callId = event.callData.callUUID;
    if (callId == null || callId.isEmpty) return;
    await _callService.acceptCall(callId);
  }

  Future<void> _onEndCall(CallKeepPerformEndCallAction event) async {
    final callId = event.callUUID;
    if (callId == null || callId.isEmpty) return;
    await _callService.endCall(callId, reason: 'ended_by_system');
  }

  Future<void> _onToggleMute(CallKeepDidPerformSetMutedCallAction event) async {
    final muted = event.muted;
    if (muted == null) return;
    await _callService.setMuted(muted);
  }

  Future<void> _onToggleHold(CallKeepDidToggleHoldAction event) async {
    final hold = event.hold;
    if (hold == null) return;
    await _callService.toggleHold(hold);
  }

  void _onDtmf(CallKeepDidPerformDTMFAction event) {
    // Intentionally ignored for now by product requirement.
    if (kDebugMode) {
      debugPrint('DTMF ignored: ${event.digits}');
    }
  }

  void _onPushKitToken(CallKeepPushKitToken event) {
    final token = event.token;
    if (token == null || token.isEmpty || _pushKitTokenController.isClosed) {
      return;
    }
    _pushKitTokenController.add(token);
  }

  int _toCallKeepEndReason(String reason) {
    switch (reason.toLowerCase()) {
      case 'failed':
      case 'error':
        return 1; // CXCallEndedReasonFailed
      case 'remote_ended':
      case 'remote_end':
      case 'ended':
      case 'ended_by_system':
      case 'hangup':
        return 2; // CXCallEndedReasonRemoteEnded
      case 'unanswered':
      case 'missed':
      case 'timeout':
      case 'no_answer':
        return 3; // CXCallEndedReasonUnanswered
      case 'answered_elsewhere':
        return 4; // CXCallEndedReasonAnsweredElsewhere
      case 'declined_elsewhere':
        return 5; // CXCallEndedReasonDeclinedElsewhere
      case 'declined':
      case 'rejected':
        return 6; // Mapped to RemoteEnded in callkeep
      default:
        return 2;
    }
  }

  Future<void> dispose() async {
    await _callStateSubscription?.cancel();
    _callKeep.remove<CallKeepPerformAnswerCallAction>(_onAnswerCall);
    _callKeep.remove<CallKeepPerformEndCallAction>(_onEndCall);
    _callKeep.remove<CallKeepDidPerformSetMutedCallAction>(_onToggleMute);
    _callKeep.remove<CallKeepDidToggleHoldAction>(_onToggleHold);
    _callKeep.remove<CallKeepDidPerformDTMFAction>(_onDtmf);
    _callKeep.remove<CallKeepPushKitToken>(_onPushKitToken);
    await _pushKitTokenController.close();
  }
}
