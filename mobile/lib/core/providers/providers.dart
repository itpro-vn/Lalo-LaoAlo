import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lalo/call/models/call_state.dart';
import 'package:lalo/call/services/call_service.dart';
import 'package:lalo/call/services/callkit_service.dart';
import 'package:lalo/call/services/device_state_monitor.dart';
import 'package:lalo/call/services/group_call_service.dart';
import 'package:lalo/call/services/push_service.dart';
import 'package:lalo/call/services/speaker_detector.dart';
import 'package:lalo/call/services/subscribe_manager.dart';
import 'package:lalo/call/services/video_slot_controller.dart';
import 'package:lalo/call/webrtc/abr_controller.dart';
import 'package:lalo/call/webrtc/media_manager.dart';
import 'package:lalo/call/webrtc/peer_connection_manager.dart';
import 'package:lalo/call/webrtc/quality_monitor.dart';
import 'package:lalo/call/webrtc/slow_loop_controller.dart';
import 'package:lalo/call/webrtc/two_loop_abr.dart';
import 'package:lalo/core/auth/token_manager.dart';
import 'package:lalo/core/config/app_config.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/network/network_monitor.dart';
import 'package:lalo/core/network/reconnection_manager.dart';
import 'package:lalo/core/network/signaling_client.dart';
import 'package:lalo/core/push/native_push_handler.dart';

/// StateNotifier wrapper around [CallStateMachine].
class CallStateNotifier extends StateNotifier<CallState> {
  CallStateNotifier._(this._machine) : super(_machine.currentState) {
    _transitionSub = _machine.onStateChanged.listen((transition) {
      state = transition.toState;
    });
  }

  factory CallStateNotifier({CallStateMachine? machine}) {
    return CallStateNotifier._(machine ?? CallStateMachine());
  }

  final CallStateMachine _machine;
  StreamSubscription<CallStateTransition>? _transitionSub;

  bool canTransition(CallState next) => _machine.canTransition(next);

  CallStateTransition transition(CallState next, {String? reason}) {
    final t = _machine.transition(next, reason: reason);
    state = t.toState;
    return t;
  }

  @override
  void dispose() {
    _transitionSub?.cancel();
    unawaited(_machine.dispose());
    super.dispose();
  }
}

final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.development();
});

final tokenManagerProvider = Provider<TokenManager>((ref) {
  final config = ref.watch(appConfigProvider);
  final refreshDio = Dio(
    BaseOptions(
      baseUrl: config.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ),
  );
  final tokenManager = TokenManager(dio: refreshDio);
  ref.onDispose(() {
    tokenManager.dispose();
    refreshDio.close(force: true);
  });
  return tokenManager;
});

/// Extracts user ID from the stored JWT access token's `sub` claim.
///
/// Returns `null` if no token is stored or decoding fails.
final userIdProvider = FutureProvider<String?>((ref) async {
  final tokenManager = ref.watch(tokenManagerProvider);
  try {
    final accessToken = await tokenManager.getAccessToken();
    if (accessToken == null || accessToken.isEmpty) return null;

    final parts = accessToken.split('.');
    if (parts.length != 3) return null;

    final normalized = base64Url.normalize(parts[1]);
    final payloadJson = utf8.decode(base64Url.decode(normalized));
    final payload = json.decode(payloadJson) as Map<String, dynamic>;

    // Try common JWT user ID claim names.
    final userId = payload['sub'] ?? payload['user_id'] ?? payload['uid'];
    return userId?.toString();
  } catch (_) {
    return null;
  }
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(appConfigProvider);
  final tokenManager = ref.watch(tokenManagerProvider);
  final client = ApiClient(config.apiBaseUrl, tokenManager);
  ref.onDispose(client.dispose);
  return client;
});

final signalingClientProvider = Provider<SignalingClient>((ref) {
  final config = ref.watch(appConfigProvider);
  final tokenManager = ref.watch(tokenManagerProvider);

  final client = SignalingClient(
    url: config.signalingUrl,
    tokenProvider: tokenManager.getAccessToken,
  );

  ref.onDispose(() {
    unawaited(client.dispose());
  });
  return client;
});

final networkMonitorProvider = Provider<NetworkMonitor>((ref) {
  final monitor = NetworkMonitor();
  ref.onDispose(() {
    unawaited(monitor.dispose());
  });
  return monitor;
});

final nativePushHandlerProvider = Provider<NativePushHandler>((ref) {
  final handler = NativePushHandler();
  ref.onDispose(handler.dispose);
  return handler;
});

final mediaManagerProvider = Provider<MediaManager>((ref) {
  final manager = MediaManager();
  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

final callStateNotifierProvider =
    StateNotifierProvider<CallStateNotifier, CallState>((ref) {
  return CallStateNotifier();
});

final peerConnectionManagerProvider = Provider<PeerConnectionManager>((ref) {
  final config = ref.watch(appConfigProvider);
  final manager = PeerConnectionManager(config.iceServers);
  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

final qualityMonitorProvider = Provider<QualityMonitor>((ref) {
  final config = ref.watch(appConfigProvider);
  final peerConnectionManager = ref.watch(peerConnectionManagerProvider);
  final monitor = QualityMonitor(
    peerConnectionManager,
    statsIntervalMs: config.statsIntervalMs,
  );
  ref.onDispose(() {
    unawaited(monitor.dispose());
  });
  return monitor;
});

final speakerDetectorProvider = Provider<SpeakerDetector>((ref) {
  final detector = SpeakerDetector();
  ref.onDispose(() {
    unawaited(detector.dispose());
  });
  return detector;
});

final deviceStateMonitorProvider = Provider<DeviceStateMonitor>((ref) {
  final monitor = DeviceStateMonitor();
  ref.onDispose(() {
    unawaited(monitor.dispose());
  });
  return monitor;
});

final abrControllerProvider = Provider<AbrController>((ref) {
  final config = ref.watch(appConfigProvider);
  final peerConnectionManager = ref.watch(peerConnectionManagerProvider);
  final qualityMonitor = ref.watch(qualityMonitorProvider);
  final mediaManager = ref.watch(mediaManagerProvider);

  final controller = AbrController(
    peerConnectionManager: peerConnectionManager,
    qualityMonitor: qualityMonitor,
    mediaManager: mediaManager,
    config: AbrConfig(
      loopIntervalMs: config.abrLoopIntervalMs,
      audioOnlyThresholdKbps: config.audioOnlyThresholdKbps,
      videoResumeThresholdKbps: config.videoResumeThresholdKbps,
      videoResumeStableSeconds: config.videoResumeStableSeconds,
    ),
  );

  ref.onDispose(() {
    unawaited(controller.dispose());
  });
  return controller;
});

/// Simulcast-aware ABR controller for group calls.
///
/// Instead of adjusting single-stream encoding, enables/disables
/// simulcast layers based on quality tier and bandwidth.
final simulcastAbrControllerProvider = Provider<SimulcastAbrController>((ref) {
  final config = ref.watch(appConfigProvider);
  final peerConnectionManager = ref.watch(peerConnectionManagerProvider);
  final qualityMonitor = ref.watch(qualityMonitorProvider);
  final mediaManager = ref.watch(mediaManagerProvider);

  final controller = SimulcastAbrController(
    peerConnectionManager: peerConnectionManager,
    qualityMonitor: qualityMonitor,
    mediaManager: mediaManager,
    config: AbrConfig(
      loopIntervalMs: config.abrLoopIntervalMs,
      audioOnlyThresholdKbps: config.audioOnlyThresholdKbps,
      videoResumeThresholdKbps: config.videoResumeThresholdKbps,
      videoResumeStableSeconds: config.videoResumeStableSeconds,
    ),
  );

  ref.onDispose(() {
    unawaited(controller.dispose());
  });
  return controller;
});

final twoLoopAbrProvider = Provider<TwoLoopAbr>((ref) {
  final peerConnectionManager = ref.watch(peerConnectionManagerProvider);
  final qualityMonitor = ref.watch(qualityMonitorProvider);
  final mediaManager = ref.watch(mediaManagerProvider);
  final deviceStateMonitor = ref.watch(deviceStateMonitorProvider);
  final groupCallService = ref.watch(groupCallServiceProvider);

  // Metrics reporter that forwards quality stats to backend via signaling.
  final reporter = _SignalingMetricsReporter(groupCallService);

  final controller = TwoLoopAbr(
    peerConnectionManager: peerConnectionManager,
    qualityMonitor: qualityMonitor,
    mediaManager: mediaManager,
    deviceStateMonitor: deviceStateMonitor,
    metricsReporter: reporter,
  );

  // Wire policy updates from GroupCallService → TwoLoopAbr.
  final policySub = groupCallService.onPolicyUpdate.listen((event) {
    controller.setPolicyOverride(
      PolicyOverride(
        maxTier: _parseTier(event.maxTier),
        forceAudioOnly: event.forceAudioOnly,
        maxBitrateKbps: event.maxBitrateKbps,
        forceCodec: _parseCodec(event.forceCodec),
      ),
    );
  });

  ref.onDispose(() {
    unawaited(policySub.cancel());
    unawaited(controller.dispose());
  });
  return controller;
});

final callServiceProvider = Provider<CallService>((ref) {
  final mediaManager = ref.watch(mediaManagerProvider);
  final signalingClient = ref.watch(signalingClientProvider);
  final service = CallService(
    mediaManager: mediaManager,
    signalingClient: signalingClient,
  );

  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final callKitServiceProvider = Provider<CallKitService>((ref) {
  final callService = ref.watch(callServiceProvider);
  final service = CallKitService(callService);
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final videoSlotControllerProvider =
    Provider.family<VideoSlotController, String>((ref, roomId) {
  final speakerDetector = ref.watch(speakerDetectorProvider);
  final subscribeManager = ref.watch(subscribeManagerProvider(roomId));

  final controller = VideoSlotController(speakerDetector: speakerDetector);
  final assignmentSub = controller.onAssignmentChanged
      .listen(subscribeManager.updateFromAssignment);

  ref.onDispose(() {
    unawaited(assignmentSub.cancel());
    unawaited(controller.dispose());
  });
  return controller;
});

final groupCallServiceProvider = Provider<GroupCallService>((ref) {
  final signalingClient = ref.watch(signalingClientProvider);
  final apiClient = ref.watch(apiClientProvider);
  final mediaManager = ref.watch(mediaManagerProvider);

  final service = GroupCallService(
    signalingClient: signalingClient,
    apiClient: apiClient,
    mediaManager: mediaManager,
  );

  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final subscribeManagerProvider =
    Provider.family<SubscribeManager, String>((ref, roomId) {
  final groupCallService = ref.watch(groupCallServiceProvider);
  final manager = SubscribeManager(
    groupCallService: groupCallService,
    roomId: roomId,
  );

  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

final reconnectionManagerProvider = Provider<ReconnectionManager>((ref) {
  final config = ref.watch(appConfigProvider);
  final signalingClient = ref.watch(signalingClientProvider);
  final networkMonitor = ref.watch(networkMonitorProvider);
  final peerConnectionManager = ref.watch(peerConnectionManagerProvider);

  final manager = ReconnectionManager(
    signalingClient: signalingClient,
    peerConnectionManager: peerConnectionManager,
    networkMonitor: networkMonitor,
    config: ReconnectionConfig(
      maxAttempts: config.maxReconnectAttempts,
      backoffMs: config.reconnectBackoff,
    ),
  );

  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

final pushServiceProvider = Provider<PushService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final callKitService = ref.watch(callKitServiceProvider);

  // Keep these providers wired and initialized in the graph.
  ref.watch(callServiceProvider);
  ref.watch(nativePushHandlerProvider);

  final service = PushService(apiClient, callKitService);
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

// ---------------------------------------------------------------------------
// Policy / Metrics helpers
// ---------------------------------------------------------------------------

/// Metrics reporter that sends quality samples to the backend via
/// [GroupCallService.sendQualityMetrics].
class _SignalingMetricsReporter implements MetricsReporter {
  _SignalingMetricsReporter(this._groupCallService);
  final GroupCallService _groupCallService;

  @override
  void reportQualityMetrics(Map<String, dynamic> sample) {
    final roomId = _groupCallService.activeRoomId;
    if (roomId == null) return;
    _groupCallService.sendQualityMetrics(roomId, [sample]);
  }
}

QualityTier? _parseTier(String? tier) {
  switch (tier) {
    case 'good':
      return QualityTier.good;
    case 'fair':
      return QualityTier.fair;
    case 'poor':
      return QualityTier.poor;
    default:
      return null;
  }
}

VideoCodec? _parseCodec(String? codec) {
  switch (codec) {
    case 'vp8':
      return VideoCodec.vp8;
    case 'h264':
      return VideoCodec.h264;
    default:
      return null;
  }
}
