import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/services/speaker_detector.dart';
import 'package:lalo/call/services/video_slot_controller.dart';

void main() {
  group('SpeakerDetector + VideoSlotController integration', () {
    const holdDuration = Duration(milliseconds: 5);
    const reassignIntervalMs = 10;

    SpeakerDetector createDetector() {
      return SpeakerDetector(holdDuration: holdDuration);
    }

    VideoSlotController createController(SpeakerDetector detector) {
      return VideoSlotController(
        speakerDetector: detector,
        reassignIntervalMs: reassignIntervalMs,
      );
    }

    Future<void> waitUntil(
      bool Function() condition, {
      Duration timeout = const Duration(milliseconds: 500),
      Duration step = const Duration(milliseconds: 5),
    }) async {
      final stopwatch = Stopwatch()..start();
      while (!condition()) {
        if (stopwatch.elapsed > timeout) {
          fail('Timed out waiting for integration condition');
        }
        await Future<void>.delayed(step);
      }
    }

    test('speaker detection -> assigns active speaker to HQ slot', () async {
      final detector = createDetector();
      final controller = createController(detector);
      addTearDown(detector.dispose);
      addTearDown(controller.dispose);

      controller.setParticipants(const <String>['alice', 'bob', 'charlie']);
      controller.start();

      detector.updateAudioLevel('bob', -10);
      detector.tick();

      await waitUntil(() {
        final slot = controller.assignment.findSlotForParticipant('bob');
        return slot != null && slot.quality == SlotQuality.hq;
      });

      final bobSlot = controller.assignment.findSlotForParticipant('bob');
      expect(bobSlot, isNotNull);
      expect(bobSlot!.quality, SlotQuality.hq);
      expect(bobSlot.index, anyOf(0, 1));
      expect(bobSlot.isSpeaking, isTrue);
    });

    test('pin participant overrides speaker logic and keeps pinned user in HQ',
        () async {
      final detector = createDetector();
      final controller = createController(detector);
      addTearDown(detector.dispose);
      addTearDown(controller.dispose);

      controller.setParticipants(const <String>['alice', 'bob', 'charlie']);
      controller.start();

      detector.updateAudioLevel('bob', -10);
      detector.tick();
      await waitUntil(() {
        final bobSlot = controller.assignment.findSlotForParticipant('bob');
        return bobSlot != null && bobSlot.quality == SlotQuality.hq;
      });

      controller.pin('alice');
      await waitUntil(() {
        final aliceSlot = controller.assignment.findSlotForParticipant('alice');
        return aliceSlot != null &&
            aliceSlot.quality == SlotQuality.hq &&
            aliceSlot.isPinned;
      });

      detector.updateAudioLevel('charlie', -8);
      detector.tick();

      await waitUntil(() {
        final charlieSlot =
            controller.assignment.findSlotForParticipant('charlie');
        return charlieSlot != null && charlieSlot.quality == SlotQuality.hq;
      });

      final aliceSlot = controller.assignment.findSlotForParticipant('alice');
      expect(aliceSlot, isNotNull);
      expect(aliceSlot!.quality, SlotQuality.hq);
      expect(aliceSlot.isPinned, isTrue);
    });

    test('rapid speaking pauses do not flicker before hold expires (hold gate)',
        () async {
      final detector = createDetector();
      final controller = createController(detector);
      addTearDown(detector.dispose);
      addTearDown(controller.dispose);

      final assignmentHistory = <VideoSlotAssignment>[];
      final sub = controller.onAssignmentChanged.listen(assignmentHistory.add);
      addTearDown(sub.cancel);

      controller.setParticipants(const <String>['bob', 'carol', 'alice']);
      controller.start();

      detector.updateAudioLevel('alice', -10);
      detector.tick();

      await waitUntil(() {
        final aliceSlot = controller.assignment.findSlotForParticipant('alice');
        return aliceSlot != null && aliceSlot.quality == SlotQuality.hq;
      });

      detector.updateAudioLevel('alice', -90); // silence, should still be held
      await Future<void>.delayed(const Duration(milliseconds: 2));
      detector.tick();

      final beforeExpirySlot =
          controller.assignment.findSlotForParticipant('alice');
      expect(beforeExpirySlot, isNotNull);
      expect(beforeExpirySlot!.quality, SlotQuality.hq);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      detector.tick();

      await waitUntil(() {
        final aliceSlot = controller.assignment.findSlotForParticipant('alice');
        return aliceSlot != null && aliceSlot.quality != SlotQuality.hq;
      });

      final afterExpirySlot =
          controller.assignment.findSlotForParticipant('alice');
      expect(afterExpirySlot, isNotNull);
      expect(afterExpirySlot!.quality, anyOf(SlotQuality.mq, SlotQuality.lq));

      expect(assignmentHistory, isNotEmpty);
    });

    test('4+ participants place overflow into LQ thumbnail strip', () async {
      final detector = createDetector();
      final controller = createController(detector);
      addTearDown(detector.dispose);
      addTearDown(controller.dispose);

      controller
          .setParticipants(const <String>['u1', 'u2', 'u3', 'u4', 'u5', 'u6']);
      controller.start();

      detector.updateAudioLevel('u5', -12);
      detector.tick();

      await waitUntil(() {
        final u5Slot = controller.assignment.findSlotForParticipant('u5');
        return u5Slot != null && u5Slot.quality == SlotQuality.hq;
      });

      final assignment = controller.assignment;
      expect(assignment.slots, hasLength(8));
      expect(
        assignment.activeSlots.where((slot) => slot.isOccupied),
        hasLength(4),
      );
      expect(
        assignment.thumbnailSlots.where((slot) => slot.isOccupied),
        hasLength(2),
      );
      expect(
        assignment.thumbnailSlots
            .where((slot) => slot.isOccupied)
            .every((slot) => slot.quality == SlotQuality.lq),
        isTrue,
      );

      expect(assignment.slots[4].isOccupied, isTrue);
      expect(assignment.slots[5].isOccupied, isTrue);
      expect(assignment.slots[4].quality, SlotQuality.lq);
      expect(assignment.slots[5].quality, SlotQuality.lq);
    });
  });
}
