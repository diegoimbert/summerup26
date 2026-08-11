import '../sources/google_drive_api.dart';
import 'library_store.dart';
import 'source_scanner.dart';

/// Lists a Google Drive, one folder at a time.
///
/// Drive files have parents rather than addresses, so the tree is walked from
/// the top and each file is given the path it was found at. That is what lets a
/// Drive file and a file on disk be described the same way once they reach the
/// library.
class GoogleDriveScanner extends SourceScanner {
  const GoogleDriveScanner({
    required this.api,
    this.maxFiles = 2000,
    this.maxDepth = 8,
  });

  final GoogleDriveApi api;

  final int maxFiles;
  final int maxDepth;

  @override
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  }) async {
    final warnings = <String>[];
    final queue = <({String id, String path, int depth})>[];

    try {
      if (roots.isEmpty) {
        // Nothing chosen means the whole drive which — unlike a disk — holds
        // only what the user put there.
        queue.add((id: GoogleDriveApi.rootId, path: '', depth: 0));
      } else {
        for (final root in roots) {
          final id = await api.resolveFolder(root);
          if (id == null) {
            // One stale folder in the settings is not worth losing the rest of
            // the scan over; it is worth saying, though.
            warnings.add('No Google Drive folder at $root');
            continue;
          }
          queue.add((
            id: id,
            path: GoogleDriveApi.normalisePath(root),
            depth: 0,
          ));
        }
      }

      final files = <ScannedFile>[];
      var truncated = false;

      while (queue.isNotEmpty) {
        final folder = queue.removeAt(0);
        String? pageToken;

        do {
          final page = await api.list(parentId: folder.id, pageToken: pageToken);

          for (final item in page.items) {
            final path = '${folder.path}/${item.name}';

            if (item.isFolder) {
              if (folder.depth < maxDepth) {
                queue.add((id: item.id, path: path, depth: folder.depth + 1));
              }
              continue;
            }

            if (files.length >= maxFiles) {
              truncated = true;
              queue.clear();
              break;
            }

            files.add(
              ScannedFile(
                path: path,
                sourceName: sourceName,
                modified: item.modified,
                externalId: item.id,
              ),
            );

            // Reported in batches: a callback per file would rebuild the UI
            // for no more information.
            if (files.length % 25 == 0) onProgress?.call(files.length);
          }

          pageToken = truncated ? null : page.nextPageToken;
        } while (pageToken != null);
      }

      onProgress?.call(files.length);
      return ScanResult(files: files, truncated: truncated, warnings: warnings);
    } on DriveException catch (failure) {
      throw ScanException(failure.message);
    }
  }
}
