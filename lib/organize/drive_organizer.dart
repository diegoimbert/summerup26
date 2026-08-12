import '../chat/drive_document_reader.dart' show DriveApiFactory;
import '../library/library_store.dart';
import '../sources/google_drive_api.dart';
import 'organize_plan.dart';
import 'source_organizer.dart';

/// Moves a file about in the user's Google Drive.
///
/// A drive has no paths, only parents, so a move is two things: the folders the
/// file is going into have to exist — made on the way down if they do not — and
/// the file is then re-parented and renamed in one request.
class GoogleDriveOrganizer extends SourceOrganizer {
  const GoogleDriveOrganizer({required this.api});

  final DriveApiFactory api;

  @override
  String get sourceName => 'Google Drive';

  @override
  bool canMove(ScannedFile file) =>
      file.externalId != null && file.sourceName == sourceName;

  @override
  Future<Relocation> move(
    ScannedFile file, {
    required String root,
    required String relative,
  }) async {
    final id = file.externalId;
    if (id == null) {
      throw OrganizeFailure('${file.name} is not a Google Drive file.');
    }

    final segments = segmentsOf(relative);
    if (segments.isEmpty) {
      throw const OrganizeFailure('There is nowhere to move that to.');
    }

    final drive = await api();
    if (drive == null) {
      throw const OrganizeFailure(
        'Google Drive is not connected — connect it again under Sources.',
      );
    }

    final name = segments.last;
    // Under the folder the drive was narrowed to, so tidying a scope does not
    // move files out of it.
    final folders = [
      ...segmentsOf(root),
      ...segments.take(segments.length - 1),
    ].join('/');

    try {
      final parentId = folders.isEmpty
          ? GoogleDriveApi.rootId
          : await drive.ensureFolder(folders);

      final info = await drive.info(id);
      await drive.moveFile(
        id,
        name: name,
        parentId: parentId,
        removeParents: info.parents,
      );

      return (
        file: ScannedFile(
          path: '/${[...segmentsOf(root), ...segments].join('/')}',
          sourceName: file.sourceName,
          modified: file.modified,
          externalId: id,
        ),
        relative: segments.join('/'),
      );
    } on DriveException catch (failure) {
      // Drive's own messages already say what the user should do about it.
      throw OrganizeFailure(failure.message);
    }
  }
}
