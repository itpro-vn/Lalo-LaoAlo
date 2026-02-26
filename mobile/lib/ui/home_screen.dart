import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:lalo/call/ui/outgoing_call_screen.dart';
import 'package:lalo/core/auth/auth_state.dart';
import 'package:lalo/core/providers/providers.dart';

/// Home screen with dial pad for initiating calls.
class HomeScreen extends ConsumerStatefulWidget {
  /// Creates a [HomeScreen].
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _peerIdController = TextEditingController();
  static const _uuid = Uuid();

  @override
  void dispose() {
    _peerIdController.dispose();
    super.dispose();
  }

  Future<void> _startCall({required bool withVideo}) async {
    final peerId = _peerIdController.text.trim();
    if (peerId.isEmpty) return;

    final callService = ref.read(callServiceProvider);
    final callId = _uuid.v4();

    // Read user ID from JWT token.
    final userIdAsync = ref.read(userIdProvider);
    final callerId = userIdAsync.valueOrNull ?? 'anonymous';

    final session = await callService.startCall(
      callId: callId,
      callerId: callerId,
      calleeId: peerId,
      hasVideo: withVideo,
    );

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OutgoingCallScreen(
          callService: callService,
          callId: session.callId,
          calleeName: peerId,
          hasVideo: withVideo,
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await ref.read(authNotifierProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lalo'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.phone_in_talk_rounded,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 24),
            Text(
              'Start a call',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _peerIdController,
              decoration: const InputDecoration(
                labelText: 'User ID or phone number',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _startCall(withVideo: false),
            ),
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _startCall(withVideo: false),
                    icon: const Icon(Icons.call),
                    label: const Text('Voice Call'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _startCall(withVideo: true),
                    icon: const Icon(Icons.videocam),
                    label: const Text('Video Call'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
