import 'dart:async';

import 'package:flutter/material.dart';

import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/services/call_service.dart';
import 'package:lalo/call/ui/active_call_screen.dart';

class OutgoingCallScreen extends StatefulWidget {
  const OutgoingCallScreen({
    super.key,
    required this.callService,
    required this.callId,
    required this.calleeName,
    required this.hasVideo,
  });

  final CallService callService;
  final String callId;
  final String calleeName;
  final bool hasVideo;

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  StreamSubscription<CallState>? _stateSubscription;
  Timer? _uiTimer;
  Timer? _autoPopTimer;

  CallState _state = CallState.outgoing;
  DateTime? _connectedAt;
  String? _endReason;

  @override
  void initState() {
    super.initState();

    _stateSubscription = widget.callService.onCallState.listen(_onStateChanged);
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _connectedAt != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _uiTimer?.cancel();
    _autoPopTimer?.cancel();
    super.dispose();
  }

  Future<void> _onStateChanged(CallState state) async {
    if (!mounted) return;

    setState(() => _state = state);

    switch (state) {
      case CallState.active:
        _connectedAt ??= DateTime.now();
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ActiveCallScreen(
              callService: widget.callService,
              callId: widget.callId,
              peerName: widget.calleeName,
              hasVideo: widget.hasVideo,
            ),
          ),
        );
        break;
      case CallState.ended:
        _endReason = widget.callService.currentSession?.endReason ?? 'Call ended';
        _autoPopTimer?.cancel();
        _autoPopTimer = Timer(const Duration(seconds: 2), () {
          if (!mounted) return;
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        });
        break;
      case CallState.connecting:
      case CallState.idle:
      case CallState.incoming:
      case CallState.outgoing:
      case CallState.reconnecting:
        break;
    }
  }

  Future<void> _endCall() async {
    await widget.callService.endCall(widget.callId, reason: 'cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              CircleAvatar(
                radius: 68,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  _initials(widget.calleeName),
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                widget.calleeName,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _statusText,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _durationText,
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white54),
              ),
              if (_state == CallState.ended && _endReason != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _endReason!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.orange.shade200,
                  ),
                ),
              ],
              const SizedBox(height: 56),
              InkWell(
                onTap: _endCall,
                customBorder: const CircleBorder(),
                child: Ink(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.call_end, color: Colors.white, size: 34),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _statusText {
    switch (_state) {
      case CallState.outgoing:
        return 'Calling...';
      case CallState.connecting:
      case CallState.reconnecting:
        return 'Connecting...';
      case CallState.active:
        return 'Connected';
      case CallState.ended:
        return 'Call ended';
      case CallState.idle:
      case CallState.incoming:
        return 'Preparing...';
    }
  }

  String get _durationText {
    final started = _connectedAt;
    if (started == null) return '00:00';
    final elapsed = DateTime.now().difference(started);
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = elapsed.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return p.isNotEmpty ? p[0].toUpperCase() : '?';
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
