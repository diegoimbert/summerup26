import 'package:flutter/material.dart';

import '../library/library_controller.dart';
import '../organize/organize_plan.dart';
import '../organize/source_organizer.dart';
import '../theme.dart';

/// Shows what Auto-organize would do, and does it if the user says so.
///
/// Nothing is touched until the button at the bottom is pressed: these are the
/// user's own files, and a list of what is about to happen to them is the least
/// they are owed before it does.
Future<OrganizeOutcome?> showOrganizePreview(
  BuildContext context, {
  required OrganizePlan plan,
  required SourceOrganizers organizers,
  required LibraryController library,
}) {
  return showDialog<OrganizeOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _OrganizePreviewDialog(
      plan: plan,
      organizers: organizers,
      library: library,
    ),
  );
}

class _OrganizePreviewDialog extends StatefulWidget {
  const _OrganizePreviewDialog({
    required this.plan,
    required this.organizers,
    required this.library,
  });

  final OrganizePlan plan;
  final SourceOrganizers organizers;
  final LibraryController library;

  @override
  State<_OrganizePreviewDialog> createState() => _OrganizePreviewDialogState();
}

class _OrganizePreviewDialogState extends State<_OrganizePreviewDialog> {
  bool _moving = false;
  int _done = 0;

  /// Filled in once the moves have been made, which turns the sheet into an
  /// account of what happened.
  OrganizeOutcome? _outcome;

  Future<void> _apply() async {
    setState(() {
      _moving = true;
      _done = 0;
    });

    final outcome = await applyMoves(
      widget.plan.moves,
      organizers: widget.organizers,
      onProgress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );

    // The library follows the files rather than being told to look again: it
    // knows exactly what moved and where it went.
    await widget.library.filesMoved(outcome.moved);
    if (!mounted) return;

    setState(() {
      _moving = false;
      _outcome = outcome;
    });

    // Nothing to report but success: the sheet has done its job.
    if (outcome.isClean && mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final moves = widget.plan.moves;
    final outcome = _outcome;

    return Dialog(
      backgroundColor: KandooColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                outcome == null
                    ? 'Move ${_files(moves.length)} into place'
                    : 'Some files could not be moved',
                style: const TextStyle(
                  fontFamily: KandooFonts.heading,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: KandooColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                outcome == null
                    ? 'Kandoo will rename and move these files on the source '
                          'itself, so it looks the way your library does.'
                    : '${_files(outcome.movedCount)} moved. '
                          'The rest were left exactly where they were.',
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: KandooColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),

              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: KandooColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: KandooColors.divider),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: outcome == null
                        ? moves.length
                        : outcome.failures.length,
                    separatorBuilder: (context, _) =>
                        const Divider(height: 1, color: KandooColors.divider),
                    itemBuilder: (context, index) {
                      if (outcome == null) {
                        return _MoveRow(move: moves[index]);
                      }
                      final failed = outcome.failures.entries.elementAt(index);
                      return _MoveRow(
                        move: failed.key,
                        failure: failed.value,
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(height: 18),
              Row(
                children: [
                  if (_moving) ...[
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'Moving $_done of ${moves.length}…',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: KandooColors.textSecondary,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (outcome != null)
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(outcome),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 13,
                        ),
                      ),
                      child: const Text('Done'),
                    )
                  else ...[
                    TextButton(
                      onPressed: _moving
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: KandooColors.textSecondary,
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _moving ? null : _apply,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 13,
                        ),
                      ),
                      child: Text('Move ${_files(moves.length)}'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _files(int count) => '$count file${count == 1 ? '' : 's'}';
}

/// One move: where the file is, and where it is going.
class _MoveRow extends StatelessWidget {
  const _MoveRow({required this.move, this.failure});

  final OrganizeMove move;

  /// Why it did not happen, once it has been tried and has not.
  final String? failure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            move.from,
            style: const TextStyle(
              fontFamily: KandooFonts.mono,
              fontSize: 11.5,
              color: KandooColors.textMuted,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 7),
                child: Icon(
                  Icons.subdirectory_arrow_right,
                  size: 13,
                  color: KandooColors.textMuted,
                ),
              ),
              Expanded(
                child: Text(
                  move.to,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: KandooColors.accentDeep,
                  ),
                ),
              ),
            ],
          ),
          if (failure != null) ...[
            const SizedBox(height: 4),
            Text(
              failure!,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFFC0392B),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
