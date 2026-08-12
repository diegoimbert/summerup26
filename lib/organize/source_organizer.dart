import '../library/library_store.dart';
import 'organize_plan.dart';

/// Where a file ended up, once its source had moved it.
///
/// [relative] is where it actually landed, which is not always where it was
/// asked to go: a name can be taken already. The library is told what happened
/// rather than what was intended, so the two views stay the same view.
typedef Relocation = ({ScannedFile file, String relative});

/// Thrown when a move cannot be made. The message is written to be shown beside
/// the file it belongs to.
class OrganizeFailure implements Exception {
  const OrganizeFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Moves a file into place on the source it lives on.
///
/// The other half of [DocumentReader]'s seam: one implementation per place a
/// file can live, since renaming a file on this Mac and re-parenting a file in
/// somebody's Drive have nothing in common but the intent.
abstract class SourceOrganizer {
  const SourceOrganizer();

  /// The source this speaks for, as the user knows it.
  String get sourceName;

  bool canMove(ScannedFile file);

  /// Moves [file] to [relative] under [root], and says where it landed.
  Future<Relocation> move(
    ScannedFile file, {
    required String root,
    required String relative,
  });
}

/// The organizers this build has, asked in turn.
class SourceOrganizers {
  const SourceOrganizers(this.organizers);

  final List<SourceOrganizer> organizers;

  SourceOrganizer? forFile(ScannedFile file) {
    for (final organizer in organizers) {
      if (organizer.canMove(file)) return organizer;
    }
    return null;
  }

  /// Whether files from [sourceName] can be moved at all in this build.
  bool handles(String sourceName) =>
      organizers.any((organizer) => organizer.sourceName == sourceName);
}

/// What came of carrying out a plan.
class OrganizeOutcome {
  const OrganizeOutcome({required this.moved, required this.failures});

  /// The library entry each moved file should now be, by the identity it had
  /// before it moved.
  final Map<String, LibraryEntry> moved;

  /// What went wrong, per move, for the ones that did.
  final Map<OrganizeMove, String> failures;

  int get movedCount => moved.length;
  bool get isClean => failures.isEmpty;
}

/// Carries out [moves], one file at a time.
///
/// One at a time on purpose: these are the user's own documents being moved
/// about, and a failure halfway through should leave a plain account of what
/// did and did not happen rather than a race.
Future<OrganizeOutcome> applyMoves(
  List<OrganizeMove> moves, {
  required SourceOrganizers organizers,
  void Function(int done, int total)? onProgress,
}) async {
  final moved = <String, LibraryEntry>{};
  final failures = <OrganizeMove, String>{};

  for (var index = 0; index < moves.length; index += 1) {
    final move = moves[index];
    final organizer = organizers.forFile(move.file);

    if (organizer == null) {
      failures[move] = 'Kandoo cannot move files on ${move.file.sourceName}.';
    } else {
      try {
        final landed = await organizer.move(
          move.file,
          root: move.root,
          relative: move.to,
        );

        moved[move.file.identity] = LibraryEntry(
          file: landed.file,
          // Where it actually is, so the library and the source agree even when
          // the move had to settle for a different name.
          organizedPath: landed.relative,
        );
      } on OrganizeFailure catch (failure) {
        failures[move] = failure.message;
      } catch (failure) {
        failures[move] = 'Could not move ${move.file.name}: $failure';
      }
    }

    onProgress?.call(index + 1, moves.length);
  }

  return OrganizeOutcome(moved: moved, failures: failures);
}
