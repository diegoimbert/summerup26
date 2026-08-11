import 'dart:convert';

import 'package:http/http.dart' as http;

import 'exceptions.dart';

/// Supplies a bearer token to the HTTP providers.
///
/// Kept separate from the providers so the OAuth dance (and where tokens are
/// stored) can change without touching Drive or Notion code.
abstract class TokenProvider {
  /// Returns a usable access token. [forceRefresh] is set by providers after
  /// a 401, meaning "the token you gave me was rejected, get another".
  Future<String> accessToken({bool forceRefresh = false});
}

/// A token that never changes: Notion internal integration secrets, or a
/// short-lived Drive token pasted in for testing.
class StaticTokenProvider implements TokenProvider {
  const StaticTokenProvider(this.token);

  final String token;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async => token;
}

/// Exchanges a long-lived refresh token for access tokens, caching until just
/// before expiry.
///
/// Concurrent callers share one in-flight refresh, so a burst of parallel
/// requests after expiry does not fire N token calls (and risk the provider
/// invalidating the older results).
class RefreshingTokenProvider implements TokenProvider {
  RefreshingTokenProvider({
    required this.tokenEndpoint,
    required this.clientId,
    required this.refreshToken,
    this.clientSecret,
    this.providerId = 'oauth',
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Google's is `https://oauth2.googleapis.com/token`.
  final Uri tokenEndpoint;
  final String clientId;

  /// Omitted for PKCE/native clients that have no secret.
  final String? clientSecret;
  final String refreshToken;
  final String providerId;

  final http.Client _http;
  final bool _ownsClient;

  String? _cachedToken;
  DateTime? _expiresAt;
  Future<String>? _inFlight;

  /// Refresh this far ahead of the stated expiry, so a token cannot lapse
  /// while a request is in flight.
  static const _expiryMargin = Duration(minutes: 2);

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    if (!forceRefresh && _isCacheValid) {
      return Future.value(_cachedToken);
    }
    // A second caller arriving mid-refresh waits on the same future. A caller
    // that just got a 401 must not reuse it, though — that future may resolve
    // to the very token that was rejected.
    final pending = _inFlight;
    if (pending != null && !forceRefresh) return pending;

    final refresh = _refresh();
    _inFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_inFlight, refresh)) _inFlight = null;
    });
  }

  bool get _isCacheValid {
    final token = _cachedToken;
    final expiry = _expiresAt;
    if (token == null || expiry == null) return false;
    return DateTime.now().isBefore(expiry.subtract(_expiryMargin));
  }

  Future<String> _refresh() async {
    http.Response response;
    try {
      response = await _http.post(
        tokenEndpoint,
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': clientId,
          if (clientSecret != null) 'client_secret': clientSecret!,
        },
      );
    } catch (error) {
      throw TransientException(
        providerId,
        'Token refresh failed: $error',
        cause: error,
      );
    }

    if (response.statusCode != 200) {
      throw AuthException(
        providerId,
        'Token refresh rejected: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final token = payload['access_token'] as String?;
    if (token == null) {
      throw AuthException(providerId, 'Token response had no access_token');
    }

    // `expires_in` is optional; assume a conservative hour when absent.
    final expiresIn = payload['expires_in'];
    final lifetime = expiresIn is num
        ? Duration(seconds: expiresIn.toInt())
        : const Duration(hours: 1);

    _cachedToken = token;
    _expiresAt = DateTime.now().add(lifetime);
    return token;
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
