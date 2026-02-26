import 'package:equatable/equatable.dart';

import 'call_state.dart';

/// Type of call session.
enum CallType { oneToOne, group }

/// Media topology used for call routing.
enum CallTopology { peerToPeer, sfu, mcu }

/// Participant role in a call.
enum ParticipantRole { caller, callee, host, guest }

/// Participant model in an active or historical call.
class CallParticipant extends Equatable {
  /// Creates a [CallParticipant].
  const CallParticipant({
    required this.userId,
    required this.role,
    this.audioEnabled = true,
    this.videoEnabled = false,
    required this.joinedAt,
  });

  /// User identifier.
  final String userId;

  /// Participant role.
  final ParticipantRole role;

  /// Whether microphone is currently enabled.
  final bool audioEnabled;

  /// Whether camera is currently enabled.
  final bool videoEnabled;

  /// Time participant joined the call.
  final DateTime joinedAt;

  /// Returns a new instance with selected fields changed.
  CallParticipant copyWith({
    String? userId,
    ParticipantRole? role,
    bool? audioEnabled,
    bool? videoEnabled,
    DateTime? joinedAt,
  }) {
    return CallParticipant(
      userId: userId ?? this.userId,
      role: role ?? this.role,
      audioEnabled: audioEnabled ?? this.audioEnabled,
      videoEnabled: videoEnabled ?? this.videoEnabled,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }

  @override
  List<Object?> get props => [
    userId,
    role,
    audioEnabled,
    videoEnabled,
    joinedAt,
  ];
}

/// Aggregate model representing a call session lifecycle.
class CallSession extends Equatable {
  /// Creates a [CallSession].
  const CallSession({
    required this.callId,
    required this.callerId,
    required this.calleeId,
    required this.callType,
    required this.state,
    required this.topology,
    this.hasVideo = false,
    required this.createdAt,
    this.answeredAt,
    this.endedAt,
    this.endReason,
    this.localSdp,
    this.remoteSdp,
    this.participants = const [],
  });

  /// Call identifier.
  final String callId;

  /// Caller user identifier.
  final String callerId;

  /// Primary callee user identifier.
  final String calleeId;

  /// One-to-one or group call.
  final CallType callType;

  /// Current lifecycle state.
  final CallState state;

  /// Signaling/media topology.
  final CallTopology topology;

  /// Whether call includes video.
  final bool hasVideo;

  /// Session creation timestamp.
  final DateTime createdAt;

  /// Time call was answered.
  final DateTime? answeredAt;

  /// Time call ended.
  final DateTime? endedAt;

  /// Optional reason for ending.
  final String? endReason;

  /// Local SDP offer/answer.
  final String? localSdp;

  /// Remote SDP offer/answer.
  final String? remoteSdp;

  /// Current session participants.
  final List<CallParticipant> participants;

  /// Returns call duration from [answeredAt] until [endedAt] or now.
  ///
  /// Returns [Duration.zero] when call has not been answered.
  Duration get duration {
    final answered = answeredAt;
    if (answered == null) {
      return Duration.zero;
    }

    final end = endedAt ?? DateTime.now().toUtc();
    if (end.isBefore(answered)) {
      return Duration.zero;
    }

    return end.difference(answered);
  }

  /// Returns a new instance with selected fields changed.
  CallSession copyWith({
    String? callId,
    String? callerId,
    String? calleeId,
    CallType? callType,
    CallState? state,
    CallTopology? topology,
    bool? hasVideo,
    DateTime? createdAt,
    DateTime? answeredAt,
    bool clearAnsweredAt = false,
    DateTime? endedAt,
    bool clearEndedAt = false,
    String? endReason,
    bool clearEndReason = false,
    String? localSdp,
    bool clearLocalSdp = false,
    String? remoteSdp,
    bool clearRemoteSdp = false,
    List<CallParticipant>? participants,
  }) {
    return CallSession(
      callId: callId ?? this.callId,
      callerId: callerId ?? this.callerId,
      calleeId: calleeId ?? this.calleeId,
      callType: callType ?? this.callType,
      state: state ?? this.state,
      topology: topology ?? this.topology,
      hasVideo: hasVideo ?? this.hasVideo,
      createdAt: createdAt ?? this.createdAt,
      answeredAt: clearAnsweredAt ? null : (answeredAt ?? this.answeredAt),
      endedAt: clearEndedAt ? null : (endedAt ?? this.endedAt),
      endReason: clearEndReason ? null : (endReason ?? this.endReason),
      localSdp: clearLocalSdp ? null : (localSdp ?? this.localSdp),
      remoteSdp: clearRemoteSdp ? null : (remoteSdp ?? this.remoteSdp),
      participants: participants ?? this.participants,
    );
  }

  @override
  List<Object?> get props => [
    callId,
    callerId,
    calleeId,
    callType,
    state,
    topology,
    hasVideo,
    createdAt,
    answeredAt,
    endedAt,
    endReason,
    localSdp,
    remoteSdp,
    participants,
  ];
}
