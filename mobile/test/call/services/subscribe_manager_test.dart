import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/services/group_call_service.dart';
import 'package:lalo/call/services/subscribe_manager.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';
import 'package:lalo/core/auth/token_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/signaling_client.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Minimal SignalingClient that provides empty streams.
class _FakeSignalingClient extends SignalingClient {
  _FakeSignalingClient()
      : super(url: 'ws://fake', tokenProvider: () async => 'fake-token');

  final List<_LayerRequest> layerRequests = <_LayerRequest>[];

  @override
  Stream<SignalingMessage> get onMessage =>
      const Stream<SignalingMessage>.empty();

  @override
  Stream<ConnectionState> get onConnectionState =>
      const Stream<ConnectionState>.empty();

  @override
  void requestLayer(String roomId, String trackSid, String layer) {
    layerRequests.add(_LayerRequest(roomId, trackSid, layer));
  }
}

class _LayerRequest {
  const _LayerRequest(this.roomId, this.trackSid, this.layer);
  final String roomId;
  final String trackSid;
  final String layer;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

VideoSlotAssignment _assignmentWith(List<VideoSlot> customSlots) {
  final slots = List<VideoSlot>.generate(8, (i) {
    for (final s in customSlots) {
      if (s.index == i) return s;
    }
    return VideoSlot(index: i, quality: SlotQuality.off);
  });
  return VideoSlotAssignment(slots: slots, pinnedParticipantId: null);
}

void main() {
  late _FakeSignalingClient fakeSignaling;
  late GroupCallService groupCallService;
  late SubscribeManager manager;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    fakeSignaling = _FakeSignalingClient();
    groupCallService = GroupCallService(
      signalingClient: fakeSignaling,
      apiClient: ApiClient('http://fake', _FakeTokenManager()),
      mediaManager: MediaManager(),
    );
    manager = SubscribeManager(
      groupCallService: groupCallService,
      roomId: 'room-1',
    );
  });

  tearDown(() async {
    await manager.dispose();
    await groupCallService.dispose();
  });

  group('registerTrack / unregisterTrack', () {
    test('registered track triggers layer request on assignment', () {
      manager.registerTrack('p1', 'track-1');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'p1',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      expect(fakeSignaling.layerRequests[0].layer, 'h');
      expect(fakeSignaling.layerRequests[0].trackSid, 'track-1');
    });

    test('unregistered track does not trigger request', () {
      manager.registerTrack('p1', 'track-1');
      manager.unregisterTrack('p1');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'p1',
        ),
      ]));

      expect(fakeSignaling.layerRequests, isEmpty);
    });
  });

  group('updateFromAssignment — layer mapping', () {
    test('HQ slot sends high layer (rid=h)', () {
      manager.registerTrack('user-a', 'track-a');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      expect(fakeSignaling.layerRequests[0].layer, 'h');
    });

    test('MQ slot sends medium layer (rid=m)', () {
      manager.registerTrack('user-a', 'track-a');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 2,
          quality: SlotQuality.mq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      expect(fakeSignaling.layerRequests[0].layer, 'm');
    });

    test('LQ slot sends low layer (rid=l)', () {
      manager.registerTrack('user-a', 'track-a');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 4,
          quality: SlotQuality.lq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      expect(fakeSignaling.layerRequests[0].layer, 'l');
    });

    test('Off slot sends low layer when transitioning from HQ', () {
      manager.registerTrack('user-a', 'track-a');

      // First assign HQ
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));
      fakeSignaling.layerRequests.clear();

      // Then transition to Off
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.off,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      // Off → null simulcastLayer → falls back to 'l' (low)
      expect(fakeSignaling.layerRequests[0].layer, 'l');
    });
  });

  group('updateFromAssignment — deduplication', () {
    test('does not re-send same layer on repeated updates', () {
      manager.registerTrack('user-a', 'track-a');

      final assignment = _assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]);

      manager.updateFromAssignment(assignment);
      manager.updateFromAssignment(assignment);

      expect(fakeSignaling.layerRequests.length, 1);
    });

    test('sends new request when layer changes', () {
      manager.registerTrack('user-a', 'track-a');

      // First: HQ
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      // Second: MQ
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.mq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 2);
      expect(fakeSignaling.layerRequests[0].layer, 'h');
      expect(fakeSignaling.layerRequests[1].layer, 'm');
    });
  });

  group('updateFromAssignment — multiple participants', () {
    test('handles 3 participants in different slots', () {
      manager.registerTrack('a', 'track-a');
      manager.registerTrack('b', 'track-b');
      manager.registerTrack('c', 'track-c');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(index: 0, quality: SlotQuality.hq, participantId: 'a'),
        const VideoSlot(index: 1, quality: SlotQuality.hq, participantId: 'b'),
        const VideoSlot(index: 4, quality: SlotQuality.lq, participantId: 'c'),
      ]));

      expect(fakeSignaling.layerRequests.length, 3);

      final layers = fakeSignaling.layerRequests
          .map((r) => '${r.trackSid}:${r.layer}')
          .toSet();
      expect(layers, containsAll(['track-a:h', 'track-b:h', 'track-c:l']));
    });

    test('skips slots without registered tracks', () {
      manager.registerTrack('a', 'track-a');
      // 'b' is NOT registered

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(index: 0, quality: SlotQuality.hq, participantId: 'a'),
        const VideoSlot(index: 1, quality: SlotQuality.hq, participantId: 'b'),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);
      expect(fakeSignaling.layerRequests[0].trackSid, 'track-a');
    });

    test('skips empty slots (no participantId)', () {
      manager.updateFromAssignment(VideoSlotAssignment.empty());
      expect(fakeSignaling.layerRequests, isEmpty);
    });
  });

  group('onSubscribeEvent stream', () {
    test('emits event when layer changes', () async {
      manager.registerTrack('user-a', 'track-a');

      final events = <SubscribeEvent>[];
      final sub = manager.onSubscribeEvent.listen(events.add);

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      // Allow stream to deliver
      await Future<void>.delayed(Duration.zero);

      expect(events.length, 1);
      expect(events[0].trackSid, 'track-a');
      expect(events[0].layer, SimulcastLayer.high);

      await sub.cancel();
    });

    test('emits null layer when transitioning from HQ to Off', () async {
      manager.registerTrack('user-a', 'track-a');

      // First assign HQ to establish a non-null layer
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      final events = <SubscribeEvent>[];
      final sub = manager.onSubscribeEvent.listen(events.add);

      // Transition to Off
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.off,
          participantId: 'user-a',
        ),
      ]));

      await Future<void>.delayed(Duration.zero);

      expect(events.length, 1);
      expect(events[0].layer, isNull);

      await sub.cancel();
    });
  });

  group('reset', () {
    test('clears state — subsequent updates do not send requests', () {
      manager.registerTrack('user-a', 'track-a');

      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests.length, 1);

      manager.reset();
      fakeSignaling.layerRequests.clear();

      // After reset, track is unregistered → no requests
      manager.updateFromAssignment(_assignmentWith([
        const VideoSlot(
          index: 0,
          quality: SlotQuality.hq,
          participantId: 'user-a',
        ),
      ]));

      expect(fakeSignaling.layerRequests, isEmpty);
    });
  });

  group('SlotQuality.simulcastLayer mapping', () {
    test('hq → SimulcastLayer.high', () {
      expect(SlotQuality.hq.simulcastLayer, SimulcastLayer.high);
    });

    test('mq → SimulcastLayer.medium', () {
      expect(SlotQuality.mq.simulcastLayer, SimulcastLayer.medium);
    });

    test('lq → SimulcastLayer.low', () {
      expect(SlotQuality.lq.simulcastLayer, SimulcastLayer.low);
    });

    test('off → null', () {
      expect(SlotQuality.off.simulcastLayer, isNull);
    });
  });

  group('SubscribeEvent', () {
    test('toString includes track and layer rid', () {
      const event = SubscribeEvent(
        trackSid: 'track-xyz',
        layer: SimulcastLayer.medium,
      );
      expect(event.toString(), contains('track-xyz'));
      expect(event.toString(), contains('m'));
    });

    test('toString shows off for null layer', () {
      const event = SubscribeEvent(trackSid: 'track-xyz', layer: null);
      expect(event.toString(), contains('off'));
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal fake TokenManager for ApiClient constructor
// ---------------------------------------------------------------------------

class _FakeTokenManager extends TokenManager {
  _FakeTokenManager() : super();
}
