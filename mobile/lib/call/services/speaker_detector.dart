import 'dart:async';

/// Tracks speaker activity for group call participants.
///
/// Uses audio level monitoring to detect who is speaking.
/// Implements a "hold" mechanism: a participant is considered speaking
/// for [holdDuration] after they actually stop (to prevent flicker).
class SpeakerDetector {
  /// Creates a [SpeakerDetector].
  SpeakerDetector({
    this.speakingThresholdDb = -40.0,
    this.holdDuration = const Duration(seconds: 3),
    this.maxRecentSpeakers = 4,
  });

  /// Audio level below this threshold (in dB) is considered silence.
  /// Default: -40 dB (matching Spec §5.4).
  final double speakingThresholdDb;

  /// How long a participant is kept in "speaking" state after going silent.
  /// Default: 3 seconds (prevents slot flickering).
  final Duration holdDuration;

  /// Maximum number of recent speakers to track.
  final int maxRecentSpeakers;

  /// Currently speaking participants (includes held).
  final Map<String, DateTime> _speakingUntil = <String, DateTime>{};

  /// Ordered list of recent speakers (most recent first).
  /// Used for MQ slot assignment.
  final List<String> _recentSpeakers = <String>[];

  /// Stream of active speaker changes.
  final StreamController<SpeakerEvent> _eventController =
      StreamController<SpeakerEvent>.broadcast();

  // -- Public API --

  /// Stream of speaker events (started/stopped speaking).
  Stream<SpeakerEvent> get onSpeakerEvent => _eventController.stream;

  /// The current active speaker (most recently started speaking).
  /// Returns null if nobody is speaking.
  String? get activeSpeaker {
    final now = DateTime.now();
    // Find the most recently active speaker
    String? mostRecent;
    DateTime? mostRecentTime;
    for (final entry in _speakingUntil.entries) {
      if (entry.value.isAfter(now)) {
        if (mostRecentTime == null || entry.value.isAfter(mostRecentTime)) {
          mostRecent = entry.key;
          mostRecentTime = entry.value;
        }
      }
    }
    return mostRecent;
  }

  /// Whether a specific participant is currently speaking (or held).
  bool isSpeaking(String participantId) {
    final until = _speakingUntil[participantId];
    if (until == null) return false;
    return until.isAfter(DateTime.now());
  }

  /// Recent speakers ordered by recency (most recent first).
  /// Excludes the current active speaker.
  List<String> get recentSpeakers =>
      List<String>.unmodifiable(_recentSpeakers);

  /// All participants currently considered speaking (including held).
  Set<String> get speakingParticipants {
    final now = DateTime.now();
    return _speakingUntil.entries
        .where((e) => e.value.isAfter(now))
        .map((e) => e.key)
        .toSet();
  }

  // -- Audio Level Updates --

  /// Updates the audio level for a participant.
  ///
  /// Call this periodically (e.g., every stats poll interval).
  /// [audioLevelDb] is the audio level in dB (typically -100 to 0).
  void updateAudioLevel(String participantId, double audioLevelDb) {
    final wasSpeaking = isSpeaking(participantId);
    final nowSpeaking = audioLevelDb > speakingThresholdDb;

    if (nowSpeaking) {
      // Extend the hold timer
      _speakingUntil[participantId] =
          DateTime.now().add(holdDuration);

      // Update recent speakers list
      _recentSpeakers.remove(participantId);
      _recentSpeakers.insert(0, participantId);
      if (_recentSpeakers.length > maxRecentSpeakers) {
        _recentSpeakers.removeLast();
      }

      if (!wasSpeaking && !_eventController.isClosed) {
        _eventController.add(
          SpeakerEvent(
            participantId: participantId,
            isSpeaking: true,
          ),
        );
      }
    }
    // Note: we don't immediately mark as not-speaking.
    // The hold timer handles that via isSpeaking() checks.
  }

  /// Explicitly marks a participant as the active speaker.
  ///
  /// Used when receiving server-side speaker events (e.g., LiveKit
  /// active speaker notifications).
  void setActiveSpeaker(String participantId) {
    _speakingUntil[participantId] =
        DateTime.now().add(holdDuration);

    _recentSpeakers.remove(participantId);
    _recentSpeakers.insert(0, participantId);
    if (_recentSpeakers.length > maxRecentSpeakers) {
      _recentSpeakers.removeLast();
    }

    if (!_eventController.isClosed) {
      _eventController.add(
        SpeakerEvent(
          participantId: participantId,
          isSpeaking: true,
        ),
      );
    }
  }

  /// Removes a participant (e.g., when they leave the room).
  void removeParticipant(String participantId) {
    _speakingUntil.remove(participantId);
    _recentSpeakers.remove(participantId);
  }

  /// Checks and emits events for participants whose hold timers expired.
  ///
  /// Call this periodically (e.g., every 500ms) to detect when
  /// participants stop speaking after hold expires.
  void tick() {
    final now = DateTime.now();
    final expired = <String>[];

    for (final entry in _speakingUntil.entries) {
      if (entry.value.isBefore(now)) {
        expired.add(entry.key);
      }
    }

    for (final id in expired) {
      _speakingUntil.remove(id);
      if (!_eventController.isClosed) {
        _eventController.add(
          SpeakerEvent(
            participantId: id,
            isSpeaking: false,
          ),
        );
      }
    }
  }

  /// Resets all state.
  void reset() {
    _speakingUntil.clear();
    _recentSpeakers.clear();
  }

  /// Disposes resources.
  Future<void> dispose() async {
    reset();
    await _eventController.close();
  }
}

/// Event emitted when a participant's speaking state changes.
class SpeakerEvent {
  /// Creates a [SpeakerEvent].
  const SpeakerEvent({
    required this.participantId,
    required this.isSpeaking,
  });

  /// The participant whose state changed.
  final String participantId;

  /// Whether they started (true) or stopped (false) speaking.
  final bool isSpeaking;

  @override
  String toString() =>
      'SpeakerEvent($participantId, speaking=$isSpeaking)';
}
