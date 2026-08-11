import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'auth.dart';
import 'content_source.dart';
import 'exceptions.dart';
import 'models.dart';
import 'rest_client.dart';

/// Google Drive, via the Drive v3 REST API.
///
/// Node ids are Drive file ids. The root is addressed as `root`, which is
/// what the API itself accepts as an alias, so `parentId: null` and
/// `parentId: 'root'` mean the same thing.
///
/// Google-native documents (Docs, Sheets, Slides) hold no bytes of their own,
/// so [read] exports them — Docs come back as markdown, which keeps them in
/// the same interchange format as Notion pages and Obsidian notes.
class GoogleDriveSource implements ContentSource {
  GoogleDriveSource({
    required TokenProvider tokenProvider,
    this.includeSharedDrives = true,
    http.Client? httpClient,
  }) : _client = RestClient(
          providerId: 'google_drive',
          tokenProvider: tokenProvider,
          httpClient: httpClient,
        );

  /// Whether shared ("team") drives are visible alongside My Drive.
  final bool includeSharedDrives;

  final RestClient _client;

  static const _apiBase = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';

  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _nativePrefix = 'application/vnd.google-apps.';

  /// Fields worth asking for; Drive returns only `id`/`name`/`mimeType` by
  /// default, and an unrequested field is simply absent.
  static const _fileFields =
      'id,name,mimeType,parents,size,modifiedTime,webViewLink,trashed';

  /// What each Google-native type is exported as. Docs export to markdown
  /// natively, which is why editing round-trips reasonably well.
  static const _exportFormats = <String, String>{
    'application/vnd.google-apps.document': 'text/markdown',
    'application/vnd.google-apps.spreadsheet': 'text/csv',
    'application/vnd.google-apps.presentation': 'text/plain',
    'application/vnd.google-apps.drawing': 'image/png',
    'application/vnd.google-apps.script': 'application/vnd.google-apps.script+json',
  };

  static const _extensionMimes = <String, String>{
    '.md': 'text/markdown',
    '.txt': 'text/plain',
    '.csv': 'text/csv',
    '.json': 'application/json',
    '.html': 'text/html',
    '.pdf': 'application/pdf',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
  };

  @override
  String get providerId => 'google_drive';

  @override
  String get displayName => 'Google Drive';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities();

  @override
  Future<void> verifyAccess() async {
    await _client.json('GET', _url('/about', {'fields': 'user(emailAddress)'}));
  }

  @override
  Future<List<Node>> children({String? parentId, int? limit}) {
    final parent = parentId ?? 'root';
    return _listFiles(
      "'${_escape(parent)}' in parents and trashed = false",
      limit: limit,
      // Folders first, then most recently touched — the ordering a picker wants.
      orderBy: 'folder,modifiedTime desc,name',
    );
  }

  @override
  Future<Node> stat(String id) async {
    final json = await _client.json(
      'GET',
      _url('/files/$id', {'fields': _fileFields}),
      nodeId: id,
    );
    return _toNode(json);
  }

  @override
  Future<NodeContent> read(String id) async {
    final node = await stat(id);
    final mime = node.mimeType ?? '';

    if (mime == _folderMime) {
      throw UnsupportedOperationException(
          providerId, 'Cannot read a folder: "${node.name}"');
    }

    if (mime.startsWith(_nativePrefix)) {
      final exportMime = _exportFormats[mime];
      if (exportMime == null) {
        throw UnsupportedOperationException(
          providerId,
          '"${node.name}" is a $mime, which Drive cannot export',
        );
      }
      final response = await _client.send(
        'GET',
        _url('/files/$id/export', {'mimeType': exportMime}),
        nodeId: id,
      );
      return NodeContent(bytes: response.bodyBytes, mimeType: exportMime);
    }

    final response = await _client.send(
      'GET',
      _url('/files/$id', {'alt': 'media'}),
      nodeId: id,
    );
    return NodeContent(bytes: response.bodyBytes, mimeType: node.mimeType);
  }

  /// Replaces the bytes of an existing file.
  ///
  /// Uploading text over a Google-native Doc keeps it a Doc — Drive converts
  /// on the way in — so a markdown round-trip through [read]/[write] does not
  /// silently turn a Doc into a plain file.
  @override
  Future<Node> write(String id, NodeContent content) async {
    final response = await _client.send(
      'PATCH',
      _uploadUrl('/files/$id', {'uploadType': 'media', 'fields': _fileFields}),
      headers: {'Content-Type': content.mimeType ?? 'application/octet-stream'},
      body: content.bytes,
      nodeId: id,
    );
    return _toNode(_decode(response.bodyBytes));
  }

  @override
  Future<Node> create({
    String? parentId,
    required String name,
    NodeContent? content,
  }) async {
    final metadata = <String, dynamic>{
      'name': name,
      'parents': [parentId ?? 'root'],
    };

    if (content == null) {
      final json = await _client.json(
        'POST',
        _url('/files', {'fields': _fileFields}),
        body: metadata,
      );
      return _toNode(json);
    }

    final mime = content.mimeType ?? _guessMime(name);
    final response = await _client.send(
      'POST',
      _uploadUrl('/files', {'uploadType': 'multipart', 'fields': _fileFields}),
      headers: {'Content-Type': 'multipart/related; boundary=$_boundary'},
      body: _multipartBody(metadata, content.bytes, mime),
    );
    return _toNode(_decode(response.bodyBytes));
  }

  @override
  Future<Node> createFolder({String? parentId, required String name}) async {
    final json = await _client.json(
      'POST',
      _url('/files', {'fields': _fileFields}),
      body: {
        'name': name,
        'mimeType': _folderMime,
        'parents': [parentId ?? 'root'],
      },
    );
    return _toNode(json);
  }

  /// Drive models a move as a parent swap, so the current parent has to be
  /// read first and passed as `removeParents` — otherwise the file ends up
  /// living in both places (Drive allows multiple parents for legacy items).
  @override
  Future<Node> move(String id, {String? parentId, String? name}) async {
    if (parentId == null && name == null) return stat(id);

    final query = {'fields': _fileFields};
    if (parentId != null) {
      final current = await stat(id);
      final currentParent = current.parentId;
      if (currentParent != null && currentParent != parentId) {
        query['removeParents'] = currentParent;
      }
      query['addParents'] = parentId;
    }

    final json = await _client.json(
      'PATCH',
      _url('/files/$id', query),
      body: {if (name != null) 'name': name},
      nodeId: id,
    );
    return _toNode(json);
  }

  @override
  Future<void> delete(String id, {bool permanent = false}) async {
    if (permanent) {
      await _client.send('DELETE', _url('/files/$id'), nodeId: id);
      return;
    }
    await _client.json(
      'PATCH',
      _url('/files/$id', {'fields': 'id'}),
      body: {'trashed': true},
      nodeId: id,
    );
  }

  @override
  Future<List<Node>> search(String query, {int limit = 25}) {
    final term = _escape(query);
    // `fullText` covers content and metadata but not partial words, so the
    // name clause is what makes prefix typing feel responsive.
    return _listFiles(
      "(name contains '$term' or fullText contains '$term') and trashed = false",
      limit: limit,
      orderBy: 'modifiedTime desc',
    );
  }

  @override
  Future<void> close() async => _client.close();

  Future<List<Node>> _listFiles(
    String query, {
    int? limit,
    String? orderBy,
  }) async {
    final nodes = <Node>[];
    String? pageToken;

    do {
      final remaining = limit == null ? 1000 : limit - nodes.length;
      final json = await _client.json(
        'GET',
        _url('/files', {
          'q': query,
          'fields': 'nextPageToken,files($_fileFields)',
          'pageSize': '${remaining.clamp(1, 1000)}',
          if (orderBy != null) 'orderBy': orderBy,
          if (pageToken != null) 'pageToken': pageToken,
        }),
      );

      final files = (json['files'] as List?) ?? const [];
      for (final file in files) {
        nodes.add(_toNode(file as Map<String, dynamic>));
        if (limit != null && nodes.length >= limit) return nodes;
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);

    return nodes;
  }

  Node _toNode(Map<String, dynamic> json) {
    final mime = json['mimeType'] as String?;
    final parents = (json['parents'] as List?)?.cast<String>();
    final size = json['size'];
    final modified = json['modifiedTime'] as String?;

    return Node(
      providerId: providerId,
      id: json['id'] as String,
      name: (json['name'] as String?) ?? 'Untitled',
      kind: mime == _folderMime ? NodeKind.folder : NodeKind.file,
      // Drive reports the root's parent as absent, which maps cleanly to null.
      parentId: (parents == null || parents.isEmpty) ? null : parents.first,
      mimeType: mime,
      // `size` is a string (int64 in JSON) and is absent for native docs.
      sizeBytes: size is String ? int.tryParse(size) : (size as int?),
      modifiedAt: modified == null ? null : DateTime.tryParse(modified),
      webUrl: json['webViewLink'] as String?,
      hasChildren: mime == _folderMime,
      raw: json,
    );
  }

  Uri _url(String path, [Map<String, String>? query]) {
    return Uri.parse('$_apiBase$path').replace(queryParameters: {
      if (includeSharedDrives) ...{
        'supportsAllDrives': 'true',
        'includeItemsFromAllDrives': 'true',
      },
      ...?query,
    });
  }

  Uri _uploadUrl(String path, Map<String, String> query) {
    return Uri.parse('$_uploadBase$path').replace(queryParameters: {
      if (includeSharedDrives) 'supportsAllDrives': 'true',
      ...query,
    });
  }

  static const _boundary = 'overlay-app-drive-boundary';

  /// `multipart/related` upload: a JSON metadata part followed by the bytes,
  /// which is the only way to create a file and its content in one round trip.
  List<int> _multipartBody(
    Map<String, dynamic> metadata,
    Uint8List bytes,
    String mime,
  ) {
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode('--$_boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n'
          '--$_boundary\r\n'
          'Content-Type: $mime\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$_boundary--'));
    return builder.takeBytes();
  }

  Map<String, dynamic> _decode(Uint8List body) =>
      jsonDecode(utf8.decode(body)) as Map<String, dynamic>;

  String _guessMime(String name) =>
      _extensionMimes[p.extension(name).toLowerCase()] ??
      'application/octet-stream';

  /// Drive query strings are single-quoted, so quotes and backslashes in a
  /// user's search term have to be escaped or the query is rejected as
  /// malformed.
  String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
}
