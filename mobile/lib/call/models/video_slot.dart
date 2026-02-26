import 'package:lalo/call/webrtc/simulcast_config.dart';

/// Quality tier for a video slot — determines which simulcast layer to subscribe.
enum SlotQuality {
  /// 720p/30fps — high simulcast layer (rid="h").
  hq,

  /// 360p/20fps — medium simulcast layer (rid="m").
  mq,

  /// 180p/10fps — low simulcast layer (rid="l").
  lq,

  /// No video — audio only, show avatar.
  off,
}

/// Extension helpers for [SlotQuality].
extension SlotQualityExt on SlotQuality {
  /// Maps this slot quality to the corresponding simulcast layer.
  /// Returns `null` for [SlotQuality.off] (no video).
  SimulcastLayer? get simulcastLayer {
    switch (this) {
      case SlotQuality.hq:
        return SimulcastLayer.high;
      case SlotQuality.mq:
        return SimulcastLayer.medium;
      case SlotQuality.lq:
        return SimulcastLayer.low;
      case SlotQuality.off:
        return null;
    }
  }
}

/// A single video display slot in the group call grid.
class VideoSlot {
  /// Creates a [VideoSlot].
  const VideoSlot({
    required this.index,
    required this.quality,
    this.participantId,
    this.trackSid,
    this.isPinned = false,
    this.isSpeaking = false,
  });

  /// Slot index (0-based). Slots 0-1 = HQ, 2-3 = MQ, 4-7 = LQ.
  final int index;

  /// Video quality tier for this slot.
  final SlotQuality quality;

  /// Participant occupying this slot (null = empty).
  final String? participantId;

  /// Track SID for simulcast layer requests (null = not subscribed).
  final String? trackSid;

  /// Whether user has pinned a participant to this slot.
  final bool isPinned;

  /// Whether the participant is currently speaking.
  final bool isSpeaking;

  /// Whether this slot has a participant assigned.
  bool get isOccupied => participantId != null;

  /// Whether this slot has video (not off).
  bool get hasVideo => quality != SlotQuality.off && isOccupied;

  /// Creates a copy with the given fields replaced.
  VideoSlot copyWith({
    int? index,
    SlotQuality? quality,
    String? participantId,
    String? trackSid,
    bool? isPinned,
    bool? isSpeaking,
    bool clearParticipant = false,
    bool clearTrackSid = false,
  }) {
    return VideoSlot(
      index: index ?? this.index,
      quality: quality ?? this.quality,
      participantId:
          clearParticipant ? null : (participantId ?? this.participantId),
      trackSid: clearTrackSid ? null : (trackSid ?? this.trackSid),
      isPinned: isPinned ?? this.isPinned,
      isSpeaking: isSpeaking ?? this.isSpeaking,
    );
  }

  @override
  String toString() =>
      'VideoSlot($index, ${quality.name}, pid=$participantId, '
      'pin=$isPinned, speaking=$isSpeaking)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoSlot &&
          index == other.index &&
          quality == other.quality &&
          participantId == other.participantId &&
          trackSid == other.trackSid &&
          isPinned == other.isPinned &&
          isSpeaking == other.isSpeaking;

  @override
  int get hashCode => Object.hash(
        index,
        quality,
        participantId,
        trackSid,
        isPinned,
        isSpeaking,
      );
}

/// Immutable snapshot of all video slot assignments.
class VideoSlotAssignment {
  /// Creates a [VideoSlotAssignment] with default 8 slots.
  const VideoSlotAssignment({
    required this.slots,
    required this.pinnedParticipantId,
  });

  /// Creates the initial 8-slot assignment with no participants.
  factory VideoSlotAssignment.empty() {
    return VideoSlotAssignment(
      slots: List<VideoSlot>.generate(8, (i) {
        final SlotQuality quality;
        if (i < 2) {
          quality = SlotQuality.hq;
        } else if (i < 4) {
          quality = SlotQuality.mq;
        } else {
          quality = SlotQuality.lq;
        }
        return VideoSlot(index: i, quality: quality);
      }),
      pinnedParticipantId: null,
    );
  }

  /// All 8 video slots.
  final List<VideoSlot> slots;

  /// Currently pinned participant (null = no pin, speaker-based assignment).
  final String? pinnedParticipantId;

  /// HQ slots (indices 0-1).
  List<VideoSlot> get hqSlots => slots.sublist(0, 2);

  /// MQ slots (indices 2-3).
  List<VideoSlot> get mqSlots => slots.sublist(2, 4);

  /// LQ slots (indices 4-7).
  List<VideoSlot> get lqSlots => slots.sublist(4);

  /// Active slots (HQ + MQ, the 2×2 grid).
  List<VideoSlot> get activeSlots => slots.sublist(0, 4);

  /// Thumbnail slots (LQ, bottom strip).
  List<VideoSlot> get thumbnailSlots => slots.sublist(4);

  /// All occupied participant IDs.
  Set<String> get occupiedParticipantIds => slots
      .where((s) => s.participantId != null)
      .map((s) => s.participantId!)
      .toSet();

  /// Finds which slot a participant is in (null = not assigned).
  VideoSlot? findSlotForParticipant(String participantId) {
    for (final slot in slots) {
      if (slot.participantId == participantId) return slot;
    }
    return null;
  }

  /// Creates a copy with the given slot replaced.
  VideoSlotAssignment replaceSlot(int index, VideoSlot slot) {
    final newSlots = List<VideoSlot>.from(slots);
    newSlots[index] = slot;
    return VideoSlotAssignment(
      slots: newSlots,
      pinnedParticipantId: pinnedParticipantId,
    );
  }

  /// Creates a copy with the pinned participant changed.
  VideoSlotAssignment withPin(String? participantId) {
    return VideoSlotAssignment(
      slots: slots,
      pinnedParticipantId: participantId,
    );
  }
}
