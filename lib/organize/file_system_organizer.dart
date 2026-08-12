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
    } on FileSystemException catch (error) {
      throw OrganizeFailure(
        'Could not make the folder ${folder.path}: ${_reasonFor(error)}',
      );
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
          'Could not move ${file.name}: ${_reasonFor(error)}',
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

  /// Why the disk said no, in words that say what to do about it.
  ///
  /// Worth the trouble because the likeliest answer by far is the sandbox:
  /// Kandoo is allowed to read the user's folders because its entitlements say
  /// so, and it can write to them for the same reason — a build whose
  /// entitlements grant only reads refuses every move, and should say that
  /// rather than leaving the user to guess at a folder that looks fine in
  /// Finder.
  static String _reasonFor(FileSystemException error) =>
      switch (error.osError?.errorCode) {
        1 || 13 =>
          'Kandoo is not allowed to write there. If this is a build of Kandoo '
              'without write access to your folders, nothing it does here will '
              'stick.',
        17 || 20 => 'Something that is not a folder is already in the way.',
        28 => 'There is no room left on the disk.',
        30 => 'That disk is read-only.',
        _ => error.osError?.message ?? error.message,
      };

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
