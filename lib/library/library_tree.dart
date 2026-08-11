import '../widgets/tree_viewer.dart';
import 'library_store.dart';

/// The organized library, in the shape the Files section browses.
///
/// This is the virtual file system: folders that exist only because the model
/// put files in them. Everything is in memory, so [childrenOf] answers at once
/// — the tree viewer's laziness costs nothing here and keeps one code path for
/// both this and the real sources.
class LibraryTree {
  LibraryTree._(this._children, this.fileCount);

  /// Rows by parent id; the empty key is the top level.
  final Map<String, List<TreeEntry>> _children;

  final int fileCount;

  bool get isEmpty => fileCount == 0;

  factory LibraryTree.from(List<LibraryEntry> entries) {
    // Folder id -> the entries filed anywhere beneath it, so a folder can say
    // how much it holds and which sources it draws on.
    final beneath = <String, List<LibraryEntry>>{};
    final folders = <String, Set<String>>{};
    final filesIn = <String, List<LibraryEntry>>{};

    for (final entry in entries) {
      final path = entry.folders;
      var parent = '';

      for (final folder in path) {
        final id = parent.isEmpty ? folder : '$parent/$folder';
        (folders[parent] ??= <String>{}).add(id);
        (beneath[id] ??= []).add(entry);
        parent = id;
      }

      (filesIn[parent] ??= []).add(entry);
    }

    final children = <String, List<TreeEntry>>{};
    for (final parent in {...folders.keys, ...filesIn.keys}) {
      final rows = <TreeEntry>[];

      final subfolders = (folders[parent] ?? const <String>{}).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final id in subfolders) {
        final held = beneath[id] ?? const <LibraryEntry>[];
        rows.add(
          TreeEntry(
            id: id,
            label: id.split('/').last,
            isFolder: true,
            detail: _folderDetail(held),
          ),
        );
      }

      // Newest first, the way a person looks for something they were just
      // working on.
      final files = [...(filesIn[parent] ?? const <LibraryEntry>[])]
        ..sort((a, b) {
          final left = a.file.modified;
          final right = b.file.modified;
          if (left == null || right == null) {
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          return right.compareTo(left);
        });

      for (final entry in files) {
        rows.add(
          TreeEntry(
            // The original path is what makes a row unique: two folders can
            // hold files the model gave the same title.
            id: 'file:${entry.file.path}',
            label: entry.title,
            detail: _fileDetail(entry),
          ),
        );
      }

      children[parent] = rows;
    }

    return LibraryTree._(children, entries.length);
  }

  /// Rows under [parent], for [TreeViewer].
  Future<List<TreeEntry>> childrenOf(TreeEntry? parent) async =>
      _children[parent?.id ?? ''] ?? const [];

  static String _folderDetail(List<LibraryEntry> held) {
    final count = held.length;
    final sources = <String>{for (final entry in held) entry.file.sourceName};

    final names = sources.toList()..sort();
    final label = names.length > 3
        ? '${names.take(3).join(' + ')} + ${names.length - 3} more'
        : names.join(' + ');

    return '${count == 1 ? '1 file' : '$count files'} · $label';
  }

  static String _fileDetail(LibraryEntry entry) {
    final modified = entry.file.modified;
    return [
      ?(modified == null ? null : _isoDate(modified)),
      entry.file.sourceName,
    ].join(' · ');
  }

  static String _isoDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
