import 'dart:io';

import '../widgets/tree_viewer.dart';

/// Lists folders and files on this Mac, one directory at a time, in the shape
/// a [TreeViewer] wants.
///
/// Nothing is walked recursively: a folder is read only when the user opens it,
/// which is what keeps browsing a home directory from stalling on the first
/// paint.
class FileSystemBrowser {
  const FileSystemBrowser({required this.rootPath});

  /// The folder the tree is rooted at. Everything the user can reach through
  /// this browser lives underneath it.
  final String rootPath;

  /// The contents of [parent], or of [rootPath] at the top level.
  Future<List<TreeEntry>> children(TreeEntry? parent) async {
    final directory = Directory(parent?.id ?? rootPath);

    final List<FileSystemEntity> entities;
    try {
      entities = await directory.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      throw TreeLoadException(_messageFor(error));
    }

    final entries = <TreeEntry>[];
    for (final entity in entities) {
      final name = entity.path.split(Platform.pathSeparator).last;

      // Dotfiles are hidden here as they are in Finder: they are noise next to
      // the documents the user came to find.
      if (name.startsWith('.')) continue;

      entries.add(
        TreeEntry(
          id: entity.path,
          label: name,
          // A symlink is listed unresolved, so its target decides whether it
          // opens as a folder.
          isFolder:
              entity is Directory ||
              (entity is Link &&
                  await FileSystemEntity.isDirectory(entity.path)),
        ),
      );
    }

    // Folders first, then files, each alphabetically the way a file browser
    // would order them.
    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });

    return entries;
  }

  /// Turns an OS error into something worth showing in a row.
  static String _messageFor(FileSystemException error) {
    return switch (error.osError?.errorCode) {
      1 || 13 => 'Kandoo is not allowed to read this folder.',
      2 => 'This folder no longer exists.',
      20 => 'This is not a folder.',
      _ => 'This folder could not be opened.',
    };
  }
}
