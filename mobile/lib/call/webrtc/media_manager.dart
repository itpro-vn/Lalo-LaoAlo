import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:permission_handler/permission_handler.dart';

/// Desired audio output route.
enum AudioOutput {
  earpiece,
  speaker,
  bluetooth,
}

/// Current active camera side.
enum CameraFacing {
  front,
  back,
}

/// Manages local media permissions and camera/microphone lifecycle.
class MediaManager {
  webrtc.MediaStream? _localStream;
  bool _isMicrophoneMuted = false;
  bool _isCameraEnabled = true;
  CameraFacing _currentCamera = CameraFacing.front;
  AudioOutput _audioOutput = AudioOutput.earpiece;

  webrtc.MediaStream? get localStream => _localStream;

  bool get isMicrophoneMuted => _isMicrophoneMuted;

  bool get isCameraEnabled => _isCameraEnabled;

  CameraFacing get currentCamera => _currentCamera;

  /// Requests camera and microphone permissions.
  Future<void> initialize() async {
    final statuses = await <Permission>[
      Permission.camera,
      Permission.microphone,
    ].request();

    final camera = statuses[Permission.camera];
    final microphone = statuses[Permission.microphone];

    final cameraGranted = camera?.isGranted ?? false;
    final micGranted = microphone?.isGranted ?? false;

    if (!cameraGranted || !micGranted) {
      throw StateError(
        'Camera and microphone permissions are required for calling.',
      );
    }
  }

  /// Starts local capture with 720p/30fps video and voice-optimized audio.
  Future<webrtc.MediaStream> startLocalStream({
    bool video = true,
    bool audio = true,
  }) async {
    await stopLocalStream();

    final constraints = <String, dynamic>{
      'audio': audio
          ? <String, dynamic>{
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            }
          : false,
      'video': video
          ? <String, dynamic>{
              'facingMode': 'user',
              'width': <String, dynamic>{'ideal': 1280},
              'height': <String, dynamic>{'ideal': 720},
              'frameRate': <String, dynamic>{'ideal': 30},
            }
          : false,
    };

    final stream = await webrtc.navigator.mediaDevices.getUserMedia(
      constraints,
    );

    _localStream = stream;
    _currentCamera = CameraFacing.front;
    _isMicrophoneMuted = false;
    _isCameraEnabled = video;

    await setAudioOutput(_audioOutput);
    return stream;
  }

  Future<void> stopLocalStream() async {
    final stream = _localStream;
    if (stream == null) return;

    for (final track in stream.getTracks()) {
      track.stop();
    }

    await stream.dispose();
    _localStream = null;
  }

  /// Switches between front and back camera.
  Future<bool> switchCamera() async {
    final stream = _localStream;
    if (stream == null) return false;

    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return false;

    final track = videoTracks.first;
    await webrtc.Helper.switchCamera(track);

    _currentCamera = _currentCamera == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    return true;
  }

  /// Toggles microphone mute state.
  ///
  /// Returns the new mute state.
  bool toggleMicrophone() {
    final stream = _localStream;
    if (stream == null) {
      _isMicrophoneMuted = !_isMicrophoneMuted;
      return _isMicrophoneMuted;
    }

    _isMicrophoneMuted = !_isMicrophoneMuted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !_isMicrophoneMuted;
    }
    return _isMicrophoneMuted;
  }

  /// Toggles camera enabled state.
  ///
  /// Returns the new camera enabled state.
  bool toggleCamera() {
    final stream = _localStream;
    if (stream == null) {
      _isCameraEnabled = !_isCameraEnabled;
      return _isCameraEnabled;
    }

    _isCameraEnabled = !_isCameraEnabled;
    for (final track in stream.getVideoTracks()) {
      track.enabled = _isCameraEnabled;
    }
    return _isCameraEnabled;
  }

  /// Sets preferred audio output route.
  ///
  /// For bluetooth on mobile, route selection is OS-managed; this method
  /// prefers non-speaker output and selects a bluetooth device where supported.
  Future<void> setAudioOutput(AudioOutput output) async {
    _audioOutput = output;

    switch (output) {
      case AudioOutput.speaker:
        await webrtc.Helper.setSpeakerphoneOn(true);
        return;
      case AudioOutput.earpiece:
        await webrtc.Helper.setSpeakerphoneOn(false);
        return;
      case AudioOutput.bluetooth:
        await webrtc.Helper.setSpeakerphoneOn(false);

        try {
          final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
          webrtc.MediaDeviceInfo? bluetoothOutput;
          for (final device in devices) {
            if (device.kind == 'audiooutput' &&
                device.label.toLowerCase().contains('bluetooth')) {
              bluetoothOutput = device;
              break;
            }
          }

          if (bluetoothOutput != null && bluetoothOutput.deviceId.isNotEmpty) {
            await webrtc.Helper.selectAudioOutput(bluetoothOutput.deviceId);
          }
        } catch (_) {
          // Non-fatal: bluetooth routing falls back to OS policy.
        }
        return;
    }
  }

  Future<void> dispose() async {
    await stopLocalStream();
  }
}
