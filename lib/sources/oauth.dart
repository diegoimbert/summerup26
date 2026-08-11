import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// The OAuth client Kandoo identifies itself with.
///
/// Supplied at build time, never by the user. See [BuiltInOAuthClients].
class OAuthClient {
  const OAuthClient({
    required this.clientId,
    this.clientSecret,
    this.tokenProxy,
  });

  final String clientId;

  /// Only set for providers that require it and only where it can be held
  /// safely; prefer [tokenProxy] in shipped builds.
  final String? clientSecret;

  /// An endpoint that performs the code-for-token exchange server-side, so the
  /// client secret never ships inside the app.
  final Uri? tokenProxy;
}

class OAuthException implements Exception {
  OAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How a provider expects the client credentials on the token request.
enum TokenAuthStyle {
  /// `client_id` and `client_secret` as form fields (Google).
  requestBody,

  /// HTTP Basic `client_id:client_secret` (Notion).
  basicAuth,
}

/// Everything provider-specific about an authorization-code flow.
class OAuthProvider {
  const OAuthProvider({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.scopes = const [],
    this.usePkce = true,
    this.tokenAuthStyle = TokenAuthStyle.requestBody,
    this.extraAuthParameters = const {},
    this.redirectPort = 53682,
  });

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final List<String> scopes;
  final bool usePkce;
  final TokenAuthStyle tokenAuthStyle;
  final Map<String, String> extraAuthParameters;

  /// The loopback port to listen on.
  ///
  /// Fixed rather than ephemeral because providers match the redirect URI
  /// exactly against what was registered, so the user needs an address they can
  /// paste into the provider's console up front.
  final int redirectPort;

  /// The address the user must register with the provider.
  String get redirectUri => 'http://127.0.0.1:$redirectPort';
}

/// Runs the OAuth 2.0 authorization-code flow against a loopback redirect.
///
/// This is the flow Google documents for desktop apps: bind a listener on
/// 127.0.0.1, hand the provider that address as the redirect URI, open the
/// consent page in the user's real browser, and catch the redirect. Nothing is
/// embedded in-app, so the user can see the address bar they are typing their
/// password into.
class OAuthFlow {
  OAuthFlow({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const Duration _timeout = Duration(minutes: 5);

  /// Completes a sign-in and returns the provider's raw token response.
  ///
  /// Throws [OAuthException] if the user denies access, the state does not
  /// match, or the provider rejects the exchange.
  Future<Map<String, dynamic>> authorize({
    required OAuthProvider provider,
    required OAuthClient client,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        provider.redirectPort,
      );
    } on SocketException {
      throw OAuthException(
        'Port ${provider.redirectPort} is already in use, so the sign-in '
        'redirect cannot be received. Close whatever is using it and retry.',
      );
    }

    try {
      final redirectUri = provider.redirectUri;
      final state = _randomToken(24);
      final verifier = _randomToken(48);

      final authParameters = <String, String>{
        'client_id': client.clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'state': state,
        if (provider.scopes.isNotEmpty) 'scope': provider.scopes.join(' '),
        if (provider.usePkce) ...{
          'code_challenge': _challengeFor(verifier),
          'code_challenge_method': 'S256',
        },
        ...provider.extraAuthParameters,
      };

      final authUrl = provider.authorizationEndpoint.replace(
        queryParameters: {
          ...provider.authorizationEndpoint.queryParameters,
          ...authParameters,
        },
      );

      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw OAuthException('Could not open the browser for sign-in.');
      }

      final code = await _awaitRedirect(server, expectedState: state);

      return await _exchange(
        provider: provider,
        client: client,
        code: code,
        redirectUri: redirectUri,
        verifier: verifier,
      );
    } finally {
      await server.close(force: true);
    }
  }

  /// Serves the redirect, validates it, and returns the authorization code.
  Future<String> _awaitRedirect(
    HttpServer server, {
    required String expectedState,
  }) async {
    final completer = Completer<String>();

    final subscription = server.listen((request) async {
      final params = request.uri.queryParameters;
      final error = params['error'];
      final code = params['code'];

      final String message;
      if (error != null) {
        message = 'Sign-in was cancelled. You can close this tab.';
      } else if (code == null) {
        // Browsers ask for /favicon.ico on the same origin; ignore anything
        // that is not the redirect itself.
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      } else if (params['state'] != expectedState) {
        message = 'Sign-in could not be verified. You can close this tab.';
      } else {
        message = 'Connected to Kandoo. You can close this tab.';
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_resultPage(message));
      await request.response.close();

      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(OAuthException('Access was denied ($error).'));
      } else if (params['state'] != expectedState) {
        completer.completeError(
          OAuthException('State mismatch; the sign-in was not completed.'),
        );
      } else {
        completer.complete(code);
      }
    });

    try {
      return await completer.future.timeout(
        _timeout,
        onTimeout: () => throw OAuthException('Timed out waiting for sign-in.'),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<Map<String, dynamic>> _exchange({
    required OAuthProvider provider,
    required OAuthClient client,
    required String code,
    required String redirectUri,
    required String verifier,
  }) => _token(
    provider: provider,
    client: client,
    body: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      if (provider.usePkce) 'code_verifier': verifier,
    },
  );

  /// Trades a refresh token for a fresh access token.
  ///
  /// Access tokens last about an hour, so anything that reads a source hours
  /// after sign-in goes through here rather than sending the user back to a
  /// consent page they have already been through.
  Future<Map<String, dynamic>> refresh({
    required OAuthProvider provider,
    required OAuthClient client,
    required String refreshToken,
  }) => _token(
    provider: provider,
    client: client,
    body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
  );

  /// Posts to the token endpoint, authenticating however the provider expects.
  Future<Map<String, dynamic>> _token({
    required OAuthProvider provider,
    required OAuthClient client,
    required Map<String, String> body,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    // When a proxy is configured it owns the client credentials, so hand it the
    // code and let it authenticate against the provider.
    final proxy = client.tokenProxy;
    if (proxy != null) {
      final response = await _http.post(
        proxy,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode != 200) {
        throw OAuthException(
          'Token exchange failed (${response.statusCode}): ${response.body}',
        );
      }
      return (jsonDecode(response.body) as Map).cast<String, dynamic>();
    }

    switch (provider.tokenAuthStyle) {
      case TokenAuthStyle.requestBody:
        body['client_id'] = client.clientId;
        if (client.clientSecret != null) {
          body['client_secret'] = client.clientSecret!;
        }
      case TokenAuthStyle.basicAuth:
        final secret = client.clientSecret;
        if (secret == null) {
          throw OAuthException('This provider requires a client secret.');
        }
        final encoded = base64Encode(utf8.encode('${client.clientId}:$secret'));
        headers['Authorization'] = 'Basic $encoded';
    }

    final response = await _http.post(
      provider.tokenEndpoint,
      headers: headers,
      body: body,
    );

    if (response.statusCode != 200) {
      throw OAuthException(
        'Token exchange failed (${response.statusCode}): ${response.body}',
      );
    }

    return (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  static String _randomToken(int bytes) {
    final random = Random.secure();
    final values = List<int>.generate(bytes, (_) => random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  static String _challengeFor(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');

  static String _resultPage(String message) =>
      '''
<!doctype html>
<meta charset="utf-8">
<title>Kandoo</title>
<body style="margin:0;display:grid;place-items:center;height:100vh;background:#FCFBF9;
             font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#1F1D1B">
  <main style="text-align:center">
    <h1 style="font-size:20px;font-weight:600;margin:0 0 6px">Kandoo</h1>
    <p style="margin:0;color:#6B6560;font-size:14px">$message</p>
  </main>
</body>
''';
}
