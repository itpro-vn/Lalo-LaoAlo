import 'package:flutter_test/flutter_test.dart';

import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/services/video_slot_controller.dart';

void main() {
  group('VideoSlotController.computeAssignment', () {
    VideoSlotAssignment compute({
      required List<String> participantIds,
      String? activeSpeaker,
      List<String> recentSpeakers = const <String>[],
      Set<String> speakingParticipants = const <String>{},
      String? pinnedParticipantId,
    }) {
      return VideoSlotController.computeAssignment(
        participantIds: participantIds,
        activeSpeaker: activeSpeaker,
        recentSpeakers: recentSpeakers,
        speakingParticipants: speakingParticipants,
        pinnedParticipantId: pinnedParticipantId,
      );
    }

    test('empty participants returns empty assignment', () {
      final assignment = compute(participantIds: const <String>[]);

      expect(assignment.occupiedParticipantIds, isEmpty);
      expect(assignment.pinnedParticipantId, isNull);
      expect(assignment.slots, hasLength(8));
      expect(assignment.slots.where((s) => s.isOccupied), isEmpty);
    });

    test('single participant gets HQ slot 0', () {
      final assignment = compute(participantIds: const <String>['u1']);

      expect(assignment.slots[0].participantId, 'u1');
      expect(assignment.slots[0].quality, SlotQuality.hq);
      expect(assignment.slots[0].isPinned, isFalse);
      expect(assignment.slots[0].isSpeaking, isFalse);
      expect(assignment.slots.skip(1).where((s) => s.isOccupied), isEmpty);
    });

    test('two participants with active speaker places speaker in HQ', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2'],
        activeSpeaker: 'u2',
      );

      final speakerSlot = assignment.findSlotForParticipant('u2');
      expect(speakerSlot, isNotNull);
      expect(speakerSlot!.quality, SlotQuality.hq);
      expect(speakerSlot.isSpeaking, isTrue);
      expect(assignment.hqSlots.where((s) => s.isOccupied), hasLength(2));
    });

    test('pinned participant always gets HQ slot 0 and isPinned=true', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2', 'u3'],
        pinnedParticipantId: 'u3',
      );

      expect(assignment.slots[0].participantId, 'u3');
      expect(assignment.slots[0].quality, SlotQuality.hq);
      expect(assignment.slots[0].isPinned, isTrue);
    });

    test('pinned + active speaker assigns pin to slot 0 and speaker to slot 1', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2', 'u3'],
        activeSpeaker: 'u2',
        pinnedParticipantId: 'u3',
      );

      expect(assignment.slots[0].participantId, 'u3');
      expect(assignment.slots[0].isPinned, isTrue);
      expect(assignment.slots[1].participantId, 'u2');
      expect(assignment.slots[1].quality, SlotQuality.hq);
      expect(assignment.slots[1].isSpeaking, isTrue);
    });

    test('4 participants fill HQ + MQ slots', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2', 'u3', 'u4'],
      );

      expect(assignment.slots.take(4).where((s) => s.isOccupied), hasLength(4));
      expect(assignment.slots.skip(4).where((s) => s.isOccupied), isEmpty);
      expect(assignment.hqSlots.every((s) => s.isOccupied), isTrue);
      expect(assignment.mqSlots.every((s) => s.isOccupied), isTrue);
    });

    test('8 participants fill all slots', () {
      const participants = <String>['u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7', 'u8'];
      final assignment = compute(participantIds: participants);

      expect(assignment.slots.where((s) => s.isOccupied), hasLength(8));
      expect(
        assignment.occupiedParticipantIds,
        equals(participants.toSet()),
      );
    });

    test('recent speakers get priority for MQ slots', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2', 'u3', 'u4'],
        activeSpeaker: 'u1',
        recentSpeakers: const <String>['u3', 'u4'],
      );

      expect(assignment.slots[2].participantId, 'u3');
      expect(assignment.slots[3].participantId, 'u4');
      expect(assignment.slots[1].participantId, 'u2');
    });

    test('speaking participant not in list is ignored', () {
      final assignment = compute(
        participantIds: const <String>['u1'],
        speakingParticipants: const <String>{'ghost'},
      );

      expect(assignment.findSlotForParticipant('ghost'), isNull);
      expect(assignment.slots[0].participantId, 'u1');
      expect(assignment.slots[0].isSpeaking, isFalse);
    });

    test('pin participant not in list is ignored', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2'],
        pinnedParticipantId: 'ghost',
      );

      expect(assignment.findSlotForParticipant('ghost'), isNull);
      expect(assignment.slots[0].participantId, 'u1');
      expect(assignment.slots[0].isPinned, isFalse);
    });

    test('more than 8 participants only assigns first 8', () {
      const participants = <String>[
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
        'u6',
        'u7',
        'u8',
        'u9',
        'u10',
      ];
      final assignment = compute(participantIds: participants);

      expect(assignment.slots.where((s) => s.isOccupied), hasLength(8));
      expect(assignment.occupiedParticipantIds, equals(participants.take(8).toSet()));
      expect(assignment.findSlotForParticipant('u9'), isNull);
      expect(assignment.findSlotForParticipant('u10'), isNull);
    });

    test('active speaker not in participants is ignored', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2'],
        activeSpeaker: 'ghost',
      );

      expect(assignment.findSlotForParticipant('ghost'), isNull);
      expect(assignment.slots[0].participantId, 'u1');
      expect(assignment.slots[1].participantId, 'u2');
    });

    test('marks speaking participants that are actually assigned', () {
      final assignment = compute(
        participantIds: const <String>['u1', 'u2', 'u3'],
        recentSpeakers: const <String>['u2'],
        speakingParticipants: const <String>{'u2', 'ghost'},
      );

      final u2Slot = assignment.findSlotForParticipant('u2');
      expect(u2Slot, isNotNull);
      expect(u2Slot!.isSpeaking, isTrue);
      expect(assignment.findSlotForParticipant('ghost'), isNull);
    });
  });
}
