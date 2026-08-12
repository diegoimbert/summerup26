import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'credential_store.dart';
import 'oauth.dart';
import 'oauth_clients.dart';

/// The providers Kandoo can actually sign in to, and how.
///
/// Only the sign-in half is built. Reading and moving Drive files, and creating
/// or editing Notion pages, come later; these definitions request the scopes
/// that work will need so users are not asked to re-consent then.
final Map<String, OAuthProvider> kOAuthProviders = {
  'google_drive': OAuthProvider(
    authorizationEndpoint: Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth',
    ),
    tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
    scopes: const [
      'https://www.googleapis.com/auth/drive',
      'openid',
      'email',
    ],
    // Google only returns a refresh token when both are asked for explicitly.
    extraAuthParameters: const {
      'access_type': 'offline',
      'prompt': 'consent',
    },
  ),
  'notion': OAuthProvider(
    authorizationEndpoint: Uri.parse('https://api.notion.com/v1/oauth/authorize'),
    tokenEndpoint: Uri.parse('https://api.notion.com/v1/oauth/token'),
    // Notion authenticates the exchange with HTTP Basic and does not accept a
    // PKCE verifier on the standard integration flow.
    usePkce: false,
    tokenAuthStyle: TokenAuthStyle.basicAuth,
    extraAuthParameters: const {'owner': 'user'},
    // Notion rejects a redirect URI that spells the loopback address as an IP,
    // so this one has to say localhost. It resolves to the same listener.
    redirectHost: 'localhost',
  ),
};

/// Holds connection state for the Sources page.
class ConnectionsController extends ChangeNotifier {
  ConnectionsController({CredentialStore? store, OAuthFlow? flow})
    : _store = store ?? CredentialStore(),
      _flow = flow ?? OAuthFlow();

  final CredentialStore _store;
  final OAuthFlow _flow;

  Map<String, SourceCredentials> _connections = {};
  Map<String, List<String>> _folders = {};
  final Set<String> _busy = {};
  final Map<String, String> _errors = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  SourceCredentials? connectionFor(String sourceId) => _connections[sourceId];
  bool isConnected(String sourceId) => _connections.containsKey(sourceId);
  bool isBusy(String sourceId) => _busy.contains(sourceId);
  String? errorFor(String sourceId) => _errors[sourceId];

  Future<String> storeLocation() => _store.location();

  /// Whether this build carries OAuth credentials for [sourceId].
  ///
  /// False means the app was built without them — a packaging problem, not
  /// something the user can fix.
  bool isConfigured(String sourceId) =>
      BuiltInOAuthClients.forSource(sourceId) != null;

  /// The folders [sourceId] has been narrowed to. Empty means everything in
  /// the source is in scope.
  List<String> foldersFor(String sourceId) =>
      _folders[sourceId] ?? const <String>[];

  Future<void> load() async {
    _connections = await _store.readAll();
    _folders = await _store.readAllFolders();
    _loaded = true;
    notifyListeners();
  }

  Future<void> setFolders(String sourceId, List<String> folders) async {
    await _store.saveFolders(sourceId, folders);
    _folders = {..._folders};
    if (folders.isEmpty) {
      _folders.remove(sourceId);
    } else {
      _folders[sourceId] = List.unmodifiable(folders);
    }
    notifyListeners();
  }

  /// Runs the provider's sign-in and persists whatever comes back.
  Future<void> connect(String sourceId) async {
    final provider = kOAuthProviders[sourceId];
    if (provider == null) {
      _fail(sourceId, 'This source cannot be connected yet.');
      return;
    }

    final client = BuiltInOAuthClients.forSource(sourceId);
    if (client == null) {
      _fail(
        sourceId,
        'This build of Kandoo has no $sourceId credentials configured.',
      );
      return;
    }

    _busy.add(sourceId);
    _errors.remove(sourceId);
    notifyListeners();

    try {
      final token = await _flow.authorize(provider: provider, client: client);
      final credentials = _credentialsFrom(sourceId, token);
      await _store.save(credentials);
      _connections = {..._connections, sourceId: credentials};
    } on OAuthException catch (error) {
      _errors[sourceId] = error.message;
    } catch (error) {
      _errors[sourceId] = 'Sign-in failed: $error';
    } finally {
      _busy.remove(sourceId);
      notifyListeners();
    }
  }

  /// Credentials that can be used right now, renewed first if they are about
  /// to lapse.
  ///
  /// Returns null when the source was never connected. A provider that will not
  /// renew throws, because the honest answer is that the user has to sign in
  /// again — quietly handing back a dead token would surface as an unexplained
  /// failure further down.
  Future<SourceCredentials?> freshCredentials(String sourceId) async {
    final current = _connections[sourceId];
    if (current == null) return null;

    final expiry = current.expiresAt;
    // A minute's margin, so a token does not lapse midway through a long scan.
    final lapsing =
        expiry != null &&
        expiry.isBefore(DateTime.now().add(const Duration(minutes: 1)));
    if (!lapsing) return current;

    final refreshToken = current.refreshToken;
    final provider = kOAuthProviders[sourceId];
    final client = BuiltInOAuthClients.forSource(sourceId);
    if (refreshToken == null || provider == null || client == null) {
      throw OAuthException(
        'The connection to $sourceId has expired. Connect it again from '
        'Sources.',
      );
    }

    final token = await _flow.refresh(
      provider: provider,
      client: client,
      refreshToken: refreshToken,
    );

    final accessToken = token['access_token'] as String?;
    if (accessToken == null) {
      throw OAuthException('The provider returned no access token.');
    }

    final expiresIn = token['expires_in'];
    final renewed = SourceCredentials(
      sourceId: current.sourceId,
      accessToken: accessToken,
      // Providers may or may not rotate the refresh token; keep the old one
      // when they do not.
      refreshToken: token['refresh_token'] as String? ?? refreshToken,
      // Built rather than copied, so a reply without an expiry clears the old
      // one instead of inheriting a time that has already passed.
      expiresAt: expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
      accountLabel: current.accountLabel,
      scopes: current.scopes,
      extra: current.extra,
    );

    await _store.save(renewed);
    _connections = {..._connections, sourceId: renewed};
    notifyListeners();
    return renewed;
  }

  Future<void> disconnect(String sourceId) async {
    await _store.delete(sourceId);
    _connections = {..._connections}..remove(sourceId);
    _errors.remove(sourceId);
    notifyListeners();
  }

  void _fail(String sourceId, String message) {
    _errors[sourceId] = message;
    notifyListeners();
  }

  /// Normalises the differing token payloads into one shape.
  SourceCredentials _credentialsFrom(
    String sourceId,
    Map<String, dynamic> token,
  ) {
    final accessToken = token['access_token'] as String?;
    if (accessToken == null) {
      throw OAuthException('The provider returned no access token.');
    }

    final expiresIn = token['expires_in'];
    final expiresAt = expiresIn is num
        ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
        : null;

    return SourceCredentials(
      sourceId: sourceId,
      accessToken: accessToken,
      refreshToken: token['refresh_token'] as String?,
      expiresAt: expiresAt,
      accountLabel: _labelFrom(sourceId, token),
      scopes: (token['scope'] as String?)?.split(' ') ?? const [],
      extra: {
        for (final key in ['workspace_id', 'workspace_name', 'bot_id'])
          if (token[key] != null) key: token[key],
      },
    );
  }

  /// A human-readable account name, so the UI can say which account is linked.
  String? _labelFrom(String sourceId, Map<String, dynamic> token) {
    final workspace = token['workspace_name'];
    if (workspace is String && workspace.isNotEmpty) return workspace;

    // Google returns the signed-in address inside the id_token, which saves a
    // separate userinfo round-trip.
    final idToken = token['id_token'];
    if (idToken is String) {
      final email = _emailFromIdToken(idToken);
      if (email != null) return email;
    }
    return null;
  }

  static String? _emailFromIdToken(String idToken) {
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    try {
      final normalised = base64Url.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalised)));
      final email = (payload as Map)['email'];
      return email is String ? email : null;
    } catch (_) {
      // A malformed id_token only costs us the label.
      return null;
    }
  }
}
