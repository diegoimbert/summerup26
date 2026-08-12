import 'dart:convert';

import 'package:http/http.dart' as http;

/// A page or database in a Notion workspace.
class NotionItem {
  const NotionItem({
    required this.id,
    required this.title,
    required this.isDatabase,
    this.parentId,
    this.lastEdited,
  });

  /// Notion's own handle on the item, and what its URL is built from.
  final String id;

  /// The title as the user typed it, or 'Untitled' — Notion allows a page to
  /// have no title at all, and shows it that way too.
  final String title;

  /// Databases hold pages rather than text. They are worth knowing about for
  /// the path they give the pages inside them.
  final bool isDatabase;

  /// The page or database this one lives in, or null when it sits at the top
  /// of the workspace — or inside something the integration was not given.
  final String? parentId;

  final DateTime? lastEdited;
}

/// Thrown when Notion will not answer. The message is written to be shown to
/// the user, so it says what to do rather than what broke.
class NotionException implements Exception {
  const NotionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The slice of the Notion API Kandoo uses: everything the workspace has shared
/// with this integration.
///
/// Notion has no folders to walk. What it has is a search that returns every
/// page and database the integration was granted, each carrying its parent —
/// so the shape of the workspace is rebuilt from the answer rather than
/// crawled.
class NotionApi {
  NotionApi({
    required this.accessToken,
    http.Client? client,
    Uri? endpoint,
    this.version = '2022-06-28',
    this.pageSize = 100,
  }) : _client = client ?? http.Client(),
       _endpoint = endpoint ?? Uri.parse('https://api.notion.com/v1/search');

  /// Notion's tokens do not expire, so this is whatever sign-in returned.
  final String accessToken;

  /// Notion dates its API and requires the header on every request; without it
  /// the shape of the answer is not the one this code reads.
  final String version;

  final int pageSize;

  final http.Client _client;
  final Uri _endpoint;

  /// How many times to wait out a rate limit before giving up. Notion allows
  /// roughly three requests a second and says how long to wait when it has had
  /// enough.
  static const int _maxRetries = 3;

  /// Every page and database shared with this integration, oldest cursor
  /// first, up to [max] items.
  Future<List<NotionItem>> everything({int max = 2000}) async {
    final items = <NotionItem>[];
    String? cursor;

    do {
      final body = await _search(cursor: cursor);

      for (final raw in (body['results'] as List? ?? const [])) {
        final item = _itemFrom((raw as Map).cast<String, dynamic>());
        if (item == null) continue;
        items.add(item);
        if (items.length >= max) return items;
      }

      cursor = (body['has_more'] as bool? ?? false)
          ? body['next_cursor'] as String?
          : null;
    } while (cursor != null);

    return items;
  }

  Future<Map<String, dynamic>> _search({String? cursor}) async {
    for (var attempt = 0; ; attempt += 1) {
      final http.Response response;
      try {
        response = await _client.post(
          _endpoint,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Notion-Version': version,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'page_size': pageSize, 'start_cursor': ?cursor}),
        );
      } catch (error) {
        throw NotionException('Could not reach Notion: $error');
      }

      if (response.statusCode == 429 && attempt < _maxRetries) {
        await Future<void>.delayed(_retryAfter(response));
        continue;
      }

      if (response.statusCode != 200) {
        throw NotionException(_failureFor(response));
      }

      try {
        return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
            .cast<String, dynamic>();
      } catch (_) {
        throw const NotionException('Notion returned something unreadable.');
      }
    }
  }

  static Duration _retryAfter(http.Response response) {
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header);
    return Duration(seconds: seconds ?? 1);
  }

  /// Reads one search result, or null when it is not something to file: an
  /// archived page, or an object shape this does not know.
  static NotionItem? _itemFrom(Map<String, dynamic> raw) {
    final id = raw['id'] as String?;
    if (id == null) return null;
    if (raw['archived'] == true || raw['in_trash'] == true) return null;

    final isDatabase = raw['object'] == 'database';
    if (!isDatabase && raw['object'] != 'page') return null;

    return NotionItem(
      id: id,
      title: _titleOf(raw, isDatabase: isDatabase),
      isDatabase: isDatabase,
      parentId: _parentOf(raw),
      lastEdited: DateTime.tryParse(raw['last_edited_time'] as String? ?? ''),
    );
  }

  /// A database carries its title at the top; a page keeps it in whichever
  /// property is the title one, which the user may have renamed.
  static String _titleOf(Map<String, dynamic> raw, {required bool isDatabase}) {
    if (isDatabase) return _plainText(raw['title']) ?? 'Untitled';

    final properties = (raw['properties'] as Map?)?.cast<String, dynamic>();
    for (final property in properties?.values ?? const []) {
      if (property is! Map) continue;
      if (property['type'] != 'title') continue;
      final title = _plainText(property['title']);
      if (title != null) return title;
    }
    return 'Untitled';
  }

  /// Notion writes text as a list of pieces, each with its own formatting.
  static String? _plainText(Object? value) {
    if (value is! List) return null;

    final text = value
        .whereType<Map>()
        .map((piece) => piece['plain_text'])
        .whereType<String>()
        .join()
        .trim();
    return text.isEmpty ? null : text;
  }

  /// What this item lives in. A page under a block — inside a column or a
  /// toggle — is reported against that block, which is not something search
  /// returns, so it is treated as living at the top.
  static String? _parentOf(Map<String, dynamic> raw) {
    final parent = (raw['parent'] as Map?)?.cast<String, dynamic>();
    if (parent == null) return null;

    return switch (parent['type']) {
      'page_id' => parent['page_id'] as String?,
      'database_id' => parent['database_id'] as String?,
      _ => null,
    };
  }

  static String _failureFor(http.Response response) =>
      switch (response.statusCode) {
        401 => 'Notion needs connecting again from Sources.',
        403 =>
          'Notion refused the request; check what the integration was '
              'given access to.',
        429 => 'Notion is rate limiting; try again shortly.',
        >= 500 => 'Notion is unavailable right now.',
        _ => 'Notion refused the request (${response.statusCode}).',
      };
}
