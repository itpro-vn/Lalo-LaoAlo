import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:lalo/call/models/video_slot.dart';
import 'package:lalo/core/network/reconnection_manager.dart';

/// Participant info for rendering in video slots.
class ParticipantInfo {
  /// Creates a [ParticipantInfo].
  const ParticipantInfo({
    required this.id,
    required this.displayName,
    this.audioMuted = false,
    this.videoMuted = false,
  });

  /// Unique participant identifier.
  final String id;

  /// Display name shown under video.
  final String displayName;

  /// Whether audio is muted.
  final bool audioMuted;

  /// Whether video is disabled.
  final bool videoMuted;
}

/// Callback when user taps a participant to pin/unpin.
typedef OnPinToggle = void Function(String participantId);

/// Group-call UI showing participants in video slot layout.
///
/// Layout:
/// - Top: Room info bar (room ID, participant count, duration)
/// - Middle: 2×2 grid for active slots (HQ + MQ)
/// - Bottom strip: LQ thumbnails for remaining participants
/// - Bottom: Call controls
class GroupCallScreen extends StatefulWidget {
  /// Creates a [GroupCallScreen].
  const GroupCallScreen({
    super.key,
    required this.roomId,
    required this.participants,
    required this.renderers,
    this.assignment,
    this.onPinToggle,
    this.onLeave,
    this.reconnectionState = ReconnectionState.idle,
    this.reconnectionAttempt,
  });

  /// Active room identifier.
  final String roomId;

  /// Participant info keyed by participant ID.
  final Map<String, ParticipantInfo> participants;

  /// Map of participant ID to their RTCVideoRenderer.
  final Map<String, RTCVideoRenderer> renderers;

  /// Current video slot assignment (null = use simple grid fallback).
  final VideoSlotAssignment? assignment;

  /// Called when user taps a participant to pin/unpin.
  final OnPinToggle? onPinToggle;

  /// Called when user taps the leave button.
  final VoidCallback? onLeave;

  /// Current reconnection state.
  final ReconnectionState reconnectionState;

  /// Latest reconnection attempt info (null when idle).
  final ReconnectionAttempt? reconnectionAttempt;

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  Timer? _timer;
  Duration _duration = Duration.zero;
  bool _isMuted = false;
  bool _cameraOn = true;
  bool _speakerOn = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _duration += const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isReconnecting =
        widget.reconnectionState == ReconnectionState.reconnectingSignaling ||
            widget.reconnectionState == ReconnectionState.restartingIce;
    final isFailed = widget.reconnectionState == ReconnectionState.failed;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                _TopBar(
                  roomId: widget.roomId,
                  participantCount: widget.participants.length,
                  durationText: _formatDuration(_duration),
                ),
                // Active slots: 2×2 grid (HQ + MQ)
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: _buildActiveGrid(),
                  ),
                ),
                // Thumbnail strip (LQ slots)
                if (_hasThumbnails)
                  SizedBox(
                    height: 90,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _buildThumbnailStrip(),
                    ),
                  ),
                const SizedBox(height: 8),
                _ControlsBar(
                  isMuted: _isMuted,
                  cameraOn: _cameraOn,
                  speakerOn: _speakerOn,
                  onToggleMute: () => setState(() => _isMuted = !_isMuted),
                  onToggleCamera: () => setState(() => _cameraOn = !_cameraOn),
                  onToggleSpeaker: () =>
                      setState(() => _speakerOn = !_speakerOn),
                  onLeave:
                      widget.onLeave ?? () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(height: 12),
              ],
            ),
            // Reconnection overlay
            if (isReconnecting || isFailed)
              _ReconnectionOverlay(
                state: widget.reconnectionState,
                attempt: widget.reconnectionAttempt,
              ),
          ],
        ),
      ),
    );
  }

  bool get _hasThumbnails {
    final assignment = widget.assignment;
    if (assignment == null) return false;
    return assignment.thumbnailSlots.any((s) => s.isOccupied);
  }

  /// Builds the 2×2 grid for active (HQ + MQ) slots.
  Widget _buildActiveGrid() {
    final assignment = widget.assignment;

    if (assignment == null) {
      // Fallback: simple grid with all participants (legacy mode)
      return _buildLegacyGrid();
    }

    final activeSlots =
        assignment.activeSlots.where((s) => s.isOccupied).toList();

    if (activeSlots.isEmpty) {
      return const Center(
        child: Text(
          'Waiting for participants...',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    final columns = activeSlots.length <= 1 ? 1 : 2;

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: activeSlots.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: columns == 1 ? 1.2 : 0.74,
      ),
      itemBuilder: (context, index) {
        final slot = activeSlots[index];
        final participant = widget.participants[slot.participantId];
        if (participant == null) return const SizedBox.shrink();

        return _SlotTile(
          participant: participant,
          renderer: widget.renderers[slot.participantId],
          slot: slot,
          onTap: () => _handlePinToggle(slot),
        );
      },
    );
  }

  /// Builds horizontal thumbnail strip for LQ slots.
  Widget _buildThumbnailStrip() {
    final assignment = widget.assignment!;
    final thumbnails =
        assignment.thumbnailSlots.where((s) => s.isOccupied).toList();

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: thumbnails.length,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final slot = thumbnails[index];
        final participant = widget.participants[slot.participantId];
        if (participant == null) return const SizedBox.shrink();

        return SizedBox(
          width: 80,
          child: _ThumbnailTile(
            participant: participant,
            renderer: widget.renderers[slot.participantId],
            isSpeaking: slot.isSpeaking,
            onTap: () => _handlePinToggle(slot),
          ),
        );
      },
    );
  }

  /// Legacy grid (no slot assignment — backward compatible).
  Widget _buildLegacyGrid() {
    final participants = widget.participants.values.take(8).toList();
    final columns = _resolveColumns(participants.length);

    return GridView.builder(
      itemCount: participants.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.74,
      ),
      itemBuilder: (context, index) {
        return _ParticipantTile(
          name: participants[index].displayName,
          audioMuted: participants[index].audioMuted,
          videoMuted: participants[index].videoMuted,
          renderer: widget.renderers[participants[index].id],
          isSpeaking: false,
          isPinned: false,
        );
      },
    );
  }

  void _handlePinToggle(VideoSlot slot) {
    if (slot.participantId == null) return;
    widget.onPinToggle?.call(slot.participantId!);
  }

  int _resolveColumns(int count) {
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    return 3;
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

// ---------------------------------------------------------------------------
// Slot tile: active grid participant with speaking indicator + pin
// ---------------------------------------------------------------------------

class _SlotTile extends StatelessWidget {
  const _SlotTile({
    required this.participant,
    this.renderer,
    required this.slot,
    required this.onTap,
  });

  final ParticipantInfo participant;
  final RTCVideoRenderer? renderer;
  final VideoSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final showAvatar = participant.videoMuted ||
        renderer == null ||
        renderer!.srcObject == null;
    final qualityLabel = slot.quality == SlotQuality.hq
        ? 'HQ'
        : slot.quality == SlotQuality.mq
            ? 'MQ'
            : 'LQ';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: slot.isSpeaking
                ? Colors.greenAccent
                : slot.isPinned
                    ? Colors.blueAccent
                    : Colors.transparent,
            width: slot.isSpeaking || slot.isPinned ? 3 : 0,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            slot.isSpeaking || slot.isPinned ? 9 : 12,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // Smooth crossfade when participant changes in this slot.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: showAvatar
                    ? KeyedSubtree(
                        key: ValueKey<String>('avatar_${participant.id}'),
                        child: _AvatarBackground(
                          name: participant.displayName,
                          videoMuted: participant.videoMuted,
                        ),
                      )
                    : KeyedSubtree(
                        key: ValueKey<String>('video_${participant.id}'),
                        child: RTCVideoView(
                          renderer!,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
              ),
              // Bottom bar: name + mute icon + quality badge
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  children: <Widget>[
                    // Pin icon
                    if (slot.isPinned)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.push_pin,
                          color: Colors.blueAccent,
                          size: 14,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        participant.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          shadows: <Shadow>[
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                    if (participant.audioMuted)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.mic_off, color: Colors.red, size: 16),
                      ),
                    // Quality badge
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            qualityLabel,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thumbnail tile: LQ participant in bottom strip
// ---------------------------------------------------------------------------

class _ThumbnailTile extends StatelessWidget {
  const _ThumbnailTile({
    required this.participant,
    this.renderer,
    required this.isSpeaking,
    required this.onTap,
  });

  final ParticipantInfo participant;
  final RTCVideoRenderer? renderer;
  final bool isSpeaking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final showAvatar = participant.videoMuted ||
        renderer == null ||
        renderer!.srcObject == null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSpeaking ? Colors.greenAccent : Colors.transparent,
            width: isSpeaking ? 2 : 0,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isSpeaking ? 6 : 8),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: showAvatar
                    ? KeyedSubtree(
                        key: ValueKey<String>('thumb_avatar_${participant.id}'),
                        child: _AvatarBackground(
                          name: participant.displayName,
                          videoMuted: participant.videoMuted,
                          fontSize: 14,
                          avatarRadius: 20,
                        ),
                      )
                    : KeyedSubtree(
                        key: ValueKey<String>('thumb_video_${participant.id}'),
                        child: RTCVideoView(
                          renderer!,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
              ),
              Positioned(
                left: 4,
                right: 4,
                bottom: 4,
                child: Text(
                  participant.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    shadows: <Shadow>[
                      Shadow(color: Colors.black54, blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avatar background: shown when video is muted or no renderer
// ---------------------------------------------------------------------------

class _AvatarBackground extends StatelessWidget {
  const _AvatarBackground({
    required this.name,
    required this.videoMuted,
    this.fontSize = 18.0,
    this.avatarRadius = 40.0,
  });

  final String name;
  final bool videoMuted;
  final double fontSize;
  final double avatarRadius;

  @override
  Widget build(BuildContext context) {
    final initials = _initials(name);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.blueGrey.shade700,
            Colors.blueGrey.shade900,
          ],
        ),
      ),
      child: Center(
        child: CircleAvatar(
          radius: math.min(
            avatarRadius,
            20 + name.length.toDouble(),
          ),
          backgroundColor: Colors.white12,
          child: Text(
            initials,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
            ),
          ),
        ),
      ),
    );
  }

  String _initials(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// Legacy participant tile (backward compatible, no slot system)
// ---------------------------------------------------------------------------

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.name,
    required this.audioMuted,
    required this.videoMuted,
    required this.isSpeaking,
    required this.isPinned,
    this.renderer,
  });

  final String name;
  final bool audioMuted;
  final bool videoMuted;
  final bool isSpeaking;
  final bool isPinned;
  final RTCVideoRenderer? renderer;

  @override
  Widget build(BuildContext context) {
    final showAvatar =
        videoMuted || renderer == null || renderer!.srcObject == null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSpeaking ? Colors.greenAccent : Colors.transparent,
          width: isSpeaking ? 3 : 0,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(isSpeaking ? 9 : 12),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: showAvatar
                  ? KeyedSubtree(
                      key: ValueKey<String>('legacy_avatar_$name'),
                      child: _AvatarBackground(
                        name: name,
                        videoMuted: videoMuted,
                      ),
                    )
                  : KeyedSubtree(
                      key: ValueKey<String>('legacy_video_$name'),
                      child: RTCVideoView(
                        renderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (audioMuted)
                    const Icon(
                      Icons.mic_off,
                      color: Colors.white,
                      size: 18,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar: room info
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.roomId,
    required this.participantCount,
    required this.durationText,
  });

  final String roomId;
  final int participantCount;
  final String durationText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Room: $roomId',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$participantCount participants',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                durationText,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Controls bar
// ---------------------------------------------------------------------------

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({
    required this.isMuted,
    required this.cameraOn,
    required this.speakerOn,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onToggleSpeaker,
    required this.onLeave,
  });

  final bool isMuted;
  final bool cameraOn;
  final bool speakerOn;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              _ControlButton(
                icon: isMuted ? Icons.mic_off : Icons.mic,
                active: isMuted,
                onTap: onToggleMute,
              ),
              _ControlButton(
                icon: cameraOn ? Icons.videocam : Icons.videocam_off,
                active: !cameraOn,
                onTap: onToggleCamera,
              ),
              _ControlButton(
                icon: speakerOn ? Icons.volume_up : Icons.hearing,
                active: speakerOn,
                onTap: onToggleSpeaker,
              ),
              InkWell(
                onTap: onLeave,
                customBorder: const CircleBorder(),
                child: Ink(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.call_end, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Ink(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? Colors.white24 : Colors.white10,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reconnection overlay: shown during signaling/ICE reconnect or failure
// ---------------------------------------------------------------------------

class _ReconnectionOverlay extends StatelessWidget {
  const _ReconnectionOverlay({
    required this.state,
    this.attempt,
  });

  final ReconnectionState state;
  final ReconnectionAttempt? attempt;

  @override
  Widget build(BuildContext context) {
    final isFailed = state == ReconnectionState.failed;

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Container(
          key: ValueKey<ReconnectionState>(state),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: isFailed
              ? Colors.red.shade700.withValues(alpha: 0.95)
              : Colors.orange.shade700.withValues(alpha: 0.9),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: <Widget>[
                if (!isFailed)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                if (isFailed)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: Icon(
                      Icons.error_outline,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                Expanded(
                  child: Text(
                    _message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (attempt != null && !isFailed)
                  Text(
                    '${attempt!.attempt}/${attempt!.maxAttempts}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _message {
    switch (state) {
      case ReconnectionState.reconnectingSignaling:
        return 'Reconnecting…';
      case ReconnectionState.restartingIce:
        return 'Restoring media…';
      case ReconnectionState.failed:
        return 'Connection lost';
      case ReconnectionState.idle:
      case ReconnectionState.reconnected:
        return '';
    }
  }
}
