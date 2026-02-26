import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages access and refresh tokens with secure persistence and auto-refresh.
class TokenManager {
  /// Creates a [TokenManager].
  TokenManager({
    FlutterSecureStorage? storage,
    Dio? dio,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _dio = dio;

  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';

  final FlutterSecureStorage _storage;
  Dio? _dio;
  Timer? _refreshTimer;

  /// Registers the API client used by scheduled token refresh.
  void setDio(Dio dio) {
    _dio = dio;
  }

  /// Saves access and refresh tokens, then schedules auto-refresh.
  Future<void> saveTokens(
    String accessToken,
    String refreshToken,
  ) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    _scheduleRefresh();
  }

  /// Reads the persisted access token.
  Future<String?> getAccessToken() {
    return _storage.read(key: _accessTokenKey);
  }

  /// Reads the persisted refresh token.
  Future<String?> getRefreshToken() {
    return _storage.read(key: _refreshTokenKey);
  }

  /// Returns whether a non-expired access token is available.
  Future<bool> get isAuthenticated async {
    final accessToken = await getAccessToken();
    if (accessToken == null || accessToken.isEmpty) {
      return false;
    }

    final expiry = parseJwtExpiry(accessToken);
    if (expiry == null) {
      return false;
    }

    return DateTime.now().toUtc().isBefore(expiry);
  }

  /// Clears all persisted tokens and cancels any scheduled refresh.
  Future<void> clearTokens() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  /// Attempts to refresh the access token using the refresh token.
  ///
  /// Expects endpoint response to include `accessToken` and optionally
  /// `refreshToken`.
  Future<String?> refreshAccessToken(Dio dio) async {
    setDio(dio);

    final refreshToken = await getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return null;
    }

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/api/v1/auth/refresh',
        data: <String, dynamic>{
          'refreshToken': refreshToken,
        },
      );

      final data = response.data;
      if (data == null) {
        return null;
      }

      final newAccessToken = data['accessToken'] as String?;
      if (newAccessToken == null || newAccessToken.isEmpty) {
        return null;
      }

      final newRefreshToken = (data['refreshToken'] as String?) ?? refreshToken;
      await saveTokens(newAccessToken, newRefreshToken);
      return newAccessToken;
    } on DioException {
      return null;
    }
  }

  /// Schedules token refresh one minute before JWT expiry.
  Future<void> _scheduleRefresh() async {
    _refreshTimer?.cancel();

    final accessToken = await getAccessToken();
    if (accessToken == null || accessToken.isEmpty) {
      return;
    }

    final expiry = parseJwtExpiry(accessToken);
    if (expiry == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final refreshAt = expiry.subtract(const Duration(minutes: 1));
    var delay = refreshAt.difference(now);
    if (delay.isNegative) {
      delay = Duration.zero;
    }

    _refreshTimer = Timer(delay, () async {
      final dio = _dio;
      if (dio == null) {
        return;
      }

      await refreshAccessToken(dio);
    });
  }

  /// Parses JWT `exp` claim and returns its UTC expiry timestamp.
  DateTime? parseJwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length < 2) {
      return null;
    }

    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final exp = map['exp'];

      if (exp is int) {
        return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      }

      if (exp is num) {
        return DateTime.fromMillisecondsSinceEpoch(
          exp.toInt() * 1000,
          isUtc: true,
        );
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// Releases internal resources.
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }
}
