import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/services/speaker_detector.dart';

void main() {
  group('SpeakerDetector', () {
    test('no speaker initially (activeSpeaker is null)', () {
      final detector = SpeakerDetector();

      expect(detector.activeSpeaker, isNull);
      expect(detector.speakingParticipants, isEmpty);
      expect(detector.recentSpeakers, isEmpty);
    });

    test('audio level above threshold makes participant active speaker', () {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);

      expect(detector.activeSpeaker, 'alice');
      expect(detector.isSpeaking('alice'), isTrue);
      expect(detector.speakingParticipants, contains('alice'));
    });

    test('audio level below threshold keeps participant speaking during hold', () {
      final detector = SpeakerDetector(holdDuration: const Duration(seconds: 1));

      detector.updateAudioLevel('alice', -20);
      detector.updateAudioLevel('alice', -80);

      expect(detector.isSpeaking('alice'), isTrue);
      expect(detector.activeSpeaker, 'alice');
    });

    test('hold timer expiration after tick removes speaking state', () async {
      final detector = SpeakerDetector(holdDuration: const Duration(milliseconds: 10));

      detector.updateAudioLevel('alice', -20);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      detector.tick();

      expect(detector.isSpeaking('alice'), isFalse);
      expect(detector.activeSpeaker, isNull);
      expect(detector.speakingParticipants, isEmpty);
    });

    test('recent speakers list keeps most recent first', () async {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      detector.updateAudioLevel('bob', -20);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      detector.updateAudioLevel('charlie', -20);

      expect(detector.recentSpeakers, <String>['charlie', 'bob', 'alice']);
    });

    test('recent speakers list enforces max cap', () {
      final detector = SpeakerDetector(maxRecentSpeakers: 2);

      detector.updateAudioLevel('alice', -20);
      detector.updateAudioLevel('bob', -20);
      detector.updateAudioLevel('charlie', -20);

      expect(detector.recentSpeakers, <String>['charlie', 'bob']);
      expect(detector.recentSpeakers, isNot(contains('alice')));
    });

    test('setActiveSpeaker updates both activeSpeaker and recentSpeakers', () {
      final detector = SpeakerDetector();

      detector.setActiveSpeaker('alice');

      expect(detector.activeSpeaker, 'alice');
      expect(detector.recentSpeakers, <String>['alice']);
      expect(detector.isSpeaking('alice'), isTrue);
    });

    test('removeParticipant clears participant from all state', () {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);
      detector.removeParticipant('alice');

      expect(detector.isSpeaking('alice'), isFalse);
      expect(detector.activeSpeaker, isNull);
      expect(detector.speakingParticipants, isNot(contains('alice')));
      expect(detector.recentSpeakers, isNot(contains('alice')));
    });

    test('reset clears speaking state, active speaker, and recent speakers', () {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);
      detector.updateAudioLevel('bob', -20);
      detector.reset();

      expect(detector.activeSpeaker, isNull);
      expect(detector.speakingParticipants, isEmpty);
      expect(detector.recentSpeakers, isEmpty);
      expect(detector.isSpeaking('alice'), isFalse);
      expect(detector.isSpeaking('bob'), isFalse);
    });

    test('emits speaker events on start and stop', () async {
      final detector = SpeakerDetector(holdDuration: const Duration(milliseconds: 5));
      final events = <SpeakerEvent>[];
      final sub = detector.onSpeakerEvent.listen(events.add);
      addTearDown(sub.cancel);

      detector.updateAudioLevel('alice', -20); // start
      await Future<void>.delayed(const Duration(milliseconds: 40));
      detector.tick(); // stop
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(events.length, 2);
      expect(events[0].participantId, 'alice');
      expect(events[0].isSpeaking, isTrue);
      expect(events[1].participantId, 'alice');
      expect(events[1].isSpeaking, isFalse);
    });

    test('multiple speakers: most recent started is activeSpeaker', () async {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      detector.updateAudioLevel('bob', -20);

      expect(detector.isSpeaking('alice'), isTrue);
      expect(detector.isSpeaking('bob'), isTrue);
      expect(detector.activeSpeaker, 'bob');
    });

    test('repeated loud updates for same participant do not duplicate recent list', () {
      final detector = SpeakerDetector();

      detector.updateAudioLevel('alice', -20);
      detector.updateAudioLevel('alice', -10);
      detector.updateAudioLevel('alice', -5);

      expect(detector.recentSpeakers, <String>['alice']);
    });

    test('does not emit start event when update stays below threshold', () async {
      final detector = SpeakerDetector();
      final events = <SpeakerEvent>[];
      final sub = detector.onSpeakerEvent.listen(events.add);
      addTearDown(sub.cancel);

      detector.updateAudioLevel('alice', -80);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(events, isEmpty);
      expect(detector.activeSpeaker, isNull);
      expect(detector.isSpeaking('alice'), isFalse);
    });
  });
}
