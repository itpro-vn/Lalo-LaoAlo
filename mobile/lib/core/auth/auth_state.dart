import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lalo/core/auth/token_manager.dart';
import 'package:lalo/core/network/api_client.dart';
import 'package:lalo/core/providers/providers.dart';

/// Authentication state for the app.
enum AuthState {
  unauthenticated,
  authenticating,
  authenticated,
}

/// Provides [AuthNotifier] managing login/logout state transitions.
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final tokenManager = ref.watch(tokenManagerProvider);
  final apiClient = ref.watch(apiClientProvider);
  return AuthNotifier(
    tokenManager: tokenManager,
    apiClient: apiClient,
  );
});

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({
    required TokenManager tokenManager,
    required ApiClient apiClient,
  })  : _tokenManager = tokenManager,
        _apiClient = apiClient,
        super(AuthState.unauthenticated);

  final TokenManager _tokenManager;
  final ApiClient _apiClient;

  Future<void> checkAuth() async {
    final authenticated = await _tokenManager.isAuthenticated;
    state = authenticated ? AuthState.authenticated : AuthState.unauthenticated;
  }

  Future<void> login(String email, String password) async {
    state = AuthState.authenticating;

    try {
      final response = await _apiClient.login(email, password);
      final accessToken = _readString(response, const <String>[
        'accessToken',
        'access_token',
        'token',
      ]);
      final refreshToken = _readString(response, const <String>[
        'refreshToken',
        'refresh_token',
      ]);

      if (accessToken == null || accessToken.isEmpty) {
        throw const FormatException('Missing access token');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw const FormatException('Missing refresh token');
      }

      await _tokenManager.saveTokens(accessToken, refreshToken);
      state = AuthState.authenticated;
    } on DioException catch (error) {
      state = AuthState.unauthenticated;
      throw Exception(_extractErrorMessage(error));
    } on FormatException catch (error) {
      state = AuthState.unauthenticated;
      throw Exception(error.message);
    } catch (_) {
      state = AuthState.unauthenticated;
      throw Exception('Login failed. Please try again.');
    }
  }

  Future<void> logout() async {
    await _tokenManager.clearTokens();
    state = AuthState.unauthenticated;
  }

  String _extractErrorMessage(DioException error) {
    final data = error.response?.data;

    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final message = _readString(map, const <String>[
        'message',
        'error',
        'detail',
      ]);
      if (message != null && message.isNotEmpty) {
        return message;
      }
    }

    return 'Login failed. Please check your credentials.';
  }

  String? _readString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}
