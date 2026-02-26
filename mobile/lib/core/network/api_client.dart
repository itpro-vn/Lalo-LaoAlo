import 'package:dio/dio.dart';

import 'package:lalo/core/auth/token_manager.dart';

/// REST API client for call/session backend operations.
class ApiClient {
  ApiClient(
    String baseUrl,
    TokenManager tokenManager,
  )   : _tokenManager = tokenManager,
        _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
            headers: const <String, String>{
              'Content-Type': 'application/json',
            },
          ),
        ),
        _refreshDio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
            headers: const <String, String>{
              'Content-Type': 'application/json',
            },
          ),
        ) {
    _tokenManager.setDio(_refreshDio);
    _dio.interceptors.add(
      QueuedInterceptorsWrapper(
        onRequest: _onRequest,
        onError: _onError,
      ),
    );
  }

  final Dio _dio;
  final Dio _refreshDio;
  final TokenManager _tokenManager;

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokenManager.getAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final requestOptions = err.requestOptions;
    final statusCode = err.response?.statusCode;

    if (statusCode != 401 || requestOptions.extra['retried'] == true) {
      handler.next(err);
      return;
    }

    final refreshedToken = await _tokenManager.refreshAccessToken(_refreshDio);
    if (refreshedToken == null || refreshedToken.isEmpty) {
      handler.next(err);
      return;
    }

    try {
      final response = await _dio.fetch<dynamic>(
        _copyRequestOptions(
          requestOptions,
          headers: <String, dynamic>{
            ...requestOptions.headers,
            'Authorization': 'Bearer $refreshedToken',
          },
          extra: <String, dynamic>{
            ...requestOptions.extra,
            'retried': true,
          },
        ),
      );
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  RequestOptions _copyRequestOptions(
    RequestOptions requestOptions, {
    required Map<String, dynamic> headers,
    required Map<String, dynamic> extra,
  }) {
    return RequestOptions(
      path: requestOptions.path,
      method: requestOptions.method,
      data: requestOptions.data,
      queryParameters:
          Map<String, dynamic>.from(requestOptions.queryParameters),
      baseUrl: requestOptions.baseUrl,
      connectTimeout: requestOptions.connectTimeout,
      sendTimeout: requestOptions.sendTimeout,
      receiveTimeout: requestOptions.receiveTimeout,
      responseType: requestOptions.responseType,
      contentType: requestOptions.contentType,
      validateStatus: requestOptions.validateStatus,
      receiveDataWhenStatusError: requestOptions.receiveDataWhenStatusError,
      followRedirects: requestOptions.followRedirects,
      maxRedirects: requestOptions.maxRedirects,
      requestEncoder: requestOptions.requestEncoder,
      responseDecoder: requestOptions.responseDecoder,
      listFormat: requestOptions.listFormat,
      headers: headers,
      extra: extra,
    );
  }

  Future<Map<String, dynamic>> createSession(
    String calleeId,
    String callType,
    bool hasVideo,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/calls/sessions',
      data: <String, dynamic>{
        'calleeId': calleeId,
        'callType': callType,
        'hasVideo': hasVideo,
      },
    );

    return _extractMap(response.data, context: 'createSession');
  }

  Future<Map<String, dynamic>> joinSession(
    String callId,
    String role,
    bool hasVideo,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/calls/sessions/$callId/join',
      data: <String, dynamic>{
        'role': role,
        'hasVideo': hasVideo,
      },
    );

    return _extractMap(response.data, context: 'joinSession');
  }

  Future<void> leaveSession(String callId) async {
    await _dio.post<void>('/calls/sessions/$callId/leave');
  }

  Future<void> endSession(String callId, String reason) async {
    await _dio.post<void>(
      '/calls/sessions/$callId/end',
      data: <String, dynamic>{'reason': reason},
    );
  }

  Future<Map<String, dynamic>> getSession(String callId) async {
    final response =
        await _dio.get<Map<String, dynamic>>('/calls/sessions/$callId');
    return _extractMap(response.data, context: 'getSession');
  }

  Future<void> updateMediaState(
    String callId,
    bool audioEnabled,
    bool videoEnabled,
  ) async {
    await _dio.patch<void>(
      '/calls/sessions/$callId/media',
      data: <String, dynamic>{
        'audioEnabled': audioEnabled,
        'videoEnabled': videoEnabled,
      },
    );
  }

  Future<Map<String, dynamic>> getTurnCredentials() async {
    final response =
        await _dio.get<Map<String, dynamic>>('/calls/turn-credentials');
    return _extractMap(response.data, context: 'getTurnCredentials');
  }

  /// Creates a group room.
  Future<Map<String, dynamic>> createRoom(
    List<String> participants,
    String callType,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/rooms',
      data: <String, dynamic>{
        'participants': participants,
        'call_type': callType,
      },
    );

    return _extractMap(response.data, context: 'createRoom');
  }

  /// Joins an existing group room.
  Future<Map<String, dynamic>> joinRoom(String roomId) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/rooms/$roomId/join',
    );
    return _extractMap(response.data, context: 'joinRoom');
  }

  /// Leaves a group room.
  Future<void> leaveRoom(String roomId) async {
    await _dio.post<void>('/api/v1/rooms/$roomId/leave');
  }

  /// Invites users to a group room.
  Future<void> inviteToRoom(String roomId, List<String> invitees) async {
    await _dio.post<void>(
      '/api/v1/rooms/$roomId/invite',
      data: <String, dynamic>{
        'invitees': invitees,
      },
    );
  }

  /// Ends a group room.
  Future<void> endRoom(String roomId) async {
    await _dio.post<void>('/api/v1/rooms/$roomId/end');
  }

  /// Fetches current room participants.
  Future<List<Map<String, dynamic>>> getRoomParticipants(String roomId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/rooms/$roomId/participants',
    );
    final payload = response.data?['data'] ?? response.data;
    if (payload is! List) {
      throw StateError(
        'Invalid response body in getRoomParticipants: expected list',
      );
    }

    return payload
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<void> registerPushToken(
    String deviceId,
    String platform,
    String pushToken, {
    String? voipToken,
  }) async {
    await _dio.post<void>(
      '/devices/push-tokens',
      data: <String, dynamic>{
        'deviceId': deviceId,
        'platform': platform,
        'pushToken': pushToken,
        if (voipToken != null && voipToken.isNotEmpty) 'voipToken': voipToken,
      },
    );
  }

  Future<void> unregisterPushToken(String deviceId) async {
    await _dio.delete<void>('/devices/push-tokens/$deviceId');
  }

  Map<String, dynamic> _extractMap(
    Map<String, dynamic>? data, {
    required String context,
  }) {
    if (data == null) {
      throw StateError('Empty response body in $context');
    }

    final payload = data['data'] ?? data;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }

    throw StateError('Invalid response body in $context: expected object');
  }

  void dispose() {
    _dio.close(force: true);
    _refreshDio.close(force: true);
  }
}
