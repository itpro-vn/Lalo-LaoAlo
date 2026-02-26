import 'package:equatable/equatable.dart';

/// Event emitted when a glare condition is detected.
///
/// Glare occurs when two users simultaneously call each other.
/// The server resolves this by picking a winner (lower user ID)
/// and cancelling the loser's call.
class CallGlareEvent extends Equatable {
  /// Creates a [CallGlareEvent].
  const CallGlareEvent({
    required this.cancelledCallId,
    required this.winningCallId,
    required this.winnerUserId,
  });

  /// The call ID that was cancelled (the loser's outgoing call).
  final String cancelledCallId;

  /// The call ID that won (the winner's outgoing call).
  final String winningCallId;

  /// The user ID whose call won the glare resolution.
  final String winnerUserId;

  /// Builds event from signaling payload.
  factory CallGlareEvent.fromJson(Map<String, dynamic> json) {
    return CallGlareEvent(
      cancelledCallId:
          (json['cancelled_call_id'] ?? json['cancelledCallId'] ?? '')
              .toString(),
      winningCallId:
          (json['winning_call_id'] ?? json['winningCallId'] ?? '').toString(),
      winnerUserId:
          (json['winner_user_id'] ?? json['winnerUserId'] ?? '').toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cancelled_call_id': cancelledCallId,
      'winning_call_id': winningCallId,
      'winner_user_id': winnerUserId,
    };
  }

  @override
  List<Object?> get props => [cancelledCallId, winningCallId, winnerUserId];
}

/// Event emitted when a call is accepted on another device.
///
/// In multi-device scenarios, when a user accepts an incoming call
/// on one device, all other devices receive this event to dismiss
/// their ringing UI.
class CallAcceptedElsewhereEvent extends Equatable {
  /// Creates a [CallAcceptedElsewhereEvent].
  const CallAcceptedElsewhereEvent({
    required this.callId,
    required this.acceptedByDeviceId,
  });

  /// The call ID that was accepted.
  final String callId;

  /// The device ID that accepted the call.
  final String acceptedByDeviceId;

  /// Builds event from signaling payload.
  factory CallAcceptedElsewhereEvent.fromJson(Map<String, dynamic> json) {
    return CallAcceptedElsewhereEvent(
      callId: (json['call_id'] ?? json['callId'] ?? '').toString(),
      acceptedByDeviceId:
          (json['accepted_by_device_id'] ?? json['acceptedByDeviceId'] ?? '')
              .toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'call_id': callId,
      'accepted_by_device_id': acceptedByDeviceId,
    };
  }

  @override
  List<Object?> get props => [callId, acceptedByDeviceId];
}

/// A single call in the state sync payload.
class StateSyncCall extends Equatable {
  /// Creates a [StateSyncCall].
  const StateSyncCall({
    required this.callId,
    required this.callerId,
    required this.calleeId,
    required this.state,
    required this.hasVideo,
    required this.createdAt,
  });

  /// Call session identifier.
  final String callId;

  /// Caller user identifier.
  final String callerId;

  /// Callee user identifier.
  final String calleeId;

  /// Current call state (e.g. "ringing", "active").
  final String state;

  /// Whether call includes video.
  final bool hasVideo;

  /// Epoch milliseconds when call was created.
  final int createdAt;

  /// Builds from signaling payload.
  factory StateSyncCall.fromJson(Map<String, dynamic> json) {
    return StateSyncCall(
      callId: (json['call_id'] ?? json['callId'] ?? '').toString(),
      callerId: (json['caller_id'] ?? json['callerId'] ?? '').toString(),
      calleeId: (json['callee_id'] ?? json['calleeId'] ?? '').toString(),
      state: (json['state'] ?? '').toString(),
      hasVideo: json['has_video'] as bool? ?? false,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  /// Converts to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'call_id': callId,
      'caller_id': callerId,
      'callee_id': calleeId,
      'state': state,
      'has_video': hasVideo,
      'created_at': createdAt,
    };
  }

  @override
  List<Object?> get props =>
      [callId, callerId, calleeId, state, hasVideo, createdAt];
}

/// Event emitted on reconnect containing active call state.
///
/// The server sends this immediately after a client connects,
/// allowing the client to restore any in-progress calls.
class StateSyncEvent extends Equatable {
  /// Creates a [StateSyncEvent].
  const StateSyncEvent({required this.activeCalls});

  /// List of active calls the user is part of.
  final List<StateSyncCall> activeCalls;

  /// Builds event from signaling payload.
  factory StateSyncEvent.fromJson(Map<String, dynamic> json) {
    final rawCalls = json['active_calls'] ?? json['activeCalls'];
    final List<StateSyncCall> calls;
    if (rawCalls is List) {
      calls = rawCalls
          .whereType<Map<String, dynamic>>()
          .map(StateSyncCall.fromJson)
          .toList();
    } else {
      calls = const [];
    }
    return StateSyncEvent(activeCalls: calls);
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'active_calls': activeCalls.map((c) => c.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [activeCalls];
}
