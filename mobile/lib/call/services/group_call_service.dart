import 'dart:async';

import 'package:lalo/call/models/group_call_models.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/signaling_client.dart';

/// Orchestrates group-call room lifecycle across API and signaling layers.
class GroupCallService {
  /// Creates a [GroupCallService].
  GroupCallService({
    required SignalingClient signalingClient,
    required ApiClient apiClient,
    required MediaManager mediaManager,
  })  : _signalingClient = signalingClient,
        _apiClient = apiClient,
        _mediaManager = mediaManager {
    _messageSubscription =
        _signalingClient.onMessage.listen(_handleSignalMessage);
  }

  final SignalingClient _signalingClient;
  final ApiClient _apiClient;
  final MediaManager _mediaManager;

  final StreamController<RoomCreatedEvent> _roomCreatedController =
      StreamController<RoomCreatedEvent>.broadcast();
  final StreamController<RoomInvitationEvent> _roomInvitationController =
      StreamController<RoomInvitationEvent>.broadcast();
  final StreamController<RoomClosedEvent> _roomClosedController =
      StreamController<RoomClosedEvent>.broadcast();
  final StreamController<ParticipantEvent> _participantJoinedController =
      StreamController<ParticipantEvent>.broadcast();
  final StreamController<ParticipantEvent> _participantLeftController =
      StreamController<ParticipantEvent>.broadcast();
  final StreamController<LayerUpdateEvent> _layerUpdateController =
      StreamController<LayerUpdateEvent>.broadcast();
  final StreamController<PolicyUpdateEvent> _policyUpdateController =
      StreamController<PolicyUpdateEvent>.broadcast();

  StreamSubscription<SignalingMessage>? _messageSubscription;

  /// Emits parsed `room_created` events from signaling.
  Stream<RoomCreatedEvent> get onRoomCreated => _roomCreatedController.stream;

  /// Emits parsed `room_invitation` events from signaling.
  Stream<RoomInvitationEvent> get onRoomInvitation =>
      _roomInvitationController.stream;

  /// Emits parsed `room_closed` events from signaling.
  Stream<RoomClosedEvent> get onRoomClosed => _roomClosedController.stream;

  /// Emits parsed `participant_joined` events from signaling.
  Stream<ParticipantEvent> get onParticipantJoined =>
      _participantJoinedController.stream;

  /// Emits parsed `participant_left` events from signaling.
  Stream<ParticipantEvent> get onParticipantLeft =>
      _participantLeftController.stream;

  /// Emits parsed `layer_update` events from signaling.
  Stream<LayerUpdateEvent> get onLayerUpdate => _layerUpdateController.stream;

  /// Emits parsed `policy_update` events from signaling.
  Stream<PolicyUpdateEvent> get onPolicyUpdate =>
      _policyUpdateController.stream;

  /// Creates room via API and joins via signaling.
  Future<RoomCreatedEvent> createRoom(
    List<String> participants,
    String callType,
  ) async {
    final payload = await _apiClient.createRoom(participants, callType);
    final event = RoomCreatedEvent.fromJson(payload);

    if (event.roomId.isEmpty) {
      throw StateError('createRoom response missing roomId');
    }

    _signalingClient.joinRoom(event.roomId);
    return event;
  }

  /// Joins room via API and then signaling.
  Future<RoomCreatedEvent> joinRoom(String roomId) async {
    final payload = await _apiClient.joinRoom(roomId);
    final event = RoomCreatedEvent.fromJson(<String, dynamic>{
      ...payload,
      if (!payload.containsKey('room_id') && !payload.containsKey('roomId'))
        'room_id': roomId,
    });

    await _mediaManager.initialize();
    _signalingClient.joinRoom(roomId);
    return event;
  }

  /// Leaves room in signaling and API.
  Future<void> leaveRoom(String roomId) async {
    _signalingClient.leaveRoom(roomId);
    await _apiClient.leaveRoom(roomId);
  }

  /// Invites additional participants via signaling.
  Future<void> inviteToRoom(String roomId, List<String> invitees) async {
    _signalingClient.inviteToRoom(roomId, invitees);
  }

  /// Requests a specific simulcast layer for a track from the SFU.
  ///
  /// [roomId] — target room.
  /// [trackSid] — publisher's track SID.
  /// [layer] — desired layer RID ('h', 'm', 'l').
  void requestLayer(String roomId, String trackSid, String layer) {
    _signalingClient.requestLayer(roomId, trackSid, layer);
  }

  /// Sends quality metrics to the server for policy engine evaluation.
  ///
  /// [callId] — call/room identifier.
  /// [samples] — list of quality metric samples.
  void sendQualityMetrics(
    String callId,
    List<Map<String, dynamic>> samples,
  ) {
    _signalingClient.sendQualityMetrics(callId, samples);
  }

  void _handleSignalMessage(SignalingMessage message) {
    switch (message.type) {
      case msgRoomCreated:
        _roomCreatedController.add(RoomCreatedEvent.fromJson(message.data));
        return;
      case msgRoomInvitation:
        _roomInvitationController
            .add(RoomInvitationEvent.fromJson(message.data));
        return;
      case msgRoomClosed:
        _roomClosedController.add(RoomClosedEvent.fromJson(message.data));
        return;
      case msgParticipantJoined:
        _participantJoinedController
            .add(ParticipantEvent.fromJson(message.data));
        return;
      case msgParticipantLeft:
        _participantLeftController.add(ParticipantEvent.fromJson(message.data));
        return;
      case msgLayerUpdate:
        _layerUpdateController.add(LayerUpdateEvent.fromJson(message.data));
        return;
      case msgPolicyUpdate:
        _policyUpdateController
            .add(PolicyUpdateEvent.fromJson(message.data));
        return;
      case msgParticipantMediaChanged:
      case msgIncomingCall:
      case msgCallAccepted:
      case msgCallRejected:
      case msgCallEnded:
      case msgCallCancelled:
      case msgPong:
      case msgError:
      case msgCallInitiate:
      case msgCallAccept:
      case msgCallReject:
      case msgCallEnd:
      case msgCallCancel:
      case msgIceCandidate:
      case msgQualityMetrics:
      case msgPing:
      case msgRoomCreate:
      case msgRoomInvite:
      case msgRoomJoin:
      case msgRoomLeave:
      case msgLayerRequest:
        return;
    }
  }

  /// Releases stream and subscription resources.
  Future<void> dispose() async {
    await _messageSubscription?.cancel();
    _messageSubscription = null;

    await _roomCreatedController.close();
    await _roomInvitationController.close();
    await _roomClosedController.close();
    await _participantJoinedController.close();
    await _participantLeftController.close();
    await _layerUpdateController.close();
    await _policyUpdateController.close();
  }
}
