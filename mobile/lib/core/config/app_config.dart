/// Application configuration for call client behavior and endpoints.
class AppConfig {
  /// Creates an [AppConfig].
  const AppConfig({
    required this.signalingUrl,
    required this.apiBaseUrl,
    required this.iceServers,
    this.ringTimeoutSeconds = 45,
    this.iceTimeoutSeconds = 15,
    this.maxReconnectAttempts = 3,
    this.reconnectBackoff = const [0, 1000, 3000],
    this.statsIntervalMs = 5000,
    this.abrLoopIntervalMs = 1000,
    this.audioOnlyThresholdKbps = 100,
    this.videoResumeThresholdKbps = 200,
    this.videoResumeStableSeconds = 10,
  });

  /// WSS endpoint for signaling.
  final String signalingUrl;

  /// REST API base URL.
  final String apiBaseUrl;

  /// WebRTC ICE server configuration.
  ///
  /// Each entry should include standard keys such as `urls`, `username`,
  /// and `credential` where applicable.
  final List<Map<String, dynamic>> iceServers;

  /// Maximum duration to ring before timing out.
  final int ringTimeoutSeconds;

  /// Timeout for ICE connectivity establishment.
  final int iceTimeoutSeconds;

  /// Maximum reconnect attempts when call drops.
  final int maxReconnectAttempts;

  /// Backoff delays (milliseconds) for reconnect attempts.
  final List<int> reconnectBackoff;

  /// Interval in milliseconds for periodic stats collection.
  final int statsIntervalMs;

  /// ABR fast-loop interval in milliseconds.
  final int abrLoopIntervalMs;

  /// Below this bandwidth (kbps), video is turned off (audio-only mode).
  final int audioOnlyThresholdKbps;

  /// Above this bandwidth (kbps) for [videoResumeStableSeconds], video resumes.
  final int videoResumeThresholdKbps;

  /// How long bandwidth must stay above resume threshold before re-enabling video.
  final int videoResumeStableSeconds;

  /// Development-friendly configuration.
  factory AppConfig.development() {
    return const AppConfig(
      signalingUrl: 'wss://localhost/ws',
      apiBaseUrl: 'https://localhost/api/v1',
      iceServers: [
        {
          'urls': ['stun:stun.l.google.com:19302'],
        },
        {
          'urls': ['turn:localhost:3478?transport=udp'],
          'username': 'lalo-dev',
          'credential': 'lalo-dev-secret',
        },
      ],
    );
  }

  /// Production configuration.
  factory AppConfig.production() {
    return const AppConfig(
      signalingUrl: 'wss://localhost/ws',
      apiBaseUrl: 'https://localhost/api/v1',
      iceServers: [
        {
          'urls': ['stun:stun.l.google.com:19302'],
        },
        {
          'urls': ['turn:turn.example.com:3478?transport=udp'],
          'username': 'lalo',
          'credential': 'replace-with-runtime-secret',
        },
        {
          'urls': ['turns:turn.example.com:5349?transport=tcp'],
          'username': 'lalo',
          'credential': 'replace-with-runtime-secret',
        },
      ],
    );
  }
}
