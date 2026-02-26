import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/services/call_service.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({
    super.key,
    required this.callService,
    required this.callId,
    required this.peerName,
    required this.hasVideo,
  });

  final CallService callService;
  final String callId;
  final String peerName;
  final bool hasVideo;

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  StreamSubscription<CallState>? _stateSubscription;
  StreamSubscription<MediaStream?>? _remoteStreamSubscription;
  StreamSubscription<QualityTier>? _qualitySubscription;

  Timer? _durationTimer;
  Timer? _autoPopTimer;

  DateTime _connectedAt = DateTime.now(); // ignore: prefer_final_fields — reassigned in initState
  Duration _duration = Duration.zero;

  Offset _pipOffset = const Offset(0.72, 0.10);

  bool _isMuted = false;
  bool _cameraEnabled = true;
  bool _speakerOn = false;
  bool _reconnecting = false;
  bool _ended = false;
  QualityTier _qualityTier = QualityTier.good;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _remoteRenderer.initialize();
    await _localRenderer.initialize();

    _localRenderer.srcObject = widget.callService.localStream;

    _isMuted = widget.callService.isMuted;
    _speakerOn = widget.callService.isSpeakerOn;

    _stateSubscription = widget.callService.onCallState.listen(_onCallStateChanged);
    _remoteStreamSubscription = widget.callService.onRemoteStream.listen((stream) {
      if (!mounted) return;
      setState(() {
        _remoteRenderer.srcObject = stream;
      });
    });

    final monitor = widget.callService.qualityMonitor;
    if (monitor != null) {
      _qualityTier = monitor.currentTier;
      _qualitySubscription = monitor.onTierChanged.listen((tier) {
        if (!mounted) return;
        setState(() => _qualityTier = tier);
      });
    }

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _ended) return;
      setState(() => _duration = DateTime.now().difference(_connectedAt));
    });

    await WakelockPlus.enable();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    _qualitySubscription?.cancel();
    _durationTimer?.cancel();
    _autoPopTimer?.cancel();

    _remoteRenderer.srcObject = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.dispose();
    _localRenderer.dispose();

    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _onCallStateChanged(CallState state) async {
    if (!mounted) return;

    if (state == CallState.reconnecting) {
      setState(() => _reconnecting = true);
      return;
    }

    if (state == CallState.active) {
      setState(() => _reconnecting = false);
      return;
    }

    if (state == CallState.ended) {
      setState(() {
        _reconnecting = false;
        _ended = true;
      });

      _autoPopTimer?.cancel();
      _autoPopTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  Future<void> _toggleMute() async {
    await widget.callService.toggleMute();
    if (!mounted) return;
    setState(() => _isMuted = widget.callService.isMuted);
  }

  Future<void> _toggleCamera() async {
    await widget.callService.toggleCamera();
    if (!mounted) return;
    setState(() => _cameraEnabled = !_cameraEnabled);
  }

  Future<void> _toggleSpeaker() async {
    await widget.callService.toggleSpeaker();
    if (!mounted) return;
    setState(() => _speakerOn = widget.callService.isSpeakerOn);
  }

  Future<void> _switchCamera() async {
    await widget.callService.switchCamera();
  }

  Future<void> _endCall() async {
    await widget.callService.endCall(widget.callId, reason: 'ended_by_user');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remoteHasVideo = widget.hasVideo && _remoteRenderer.srcObject != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: remoteHasVideo
                  ? RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _AudioOnlyBackground(peerName: widget.peerName),
            ),
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: _TopOverlay(
                durationText: _formatDuration(_duration),
                reconnecting: _reconnecting,
                ended: _ended,
                qualityTier: _qualityTier,
                videoDisabledByAbr: widget.callService.isVideoDisabledByAbr,
              ),
            ),
            if (widget.hasVideo)
              _DraggablePip(
                initialOffset: _pipOffset,
                onChanged: (v) => _pipOffset = v,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 120,
                    height: 170,
                    color: Colors.black87,
                    child: _cameraEnabled && _localRenderer.srcObject != null
                        ? RTCVideoView(
                            _localRenderer,
                            mirror: true,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          )
                        : const Center(
                            child: Icon(Icons.videocam_off, color: Colors.white70),
                          ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: _ControlBar(
                isMuted: _isMuted,
                isCameraOn: _cameraEnabled,
                isSpeakerOn: _speakerOn,
                onMute: _toggleMute,
                onCamera: _toggleCamera,
                onSpeaker: _toggleSpeaker,
                onSwitchCamera: _switchCamera,
                onEndCall: _endCall,
                enabled: !_ended,
                theme: theme,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

class _TopOverlay extends StatelessWidget {
  const _TopOverlay({
    required this.durationText,
    required this.reconnecting,
    required this.ended,
    required this.qualityTier,
    required this.videoDisabledByAbr,
  });

  final String durationText;
  final bool reconnecting;
  final bool ended;
  final QualityTier qualityTier;
  final bool videoDisabledByAbr;

  @override
  Widget build(BuildContext context) {
    final qualityColor = switch (qualityTier) {
      QualityTier.good => Colors.green,
      QualityTier.fair => Colors.yellow,
      QualityTier.poor => Colors.red,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  ended ? 'Call ended · $durationText' : durationText,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: qualityColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Quality', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (reconnecting) ...<Widget>[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
               color: Colors.orange.shade700.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                'Reconnecting…',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
        if (!reconnecting && qualityTier == QualityTier.poor) ...<Widget>[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.red.shade700.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                videoDisabledByAbr
                    ? 'Poor connection · Audio only'
                    : 'Poor connection',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.isMuted,
    required this.isCameraOn,
    required this.isSpeakerOn,
    required this.onMute,
    required this.onCamera,
    required this.onSpeaker,
    required this.onSwitchCamera,
    required this.onEndCall,
    required this.enabled,
    required this.theme,
  });

  final bool isMuted;
  final bool isCameraOn;
  final bool isSpeakerOn;
  final Future<void> Function() onMute;
  final Future<void> Function() onCamera;
  final Future<void> Function() onSpeaker;
  final Future<void> Function() onSwitchCamera;
  final Future<void> Function() onEndCall;
  final bool enabled;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    const disabledColor = Colors.white24;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
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
                onTap: enabled ? onMute : null,
              ),
              _ControlButton(
                icon: isCameraOn ? Icons.videocam : Icons.videocam_off,
                active: !isCameraOn,
                onTap: enabled ? onCamera : null,
              ),
              _ControlButton(
                icon: isSpeakerOn ? Icons.volume_up : Icons.hearing,
                active: isSpeakerOn,
                onTap: enabled ? onSpeaker : null,
              ),
              _ControlButton(
                icon: Icons.cameraswitch,
                active: false,
                onTap: enabled ? onSwitchCamera : null,
              ),
              InkWell(
                onTap: enabled ? () => onEndCall() : null,
                customBorder: const CircleBorder(),
                child: Ink(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: enabled ? Colors.red.shade600 : disabledColor,
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
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = active ? Colors.white24 : Colors.white12;

    return InkWell(
      onTap: onTap == null ? null : () => onTap!(),
      customBorder: const CircleBorder(),
      child: Ink(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _AudioOnlyBackground extends StatelessWidget {
  const _AudioOnlyBackground({required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(peerName);

    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircleAvatar(
              radius: 72,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                initials,
                style: theme.textTheme.displaySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              peerName,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final first = parts.first;
      return first.isNotEmpty ? first[0].toUpperCase() : '?';
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

class _DraggablePip extends StatefulWidget {
  const _DraggablePip({
    required this.initialOffset,
    required this.onChanged,
    required this.child,
  });

  final Offset initialOffset;
  final ValueChanged<Offset> onChanged;
  final Widget child;

  @override
  State<_DraggablePip> createState() => _DraggablePipState();
}

class _DraggablePipState extends State<_DraggablePip> {
  late Offset _normalizedOffset;

  @override
  void initState() {
    super.initState();
    _normalizedOffset = widget.initialOffset;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const pipWidth = 120.0;
        const pipHeight = 170.0;

        final maxX = (constraints.maxWidth - pipWidth).clamp(0, double.infinity);
        final maxY = (constraints.maxHeight - pipHeight).clamp(0, double.infinity);

        final left = (_normalizedOffset.dx * constraints.maxWidth)
            .clamp(0.0, maxX)
            .toDouble();
        final top = (_normalizedOffset.dy * constraints.maxHeight)
            .clamp(0.0, maxY)
            .toDouble();

        return Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            onPanUpdate: (details) {
              final nextLeft = (left + details.delta.dx).clamp(0.0, maxX).toDouble();
              final nextTop = (top + details.delta.dy).clamp(0.0, maxY).toDouble();

              setState(() {
                _normalizedOffset = Offset(
                  constraints.maxWidth > 0 ? nextLeft / constraints.maxWidth : 0,
                  constraints.maxHeight > 0 ? nextTop / constraints.maxHeight : 0,
                );
              });
              widget.onChanged(_normalizedOffset);
            },
            child: widget.child,
          ),
        );
      },
    );
  }
}
