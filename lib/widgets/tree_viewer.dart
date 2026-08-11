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

/// What is known about one folder's contents.
class _Branch {
  bool expanded = false;
  bool loading = false;
  String? error;
  List<TreeEntry>? children;
}

class _TreeViewerState extends State<TreeViewer> {
  /// Keyed by entry id; the null key is the top level.
  final Map<String?, _Branch> _branches = {};

  @override
  void initState() {
    super.initState();
    _branches[null] = _Branch()..expanded = true;
    _load(null);
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
  }

  void _toggle(TreeEntry entry) {
    final branch = _branches[entry.id];

    // First open: nothing has been fetched for this folder yet.
    if (branch == null) {
      _branches[entry.id] = _Branch()..expanded = true;
      _load(entry);
      return;
    }

    // An open folder that failed to list retries rather than collapsing, so a
    // transient error is one click from being cleared.
    if (branch.expanded && branch.error != null) {
      _load(entry);
      return;
    }

    setState(() => branch.expanded = !branch.expanded);
  }

  /// Flattens the opened parts of the tree into the rows to draw.
  List<_Row> _rows() {
    final rows = <_Row>[];

    void walk(TreeEntry? parent, int depth) {
      final branch = _branches[parent?.id];
      if (branch == null) return;

      if (branch.loading) {
        rows.add(_NoteRow(depth: depth, text: 'Loading…', spinner: true));
        return;
      }
      final error = branch.error;
      if (error != null) {
        rows.add(_NoteRow(depth: depth, text: error, isError: true));
        return;
      }

      final children = branch.children ?? const <TreeEntry>[];
      if (children.isEmpty) {
        rows.add(_NoteRow(depth: depth, text: widget.emptyMessage));
        return;
      }

      for (final entry in children) {
        final child = _branches[entry.id];
        final expanded = entry.isFolder && (child?.expanded ?? false);
        rows.add(_EntryRow(depth: depth, entry: entry, expanded: expanded));
        if (expanded) walk(entry, depth + 1);
      }
    }

    walk(null, 0);
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
        return switch (row) {
          _EntryRow() => _TreeTile(
            entry: row.entry,
            depth: row.depth,
            expanded: row.expanded,
            onTap: row.entry.isFolder ? () => _toggle(row.entry) : null,
          ),
          _NoteRow() => _NoteTile(row: row),
        };
      },
    );
  }
}

sealed class _Row {
  const _Row({required this.depth});

  final int depth;
}

class _EntryRow extends _Row {
  const _EntryRow({
    required super.depth,
    required this.entry,
    required this.expanded,
  });

  final TreeEntry entry;
  final bool expanded;
}

class _NoteRow extends _Row {
  const _NoteRow({
    required super.depth,
    required this.text,
    this.spinner = false,
    this.isError = false,
  });

  final String text;
  final bool spinner;
  final bool isError;
}

/// Indentation of a row at [depth], leaving room for the chevron column.
double _indentFor(int depth) => 10 + depth * 17;

class _TreeTile extends StatefulWidget {
  const _TreeTile({
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.onTap,
  });

  final TreeEntry entry;
  final int depth;
  final bool expanded;
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
          height: 30,
          padding: EdgeInsets.only(left: _indentFor(widget.depth), right: 12),
          color: _hovered ? KandooColors.hoverFill : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 17,
                child: entry.isFolder
                    ? Icon(
                        widget.expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                        color: KandooColors.textMuted,
                      )
                    : null,
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
      height: 30,
      padding: EdgeInsets.only(left: _indentFor(row.depth) + 17, right: 12),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          if (row.spinner) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 9),
          ] else if (row.isError) ...[
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
