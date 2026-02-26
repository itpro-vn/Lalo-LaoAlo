import 'dart:async';

import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/call/services/group_call_service.dart';
import 'package:lalo/call/webrtc/simulcast_config.dart';

/// Manages simulcast layer subscriptions based on video slot assignments.
///
/// When slot assignments change, this manager sends layer requests
/// to ensure each subscriber receives the appropriate quality layer:
/// - HQ slots → high simulcast layer (rid="h")
/// - MQ slots → medium simulcast layer (rid="m")
/// - LQ slots → low simulcast layer (rid="l")
/// - Off slots → unsubscribed
class SubscribeManager {
  /// Creates a [SubscribeManager].
  SubscribeManager({
    required GroupCallService groupCallService,
    required String roomId,
  })  : _groupCallService = groupCallService,
        _roomId = roomId;

  final GroupCallService _groupCallService;
  final String _roomId;

  /// Last requested layer per track SID (to avoid redundant requests).
  final Map<String, SimulcastLayer?> _currentLayers =
      <String, SimulcastLayer?>{};

  /// Track SID mapping: participantId → trackSid.
  final Map<String, String> _trackSids = <String, String>{};

  /// Stream of subscribe events for observability.
  final StreamController<SubscribeEvent> _eventController =
      StreamController<SubscribeEvent>.broadcast();

  // -- Public API --

  /// Stream of subscribe events.
  Stream<SubscribeEvent> get onSubscribeEvent => _eventController.stream;

  /// Registers a participant's video track SID.
  ///
  /// Call when a participant publishes a video track.
  void registerTrack(String participantId, String trackSid) {
    _trackSids[participantId] = trackSid;
  }

  /// Unregisters a participant's track.
  void unregisterTrack(String participantId) {
    final trackSid = _trackSids.remove(participantId);
    if (trackSid != null) {
      _currentLayers.remove(trackSid);
    }
  }

  /// Updates subscriptions based on new slot assignments.
  ///
  /// For each occupied slot with a known track SID:
  /// - Determines the target simulcast layer from slot quality
  /// - Sends a layer request if the layer changed
  void updateFromAssignment(VideoSlotAssignment assignment) {
    for (final slot in assignment.slots) {
      if (slot.participantId == null) continue;

      final trackSid = _trackSids[slot.participantId!];
      if (trackSid == null) continue;

      final targetLayer = slot.quality.simulcastLayer;
      final currentLayer = _currentLayers[trackSid];

      if (targetLayer != currentLayer) {
        _requestLayer(trackSid, targetLayer);
        _currentLayers[trackSid] = targetLayer;
      }
    }
  }

  /// Resets all subscription state.
  void reset() {
    _currentLayers.clear();
    _trackSids.clear();
  }

  /// Disposes resources.
  Future<void> dispose() async {
    reset();
    await _eventController.close();
  }

  // -- Internal --

  void _requestLayer(String trackSid, SimulcastLayer? layer) {
    if (layer == null) {
      // Off — request lowest layer (SFU will handle unsubscribe via bandwidth)
      _groupCallService.requestLayer(_roomId, trackSid, SimulcastLayer.low.rid);
    } else {
      _groupCallService.requestLayer(_roomId, trackSid, layer.rid);
    }

    if (!_eventController.isClosed) {
      _eventController.add(
        SubscribeEvent(
          trackSid: trackSid,
          layer: layer,
        ),
      );
    }
  }
}

/// Event emitted when a subscription layer is changed.
class SubscribeEvent {
  /// Creates a [SubscribeEvent].
  const SubscribeEvent({
    required this.trackSid,
    required this.layer,
  });

  /// Track SID that changed.
  final String trackSid;

  /// New layer (null = unsubscribed/off).
  final SimulcastLayer? layer;

  @override
  String toString() =>
      'SubscribeEvent($trackSid, layer=${layer?.rid ?? "off"})';
}
