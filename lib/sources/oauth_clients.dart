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
/// * Google's Desktop app clients need both a client id and a client secret at
///   the token endpoint; omitting the secret fails with "client_secret is
///   missing". Its exemption ("not applicable") covers only Android, iOS and
///   Chrome clients. Google does document the value as not confidential for
///   installed apps, and PKCE is what actually protects the exchange, so
///   shipping it in the binary is the intended arrangement here.
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

  /// Required by Google's Desktop app clients at the token endpoint. Not
  /// confidential per Google's own docs for installed apps; PKCE is what binds
  /// the exchange to this app.
  static const String googleDriveClientSecret = String.fromEnvironment(
    'GOOGLE_DRIVE_CLIENT_SECRET',
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
        return OAuthClient(
          clientId: googleDriveClientId,
          clientSecret: googleDriveClientSecret.isEmpty
              ? null
              : googleDriveClientSecret,
        );

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
