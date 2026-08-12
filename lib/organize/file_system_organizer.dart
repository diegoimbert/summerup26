import 'dart:io';

import '../library/library_store.dart';
import 'organize_plan.dart';
import 'source_organizer.dart';

/// Moves a file about on this Mac.
///
/// Nothing is ever overwritten and nothing ever leaves the folder Kandoo was
/// pointed at. These are the user's own documents: the worst this is allowed to
/// do is put one somewhere they did not expect, never to lose one.
class FileSystemOrganizer extends SourceOrganizer {
  const FileSystemOrganizer();

  @override
  String get sourceName => 'File System';

  @override
  bool canMove(ScannedFile file) => file.externalId == null;

  @override
  Future<Relocation> move(
    ScannedFile file, {
    required String root,
    required String relative,
  }) async {
    final segments = segmentsOf(relative);
    if (segments.isEmpty) {
      throw const OrganizeFailure('There is nowhere to move that to.');
    }
    if (root.isEmpty) {
      throw OrganizeFailure(
        '${file.name} is not inside a folder Kandoo was pointed at.',
      );
    }

    final source = File(file.path);
    if (!await source.exists()) {
      throw OrganizeFailure('${file.name} is no longer on this Mac.');
    }

    final folder = Directory('$root/${segments.take(segments.length - 1).join('/')}');
    final wanted = '${folder.path}/${segments.last}';

    if (wanted == file.path) {
      // Already there, which the plan should have noticed; nothing to do.
      return (file: file, relative: segments.join('/'));
    }

    try {
      await folder.create(recursive: true);
    } on FileSystemException {
      throw OrganizeFailure('Kandoo could not make the folder ${folder.path}.');
    }

    final destination = await _freePath(wanted);

    File landed;
    try {
      landed = await source.rename(destination);
    } on FileSystemException {
      // Across volumes a rename is not allowed, and a copy is the only way.
      try {
        landed = await source.copy(destination);
        await source.delete();
      } on FileSystemException catch (error) {
        throw OrganizeFailure(
          error.osError?.errorCode == 13
              ? 'Kandoo is not allowed to move ${file.name}.'
              : 'Could not move ${file.name}: ${error.osError?.message ?? error.message}',
        );
      }
    }

    return (
      file: ScannedFile(
        path: landed.path,
        sourceName: file.sourceName,
        modified: await _modifiedOf(landed),
      ),
      relative: placeOf(
        ScannedFile(path: landed.path, sourceName: file.sourceName),
        [root],
      ).relative,
    );
  }

  /// [wanted], or the nearest name to it that nothing already answers to.
  ///
  /// Two files can be filed under one name — the model works from names, and
  /// names repeat — and the second one to arrive must not land on the first.
  static Future<String> _freePath(String wanted) async {
    if (!await _exists(wanted)) return wanted;

    final cut = wanted.lastIndexOf('.');
    final slash = wanted.lastIndexOf('/');
    final hasExtension = cut > slash + 1;
    final stem = hasExtension ? wanted.substring(0, cut) : wanted;
    final extension = hasExtension ? wanted.substring(cut) : '';

    for (var index = 2; index < 100; index += 1) {
      final candidate = '$stem ($index)$extension';
      if (!await _exists(candidate)) return candidate;
    }

    throw OrganizeFailure('There is already a file called ${wanted.split('/').last} there.');
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  static Future<DateTime?> _modifiedOf(File file) async {
    try {
      return (await file.stat()).modified;
    } on FileSystemException {
      return null;
    }
  }
}
