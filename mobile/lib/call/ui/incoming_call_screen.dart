import 'package:flutter/material.dart';

import 'package:lalo/call/services/call_service.dart';
import 'package:lalo/call/ui/active_call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.callService,
    required this.callId,
    required this.callerName,
    required this.hasVideo,
  });

  final CallService callService;
  final String callId;
  final String callerName;
  final bool hasVideo;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_processing) return;
    setState(() => _processing = true);

    await widget.callService.acceptCall(widget.callId);
    if (!mounted) return;

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ActiveCallScreen(
          callService: widget.callService,
          callId: widget.callId,
          peerName: widget.callerName,
          hasVideo: widget.hasVideo,
        ),
      ),
    );
  }

  Future<void> _reject() async {
    if (_processing) return;
    setState(() => _processing = true);

    await widget.callService.rejectCall(widget.callId);
    if (!mounted) return;

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const _CallDismissedPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(widget.callerName);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  final scale = 1 + (_pulseAnimation.value * 0.08);
                  final opacity = 0.15 + (_pulseAnimation.value * 0.2);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: opacity),
                      ),
                      child: Center(child: child),
                    ),
                  );
                },
                child: CircleAvatar(
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
              ),
              const SizedBox(height: 28),
              Text(
                widget.callerName,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Incoming ${widget.hasVideo ? 'video' : 'voice'} call',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 56),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _RoundCallButton(
                    icon: Icons.call_end,
                    color: Colors.red.shade600,
                    onTap: _processing ? null : _reject,
                  ),
                  const SizedBox(width: 48),
                  _RoundCallButton(
                    icon: Icons.call,
                    color: Colors.green.shade600,
                    onTap: _processing ? null : _accept,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final first = parts.first;
      return first.isNotEmpty ? first[0].toUpperCase() : '?';
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

class _RoundCallButton extends StatelessWidget {
  const _RoundCallButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Ink(
        width: 76,
        height: 76,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 34),
      ),
    );
  }
}

class _CallDismissedPage extends StatelessWidget {
  const _CallDismissedPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Call dismissed')),
    );
  }
}
