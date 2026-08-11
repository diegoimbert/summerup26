import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/sources/oauth_clients.dart';

/// Guards the mechanism the connect flow depends on: credentials arrive from
/// `--dart-define` at build time, never from the user.
///
/// Run configured:
///   flutter test --dart-define=GOOGLE_DRIVE_CLIENT_ID=abc.apps.googleusercontent.com
void main() {
  const googleId = String.fromEnvironment('GOOGLE_DRIVE_CLIENT_ID');

  test('Google Drive client reflects the build-time define', () {
    final client = BuiltInOAuthClients.forSource('google_drive');

    if (googleId.isEmpty) {
      expect(
        client,
        isNull,
        reason: 'an unconfigured build must report no client',
      );
    } else {
      expect(client, isNotNull);
      expect(client!.clientId, googleId);
      expect(
        client.clientSecret,
        const String.fromEnvironment('GOOGLE_DRIVE_CLIENT_SECRET').isEmpty
            ? isNull
            : isNotNull,
        reason:
            'Google Desktop clients need the secret at the token endpoint; '
            'omitting it fails with "client_secret is missing"',
      );
    }
  });

  test('Notion needs a secret holder as well as a client id', () {
    const notionId = String.fromEnvironment('NOTION_CLIENT_ID');
    const proxy = String.fromEnvironment('NOTION_TOKEN_PROXY');
    const secret = String.fromEnvironment('NOTION_CLIENT_SECRET');

    final client = BuiltInOAuthClients.forSource('notion');

    if (notionId.isEmpty || (proxy.isEmpty && secret.isEmpty)) {
      expect(
        client,
        isNull,
        reason: 'a client id alone cannot complete Notion token exchange',
      );
    } else {
      expect(client, isNotNull);
    }
  });

  test('sources with no sign-in support report no client', () {
    expect(BuiltInOAuthClients.forSource('dropbox'), isNull);
    expect(BuiltInOAuthClients.forSource('obsidian'), isNull);
  });
}
