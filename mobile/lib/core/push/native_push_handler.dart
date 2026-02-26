import 'dart:async';
import 'package:flutter/services.dart';

/// Native platform channel handler for VoIP push notifications.
///
/// Bridges iOS PushKit / Android FCM native callbacks to Flutter.
/// Handles deduplication of push+WebSocket incoming calls by call_id.
class NativePushHandler {
  static const _channel = MethodChannel('com.lalo.call/push');

  final _incomingCallController =
      StreamController<IncomingCallPushData>.broadcast();
  final _tokenController = StreamController<VoIPTokenData>.broadcast();
  final _pendingCalls = <String, DateTime>{};

  static const _deduplicationWindowMs = 5000;

  Stream<IncomingCallPushData> get onIncomingCall =>
      _incomingCallController.stream;
  Stream<VoIPTokenData> get onVoIPToken => _tokenController.stream;

  NativePushHandler() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onIncomingCall':
        final data = Map<String, dynamic>.from(call.arguments as Map);
        _handleIncomingCall(data);
      case 'onVoIPToken':
        final token = call.arguments as String;
        _tokenController.add(VoIPTokenData(token: token));
      case 'onCallCancelled':
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final callId = data['call_id'] as String?;
        if (callId != null) {
          _pendingCalls.remove(callId);
        }
    }
  }

  void _handleIncomingCall(Map<String, dynamic> data) {
    final callId = data['call_id'] as String?;
    if (callId == null) return;

    // Dedup: if we've already seen this call_id within the window, skip.
    final existing = _pendingCalls[callId];
    if (existing != null) {
      final elapsed =
          DateTime.now().difference(existing).inMilliseconds;
      if (elapsed < _deduplicationWindowMs) {
        return; // Duplicate — already handled via push or WSS
      }
    }

    _pendingCalls[callId] = DateTime.now();

    // Clean up old entries
    _cleanupPendingCalls();

    _incomingCallController.add(
      IncomingCallPushData(
        callId: callId,
        callerName: data['caller_name'] as String? ?? 'Unknown',
        callerId: data['caller_id'] as String? ?? '',
        hasVideo: data['has_video'] as bool? ?? false,
      ),
    );
  }

  /// Check if a call_id has already been reported via push.
  /// Used by WebSocket signaling to dedup incoming_call messages.
  bool isCallAlreadyReported(String callId) {
    final existing = _pendingCalls[callId];
    if (existing == null) return false;
    final elapsed = DateTime.now().difference(existing).inMilliseconds;
    return elapsed < _deduplicationWindowMs;
  }

  /// Mark a call as reported (from WebSocket signaling side).
  void markCallReported(String callId) {
    _pendingCalls[callId] = DateTime.now();
  }

  void _cleanupPendingCalls() {
    final now = DateTime.now();
    _pendingCalls.removeWhere((_, time) {
      return now.difference(time).inMilliseconds > _deduplicationWindowMs * 2;
    });
  }

  void dispose() {
    _incomingCallController.close();
    _tokenController.close();
    _pendingCalls.clear();
    _channel.setMethodCallHandler(null);
  }
}

/// Push notification data for an incoming call.
class IncomingCallPushData {
  final String callId;
  final String callerName;
  final String callerId;
  final bool hasVideo;

  const IncomingCallPushData({
    required this.callId,
    required this.callerName,
    required this.callerId,
    required this.hasVideo,
  });
}

/// VoIP push token data.
class VoIPTokenData {
  final String token;

  const VoIPTokenData({required this.token});
}
