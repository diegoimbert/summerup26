import 'package:http/http.dart' as http;

import 'auth.dart';
import 'content_source.dart';
import 'exceptions.dart';
import 'models.dart';
import 'notion_markdown.dart';
import 'rest_client.dart';

/// Notion, via the public REST API.
///
/// The impedance mismatch worth knowing about: Notion has no files. A page is
/// a tree of blocks and is itself a container for other pages, so pages are
/// reported as [NodeKind.file] with `hasChildren: true` — readable *and*
/// listable. Databases are reported as folders, since all they do is hold
/// rows.
///
/// Content is converted to and from markdown by [NotionMarkdown]; see that
/// class for what survives the round trip.
///
/// The integration only ever sees pages that have been explicitly shared with
/// it in Notion's UI. A 404 usually means "not shared", not "does not exist".
class NotionSource implements ContentSource {
  NotionSource({
    required TokenProvider tokenProvider,
    this.apiVersion = defaultApiVersion,
    this.maxReadDepth = 4,
    http.Client? httpClient,
  }) : _client = RestClient(
          providerId: 'notion',
          tokenProvider: tokenProvider,
          httpClient: httpClient,
          defaultHeaders: {'Notion-Version': apiVersion},
        );

  /// Pinned deliberately: Notion versions its API by date and changes block
  /// and database shapes between them, so this has to move in step with the
  /// parsing code rather than float.
  static const defaultApiVersion = '2022-06-28';

  final String apiVersion;

  /// How deep [read] follows `has_children`. Each level costs one request per
  /// parent block, and notes rarely nest deeper than a few levels.
  final int maxReadDepth;

  final RestClient _client;

  static const _base = 'https://api.notion.com/v1';

  @override
  String get providerId => 'notion';

  @override
  String get displayName => 'Notion';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
        // Notion stores no arbitrary bytes; files are uploaded elsewhere and
        // referenced by URL.
        storesBinary: false,
        // Everything is a page, so "new folder" is just a page with no body.
        canCreateFolders: true,
      );

  @override
  Future<void> verifyAccess() async {
    await _client.json('GET', Uri.parse('$_base/users/me'));
  }

  @override
  Future<List<Node>> children({String? parentId, int? limit}) async {
    // The workspace root cannot be listed directly — search with no query is
    // the only way to enumerate what the integration can see, and top-level
    // items are the ones parented to the workspace itself.
    if (parentId == null) {
      final all = await _search(query: '', limit: null);
      final roots = all
          .where((node) => node.parentId == null)
          .take(limit ?? all.length)
          .toList();
      return roots;
    }

    final parent = await stat(parentId);
    if (parent.raw['object'] == 'database') {
      return _queryDatabase(parentId, limit: limit);
    }

    // Only structural children are listed; paragraphs and headings are
    // content, and belong to read().
    final blocks = await _childBlocks(parentId, limit: null);
    final nodes = <Node>[];
    for (final block in blocks) {
      final type = block['type'] as String?;
      if (type != 'child_page' && type != 'child_database') continue;
      final value = (block[type] as Map<String, dynamic>?) ?? const {};
      nodes.add(Node(
        providerId: providerId,
        id: block['id'] as String,
        name: (value['title'] as String?)?.trim().isNotEmpty == true
            ? value['title'] as String
            : 'Untitled',
        kind: type == 'child_page' ? NodeKind.file : NodeKind.folder,
        parentId: parentId,
        mimeType: type == 'child_page' ? 'text/markdown' : null,
        modifiedAt: _time(block['last_edited_time']),
        hasChildren: true,
        raw: block,
      ));
      if (limit != null && nodes.length >= limit) break;
    }
    return nodes;
  }

  @override
  Future<Node> stat(String id) async {
    try {
      return _toNode(await _client.json('GET', Uri.parse('$_base/pages/$id'), nodeId: id));
    } on NodeNotFoundException {
      // Pages and databases share an id space but not an endpoint, so a miss
      // on one is not proof the id is unknown.
      return _toNode(
          await _client.json('GET', Uri.parse('$_base/databases/$id'), nodeId: id));
    }
  }

  @override
  Future<NodeContent> read(String id) async {
    final blocks = await _readTree(id, depth: 0);
    return NodeContent.text(NotionMarkdown.fromBlocks(blocks));
  }

  /// Replaces a page's body with [content].
  ///
  /// Notion has no "replace children" call, so this archives the existing
  /// blocks and appends new ones. That is not atomic: a failure partway
  /// through leaves the page truncated, and block-level comments and
  /// edit history on the old blocks are lost. Use `appendText` when adding to
  /// a page rather than rewriting it.
  @override
  Future<Node> write(String id, NodeContent content) async {
    if (!content.isText) {
      throw UnsupportedOperationException(
        providerId,
        'Notion pages hold text; cannot write ${content.mimeType}',
      );
    }

    final existing = await _childBlocks(id, limit: null);
    for (final block in existing) {
      await _client.send('DELETE', Uri.parse('$_base/blocks/${block['id']}'));
    }

    await _appendBlocks(id, NotionMarkdown.toBlocks(content.text));
    return stat(id);
  }

  @override
  Future<Node> create({
    String? parentId,
    required String name,
    NodeContent? content,
  }) async {
    if (content != null && !content.isText) {
      throw UnsupportedOperationException(
        providerId,
        'Notion pages hold text; cannot store ${content.mimeType}',
      );
    }

    final parent = await _parentReference(parentId);
    final blocks =
        content == null ? const <Map<String, dynamic>>[] : NotionMarkdown.toBlocks(content.text);

    final created = await _client.json(
      'POST',
      Uri.parse('$_base/pages'),
      body: {
        'parent': parent.reference,
        'properties': {
          parent.titleProperty: {'title': NotionMarkdown.richText(name)},
        },
        if (blocks.isNotEmpty)
          'children': blocks.take(NotionMarkdown.maxBlocksPerRequest).toList(),
      },
    );

    // A page can only be created with 100 blocks; the rest are appended.
    if (blocks.length > NotionMarkdown.maxBlocksPerRequest) {
      await _appendBlocks(
        created['id'] as String,
        blocks.skip(NotionMarkdown.maxBlocksPerRequest).toList(),
      );
    }
    return _toNode(created);
  }

  /// Notion has no folders. This creates an empty page, which serves the same
  /// purpose: other pages can be nested inside it.
  @override
  Future<Node> createFolder({String? parentId, required String name}) =>
      create(parentId: parentId, name: name);

  @override
  Future<Node> move(String id, {String? parentId, String? name}) async {
    if (parentId == null && name == null) return stat(id);

    final body = <String, dynamic>{};
    if (parentId != null) {
      final parent = await _parentReference(parentId);
      body['parent'] = parent.reference;
    }
    if (name != null) {
      // The title property is named by the parent database ("Name", "Task"…)
      // and is plain `title` for page-parented pages, so it has to be read
      // off the page rather than assumed.
      final current = await stat(id);
      body['properties'] = {
        _titlePropertyOf(current.raw): {'title': NotionMarkdown.richText(name)},
      };
    }

    try {
      return _toNode(
        await _client.json('PATCH', Uri.parse('$_base/pages/$id'), body: body, nodeId: id),
      );
    } on IntegrationException catch (error) {
      // Re-parenting is rejected outright in some workspaces and across
      // workspace boundaries; a bare 400 here is not a useful message.
      if (error.statusCode == 400 && parentId != null) {
        throw UnsupportedOperationException(
          providerId,
          'Notion refused to move this page to "$parentId": ${error.message}',
        );
      }
      rethrow;
    }
  }

  /// Archives the page. Notion's API has no permanent delete, so [permanent]
  /// is accepted for interface compatibility and ignored — the page lands in
  /// the workspace trash either way.
  @override
  Future<void> delete(String id, {bool permanent = false}) async {
    await _client.json(
      'PATCH',
      Uri.parse('$_base/pages/$id'),
      body: {'archived': true},
      nodeId: id,
    );
  }

  @override
  Future<List<Node>> search(String query, {int limit = 25}) =>
      _search(query: query, limit: limit);

  @override
  Future<void> close() async => _client.close();

  Future<List<Node>> _search({required String query, int? limit}) async {
    final nodes = <Node>[];
    String? cursor;

    do {
      final json = await _client.json(
        'POST',
        Uri.parse('$_base/search'),
        body: {
          if (query.isNotEmpty) 'query': query,
          'page_size': (limit == null ? 100 : (limit - nodes.length)).clamp(1, 100),
          if (cursor != null) 'start_cursor': cursor,
        },
      );

      for (final result in (json['results'] as List?) ?? const []) {
        nodes.add(_toNode(result as Map<String, dynamic>));
        if (limit != null && nodes.length >= limit) return nodes;
      }

      cursor = json['has_more'] == true ? json['next_cursor'] as String? : null;
    } while (cursor != null);

    return nodes;
  }

  Future<List<Node>> _queryDatabase(String databaseId, {int? limit}) async {
    final nodes = <Node>[];
    String? cursor;

    do {
      final json = await _client.json(
        'POST',
        Uri.parse('$_base/databases/$databaseId/query'),
        body: {
          'page_size': (limit == null ? 100 : (limit - nodes.length)).clamp(1, 100),
          if (cursor != null) 'start_cursor': cursor,
        },
        nodeId: databaseId,
      );

      for (final row in (json['results'] as List?) ?? const []) {
        nodes.add(_toNode(row as Map<String, dynamic>));
        if (limit != null && nodes.length >= limit) return nodes;
      }

      cursor = json['has_more'] == true ? json['next_cursor'] as String? : null;
    } while (cursor != null);

    return nodes;
  }

  /// Fetches a block's children, following pagination.
  Future<List<Map<String, dynamic>>> _childBlocks(String id, {int? limit}) async {
    final blocks = <Map<String, dynamic>>[];
    String? cursor;

    do {
      final json = await _client.json(
        'GET',
        Uri.parse('$_base/blocks/$id/children').replace(queryParameters: {
          'page_size': '100',
          if (cursor != null) 'start_cursor': cursor,
        }),
        nodeId: id,
      );

      for (final block in (json['results'] as List?) ?? const []) {
        blocks.add(block as Map<String, dynamic>);
        if (limit != null && blocks.length >= limit) return blocks;
      }

      cursor = json['has_more'] == true ? json['next_cursor'] as String? : null;
    } while (cursor != null);

    return blocks;
  }

  /// Reads a page's blocks, recursing into nested ones so lists and toggles
  /// keep their structure. Nested child *pages* are not followed — they are
  /// separate nodes with their own content.
  Future<List<Map<String, dynamic>>> _readTree(String id, {required int depth}) async {
    final blocks = await _childBlocks(id, limit: null);
    if (depth >= maxReadDepth) return blocks;

    for (final block in blocks) {
      if (block['has_children'] != true) continue;
      final type = block['type'];
      if (type == 'child_page' || type == 'child_database') continue;
      block[NotionMarkdown.childrenKey] =
          await _readTree(block['id'] as String, depth: depth + 1);
    }
    return blocks;
  }

  Future<void> _appendBlocks(String id, List<Map<String, dynamic>> blocks) async {
    for (var i = 0; i < blocks.length; i += NotionMarkdown.maxBlocksPerRequest) {
      final end = (i + NotionMarkdown.maxBlocksPerRequest).clamp(0, blocks.length);
      await _client.json(
        'PATCH',
        Uri.parse('$_base/blocks/$id/children'),
        body: {'children': blocks.sublist(i, end)},
        nodeId: id,
      );
    }
  }

  /// Resolves where a new page should live, and under which property its
  /// title goes — a database row's title property is named by the database.
  Future<_ParentRef> _parentReference(String? parentId) async {
    if (parentId == null) {
      // Notion rejects workspace-level page creation from integrations, so
      // fail with an explanation instead of a raw 400 from the API.
      throw UnsupportedOperationException(
        providerId,
        'Notion cannot create pages at the workspace root; pick a parent page',
      );
    }

    final parent = await stat(parentId);
    if (parent.raw['object'] != 'database') {
      return _ParentRef({'page_id': parentId}, 'title');
    }

    final properties = (parent.raw['properties'] as Map?) ?? const {};
    for (final entry in properties.entries) {
      final value = entry.value;
      if (value is Map && value['type'] == 'title') {
        return _ParentRef({'database_id': parentId}, entry.key as String);
      }
    }
    // Every database has exactly one title property; if none came back the
    // payload was not what we think it is.
    throw IntegrationException(
      providerId,
      'Database "$parentId" has no title property',
    );
  }

  Node _toNode(Map<String, dynamic> json) {
    final isDatabase = json['object'] == 'database';
    final parent = (json['parent'] as Map?) ?? const {};

    return Node(
      providerId: providerId,
      id: json['id'] as String,
      name: isDatabase
          ? _plainTitle(json['title']) ?? 'Untitled database'
          : _pageTitle(json) ?? 'Untitled',
      // A page holds content, a database only holds rows.
      kind: isDatabase ? NodeKind.folder : NodeKind.file,
      parentId: parent['page_id'] as String? ??
          parent['database_id'] as String? ??
          parent['block_id'] as String?,
      mimeType: isDatabase ? null : 'text/markdown',
      modifiedAt: _time(json['last_edited_time']),
      webUrl: json['url'] as String?,
      hasChildren: true,
      raw: json,
    );
  }

  String? _pageTitle(Map<String, dynamic> page) {
    final properties = (page['properties'] as Map?) ?? const {};
    for (final value in properties.values) {
      if (value is Map && value['type'] == 'title') {
        final title = _plainTitle(value['title']);
        if (title != null) return title;
      }
    }
    return null;
  }

  String _titlePropertyOf(Map<String, dynamic> page) {
    final properties = (page['properties'] as Map?) ?? const {};
    for (final entry in properties.entries) {
      final value = entry.value;
      if (value is Map && value['type'] == 'title') return entry.key as String;
    }
    return 'title';
  }

  /// Joins a rich text array into a plain string, dropping annotations —
  /// titles are displayed as text, not markdown.
  String? _plainTitle(Object? richText) {
    if (richText is! List) return null;
    final text = richText
        .whereType<Map>()
        .map((run) => run['plain_text'] as String? ?? '')
        .join()
        .trim();
    return text.isEmpty ? null : text;
  }

  DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class _ParentRef {
  const _ParentRef(this.reference, this.titleProperty);

  /// `{'page_id': ...}` or `{'database_id': ...}`, as the API expects.
  final Map<String, String> reference;
  final String titleProperty;
}
