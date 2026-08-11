import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// OAuth client credentials for one provider.
///
/// Kandoo ships no client of its own, so each user registers an app with the
/// provider and pastes the identifiers in. They live beside the tokens.
class OAuthClient {
  const OAuthClient({required this.clientId, this.clientSecret});

  final String clientId;

  /// Google desktop clients issue one but treat it as non-confidential; Notion
  /// requires it for the token exchange.
  final String? clientSecret;

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    if (clientSecret != null) 'clientSecret': clientSecret,
  };

  static OAuthClient fromJson(Map<String, dynamic> json) => OAuthClient(
    clientId: json['clientId'] as String,
    clientSecret: json['clientSecret'] as String?,
  );
}

/// A completed connection to a provider.
class SourceCredentials {
  const SourceCredentials({
    required this.sourceId,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.accountLabel,
    this.scopes = const [],
    this.extra = const {},
  });

  final String sourceId;
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  /// Shown in the UI so the user can tell which account is linked.
  final String? accountLabel;

  final List<String> scopes;

  /// Provider-specific leftovers, e.g. Notion's workspace and bot ids.
  final Map<String, dynamic> extra;

  bool get isExpired {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return DateTime.now().isAfter(expiry);
  }

  SourceCredentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) => SourceCredentials(
    sourceId: sourceId,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    accountLabel: accountLabel,
    scopes: scopes,
    extra: extra,
  );

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    if (accountLabel != null) 'accountLabel': accountLabel,
    'scopes': scopes,
    'extra': extra,
  };

  static SourceCredentials fromJson(Map<String, dynamic> json) =>
      SourceCredentials(
        sourceId: json['sourceId'] as String,
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String?,
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.tryParse(json['expiresAt'] as String),
        accountLabel: json['accountLabel'] as String?,
        scopes: (json['scopes'] as List?)?.cast<String>() ?? const [],
        extra: (json['extra'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// Persists connections and client credentials to a JSON file.
///
/// The file lives in Application Support, which under the app sandbox resolves
/// inside the app's own container and is not readable by other apps. It is
/// still plaintext on disk: the Keychain would be the right home for tokens if
/// this ever ships.
class CredentialStore {
  CredentialStore({this.fileName = 'connections.json'});

  final String fileName;

  Map<String, dynamic>? _cache;
  File? _file;

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;

    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return _file = File('${directory.path}/$fileName');
  }

  Future<Map<String, dynamic>> _read() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = await _resolveFile();
    if (!await file.exists()) {
      return _cache = {'version': 1, 'clients': {}, 'connections': {}};
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = (decoded as Map).cast<String, dynamic>();
      map.putIfAbsent('clients', () => <String, dynamic>{});
      map.putIfAbsent('connections', () => <String, dynamic>{});
      return _cache = map;
    } on FormatException {
      // A corrupt file should not wedge the app; start over rather than throw
      // on every read.
      return _cache = {'version': 1, 'clients': {}, 'connections': {}};
    }
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final file = await _resolveFile();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    _cache = data;
  }

  /// Where credentials are written, for display in the UI.
  Future<String> location() async => (await _resolveFile()).path;

  Future<OAuthClient?> readClient(String sourceId) async {
    final data = await _read();
    final raw = (data['clients'] as Map)[sourceId];
    if (raw == null) return null;
    return OAuthClient.fromJson((raw as Map).cast<String, dynamic>());
  }

  Future<void> saveClient(String sourceId, OAuthClient client) async {
    final data = await _read();
    (data['clients'] as Map)[sourceId] = client.toJson();
    await _write(data);
  }

  Future<SourceCredentials?> read(String sourceId) async {
    final data = await _read();
    final raw = (data['connections'] as Map)[sourceId];
    if (raw == null) return null;
    return SourceCredentials.fromJson((raw as Map).cast<String, dynamic>());
  }

  Future<Map<String, SourceCredentials>> readAll() async {
    final data = await _read();
    final connections = (data['connections'] as Map).cast<String, dynamic>();
    return {
      for (final entry in connections.entries)
        entry.key: SourceCredentials.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    };
  }

  Future<void> save(SourceCredentials credentials) async {
    final data = await _read();
    (data['connections'] as Map)[credentials.sourceId] = credentials.toJson();
    await _write(data);
  }

  /// Forgets a connection. Client credentials are kept so the user does not
  /// have to paste them again when reconnecting.
  Future<void> delete(String sourceId) async {
    final data = await _read();
    (data['connections'] as Map).remove(sourceId);
    await _write(data);
  }
}
