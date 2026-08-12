import '../sources/notion_api.dart';
import 'library_store.dart';
import 'source_scanner.dart';

/// Lists the pages a Notion workspace has shared with Kandoo.
///
/// Notion has nothing to walk: one search returns every page and database the
/// integration was granted, each naming its parent. The workspace's shape is
/// rebuilt from that, and a page is given the path its parents spell out — so
/// a Notion page and a file on disk describe the same way once they reach the
/// library.
///
/// Databases and parent pages are not filed themselves. A database is a place
/// pages live rather than a document, and a page that holds other pages is
/// filed on its own account anyway.
class NotionScanner extends SourceScanner implements PollableScanner {
  const NotionScanner({
    required this.api,
    this.maxFiles = 2000,
    this.maxDepth = 8,
  });

  final NotionApi api;

  final int maxFiles;

  /// How far up a parent chain to walk before deciding the path is deep enough.
  final int maxDepth;

  /// Whether anything in the workspace has been touched since [watermark].
  ///
  /// One request: the workspace is read newest first and stops at the first
  /// page as old as the watermark. A deletion is invisible to this — a page
  /// that is gone is simply absent — so it is caught by the sweep instead.
  @override
  Future<bool> hasChangesSince(DateTime? watermark) async {
    if (watermark == null) return true;

    try {
      final newest = await api.everything(max: 1, changedSince: watermark);
      return newest.isNotEmpty;
    } on NotionException catch (failure) {
      throw ScanException(failure.message);
    }
  }

  @override
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  }) async {
    // Notion is scoped by what the user shared with the integration during
    // sign-in, not by folders chosen here, so [roots] has nothing to say.
    final List<NotionItem> items;
    try {
      items = await api.everything(max: maxFiles * 2);
    } on NotionException catch (failure) {
      throw ScanException(failure.message);
    }

    final byId = {for (final item in items) item.id: item};
    final files = <ScannedFile>[];
    var truncated = false;

    for (final item in items) {
      // A database is a container; the pages inside it are what there is to
      // read.
      if (item.isDatabase) continue;

      if (files.length >= maxFiles) {
        truncated = true;
        break;
      }

      files.add(
        ScannedFile(
          path: _pathOf(item, byId),
          sourceName: sourceName,
          modified: item.lastEdited,
          // Two pages can share a title anywhere in a workspace, and nothing
          // could be opened later without this.
          externalId: item.id,
        ),
      );

      if (files.length % 25 == 0) onProgress?.call(files.length);
    }

    onProgress?.call(files.length);
    return ScanResult(files: files, truncated: truncated);
  }

  /// Where a page sits, spelled by its parents: `/Projects/Q3/Kick-off notes`.
  ///
  /// A parent the integration was not given is not in [byId], so the chain
  /// stops there and the page sits as high as Kandoo can see.
  String _pathOf(NotionItem item, Map<String, NotionItem> byId) {
    final segments = <String>[_clean(item.title)];
    final seen = <String>{item.id};

    var parentId = item.parentId;
    while (parentId != null && segments.length < maxDepth) {
      // A workspace cannot nest into itself, but a bad answer should not spin
      // forever either.
      if (!seen.add(parentId)) break;

      final parent = byId[parentId];
      if (parent == null) break;

      segments.insert(0, _clean(parent.title));
      parentId = parent.parentId;
    }

    return '/${segments.join('/')}';
  }

  /// A title is free text and may hold slashes, which would read as folders it
  /// does not have.
  static String _clean(String title) {
    final cleaned = title.replaceAll('/', '∕').trim();
    return cleaned.isEmpty ? 'Untitled' : cleaned;
  }
}
