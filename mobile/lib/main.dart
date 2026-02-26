import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lalo/core/auth/auth_state.dart';
import 'package:lalo/core/auth/login_screen.dart';
import 'package:lalo/core/providers/providers.dart';
import 'package:lalo/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ProviderScope(child: LaloApp()));
}

/// Root application widget for the Lalo call client.
class LaloApp extends ConsumerWidget {
  /// Creates a [LaloApp].
  const LaloApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Lalo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

/// Routes to [LoginScreen] or [HomeScreen] based on auth state.
class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  @override
  void initState() {
    super.initState();
    // Check if user is already authenticated on startup.
    Future.microtask(
      () => ref.read(authNotifierProvider.notifier).checkAuth(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);

    return switch (authState) {
      AuthState.unauthenticated => const LoginScreen(),
      AuthState.authenticating => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      AuthState.authenticated => const _AuthenticatedShell(),
    };
  }
}

/// Wraps the authenticated app area, initializing push and incoming call
/// listeners.
class _AuthenticatedShell extends ConsumerStatefulWidget {
  const _AuthenticatedShell();

  @override
  ConsumerState<_AuthenticatedShell> createState() =>
      _AuthenticatedShellState();
}

class _AuthenticatedShellState extends ConsumerState<_AuthenticatedShell> {
  @override
  void initState() {
    super.initState();
    _initServices();
  }

  void _initServices() {
    // Eagerly read services so their providers initialize.
    ref.read(pushServiceProvider);
    ref.read(callKitServiceProvider);
    ref.read(networkMonitorProvider);
  }

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}
