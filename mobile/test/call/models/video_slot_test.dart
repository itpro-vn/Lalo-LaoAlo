import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';

void main() {
  group('SlotQualityExt', () {
    test('hq maps to SimulcastLayer.high', () {
      expect(SlotQuality.hq.simulcastLayer, SimulcastLayer.high);
    });

    test('mq maps to SimulcastLayer.medium', () {
      expect(SlotQuality.mq.simulcastLayer, SimulcastLayer.medium);
    });

    test('lq maps to SimulcastLayer.low', () {
      expect(SlotQuality.lq.simulcastLayer, SimulcastLayer.low);
    });

    test('off maps to null', () {
      expect(SlotQuality.off.simulcastLayer, isNull);
    });
  });

  group('VideoSlot', () {
    test('constructs with required fields and default flags', () {
      const slot = VideoSlot(index: 3, quality: SlotQuality.mq);

      expect(slot.index, 3);
      expect(slot.quality, SlotQuality.mq);
      expect(slot.participantId, isNull);
      expect(slot.trackSid, isNull);
      expect(slot.isPinned, isFalse);
      expect(slot.isSpeaking, isFalse);
    });

    test('isOccupied is true when participantId is present', () {
      const slot = VideoSlot(
        index: 0,
        quality: SlotQuality.hq,
        participantId: 'p1',
      );

      expect(slot.isOccupied, isTrue);
    });

    test('hasVideo is false when quality is off even if occupied', () {
      const slot = VideoSlot(
        index: 4,
        quality: SlotQuality.off,
        participantId: 'p1',
      );

      expect(slot.hasVideo, isFalse);
    });

    test('hasVideo is false when unoccupied even if quality is not off', () {
      const slot = VideoSlot(index: 1, quality: SlotQuality.hq);

      expect(slot.hasVideo, isFalse);
    });

    test('hasVideo is true when occupied and quality is not off', () {
      const slot = VideoSlot(
        index: 1,
        quality: SlotQuality.hq,
        participantId: 'p1',
      );

      expect(slot.hasVideo, isTrue);
    });

    test('equality and hashCode compare all fields', () {
      const a = VideoSlot(
        index: 2,
        quality: SlotQuality.mq,
        participantId: 'p1',
        trackSid: 't1',
        isPinned: true,
        isSpeaking: true,
      );
      const b = VideoSlot(
        index: 2,
        quality: SlotQuality.mq,
        participantId: 'p1',
        trackSid: 't1',
        isPinned: true,
        isSpeaking: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith updates only provided fields', () {
      const slot = VideoSlot(
        index: 2,
        quality: SlotQuality.mq,
        participantId: 'p1',
        trackSid: 't1',
        isPinned: false,
        isSpeaking: false,
      );

      final updated = slot.copyWith(quality: SlotQuality.hq, isSpeaking: true);

      expect(updated.index, 2);
      expect(updated.quality, SlotQuality.hq);
      expect(updated.participantId, 'p1');
      expect(updated.trackSid, 't1');
      expect(updated.isPinned, isFalse);
      expect(updated.isSpeaking, isTrue);
    });

    test('copyWith clearParticipant removes participantId', () {
      const slot = VideoSlot(
        index: 0,
        quality: SlotQuality.hq,
        participantId: 'p1',
      );

      final updated = slot.copyWith(clearParticipant: true);

      expect(updated.participantId, isNull);
      expect(updated.isOccupied, isFalse);
    });

    test('copyWith clearTrackSid removes trackSid', () {
      const slot = VideoSlot(
        index: 0,
        quality: SlotQuality.hq,
        participantId: 'p1',
        trackSid: 't1',
      );

      final updated = slot.copyWith(clearTrackSid: true);

      expect(updated.trackSid, isNull);
    });

    test('clear flags take precedence over provided values', () {
      const slot = VideoSlot(
        index: 0,
        quality: SlotQuality.hq,
        participantId: 'old',
        trackSid: 'oldTrack',
      );

      final updated = slot.copyWith(
        participantId: 'new',
        trackSid: 'newTrack',
        clearParticipant: true,
        clearTrackSid: true,
      );

      expect(updated.participantId, isNull);
      expect(updated.trackSid, isNull);
    });
  });

  group('VideoSlotAssignment', () {
    test('empty creates 8 slots and no pin', () {
      final assignment = VideoSlotAssignment.empty();

      expect(assignment.slots.length, 8);
      expect(assignment.pinnedParticipantId, isNull);
    });

    test('empty slots have indices 0 through 7', () {
      final assignment = VideoSlotAssignment.empty();

      expect(
        assignment.slots.map((s) => s.index).toList(),
        equals(List<int>.generate(8, (i) => i)),
      );
    });

    test('empty quality distribution is 0-1 HQ, 2-3 MQ, 4-7 LQ', () {
      final assignment = VideoSlotAssignment.empty();

      expect(assignment.slots[0].quality, SlotQuality.hq);
      expect(assignment.slots[1].quality, SlotQuality.hq);
      expect(assignment.slots[2].quality, SlotQuality.mq);
      expect(assignment.slots[3].quality, SlotQuality.mq);
      expect(assignment.slots[4].quality, SlotQuality.lq);
      expect(assignment.slots[5].quality, SlotQuality.lq);
      expect(assignment.slots[6].quality, SlotQuality.lq);
      expect(assignment.slots[7].quality, SlotQuality.lq);
    });

    test('hqSlots, mqSlots, and lqSlots expose expected index ranges', () {
      final assignment = VideoSlotAssignment.empty();

      expect(assignment.hqSlots.map((s) => s.index), [0, 1]);
      expect(assignment.mqSlots.map((s) => s.index), [2, 3]);
      expect(assignment.lqSlots.map((s) => s.index), [4, 5, 6, 7]);
    });

    test('activeSlots are 0-3 and thumbnailSlots are 4-7', () {
      final assignment = VideoSlotAssignment.empty();

      expect(assignment.activeSlots.map((s) => s.index), [0, 1, 2, 3]);
      expect(assignment.thumbnailSlots.map((s) => s.index), [4, 5, 6, 7]);
    });

    test('occupiedParticipantIds returns unique participant ids only', () {
      var assignment = VideoSlotAssignment.empty();
      assignment = assignment
          .replaceSlot(
            0,
            assignment.slots[0].copyWith(participantId: 'p1', trackSid: 't1'),
          )
          .replaceSlot(
            1,
            assignment.slots[1].copyWith(participantId: 'p2', trackSid: 't2'),
          )
          .replaceSlot(
            2,
            assignment.slots[2].copyWith(participantId: 'p1', trackSid: 't3'),
          );

      expect(assignment.occupiedParticipantIds, equals({'p1', 'p2'}));
    });

    test('findSlotForParticipant returns matching slot when found', () {
      var assignment = VideoSlotAssignment.empty();
      assignment = assignment.replaceSlot(
        3,
        assignment.slots[3].copyWith(participantId: 'target', trackSid: 't1'),
      );

      final slot = assignment.findSlotForParticipant('target');

      expect(slot, isNotNull);
      expect(slot!.index, 3);
      expect(slot.participantId, 'target');
    });

    test('findSlotForParticipant returns null when not found', () {
      final assignment = VideoSlotAssignment.empty();

      expect(assignment.findSlotForParticipant('missing'), isNull);
    });

    test('replaceSlot returns new assignment with only target slot replaced', () {
      final assignment = VideoSlotAssignment.empty();
      final replacement = assignment.slots[5].copyWith(
        participantId: 'p5',
        trackSid: 't5',
        isSpeaking: true,
      );

      final updated = assignment.replaceSlot(5, replacement);

      expect(updated, isNot(same(assignment)));
      expect(updated.slots[5], equals(replacement));
      expect(assignment.slots[5].participantId, isNull);
      expect(updated.slots[4], equals(assignment.slots[4]));
      expect(updated.slots[6], equals(assignment.slots[6]));
    });

    test('withPin sets pinnedParticipantId and keeps slots unchanged', () {
      final assignment = VideoSlotAssignment.empty();

      final updated = assignment.withPin('pinned-id');

      expect(updated.pinnedParticipantId, 'pinned-id');
      expect(updated.slots, same(assignment.slots));
    });

    test('withPin allows clearing pin with null', () {
      final assignment = VideoSlotAssignment.empty().withPin('p1');

      final cleared = assignment.withPin(null);

      expect(cleared.pinnedParticipantId, isNull);
    });
  });
}
