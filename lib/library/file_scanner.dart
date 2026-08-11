import 'dart:io';

import 'library_store.dart';
import 'source_scanner.dart';

/// Walks the folders the File System source has been narrowed to and lists
/// every file underneath them.
///
/// Unlike the tree the user browses, this reads everything up front — it is the
/// input the organizer works from. The limits below are what keep "everything"
/// from meaning a whole disk: a scan that never ends is worse than one that
/// stops early and says so.
class FileSystemScanner extends SourceScanner {
  const FileSystemScanner({this.maxFiles = 2000, this.maxDepth = 8});

  /// Stops once this many files are found. [ScanResult.truncated] says whether
  /// it came to that.
  final int maxFiles;

  /// How far below a chosen folder to descend.
  final int maxDepth;

  /// Folders that hold machinery rather than the user's own work. Dotfiles are
  /// skipped separately, which covers `.git` and the rest.
  static const Set<String> _skippedFolders = {
    'node_modules',
    'Pods',
    'build',
    'DerivedData',
    '__pycache__',
    'venv',
    'Library',
  };

  @override
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  }) async {
    final files = <ScannedFile>[];
    var truncated = false;

    // Breadth-first, so a scan cut short by [maxFiles] still spans the chosen
    // folders rather than exhausting the first branch it wandered into.
    final queue = <({String path, int depth})>[
      for (final root in roots) (path: root, depth: 0),
    ];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);

      final List<FileSystemEntity> entities;
      try {
        entities = await Directory(
          current.path,
        ).list(followLinks: false).toList();
      } on FileSystemException {
        // An unreadable or vanished folder costs us that folder, nothing more.
        continue;
      }

      for (final entity in entities) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;

        if (entity is Directory) {
          if (_skippedFolders.contains(name)) continue;
          if (current.depth + 1 > maxDepth) continue;
          queue.add((path: entity.path, depth: current.depth + 1));
          continue;
        }

        // Symlinks are left alone: following them invites both duplicates and
        // loops, and anything worth scanning has a real path of its own.
        if (entity is! File) continue;

        if (files.length >= maxFiles) {
          truncated = true;
          queue.clear();
          break;
        }

        DateTime? modified;
        try {
          modified = (await entity.stat()).modified;
        } on FileSystemException {
          modified = null;
        }

        files.add(
          ScannedFile(
            path: entity.path,
            sourceName: sourceName,
            modified: modified,
          ),
        );

        // Reported in batches: a callback per file would rebuild the UI
        // thousands of times for no more information.
        if (files.length % 25 == 0) onProgress?.call(files.length);
      }
    }

    onProgress?.call(files.length);
    return ScanResult(files: files, truncated: truncated);
  }
}
