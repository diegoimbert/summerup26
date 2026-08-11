import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'exceptions.dart';

/// Thin HTTP layer shared by the remote providers.
///
/// Handles the three things every call needs and no provider should repeat:
/// attaching the bearer token (and retrying once with a fresh one after a
/// 401), backing off on throttling, and turning transport/status failures
/// into [IntegrationException]s.
class RestClient {
  RestClient({
    required this.providerId,
    required this.tokenProvider,
    this.defaultHeaders = const {},
    this.maxAttempts = 3,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String providerId;
  final TokenProvider tokenProvider;

  /// Sent on every request — Notion's `Notion-Version`, for instance.
  final Map<String, String> defaultHeaders;

  /// Total tries per request, including the first.
  final int maxAttempts;

  final http.Client _http;
  final bool _ownsClient;

  Future<http.Response> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    String? nodeId,
  }) async {
    // A retried POST could duplicate a create, so server errors are only
    // retried for methods that are safe to repeat. 429 is different: it means
    // the request was rejected, not applied, so it is always retryable.
    final idempotent = method == 'GET' || method == 'HEAD';
    var refreshed = false;

    for (var attempt = 1;; attempt++) {
      final response = await _sendOnce(
        method,
        url,
        headers: headers,
        body: body,
        forceRefreshToken: refreshed,
      );

      if (response.statusCode < 400) return response;

      // One retry with a fresh token: the cached one may have been revoked
      // early, which no expiry check can predict.
      if (response.statusCode == 401 && !refreshed) {
        refreshed = true;
        continue;
      }

      final retryable = response.statusCode == 429 ||
          (idempotent && response.statusCode >= 500);
      if (retryable && attempt < maxAttempts) {
        await Future<void>.delayed(_backoff(response, attempt));
        continue;
      }

      throw _toException(response, nodeId);
    }
  }

  Future<http.Response> _sendOnce(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    required bool forceRefreshToken,
  }) async {
    final token = await tokenProvider.accessToken(forceRefresh: forceRefreshToken);
    final request = http.Request(method, url)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        ...defaultHeaders,
        ...?headers,
      });
    if (body != null) request.bodyBytes = Uint8List.fromList(body);

    try {
      return await http.Response.fromStream(await _http.send(request));
    } on http.ClientException catch (error) {
      throw TransientException(
        providerId,
        'Request to ${url.path} failed: ${error.message}',
        cause: error,
      );
    }
  }

  /// JSON request/response convenience. Returns the decoded object, or an
  /// empty map for the 204s that deletes tend to produce.
  Future<Map<String, dynamic>> json(
    String method,
    Uri url, {
    Object? body,
    Map<String, String>? headers,
    String? nodeId,
  }) async {
    final response = await send(
      method,
      url,
      nodeId: nodeId,
      headers: {
        if (body != null) 'Content-Type': 'application/json',
        ...?headers,
      },
      body: body == null ? null : utf8.encode(jsonEncode(body)),
    );

    if (response.bodyBytes.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw IntegrationException(
        providerId,
        'Expected a JSON object from ${url.path}, got ${decoded.runtimeType}',
      );
    }
    return decoded;
  }

  Duration _backoff(http.Response response, int attempt) {
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header.trim());
    if (seconds != null) return Duration(seconds: seconds);
    // 0.5s, 1s, 2s … — no jitter, since a single desktop client is not a
    // thundering herd.
    return Duration(milliseconds: 500 * (1 << (attempt - 1)));
  }

  IntegrationException _toException(http.Response response, String? nodeId) {
    final status = response.statusCode;
    final detail = _errorDetail(response);

    switch (status) {
      case 401:
        return AuthException(providerId, detail, statusCode: status);
      case 403:
        // Google reports quota exhaustion as 403 with a reason in the body,
        // which callers should treat as throttling rather than a real denial.
        final throttled = detail.contains('rateLimitExceeded') ||
            detail.contains('userRateLimitExceeded') ||
            detail.contains('quotaExceeded');
        return throttled
            ? RateLimitException(providerId, detail, statusCode: status)
            : PermissionException(providerId, detail, statusCode: status);
      case 404:
        return nodeId != null
            ? NodeNotFoundException(providerId, nodeId, statusCode: status)
            : IntegrationException(providerId, detail, statusCode: status);
      case 409:
        return ConflictException(providerId, detail, statusCode: status);
      case 429:
        final header = response.headers['retry-after'];
        final seconds = header == null ? null : int.tryParse(header.trim());
        return RateLimitException(
          providerId,
          detail,
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
          statusCode: status,
        );
      default:
        if (status >= 500) {
          return TransientException(providerId, detail, statusCode: status);
        }
        return IntegrationException(providerId, detail, statusCode: status);
    }
  }

  /// Pulls the human-readable part out of a provider error envelope, falling
  /// back to the raw body.
  String _errorDetail(http.Response response) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        // Google: {"error": {"message": ...}}. Notion: {"message": ..., "code": ...}.
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (decoded['message'] is String) {
          final code = decoded['code'];
          final message = decoded['message'] as String;
          return code is String ? '$message ($code)' : message;
        }
      }
    } on FormatException {
      // Not JSON — HTML error pages happen at the edge.
    }
    return body.isEmpty ? 'HTTP ${response.statusCode}' : body;
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
