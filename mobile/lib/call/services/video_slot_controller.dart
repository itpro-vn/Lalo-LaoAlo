import 'dart:async';

import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/services/speaker_detector.dart';

/// Manages video slot assignments for group calls.
///
/// Assigns participants to 8 video slots based on:
/// - Active speaker → HQ slot (index 0-1)
/// - Recent speakers → MQ slots (index 2-3)
/// - Pinned participant → HQ slot (overrides speaker logic)
/// - Remaining → LQ slots (index 4-7) or off
///
/// Usage:
/// ```dart
/// final controller = VideoSlotController(speakerDetector: detector);
/// controller.setParticipants(['user1', 'user2', ...]);
/// controller.onAssignmentChanged.listen((assignment) { ... });
/// ```
class VideoSlotController {
  /// Creates a [VideoSlotController].
  VideoSlotController({
    required SpeakerDetector speakerDetector,
    this.reassignIntervalMs = 500,
  }) : _speakerDetector = speakerDetector;

  final SpeakerDetector _speakerDetector;

  /// How often to re-evaluate slot assignments (ms).
  final int reassignIntervalMs;

  Timer? _reassignTimer;
  StreamSubscription<SpeakerEvent>? _speakerSubscription;

  /// Current slot assignment snapshot.
  VideoSlotAssignment _assignment = VideoSlotAssignment.empty();

  /// All known participant IDs in the room.
  List<String> _participantIds = <String>[];

  /// Stream of assignment changes.
  final StreamController<VideoSlotAssignment> _assignmentController =
      StreamController<VideoSlotAssignment>.broadcast();

  // -- Public API --

  /// Current assignment snapshot.
  VideoSlotAssignment get assignment => _assignment;

  /// Stream of assignment changes (emits after each reassignment).
  Stream<VideoSlotAssignment> get onAssignmentChanged =>
      _assignmentController.stream;

  /// Starts the slot controller.
  void start() {
    if (_reassignTimer != null) return;

    _speakerSubscription =
        _speakerDetector.onSpeakerEvent.listen((_) => _reassign());

    _reassignTimer = Timer.periodic(
      Duration(milliseconds: reassignIntervalMs),
      (_) => _reassign(),
    );
  }

  /// Stops the slot controller.
  void stop() {
    _reassignTimer?.cancel();
    _reassignTimer = null;
    _speakerSubscription?.cancel();
    _speakerSubscription = null;
  }

  /// Updates the participant list (call when participants join/leave).
  void setParticipants(List<String> participantIds) {
    _participantIds = List<String>.from(participantIds);
    _reassign();
  }

  /// Pins a participant to HQ slot 0.
  ///
  /// Pin is sticky until [unpin] is called.
  /// Pinned participant always gets HQ regardless of speaker state.
  void pin(String participantId) {
    _assignment = _assignment.withPin(participantId);
    _reassign();
  }

  /// Removes the current pin. Reverts to speaker-based assignment.
  void unpin() {
    _assignment = _assignment.withPin(null);
    _reassign();
  }

  /// Disposes resources.
  Future<void> dispose() async {
    stop();
    await _assignmentController.close();
  }

  // -- Internal --

  /// Core reassignment logic (pure, deterministic).
  ///
  /// Priority order:
  /// 1. Pinned participant → HQ slot 0
  /// 2. Active speaker → HQ slot (0 or 1)
  /// 3. Recent speakers → MQ slots (2-3)
  /// 4. Remaining → LQ slots (4-7)
  void _reassign() {
    final newAssignment = computeAssignment(
      participantIds: _participantIds,
      activeSpeaker: _speakerDetector.activeSpeaker,
      recentSpeakers: _speakerDetector.recentSpeakers,
      speakingParticipants: _speakerDetector.speakingParticipants,
      pinnedParticipantId: _assignment.pinnedParticipantId,
    );

    if (_assignmentChanged(newAssignment)) {
      _assignment = newAssignment;
      if (!_assignmentController.isClosed) {
        _assignmentController.add(_assignment);
      }
    }
  }

  /// Pure function: compute slot assignments from inputs.
  ///
  /// Exposed as static for testability.
  static VideoSlotAssignment computeAssignment({
    required List<String> participantIds,
    required String? activeSpeaker,
    required List<String> recentSpeakers,
    required Set<String> speakingParticipants,
    required String? pinnedParticipantId,
  }) {
    if (participantIds.isEmpty) return VideoSlotAssignment.empty();

    final assigned = <String>{};
    final slots = List<VideoSlot>.generate(8, (i) {
      final SlotQuality quality;
      if (i < 2) {
        quality = SlotQuality.hq;
      } else if (i < 4) {
        quality = SlotQuality.mq;
      } else {
        quality = SlotQuality.lq;
      }
      return VideoSlot(index: i, quality: quality);
    });

    // 1. Pinned participant → HQ slot 0
    if (pinnedParticipantId != null &&
        participantIds.contains(pinnedParticipantId)) {
      slots[0] = slots[0].copyWith(
        participantId: pinnedParticipantId,
        isPinned: true,
        isSpeaking: speakingParticipants.contains(pinnedParticipantId),
      );
      assigned.add(pinnedParticipantId);
    }

    // 2. Active speaker → first available HQ slot
    if (activeSpeaker != null &&
        !assigned.contains(activeSpeaker) &&
        participantIds.contains(activeSpeaker)) {
      final hqIndex = slots[0].isOccupied ? 1 : 0;
      if (hqIndex < 2) {
        slots[hqIndex] = slots[hqIndex].copyWith(
          participantId: activeSpeaker,
          isSpeaking: true,
        );
        assigned.add(activeSpeaker);
      }
    }

    // 3. Recent speakers → MQ slots (2-3), then remaining HQ
    for (final speakerId in recentSpeakers) {
      if (assigned.contains(speakerId)) continue;
      if (!participantIds.contains(speakerId)) continue;

      // Prefer MQ slots first (2-3), then fallback to HQ (0-1).
      int? targetIndex;
      for (int i = 2; i < 4; i++) {
        if (!slots[i].isOccupied) {
          targetIndex = i;
          break;
        }
      }

      targetIndex ??= () {
        for (int i = 0; i < 2; i++) {
          if (!slots[i].isOccupied) {
            return i;
          }
        }
        return null;
      }();

      if (targetIndex != null) {
        slots[targetIndex] = slots[targetIndex].copyWith(
          participantId: speakerId,
          isSpeaking: speakingParticipants.contains(speakerId),
        );
        assigned.add(speakerId);
      }
    }

    // 4. Remaining participants → fill remaining slots (HQ/MQ first, then LQ)
    for (final participantId in participantIds) {
      if (assigned.contains(participantId)) continue;

      int? targetIndex;
      for (int i = 0; i < 8; i++) {
        if (!slots[i].isOccupied) {
          targetIndex = i;
          break;
        }
      }

      if (targetIndex != null) {
        slots[targetIndex] = slots[targetIndex].copyWith(
          participantId: participantId,
          isSpeaking: speakingParticipants.contains(participantId),
        );
        assigned.add(participantId);
      }
    }

    return VideoSlotAssignment(
      slots: slots,
      pinnedParticipantId: pinnedParticipantId,
    );
  }

  /// Check if the assignment actually changed (avoid unnecessary rebuilds).
  bool _assignmentChanged(VideoSlotAssignment newAssignment) {
    if (_assignment.pinnedParticipantId != newAssignment.pinnedParticipantId) {
      return true;
    }
    for (int i = 0; i < 8; i++) {
      if (_assignment.slots[i] != newAssignment.slots[i]) return true;
    }
    return false;
  }
}
