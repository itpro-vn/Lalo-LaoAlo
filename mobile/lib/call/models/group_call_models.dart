import 'package:equatable/equatable.dart';

/// Event emitted when a group room is created.
class RoomCreatedEvent extends Equatable {
  /// Creates a [RoomCreatedEvent].
  const RoomCreatedEvent({
    required this.roomId,
    required this.liveKitToken,
    required this.liveKitUrl,
  });

  /// Room identifier.
  final String roomId;

  /// LiveKit access token for the current participant.
  final String liveKitToken;

  /// LiveKit websocket URL.
  final String liveKitUrl;

  /// Builds event from signaling/API payload.
  factory RoomCreatedEvent.fromJson(Map<String, dynamic> json) {
    return RoomCreatedEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      liveKitToken:
          (json['livekit_token'] ?? json['liveKitToken'] ?? '').toString(),
      liveKitUrl: (json['livekit_url'] ?? json['liveKitUrl'] ?? '').toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'livekit_token': liveKitToken,
      'livekit_url': liveKitUrl,
    };
  }

  @override
  List<Object?> get props => <Object?>[roomId, liveKitToken, liveKitUrl];
}

/// Event emitted when user receives a room invitation.
class RoomInvitationEvent extends Equatable {
  /// Creates a [RoomInvitationEvent].
  const RoomInvitationEvent({
    required this.roomId,
    required this.inviterId,
    required this.callType,
    required this.participants,
  });

  /// Room identifier.
  final String roomId;

  /// Inviter user ID.
  final String inviterId;

  /// Call media type (audio/video).
  final String callType;

  /// Participants in room/invitation context.
  final List<String> participants;

  /// Builds event from signaling payload.
  factory RoomInvitationEvent.fromJson(Map<String, dynamic> json) {
    final rawParticipants = json['participants'];
    final participants = rawParticipants is List
        ? rawParticipants.map((item) => item.toString()).toList(growable: false)
        : const <String>[];

    return RoomInvitationEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      inviterId: (json['inviter_id'] ?? json['inviterId'] ?? '').toString(),
      callType: (json['call_type'] ?? json['callType'] ?? '').toString(),
      participants: participants,
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'inviter_id': inviterId,
      'call_type': callType,
      'participants': participants,
    };
  }

  @override
  List<Object?> get props =>
      <Object?>[roomId, inviterId, callType, participants];
}

/// Event emitted when a group room is closed.
class RoomClosedEvent extends Equatable {
  /// Creates a [RoomClosedEvent].
  const RoomClosedEvent({
    required this.roomId,
    required this.reason,
  });

  /// Room identifier.
  final String roomId;

  /// Close reason sent by backend.
  final String reason;

  /// Builds event from signaling payload.
  factory RoomClosedEvent.fromJson(Map<String, dynamic> json) {
    return RoomClosedEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      reason: (json['reason'] ?? '').toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'reason': reason,
    };
  }

  @override
  List<Object?> get props => <Object?>[roomId, reason];
}

/// Event emitted when a participant joins or leaves a room.
class ParticipantEvent extends Equatable {
  /// Creates a [ParticipantEvent].
  const ParticipantEvent({
    required this.roomId,
    required this.userId,
    this.role,
  });

  /// Room identifier.
  final String roomId;

  /// Participant user ID.
  final String userId;

  /// Optional participant role.
  final String? role;

  /// Builds event from signaling payload.
  factory ParticipantEvent.fromJson(Map<String, dynamic> json) {
    final rawRole = json['role'];
    return ParticipantEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
      role: rawRole?.toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'user_id': userId,
      if (role != null && role!.isNotEmpty) 'role': role,
    };
  }

  @override
  List<Object?> get props => <Object?>[roomId, userId, role];
}

/// Event emitted when participant audio/video state changes.
class ParticipantMediaEvent extends Equatable {
  /// Creates a [ParticipantMediaEvent].
  const ParticipantMediaEvent({
    required this.roomId,
    required this.userId,
    required this.audio,
    required this.video,
  });

  /// Room identifier.
  final String roomId;

  /// Participant user ID.
  final String userId;

  /// Whether participant audio is enabled.
  final bool audio;

  /// Whether participant video is enabled.
  final bool video;

  /// Builds event from signaling payload.
  factory ParticipantMediaEvent.fromJson(Map<String, dynamic> json) {
    return ParticipantMediaEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
      audio: _readBool(json['audio']),
      video: _readBool(json['video']),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'user_id': userId,
      'audio': audio,
      'video': video,
    };
  }

  static bool _readBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }
    return false;
  }

  @override
  List<Object?> get props => <Object?>[roomId, userId, audio, video];
}

/// Event emitted when a simulcast layer update is received from the SFU.
///
/// This is sent by the server when a subscriber's received layer changes
/// (e.g., due to bandwidth-based switching or manual layer request).
class LayerUpdateEvent extends Equatable {
  /// Creates a [LayerUpdateEvent].
  const LayerUpdateEvent({
    required this.roomId,
    required this.trackSid,
    required this.layer,
    this.publisherId,
    this.reason,
  });

  /// Room identifier.
  final String roomId;

  /// Publisher's track SID that the layer change applies to.
  final String trackSid;

  /// Current active layer ('h', 'm', 'l').
  final String layer;

  /// Optional publisher user ID.
  final String? publisherId;

  /// Optional reason for the layer change (bandwidth, manual, speaker).
  final String? reason;

  /// Builds event from signaling payload.
  factory LayerUpdateEvent.fromJson(Map<String, dynamic> json) {
    return LayerUpdateEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      trackSid: (json['track_sid'] ?? json['trackSid'] ?? '').toString(),
      layer: (json['layer'] ?? '').toString(),
      publisherId: json['publisher_id']?.toString(),
      reason: json['reason']?.toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      'track_sid': trackSid,
      'layer': layer,
      if (publisherId != null && publisherId!.isNotEmpty)
        'publisher_id': publisherId,
      if (reason != null && reason!.isNotEmpty) 'reason': reason,
    };
  }

  @override
  List<Object?> get props =>
      <Object?>[roomId, trackSid, layer, publisherId, reason];
}

/// Event emitted when the server-side policy engine pushes an ABR override.
///
/// The policy engine evaluates room-wide quality metrics and may override
/// client-side ABR decisions (e.g., cap tier, force audio-only, force codec).
class PolicyUpdateEvent extends Equatable {
  /// Creates a [PolicyUpdateEvent].
  const PolicyUpdateEvent({
    required this.roomId,
    this.maxTier,
    this.forceAudioOnly,
    this.maxBitrateKbps,
    this.forceCodec,
    this.reason,
  });

  /// Room identifier.
  final String roomId;

  /// Maximum allowed quality tier ('good', 'fair', 'poor').
  final String? maxTier;

  /// Whether to force audio-only mode.
  final bool? forceAudioOnly;

  /// Maximum allowed bitrate in kbps.
  final int? maxBitrateKbps;

  /// Force a specific video codec ('vp8', 'h264').
  final String? forceCodec;

  /// Reason for the policy override.
  final String? reason;

  /// Builds event from signaling payload.
  factory PolicyUpdateEvent.fromJson(Map<String, dynamic> json) {
    return PolicyUpdateEvent(
      roomId: (json['room_id'] ?? json['roomId'] ?? '').toString(),
      maxTier: json['max_tier']?.toString(),
      forceAudioOnly: json['force_audio_only'] as bool?,
      maxBitrateKbps: json['max_bitrate_kbps'] as int?,
      forceCodec: json['force_codec']?.toString(),
      reason: json['reason']?.toString(),
    );
  }

  /// Converts event to JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'room_id': roomId,
      if (maxTier != null) 'max_tier': maxTier,
      if (forceAudioOnly != null) 'force_audio_only': forceAudioOnly,
      if (maxBitrateKbps != null) 'max_bitrate_kbps': maxBitrateKbps,
      if (forceCodec != null) 'force_codec': forceCodec,
      if (reason != null && reason!.isNotEmpty) 'reason': reason,
    };
  }

  @override
  List<Object?> get props => <Object?>[
        roomId,
        maxTier,
        forceAudioOnly,
        maxBitrateKbps,
        forceCodec,
        reason,
      ];
}
