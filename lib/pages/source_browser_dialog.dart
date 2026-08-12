import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/library_controller.dart';
import '../organize/organize_plan.dart';
import '../organize/source_organizer.dart';
import '../sources/connections.dart';
import '../sources/item_actions.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/source_logo.dart';
import '../widgets/tree_viewer.dart';
import 'organize_preview_dialog.dart';

/// Opens a source as it really is, over the section rather than in place of it.
///
/// The library is the point of the Files section; a source's own tree is
/// something the user drops into and comes back out of, which is what a sheet
/// over the top says and what replacing the page did not.
Future<void> showSourceBrowser(
  BuildContext context, {
  required SourceDescriptor source,
  required ConnectionsController connections,
  required LibraryController library,
  required SourceOrganizers organizers,
  required TreeChildrenLoader Function(String root) loaderFor,
  UrlOpener openUrl = openWithSystem,
  bool browsable = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SourceBrowser(
      source: source,
      connections: connections,
      library: library,
      organizers: organizers,
      loaderFor: loaderFor,
      openUrl: openUrl,
      browsable: browsable,
    ),
  );
}

class _SourceBrowser extends StatefulWidget {
  const _SourceBrowser({
    required this.source,
    required this.connections,
    required this.library,
    required this.organizers,
    required this.loaderFor,
    required this.openUrl,
    required this.browsable,
  });

  final SourceDescriptor source;
  final ConnectionsController connections;
  final LibraryController library;
  final SourceOrganizers organizers;
  final TreeChildrenLoader Function(String root) loaderFor;
  final UrlOpener openUrl;

  /// False for a source Kandoo can scan but cannot yet list a folder at a time.
  final bool browsable;

  @override
  State<_SourceBrowser> createState() => _SourceBrowserState();
}

class _SourceBrowserState extends State<_SourceBrowser> {
  /// The folder the tree is rooted at, out of the ones the source was narrowed
  /// to. The whole source when it was narrowed to nothing.
  late String _root = _folders.isEmpty ? '/' : _folders.first;

  List<String> get _folders => widget.connections.foldersFor(widget.source.id);

  Future<void> _open(Uri url, {required String what}) async {
    final opened = await widget.openUrl(url);
    if (opened || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open $what.'),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  Future<void> _copy(String value, {required String what}) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what copied.'),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  /// What a row of the source's own tree offers, which depends on whether its
  /// files are on this Mac at all.
  List<TreeAction> _actionsFor(TreeEntry entry) {
    if (widget.source.id == 'google_drive') {
      final url = driveItemUrl(entry.id, isFolder: entry.isFolder);
      return [
        TreeAction(
          label: 'Open in Drive',
          icon: Icons.open_in_new,
          onSelected: () => _open(url, what: entry.label),
        ),
        TreeAction(
          label: 'Copy link',
          icon: Icons.link,
          onSelected: () => _copy('$url', what: 'Link'),
        ),
      ];
    }

    return [
      if (!entry.isFolder)
        TreeAction(
          label: 'Open',
          icon: Icons.open_in_new,
          onSelected: () => _open(localFileUrl(entry.id), what: entry.label),
        ),
      TreeAction(
        label: 'Show in Finder',
        icon: Icons.folder_open_outlined,
        onSelected: () =>
            _open(enclosingFolderUrl(entry.id), what: 'that folder'),
      ),
      TreeAction(
        label: 'Copy path',
        icon: Icons.content_copy,
        onSelected: () => _copy(entry.id, what: 'Path'),
      ),
    ];
  }

  Future<void> _fix(OrganizePlan plan) async {
    final outcome = await showOrganizePreview(
      context,
      plan: plan,
      organizers: widget.organizers,
      library: widget.library,
    );

    if (outcome == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          outcome.movedCount == 0
              ? 'Nothing was moved.'
              : '${outcome.movedCount} file'
                    '${outcome.movedCount == 1 ? '' : 's'} moved into place.',
        ),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: KandooColors.background,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: window.width > 1040 ? 960 : window.width - 80,
        height: window.height - 64,
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.library, widget.connections]),
          builder: (context, _) {
            final plan = planFor(
              sourceName: widget.source.name,
              entries: widget.library.entries,
              roots: _folders,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  source: widget.source,
                  onClose: () => Navigator.of(context).pop(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                  child: _AutoOrganize(
                    plan: plan,
                    source: widget.source,
                    canMove: widget.organizers.handles(widget.source.name),
                    busy: widget.library.isBusy,
                    onFix: () => _fix(plan),
                  ),
                ),
                if (_folders.length > 1)
                  _RootChoice(
                    folders: _folders,
                    selected: _root,
                    onSelected: (folder) => setState(() => _root = folder),
                  ),
                const Divider(height: 1, color: KandooColors.divider),
                Expanded(child: _tree()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tree() {
    if (!widget.browsable) {
      return _Nothing(
        icon: Icons.hourglass_empty,
        message: 'Browsing ${widget.source.name} is not built yet',
      );
    }

    return TreeViewer(
      // Rooting the tree somewhere new starts it from scratch, rather than
      // inheriting the previous folder's expansions.
      key: ValueKey('${widget.source.id}:$_root'),
      loadChildren: widget.loaderFor(_root),
      onActivate: (entry) => _open(
        widget.source.id == 'google_drive'
            ? driveItemUrl(entry.id, isFolder: false)
            : localFileUrl(entry.id),
        what: entry.label,
      ),
      actionsFor: _actionsFor,
    );
  }
}

/// Which source is open, and the way back out.
class _Header extends StatelessWidget {
  const _Header({required this.source, required this.onClose});

  final SourceDescriptor source;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 14, 16),
      child: Row(
        children: [
          SourceLogo(source: source, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  source.name,
                  style: const TextStyle(
                    fontFamily: KandooFonts.heading,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: KandooColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'As it really is, rather than as Kandoo files it.',
                  style: TextStyle(
                    fontSize: 12,
                    color: KandooColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
            color: KandooColors.textSecondary,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}

/// Whether the source agrees with the library, and the way to make it.
class _AutoOrganize extends StatelessWidget {
  const _AutoOrganize({
    required this.plan,
    required this.source,
    required this.canMove,
    required this.busy,
    required this.onFix,
  });

  final OrganizePlan plan;
  final SourceDescriptor source;

  /// Whether this build can move files on this source at all.
  final bool canMove;

  /// True while a scan is running, when what the plan says is already stale.
  final bool busy;

  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final unorganized = plan.moves.length;
    final tidy = plan.isTidy;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: tidy ? KandooColors.divider : KandooColors.lineStrong,
        ),
      ),
      child: Row(
        children: [
          Icon(
            tidy ? Icons.check_circle_outline : Icons.auto_fix_high,
            size: 16,
            color: tidy ? KandooColors.textMuted : KandooColors.accentDeep,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Auto-organize',
                  style: const TextStyle(
                    fontFamily: KandooFonts.heading,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: KandooColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _saying(unorganized, tidy),
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: KandooColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!tidy && canMove) ...[
            const SizedBox(width: 12),
            FilledButton(
              onPressed: busy ? null : onFix,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
              child: const Text('Fix'),
            ),
          ],
        ],
      ),
    );
  }

  String _saying(int unorganized, bool tidy) {
    if (plan.total == 0) {
      return 'Nothing from ${source.name} has been filed yet.';
    }
    if (tidy) {
      return 'Every file is where your library says it is.';
    }
    if (!canMove) {
      return '$unorganized file${unorganized == 1 ? ' is' : 's are'} not where '
          'your library says — and Kandoo cannot move files on ${source.name} '
          'yet.';
    }
    return '$unorganized file${unorganized == 1 ? '' : 's'} not organized '
        '— ${plan.inPlace} already in place.';
  }
}

/// The configured folders, when there is more than one to root the tree at.
class _RootChoice extends StatelessWidget {
  const _RootChoice({
    required this.folders,
    required this.selected,
    required this.onSelected,
  });

  final List<String> folders;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
        children: [
          for (final folder in folders)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _RootChip(
                folder: folder,
                selected: folder == selected,
                onTap: () => onSelected(folder),
              ),
            ),
        ],
      ),
    );
  }
}

class _RootChip extends StatelessWidget {
  const _RootChip({
    required this.folder,
    required this.selected,
    required this.onTap,
  });

  final String folder;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? KandooColors.selectedFill : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? KandooColors.accent : KandooColors.divider,
            ),
          ),
          child: Text(
            folder,
            style: TextStyle(
              fontFamily: KandooFonts.mono,
              fontSize: 11.5,
              color: selected
                  ? KandooColors.accentDeep
                  : KandooColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: KandooColors.textMuted),
          const SizedBox(height: 11),
          Text(
            message,
            style: const TextStyle(
              color: KandooColors.textMuted,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
