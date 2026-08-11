import 'dart:convert';

import 'package:http/http.dart' as http;

/// One item in a Drive folder.
class DriveItem {
  const DriveItem({
    required this.id,
    required this.name,
    required this.isFolder,
    this.modified,
  });

  /// Drive's own handle on the item. Two items in one folder can share a name,
  /// so this is the only thing that identifies it.
  final String id;

  final String name;
  final bool isFolder;
  final DateTime? modified;
}

/// A page of a folder's contents.
class DriveListing {
  const DriveListing({required this.items, this.nextPageToken});

  final List<DriveItem> items;

  /// Present while Drive has more of this folder to give.
  final String? nextPageToken;
}

/// Thrown when Drive will not answer. The message is written to be shown to the
/// user, so it says what to do rather than what broke.
class DriveException implements Exception {
  const DriveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The slice of the Drive API Kandoo uses: list a folder, and find one by path.
///
/// Shared by the scanner, which walks the whole drive once, and the browser,
/// which opens a folder at a time. Both need exactly this, and neither should
/// have to know how Drive spells a query.
class GoogleDriveApi {
  GoogleDriveApi({required this.accessToken, http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _endpoint =
          endpoint ?? Uri.parse('https://www.googleapis.com/drive/v3/files');

  /// A token good right now; renewing it is the caller's business.
  final String accessToken;

  final http.Client _client;
  final Uri _endpoint;

  static const String folderMimeType = 'application/vnd.google-apps.folder';

  /// What Drive calls the top of a user's own drive.
  static const String rootId = 'root';

  /// The contents of one folder, a page at a time.
  Future<DriveListing> list({
    required String parentId,
    String? pageToken,
    int pageSize = 200,
  }) async {
    final body = await _get({
      'q': "'$parentId' in parents and trashed = false",
      'fields': 'nextPageToken, files(id, name, mimeType, modifiedTime)',
      'pageSize': '$pageSize',
      // The user's own drive, not everything they can see.
      'spaces': 'drive',
      'pageToken': ?pageToken,
    });

    return DriveListing(
      items: [
        for (final raw in (body['files'] as List? ?? const []))
          ?_itemFrom((raw as Map).cast<String, dynamic>()),
      ],
      nextPageToken: body['nextPageToken'] as String?,
    );
  }

  /// The id of the folder at [path], walked down by name from the top of the
  /// drive. Null when there is no such folder.
  ///
  /// Drive has no paths of its own, so a folder the user typed into their
  /// settings has to be found a segment at a time.
  Future<String?> resolveFolder(String path) async {
    var parent = rootId;

    for (final segment in normalisePath(path).split('/')) {
      if (segment.isEmpty) continue;

      final body = await _get({
        'q':
            "'$parent' in parents and trashed = false "
            "and mimeType = '$folderMimeType' and name = '${_escape(segment)}'",
        'fields': 'files(id)',
        'pageSize': '1',
        'spaces': 'drive',
      });

      final files = body['files'] as List? ?? const [];
      if (files.isEmpty) return null;
      final id = ((files.first as Map)['id']) as String?;
      if (id == null) return null;
      parent = id;
    }

    return parent;
  }

  /// Trims a folder the user typed to bare segments: `/Work/Invoices/` and
  /// `Work/Invoices` name the same folder, and `/` is the drive itself.
  static String normalisePath(String path) {
    final segments = path
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? '' : '/${segments.join('/')}';
  }

  Future<Map<String, dynamic>> _get(Map<String, String> parameters) async {
    final http.Response response;
    try {
      response = await _client.get(
        _endpoint.replace(queryParameters: parameters),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
    } catch (error) {
      throw DriveException('Could not reach Google Drive: $error');
    }

    if (response.statusCode != 200) throw DriveException(_failureFor(response));

    try {
      return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      throw const DriveException('Google Drive returned something unreadable.');
    }
  }

  static DriveItem? _itemFrom(Map<String, dynamic> raw) {
    final id = raw['id'] as String?;
    if (id == null) return null;

    return DriveItem(
      id: id,
      name: raw['name'] as String? ?? 'Untitled',
      isFolder: raw['mimeType'] == folderMimeType,
      modified: DateTime.tryParse(raw['modifiedTime'] as String? ?? ''),
    );
  }

  /// Drive quotes names in single quotes, so a name containing one has to
  /// escape it or the query is malformed.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  static String _failureFor(http.Response response) =>
      switch (response.statusCode) {
        401 => 'Google Drive needs connecting again from Sources.',
        403 => 'Google Drive refused the request; check what it was granted.',
        404 => 'That Google Drive folder no longer exists.',
        429 => 'Google Drive is rate limiting; try again shortly.',
        >= 500 => 'Google Drive is unavailable right now.',
        _ => 'Google Drive refused the request (${response.statusCode}).',
      };
}
