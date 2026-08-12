import '../library/library_store.dart';

/// The organized library as the assistant walks it.
///
/// The Files section shows the same virtual tree as rows on a screen; this
/// shows it as lines of text a model can read, and gives every file a number to
/// ask for it by. Numbers rather than paths because a path is something a model
/// can misremember or invent, while a number either names a file in this
/// library or does not.
class LibraryNavigator {
  LibraryNavigator(this.entries);

  final List<LibraryEntry> entries;

  /// A file's number is where it sits in the library, so the same file keeps
  /// the same number for as long as the conversation lasts.
  LibraryEntry? at(int id) =>
      id >= 0 && id < entries.length ? entries[id] : null;

  /// The folders and files directly under [path]; the empty path is the top.
  ///
  /// Returns null when there is no such folder, which the caller says out loud
  /// rather than passing off as an empty one.
  String? listing(String path) {
    final folder = _normalise(path);
    if (folder.isNotEmpty && !_folders().contains(folder)) return null;

    final lines = <String>[];

    for (final child in _childFoldersOf(folder)) {
      final held = _countBeneath(child);
      lines.add('[folder] $child — $held file${held == 1 ? '' : 's'}');
    }

    for (final id in _fileIdsIn(folder)) {
      lines.add(_line(id));
    }

    if (lines.isEmpty) {
      return '${folder.isEmpty ? 'The top level' : folder} is empty.';
    }
    return '${folder.isEmpty ? 'Top level' : folder}:\n${lines.join('\n')}';
  }

  /// The files whose name, folders or original path mention [query].
  ///
  /// Words rather than a phrase: a person asking about "2025 tax" should find
  /// `Self/Finance/Tax return 2025.pdf`, which contains both words and the
  /// phrase neither.
  String search(String query, {int limit = 30}) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length > 1)
        .toList();

    if (words.isEmpty) return 'Nothing to search for.';

    final scored = <({int id, int score})>[];
    for (var id = 0; id < entries.length; id += 1) {
      final entry = entries[id];
      final haystack =
          '${entry.organizedPath} ${entry.file.path}'.toLowerCase();

      var score = 0;
      for (final word in words) {
        if (haystack.contains(word)) score += 1;
      }
      if (score > 0) scored.add((id: id, score: score));
    }

    if (scored.isEmpty) return 'No files match "$query".';

    // Most of the words first; ties keep library order, which is the order the
    // sources were scanned in.
    scored.sort((a, b) => b.score.compareTo(a.score));

    final shown = scored.take(limit).toList();
    final lines = [for (final match in shown) _line(match.id, withFolder: true)];

    return [
      '${scored.length} file${scored.length == 1 ? '' : 's'} match "$query"'
          '${scored.length > shown.length ? ', best $limit shown' : ''}:',
      ...lines,
    ].join('\n');
  }

  /// The top of the library, for the model's first look at it.
  String get overview {
    if (entries.isEmpty) return 'The library is empty.';
    return listing('') ?? 'The library is empty.';
  }

  /// One file as a line: its number, its name, where it came from.
  String _line(int id, {bool withFolder = false}) {
    final entry = entries[id];
    final modified = entry.file.modified;
    final folders = entry.folders.join('/');

    return [
      '#$id',
      if (withFolder && folders.isNotEmpty)
        '$folders/${entry.title}'
      else
        entry.title,
      entry.file.sourceName,
      if (modified != null) _isoDate(modified),
    ].join(' | ');
  }

  /// Every folder the library uses, at every level.
  Set<String> _folders() {
    final folders = <String>{};
    for (final entry in entries) {
      final path = entry.folders;
      for (var depth = 1; depth <= path.length; depth += 1) {
        folders.add(path.take(depth).join('/'));
      }
    }
    return folders;
  }

  List<String> _childFoldersOf(String parent) {
    final prefix = parent.isEmpty ? '' : '$parent/';
    final children = <String>{};

    for (final folder in _folders()) {
      if (!folder.startsWith(prefix)) continue;
      final rest = folder.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      children.add(folder);
    }

    return children.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<int> _fileIdsIn(String folder) => [
    for (var id = 0; id < entries.length; id += 1)
      if (entries[id].folders.join('/') == folder) id,
  ];

  int _countBeneath(String folder) {
    var held = 0;
    for (final entry in entries) {
      final path = entry.folders.join('/');
      if (path == folder || path.startsWith('$folder/')) held += 1;
    }
    return held;
  }

  /// Trims what the model asked for to a bare folder path: `/Self/Finance/`
  /// and `Self/Finance` are the same folder.
  static String _normalise(String path) => path
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .join('/');

  static String _isoDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
