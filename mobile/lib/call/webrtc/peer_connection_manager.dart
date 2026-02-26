import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:lalo/call/webrtc/simulcast_config.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Manages [RTCPeerConnection] lifecycle and core WebRTC signaling helpers.
class PeerConnectionManager {
  PeerConnectionManager(
    this._iceServers, {
    this.turnOnly = false,
  });

  final List<Map<String, dynamic>> _iceServers;

  /// When true, use TURN relay-only transport policy.
  final bool turnOnly;

  webrtc.RTCPeerConnection? _peerConnection;
  bool _isClosed = false;

  bool _isRestartingIce = false;
  bool _pendingAutoRestart = false;

  final StreamController<webrtc.RTCIceCandidate> _iceCandidateController =
      StreamController<webrtc.RTCIceCandidate>.broadcast();
  final StreamController<webrtc.RTCIceConnectionState>
      _iceConnectionStateController =
      StreamController<webrtc.RTCIceConnectionState>.broadcast();
  final StreamController<webrtc.RTCTrackEvent> _trackController =
      StreamController<webrtc.RTCTrackEvent>.broadcast();
  final StreamController<webrtc.MediaStream> _removeStreamController =
      StreamController<webrtc.MediaStream>.broadcast();

  Stream<webrtc.RTCIceCandidate> get onIceCandidate =>
      _iceCandidateController.stream;

  Stream<webrtc.RTCIceConnectionState> get onIceConnectionState =>
      _iceConnectionStateController.stream;

  Stream<webrtc.RTCTrackEvent> get onTrack => _trackController.stream;

  Stream<webrtc.MediaStream> get onRemoveStream =>
      _removeStreamController.stream;

  webrtc.RTCPeerConnection get _pc {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection has not been created.');
    }
    return pc;
  }

  /// Creates and configures a peer connection.
  Future<webrtc.RTCPeerConnection> createPeerConnection() async {
    if (_isClosed) {
      throw StateError('PeerConnectionManager is already disposed.');
    }

    if (_peerConnection != null) {
      return _peerConnection!;
    }

    final configuration = <String, dynamic>{
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
      if (turnOnly) 'iceTransportPolicy': 'relay',
    };

    final pc = await webrtc.createPeerConnection(configuration);

    pc.onIceCandidate = (candidate) {
      if (!_iceCandidateController.isClosed) {
        _iceCandidateController.add(candidate);
      }
    };

    pc.onIceConnectionState = (state) {
      if (!_iceConnectionStateController.isClosed) {
        _iceConnectionStateController.add(state);
      }

      if (state == webrtc.RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _triggerAutoIceRestart();
      }
    };

    pc.onTrack = (event) {
      if (!_trackController.isClosed) {
        _trackController.add(event);
      }
    };

    pc.onRemoveStream = (stream) {
      if (!_removeStreamController.isClosed) {
        _removeStreamController.add(stream);
      }
    };

    _peerConnection = pc;
    return pc;
  }

  Future<webrtc.RTCSessionDescription> createOffer() async {
    final offer = await _pc.createOffer(<String, dynamic>{});
    return offer;
  }

  Future<webrtc.RTCSessionDescription> createAnswer() async {
    final answer = await _pc.createAnswer(<String, dynamic>{});
    return answer;
  }

  Future<void> setLocalDescription(
    webrtc.RTCSessionDescription description,
  ) async {
    await _pc.setLocalDescription(description);
  }

  Future<void> setRemoteDescription(
    webrtc.RTCSessionDescription description,
  ) async {
    await _pc.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(webrtc.RTCIceCandidate candidate) async {
    await _pc.addCandidate(candidate);
  }

  Future<void> addStream(webrtc.MediaStream stream) async {
    await _pc.addStream(stream);
  }

  /// Attempts ICE restart with backoff delays: [0ms, 1000ms, 3000ms].
  Future<void> restartIce() async {
    if (_isClosed) return;
    if (_isRestartingIce) {
      _pendingAutoRestart = true;
      return;
    }

    _isRestartingIce = true;
    const backoffsMs = <int>[0, 1000, 3000];

    try {
      for (var i = 0; i < backoffsMs.length; i++) {
        if (_isClosed) return;
        final pc = _peerConnection;
        if (pc == null) return;

        final delayMs = backoffsMs[i];
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }

        final current = pc.iceConnectionState;
        if (current ==
                webrtc.RTCIceConnectionState.RTCIceConnectionStateConnected ||
            current ==
                webrtc.RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          return;
        }

        try {
          await pc.restartIce();

          final offer = await pc.createOffer(<String, dynamic>{
            'iceRestart': true,
          });
          await pc.setLocalDescription(offer);

          return;
        } catch (_) {
          if (i == backoffsMs.length - 1) {
            rethrow;
          }
        }
      }
    } finally {
      _isRestartingIce = false;
      if (_pendingAutoRestart && !_isClosed) {
        _pendingAutoRestart = false;
        unawaited(restartIce());
      }
    }
  }

  Future<List<webrtc.StatsReport>> getStats() async {
    return _pc.getStats();
  }

  /// Returns the video [RTCRtpSender], or `null` if none exists.
  Future<webrtc.RTCRtpSender?> getVideoSender() async {
    final pc = _peerConnection;
    if (pc == null) return null;

    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        return sender;
      }
    }
    return null;
  }

  /// Adds a video track with simulcast encodings via the transceiver API.
  ///
  /// Uses [RTCRtpTransceiver] with multiple [RTCRtpEncoding] entries
  /// to publish 3 simulcast layers (high/medium/low) simultaneously.
  /// Returns the created transceiver.
  Future<webrtc.RTCRtpTransceiver> addVideoTrackWithSimulcast(
    webrtc.MediaStreamTrack videoTrack,
    webrtc.MediaStream stream, {
    SimulcastConfig config = SimulcastConfig.defaultConfig,
  }) async {
    final encodings = config.encodings.map((e) {
      return webrtc.RTCRtpEncoding(
        rid: e.rid,
        active: e.active,
        maxBitrate: e.maxBitrateKbps * 1000, // bps
        maxFramerate: e.maxFramerate,
        scaleResolutionDownBy: e.scaleResolutionDownBy,
      );
    }).toList(growable: false);

    final transceiver = await _pc.addTransceiver(
      track: videoTrack,
      kind: webrtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: webrtc.RTCRtpTransceiverInit(
        direction: webrtc.TransceiverDirection.SendOnly,
        streams: <webrtc.MediaStream>[stream],
        sendEncodings: encodings,
      ),
    );

    return transceiver;
  }

  /// Enables or disables a specific simulcast layer by RID.
  ///
  /// [rid] — the layer RID ('h', 'm', or 'l').
  /// [enabled] — whether the layer should be active.
  /// Returns `true` if the parameter was applied successfully.
  Future<bool> setSimulcastLayerEnabled(String rid, bool enabled) async {
    final sender = await getVideoSender();
    if (sender == null) return false;

    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) return false;

    var found = false;
    for (final encoding in encodings) {
      if (encoding.rid == rid) {
        encoding.active = enabled;
        found = true;
        break;
      }
    }

    if (!found) return false;

    await sender.setParameters(params);
    return true;
  }

  /// Updates encoding parameters for a specific simulcast layer.
  ///
  /// Only non-null parameters are updated. Returns `true` if applied.
  Future<bool> setSimulcastEncodingParameters({
    required String rid,
    int? maxBitrateKbps,
    int? maxFramerate,
    double? scaleResolutionDownBy,
    bool? active,
  }) async {
    final sender = await getVideoSender();
    if (sender == null) return false;

    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) return false;

    var found = false;
    for (final encoding in encodings) {
      if (encoding.rid == rid) {
        if (maxBitrateKbps != null) {
          encoding.maxBitrate = maxBitrateKbps * 1000; // bps
        }
        if (maxFramerate != null) {
          encoding.maxFramerate = maxFramerate;
        }
        if (scaleResolutionDownBy != null) {
          encoding.scaleResolutionDownBy = scaleResolutionDownBy;
        }
        if (active != null) {
          encoding.active = active;
        }
        found = true;
        break;
      }
    }

    if (!found) return false;

    await sender.setParameters(params);
    return true;
  }

  /// Returns all current simulcast encoding parameters from the video sender.
  ///
  /// Returns empty list if no video sender or no encodings configured.
  Future<List<Map<String, dynamic>>> getSimulcastEncodings() async {
    final sender = await getVideoSender();
    if (sender == null) return const <Map<String, dynamic>>[];

    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    return encodings.map((e) {
      return <String, dynamic>{
        'rid': e.rid,
        'active': e.active,
        'maxBitrate': e.maxBitrate,
        'maxFramerate': e.maxFramerate,
        'scaleResolutionDownBy': e.scaleResolutionDownBy,
      };
    }).toList(growable: false);
  }

  /// Applies encoding parameters to the video sender.
  ///
  /// [maxBitrateKbps] – target max bitrate in kbps.
  /// [maxFramerate] – target max framerate.
  /// [scaleResolutionDownBy] – resolution downscale factor (1.0 = original).
  Future<bool> setVideoEncodingParameters({
    int? maxBitrateKbps,
    int? maxFramerate,
    double? scaleResolutionDownBy,
  }) async {
    final sender = await getVideoSender();
    if (sender == null) return false;

    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) return false;

    for (final encoding in encodings) {
      if (maxBitrateKbps != null) {
        encoding.maxBitrate = maxBitrateKbps * 1000; // bps
      }
      if (maxFramerate != null) {
        encoding.maxFramerate = maxFramerate;
      }
      if (scaleResolutionDownBy != null) {
        encoding.scaleResolutionDownBy = scaleResolutionDownBy;
      }
    }

    await sender.setParameters(params);
    return true;
  }

  /// Returns the audio [RTCRtpSender], or `null` if none exists.
  Future<webrtc.RTCRtpSender?> getAudioSender() async {
    final pc = _peerConnection;
    if (pc == null) return null;

    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'audio') {
        return sender;
      }
    }
    return null;
  }

  /// Applies audio encoding parameters to the audio sender.
  ///
  /// [maxBitrateKbps] – target max bitrate in kbps (Opus).
  /// Returns `true` if the parameters were applied successfully.
  Future<bool> setAudioEncodingParameters({
    int? maxBitrateKbps,
  }) async {
    final sender = await getAudioSender();
    if (sender == null) return false;

    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) return false;

    for (final encoding in encodings) {
      if (maxBitrateKbps != null) {
        encoding.maxBitrate = maxBitrateKbps * 1000; // bps
      }
    }

    await sender.setParameters(params);
    return true;
  }

  // -- Audio Opus codec parameters --

  /// Current Opus SDP parameters applied during renegotiation.
  AudioOpusConfig _opusConfig = const AudioOpusConfig();

  /// Returns the current Opus config.
  AudioOpusConfig get opusConfig => _opusConfig;

  /// Applies Opus codec parameters (FEC, ptime) via SDP renegotiation.
  ///
  /// This triggers a local offer/answer cycle with munged SDP to change
  /// codec-level parameters that can't be set via RTCRtpSender.setParameters.
  ///
  /// [config] – desired Opus configuration.
  /// Returns `true` if renegotiation completed successfully.
  Future<bool> applyAudioOpusConfig(AudioOpusConfig config) async {
    final pc = _peerConnection;
    if (pc == null || _isClosed) return false;

    // Skip if nothing changed.
    if (config == _opusConfig) return true;

    _opusConfig = config;

    try {
      final offer = await pc.createOffer(<String, dynamic>{});
      final mungedOffer = webrtc.RTCSessionDescription(
        _mungeOpusSdp(offer.sdp ?? '', config),
        offer.type,
      );
      await pc.setLocalDescription(mungedOffer);

      // In a real call the answer comes from the remote peer. For local-only
      // renegotiation (codec param change) the remote answer will carry the
      // negotiated params. We don't await the full round-trip here — the
      // caller is responsible for signaling the new offer to the remote.
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Munges SDP to set Opus-specific parameters.
  ///
  /// Modifies the `a=fmtp:<opus-pt>` line and inserts/updates `a=ptime:`.
  static String _mungeOpusSdp(String sdp, AudioOpusConfig config) {
    final lines = sdp.split('\r\n');
    final result = <String>[];
    String? opusPayloadType;
    var ptimeInserted = false;

    // Find Opus payload type from rtpmap line.
    for (final line in lines) {
      // e.g. "a=rtpmap:111 opus/48000/2"
      final match = RegExp(r'^a=rtpmap:(\d+)\s+opus/').firstMatch(line);
      if (match != null) {
        opusPayloadType = match.group(1);
        break;
      }
    }

    for (final line in lines) {
      // Update Opus fmtp line.
      if (opusPayloadType != null &&
          line.startsWith('a=fmtp:$opusPayloadType ')) {
        var fmtp = line;
        fmtp =
            _setFmtpParam(fmtp, 'useinbandfec', config.fecEnabled ? '1' : '0');
        fmtp = _setFmtpParam(fmtp, 'usedtx', config.dtxEnabled ? '1' : '0');
        result.add(fmtp);
        continue;
      }

      // Replace existing ptime.
      if (line.startsWith('a=ptime:')) {
        result.add('a=ptime:${config.packetTimeMs}');
        ptimeInserted = true;
        continue;
      }

      result.add(line);

      // Insert ptime after the Opus fmtp line if not yet present.
      if (!ptimeInserted &&
          opusPayloadType != null &&
          line.startsWith('a=fmtp:$opusPayloadType ')) {
        // Already handled above in the fmtp replacement, insert ptime after.
      }
    }

    // If no existing ptime line was found, insert before the first m=audio.
    if (!ptimeInserted) {
      final audioIdx = result.indexWhere((l) => l.startsWith('m=audio'));
      if (audioIdx >= 0) {
        // Insert after the m=audio line.
        result.insert(audioIdx + 1, 'a=ptime:${config.packetTimeMs}');
      }
    }

    return result.join('\r\n');
  }

  /// Sets or updates a key=value parameter in an fmtp line.
  static String _setFmtpParam(String fmtpLine, String key, String value) {
    final pattern = RegExp('$key=\\d+');
    if (pattern.hasMatch(fmtpLine)) {
      return fmtpLine.replaceAll(pattern, '$key=$value');
    }
    return '$fmtpLine;$key=$value';
  }

  /// Test-only accessor for SDP munging.
  @visibleForTesting
  static String mungeOpusSdpForTest(String sdp, AudioOpusConfig config) =>
      _mungeOpusSdp(sdp, config);

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    final pc = _peerConnection;
    _peerConnection = null;

    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
  }

  Future<void> dispose() async {
    await close();
    await _iceCandidateController.close();
    await _iceConnectionStateController.close();
    await _trackController.close();
    await _removeStreamController.close();
  }

  void _triggerAutoIceRestart() {
    if (_isClosed) return;
    unawaited(restartIce());
  }
}

/// Opus codec configuration for SDP renegotiation.
///
/// Controls FEC, DTX, and packet time — parameters that require SDP
/// manipulation and can't be set via RTCRtpSender.setParameters.
class AudioOpusConfig {
  const AudioOpusConfig({
    this.fecEnabled = true,
    this.dtxEnabled = false,
    this.packetTimeMs = 20,
  });

  /// Whether Opus in-band FEC is enabled.
  final bool fecEnabled;

  /// Whether Opus discontinuous transmission is enabled.
  final bool dtxEnabled;

  /// Opus packet time in milliseconds (20 or 40).
  final int packetTimeMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioOpusConfig &&
          fecEnabled == other.fecEnabled &&
          dtxEnabled == other.dtxEnabled &&
          packetTimeMs == other.packetTimeMs;

  @override
  int get hashCode => Object.hash(fecEnabled, dtxEnabled, packetTimeMs);

  @override
  String toString() =>
      'AudioOpusConfig(fec=$fecEnabled, dtx=$dtxEnabled, ptime=${packetTimeMs}ms)';
}
