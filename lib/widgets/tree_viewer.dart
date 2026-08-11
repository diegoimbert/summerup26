import 'package:flutter/material.dart';

import '../theme.dart';

/// One row of a [TreeViewer]: a folder that can be opened, or a leaf.
@immutable
class TreeEntry {
  const TreeEntry({
    required this.id,
    required this.label,
    this.isFolder = false,
    this.icon,
    this.detail,
    this.trailing,
  });

  /// Stable identity, and what the loader is handed to fetch children. A path
  /// for the file system, a file id for a drive.
  final String id;

  final String label;

  /// Whether this row can be expanded. Only folders get a chevron.
  final bool isFolder;

  /// Overrides the default folder/file icon, for sources whose items have a
  /// type of their own (a doc, a spreadsheet, …).
  final IconData? icon;

  /// Metadata shown quietly at the end of the row: how much a folder holds, or
  /// when a file last changed.
  final String? detail;

  /// Drawn after [detail], for what a row is better off showing than saying —
  /// the brand marks of the sources behind it, typically.
  final Widget? trailing;
}

/// Thrown by a loader when a folder cannot be listed. The message is shown in
/// place of that folder's contents, so it should be worth reading.
class TreeLoadException implements Exception {
  const TreeLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches the children of [parent], or the top level when [parent] is null.
typedef TreeChildrenLoader =
    Future<List<TreeEntry>> Function(TreeEntry? parent);

/// A lazily loaded folder tree.
///
/// Only the top level is fetched up front; every folder starts collapsed and
/// its contents are loaded the first time it is opened, then kept for as long
/// as the viewer is alive. That keeps a source with thousands of nested items
/// to one request per folder the user actually looks inside.
///
/// The viewer knows nothing about where the rows come from — give it a
/// [loadChildren] and it will browse a disk, a drive or anything else. Key the
/// widget on whatever the loader is rooted at, so pointing it somewhere new
/// starts from a clean tree rather than reusing the old one's expansions.
class TreeViewer extends StatefulWidget {
  const TreeViewer({
    super.key,
    required this.loadChildren,
    this.emptyMessage = 'This folder is empty',
    this.padding = const EdgeInsets.symmetric(vertical: 6),
  });

  final TreeChildrenLoader loadChildren;

  /// Shown when a folder turns out to hold nothing.
  final String emptyMessage;

  final EdgeInsets padding;

  @override
  State<TreeViewer> createState() => _TreeViewerState();
}

/// What is known about one folder's contents, and how much of it is on screen.
class _Branch {
  /// What the user asked for. The reveal below may still be catching up.
  bool open = false;

  bool loading = false;
  String? error;
  List<TreeEntry>? children;

  /// 0 when the folder is closed, 1 when its contents are fully out. Null for
  /// the top level, which is never revealed because it is never hidden.
  AnimationController? reveal;

  /// [reveal], eased. This is what the rows are scaled by.
  CurvedAnimation? eased;

  /// Whether this folder's rows belong on screen at all: while collapsing they
  /// are still there, just shrinking.
  bool get isShowing => open || (reveal?.value ?? 0) > 0;

  void dispose() {
    eased?.dispose();
    reveal?.dispose();
  }
}

class _TreeViewerState extends State<TreeViewer> with TickerProviderStateMixin {
  /// Keyed by entry id; the null key is the top level.
  final Map<String?, _Branch> _branches = {};

  /// Long enough to read as a movement, short enough not to be waited on.
  static const Duration _revealDuration = Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    _branches[null] = _Branch()..open = true;
    _load(null);
  }

  @override
  void dispose() {
    for (final branch in _branches.values) {
      branch.dispose();
    }
    super.dispose();
  }

  Future<void> _load(TreeEntry? parent) async {
    final branch = _branches.putIfAbsent(parent?.id, _Branch.new);
    setState(() {
      branch.loading = true;
      branch.error = null;
    });

    try {
      final children = await widget.loadChildren(parent);
      if (!mounted) return;
      setState(() {
        branch.children = children;
        branch.loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        branch.error = error is TreeLoadException
            ? error.message
            : 'This folder could not be opened.';
        branch.loading = false;
      });
    }

    // The contents animate out once there are contents: a folder still being
    // read says so on its own row, rather than growing to hold a spinner and
    // then jumping to fit what arrives.
    if (parent != null && branch.open) _reveal(branch, open: true);
  }

  /// Grows or shrinks a folder's contents.
  void _reveal(_Branch branch, {required bool open}) {
    final controller = branch.reveal ??= AnimationController(
      vsync: this,
      duration: _revealDuration,
    );
    branch.eased ??= CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    // Someone who has turned animations off is asking not to be kept waiting.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      setState(() => controller.value = open ? 1 : 0);
      return;
    }

    if (open) {
      controller.forward();
    } else {
      // Rows leave the list only once they have finished shrinking.
      controller.reverse().whenCompleteOrCancel(() {
        if (mounted) setState(() {});
      });
    }
  }

  void _toggle(TreeEntry entry) {
    final branch = _branches[entry.id];

    // First open: nothing has been fetched for this folder yet, so the reveal
    // waits for [_load] to come back with something to reveal.
    if (branch == null) {
      _branches[entry.id] = _Branch()..open = true;
      _load(entry);
      return;
    }

    // An open folder that failed to list retries rather than collapsing, so a
    // transient error is one click from being cleared.
    if (branch.open && branch.error != null) {
      _load(entry);
      return;
    }

    setState(() => branch.open = !branch.open);
    if (branch.children == null && branch.open) {
      // Opened again before its first read ever finished.
      if (!branch.loading) _load(entry);
      return;
    }
    _reveal(branch, open: branch.open);
  }

  /// Flattens the opened parts of the tree into the rows to draw.
  ///
  /// A row carries the reveals of every folder it sits inside, because a
  /// subtree opening inside another that is itself still opening is scaled by
  /// both.
  List<_Row> _rows() {
    final rows = <_Row>[];

    void walk(TreeEntry? parent, int depth, List<Animation<double>> reveals) {
      final branch = _branches[parent?.id];
      if (branch == null) return;

      final error = branch.error;
      if (error != null) {
        rows.add(
          _NoteRow(depth: depth, reveals: reveals, text: error, isError: true),
        );
        return;
      }

      final children = branch.children;
      // Still being read: the folder's own row carries the spinner.
      if (children == null) return;

      if (children.isEmpty) {
        rows.add(
          _NoteRow(depth: depth, reveals: reveals, text: widget.emptyMessage),
        );
        return;
      }

      for (final entry in children) {
        final child = _branches[entry.id];
        final showing = entry.isFolder && (child?.isShowing ?? false);

        rows.add(
          _EntryRow(
            depth: depth,
            reveals: reveals,
            entry: entry,
            open: child?.open ?? false,
            loading: child?.loading ?? false,
          ),
        );

        if (showing) {
          final reveal = child!.eased;
          walk(entry, depth + 1, [...reveals, ?reveal]);
        }
      }
    }

    walk(null, 0, const []);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();

    // The top level has its own centred treatment: an inline spinner or error
    // where the whole tree should be reads as a broken row otherwise.
    final root = _branches[null]!;
    if (root.loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (root.error != null) {
      return _RootNote(icon: Icons.lock_outline, message: root.error!);
    }
    if ((root.children ?? const []).isEmpty) {
      return _RootNote(
        icon: Icons.folder_open_outlined,
        message: widget.emptyMessage,
      );
    }

    return ListView.builder(
      padding: widget.padding,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return _Revealed(
          reveals: row.reveals,
          child: switch (row) {
            _EntryRow() => _TreeTile(
              entry: row.entry,
              depth: row.depth,
              expanded: row.open,
              loading: row.loading,
              onTap: row.entry.isFolder ? () => _toggle(row.entry) : null,
            ),
            _NoteRow() => _NoteTile(row: row),
          },
        );
      },
    );
  }
}

/// A row being grown into place, or shrunk out of it.
///
/// Scaling each row rather than wrapping the subtree keeps the list lazy: the
/// folder still appears to grow as one, because every row inside it moves
/// together.
class _Revealed extends StatelessWidget {
  const _Revealed({required this.reveals, required this.child});

  /// The reveals of every folder this row sits inside, outermost first.
  final List<Animation<double>> reveals;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reveals.isEmpty) return child;

    return AnimatedBuilder(
      animation: Listenable.merge(reveals),
      child: child,
      builder: (context, child) {
        var factor = 1.0;
        for (final reveal in reveals) {
          factor *= reveal.value;
        }
        if (factor >= 1) return child!;

        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: factor.clamp(0.0, 1.0),
            // Fading as it goes keeps a half-height row from reading as a
            // clipped one.
            child: Opacity(opacity: factor.clamp(0.0, 1.0), child: child),
          ),
        );
      },
    );
  }
}

sealed class _Row {
  const _Row({required this.depth, required this.reveals});

  final int depth;

  /// The reveals of the folders this row sits inside; empty at the top level.
  final List<Animation<double>> reveals;
}

class _EntryRow extends _Row {
  const _EntryRow({
    required super.depth,
    required super.reveals,
    required this.entry,
    required this.open,
    required this.loading,
  });

  final TreeEntry entry;

  /// Whether this row's own folder is open.
  final bool open;

  /// Whether its contents are still being read.
  final bool loading;
}

class _NoteRow extends _Row {
  const _NoteRow({
    required super.depth,
    required super.reveals,
    required this.text,
    this.isError = false,
  });

  final String text;
  final bool isError;
}

/// Row height. Tall enough that a long list reads as a list rather than a
/// block of text.
const double _rowHeight = 36;

/// Indentation of a row at [depth], leaving room for the chevron column.
double _indentFor(int depth) => 10 + depth * 17;

class _TreeTile extends StatefulWidget {
  const _TreeTile({
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.loading,
    required this.onTap,
  });

  final TreeEntry entry;
  final int depth;
  final bool expanded;

  /// Whether this folder's contents are on their way. Said here rather than on
  /// a row of its own, so what arrives can grow into place.
  final bool loading;

  final VoidCallback? onTap;

  @override
  State<_TreeTile> createState() => _TreeTileState();
}

class _TreeTileState extends State<_TreeTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final icon =
        entry.icon ??
        (entry.isFolder
            ? (widget.expanded ? Icons.folder_open : Icons.folder_outlined)
            : Icons.insert_drive_file_outlined);

    return MouseRegion(
      cursor: entry.isFolder
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: _rowHeight,
          padding: EdgeInsets.only(left: _indentFor(widget.depth), right: 12),
          color: _hovered ? KandooColors.hoverFill : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 17,
                child: switch ((entry.isFolder, widget.loading)) {
                  (true, true) => const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                  (true, false) => Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: KandooColors.textMuted,
                  ),
                  _ => null,
                },
              ),
              Icon(
                icon,
                size: 15,
                color: entry.isFolder
                    ? KandooColors.accentDeep
                    : KandooColors.textMuted,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  entry.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: KandooColors.textPrimary,
                  ),
                ),
              ),
              if (entry.detail != null) ...[
                const SizedBox(width: 12),
                // Bounded so a long detail gives way to the name rather than
                // squeezing it out.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Text(
                    entry.detail!,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontFamily: KandooFonts.mono,
                      fontSize: 10.5,
                      color: KandooColors.textMuted,
                    ),
                  ),
                ),
              ],
              if (entry.trailing != null) ...[
                const SizedBox(width: 10),
                entry.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A row standing in for a folder's contents: loading, empty, or a failure.
class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.row});

  final _NoteRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _rowHeight,
      padding: EdgeInsets.only(left: _indentFor(row.depth) + 17, right: 12),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          if (row.isError) ...[
            const Icon(
              Icons.error_outline,
              size: 14,
              color: KandooColors.textSecondary,
            ),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(
              row.text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: KandooColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole-tree version of a note, for when the top level itself has nothing
/// to show.
class _RootNote extends StatelessWidget {
  const _RootNote({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: KandooColors.textMuted),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: KandooColors.textMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
