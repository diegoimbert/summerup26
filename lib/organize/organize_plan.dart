import 'package:flutter/foundation.dart';

import '../library/library_store.dart';

/// One file that is not where the library says it belongs.
///
/// [from] and [to] are both relative to [root] — the folder the source was
/// pointed at — because that is the only footing on which a real path and a
/// path the model invented can be compared at all.
@immutable
class OrganizeMove {
  const OrganizeMove({
    required this.entry,
    required this.root,
    required this.from,
    required this.to,
  });

  final LibraryEntry entry;

  /// The configured folder this file lives under. Empty when the source was
  /// taken whole, which is what an unset scope means everywhere in Kandoo.
  final String root;

  /// Where the file is now.
  final String from;

  /// Where the library says it should be, name and all.
  final String to;

  ScannedFile get file => entry.file;
}

/// What tidying one source would come to.
@immutable
class OrganizePlan {
  const OrganizePlan({required this.moves, required this.inPlace});

  final List<OrganizeMove> moves;

  /// Files already where the library says they should be.
  final int inPlace;

  int get total => moves.length + inPlace;

  bool get isTidy => moves.isEmpty;
}

/// Which of [entries] are not where the library says they should be.
///
/// A file is in place when the path it can be reached by on its source — with
/// the configured folder taken off the front — is the path the model filed it
/// under. Anything else is a move waiting to happen.
OrganizePlan planFor({
  required String sourceName,
  required List<LibraryEntry> entries,
  required List<String> roots,
}) {
  final moves = <OrganizeMove>[];
  var inPlace = 0;

  for (final entry in entries) {
    if (entry.file.sourceName != sourceName) continue;

    final place = placeOf(entry.file, roots);
    final to = normalisePath(entry.organizedPath);

    if (place.relative == to) {
      inPlace += 1;
      continue;
    }

    moves.add(
      OrganizeMove(
        entry: entry,
        root: place.root,
        from: place.relative,
        to: to,
      ),
    );
  }

  // In the order the user reads them: by where they are going, so a folder's
  // worth of moves is one block of the preview rather than four scattered ones.
  moves.sort((a, b) => a.to.toLowerCase().compareTo(b.to.toLowerCase()));

  return OrganizePlan(moves: moves, inPlace: inPlace);
}

/// Where [file] sits, split into the folder Kandoo was pointed at and the part
/// of the path that is the library's business.
///
/// The root comes back as the user wrote it, because that is what has to be
/// handed to a disk or a drive again; only the part underneath is reduced to
/// bare segments, since that is all that is ever compared.
({String root, String relative}) placeOf(ScannedFile file, List<String> roots) {
  final path = segmentsOf(file.path);

  // The innermost configured folder holding the file: two roots can nest, and
  // it is the nearer one the file was found through.
  List<String>? deepest;
  var root = '';

  for (final candidate in roots) {
    final segments = segmentsOf(candidate);
    if (segments.isEmpty) continue;
    if (!_startsWith(path, segments)) continue;
    if (deepest != null && segments.length <= deepest.length) continue;

    deepest = segments;
    root = _trimmed(candidate);
  }

  return (
    root: root,
    relative: path.skip(deepest?.length ?? 0).join('/'),
  );
}

/// A path as bare segments: `/Work/Invoices/` and `Work/Invoices` name the same
/// place, and neither leads anywhere but where it says.
String normalisePath(String path) => segmentsOf(path).join('/');

List<String> segmentsOf(String path) => [
  for (final segment in path.split('/'))
    if (segment.trim().isNotEmpty && segment.trim() != '.') segment.trim(),
];

/// [candidate] as the user wrote it, without a trailing separator — so an
/// absolute path stays absolute.
String _trimmed(String candidate) {
  final path = candidate.trim();
  return path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
}

bool _startsWith(List<String> path, List<String> prefix) {
  if (prefix.length > path.length) return false;
  for (var index = 0; index < prefix.length; index += 1) {
    if (path[index] != prefix[index]) return false;
  }
  return true;
}
