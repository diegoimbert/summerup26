import '../widgets/tree_viewer.dart';
import 'google_drive_api.dart';

/// Browses a Google Drive folder by folder, in the shape a [TreeViewer] wants.
///
/// The rows carry Drive ids rather than paths, because that is what Drive
/// answers to and because two items in one folder may share a name.
class GoogleDriveBrowser {
  const GoogleDriveBrowser({required this.api, this.rootPath = '/'});

  final GoogleDriveApi api;

  /// The folder the tree is rooted at, as the user typed it in their settings.
  /// `/` is the drive itself.
  final String rootPath;

  /// The contents of [parent], or of [rootPath] at the top level.
  Future<List<TreeEntry>> children(TreeEntry? parent) async {
    try {
      final parentId = parent?.id ?? await _rootId();
      if (parentId == null) {
        throw TreeLoadException('No Google Drive folder at $rootPath.');
      }

      final items = <DriveItem>[];
      String? pageToken;
      do {
        final page = await api.list(parentId: parentId, pageToken: pageToken);
        items.addAll(page.items);
        pageToken = page.nextPageToken;
      } while (pageToken != null);

      final entries = [
        for (final item in items)
          TreeEntry(id: item.id, label: item.name, isFolder: item.isFolder),
      ];

      // Folders first, then files, each alphabetically — the order Drive's own
      // web view uses, and the one the file system browser uses.
      entries.sort((a, b) {
        if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

      return entries;
    } on DriveException catch (failure) {
      throw TreeLoadException(failure.message);
    }
  }

  Future<String?> _rootId() async {
    final path = GoogleDriveApi.normalisePath(rootPath);
    if (path.isEmpty) return GoogleDriveApi.rootId;
    return api.resolveFolder(path);
  }
}
