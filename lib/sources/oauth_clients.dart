import 'oauth.dart';

/// OAuth client configuration baked in at build time.
///
/// End users never see any of this: they press Connect and the browser opens.
/// Kandoo's developers register one OAuth app per provider and supply the
/// values at build time with
/// `flutter build macos --dart-define-from-file=oauth.json`
/// (see `oauth.example.json`; the real file is gitignored).
///
/// What is safe to embed differs per provider:
///
/// * Google documents the client secret as "not applicable" for installed
///   apps, so the loopback + PKCE flow needs only a client id. Nothing
///   confidential ships in the binary.
/// * Notion supports no PKCE and authenticates the token exchange with HTTP
///   Basic `client_id:client_secret`, and its docs say the secret must never
///   live in source code. A shipped binary cannot keep it, so the supported
///   path is [notionTokenProxy]: a small endpoint you host that holds the
///   secret and performs the exchange. [notionClientSecret] exists as an
///   escape hatch for local development only.
abstract final class BuiltInOAuthClients {
  static const String googleDriveClientId = String.fromEnvironment(
    'GOOGLE_DRIVE_CLIENT_ID',
  );

  static const String notionClientId = String.fromEnvironment(
    'NOTION_CLIENT_ID',
  );

  /// URL of a token-exchange endpoint that holds the Notion client secret.
  static const String notionTokenProxy = String.fromEnvironment(
    'NOTION_TOKEN_PROXY',
  );

  /// Development-only fallback. Anything shipped in a binary is extractable.
  static const String notionClientSecret = String.fromEnvironment(
    'NOTION_CLIENT_SECRET',
  );

  /// The client to use for [sourceId], or null when this build has none
  /// configured for it.
  static OAuthClient? forSource(String sourceId) {
    switch (sourceId) {
      case 'google_drive':
        if (googleDriveClientId.isEmpty) return null;
        return const OAuthClient(clientId: googleDriveClientId);

      case 'notion':
        if (notionClientId.isEmpty) return null;
        if (notionTokenProxy.isEmpty && notionClientSecret.isEmpty) return null;
        return OAuthClient(
          clientId: notionClientId,
          clientSecret: notionClientSecret.isEmpty ? null : notionClientSecret,
          tokenProxy: notionTokenProxy.isEmpty
              ? null
              : Uri.parse(notionTokenProxy),
        );

      default:
        return null;
    }
  }
}
