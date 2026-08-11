import 'package:flutter/material.dart';

import '../library/library_controller.dart';
import '../sources/connections.dart';
import '../sources/file_system_browser.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';
import '../widgets/source_logo.dart';
import '../widgets/tree_viewer.dart';

/// The sources whose contents Kandoo can actually list today. The rest are
/// connected and scoped, but their APIs are not wired up yet.
const Set<String> kBrowsableSources = {'file_system'};

/// Builds the loader that browses [source] from [root]. Called only for the
/// sources in [kBrowsableSources].
typedef SourceTreeLoader =
    TreeChildrenLoader Function(SourceDescriptor source, String root);

/// Everything browsable today lives on this Mac. Drive and the rest will pick
/// their loader off [source] once their APIs are built.
TreeChildrenLoader defaultTreeLoader(SourceDescriptor source, String root) =>
    FileSystemBrowser(rootPath: root).children;

/// The Files section.
///
/// What it shows by default is the organized library: the virtual tree the
/// model built out of everything the sources hold. The grid at the top is the
/// way down to a source as it really is, for when the tidy view is not what the
/// user is after.
class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.connections,
    required this.library,
    this.treeLoader = defaultTreeLoader,
  });

  final ConnectionsController connections;
  final LibraryController library;

  /// Where a source's raw tree comes from. Overridden in tests, which cannot
  /// wait on real disk reads.
  final SourceTreeLoader treeLoader;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  SourceDescriptor? _source;

  /// The folder the tree is rooted at. Null while the user still has a choice
  /// to make between the folders configured for [_source].
  String? _root;

  @override
  void initState() {
    super.initState();
    if (!widget.connections.isLoaded) widget.connections.load();
  }

  /// The sources on offer: everything already reachable, which means the ones
  /// signed in to plus the ones that never needed signing in.
  List<SourceDescriptor> get _connected => kSourceCatalog
      .where(
        (source) =>
            source.isAvailable &&
            (!source.needsSignIn || widget.connections.isConnected(source.id)),
      )
      .toList();

  /// Opens a source's own tree, or returns to the library when the source
  /// already showing is tapped again.
  void _select(SourceDescriptor source) {
    if (_source?.id == source.id) {
      setState(() {
        _source = null;
        _root = null;
      });
      return;
    }

    final folders = widget.connections.foldersFor(source.id);

    setState(() {
      _source = source;
      // One folder is no choice at all, and no folders means the source was
      // never narrowed — so both go straight to the tree.
      _root = switch (folders.length) {
        0 => '/',
        1 => folders.single,
        _ => null,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.connections, widget.library]),
      builder: (context, _) {
        final sources = _connected;

        // A source can lose its connection while the page is open; drop the
        // selection rather than browsing something no longer listed.
        final selected = _source;
        if (selected != null && !sources.any((s) => s.id == selected.id)) {
          _source = null;
          _root = null;
        }

        return PageShell(
          title: 'Files',
          subtitle: 'Everything Kandoo has gathered',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _IntegrationGrid(
                sources: sources,
                selectedId: _source?.id,
                onSelected: _select,
              ),
              ScanStatusStrip(library: widget.library),
              const Divider(height: 1, color: KandooColors.divider),
              Expanded(child: _body()),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    final source = _source;
    // Nothing picked out of the grid means the organized library, which is the
    // point of the section.
    if (source == null) return _LibraryView(library: widget.library);

    if (!kBrowsableSources.contains(source.id)) {
      return EmptySection(
        icon: Icons.hourglass_empty,
        message: 'Browsing ${source.name} is not built yet',
      );
    }

    final folders = widget.connections.foldersFor(source.id);
    final root = _root;
    if (root == null) {
      return _FolderChoice(
        source: source,
        folders: folders,
        onChosen: (folder) => setState(() => _root = folder),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrowsingBar(
          path: root,
          // Backing out only means something when there was a choice.
          onChange: folders.length > 1
              ? () => setState(() => _root = null)
              : null,
          onLibrary: () => setState(() {
            _source = null;
            _root = null;
          }),
        ),
        Expanded(
          child: TreeViewer(
            // Rooting the tree somewhere new starts it from scratch, rather
            // than inheriting the previous folder's expansions.
            key: ValueKey('${source.id}:$root'),
            loadChildren: widget.treeLoader(source, root),
          ),
        ),
      ],
    );
  }
}

/// Says what the scan is doing, and offers the way to run it again.
///
/// Scanning starts on launch and can take a while on a large folder, so it is
/// never silent: the strip is where the user finds out their files are being
/// read, placed, or that something went wrong.
class ScanStatusStrip extends StatelessWidget {
  const ScanStatusStrip({super.key, required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final (message, isError) = _statusFor(library);

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 0, 24, 16),
      child: Row(
        children: [
          if (library.isBusy)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else
            Icon(
              isError ? Icons.error_outline : Icons.auto_awesome_outlined,
              size: 14,
              color: isError ? const Color(0xFFC0392B) : KandooColors.textMuted,
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: isError
                    ? const Color(0xFFC0392B)
                    : KandooColors.textSecondary,
              ),
            ),
          ),
          if (!library.isBusy && library.hasScannableFolders)
            TextButton(
              onPressed: () => library.refresh(force: true),
              style: TextButton.styleFrom(
                foregroundColor: KandooColors.accentDeep,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                library.stage == LibraryStage.failed ? 'Try again' : 'Rescan',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  static (String, bool) _statusFor(LibraryController library) {
    switch (library.stage) {
      case LibraryStage.scanning:
        final source = library.currentSource ?? 'your sources';
        final found = library.scannedCount;
        return (
          found == 0
              ? 'Scanning $source…'
              : 'Scanning $source — $found files so far',
          false,
        );

      case LibraryStage.organizing:
        final placed = library.organizedCount;
        return (
          'Organizing ${library.scannedCount} files with DeepSeek'
              '${placed == 0 ? '…' : ' — $placed placed'}',
          false,
        );

      case LibraryStage.failed:
        return (library.error ?? 'Something went wrong.', true);

      case LibraryStage.idle:
      case LibraryStage.ready:
        if (!library.hasScannableFolders) {
          return (
            'Nothing to scan yet — add folders to a source under Sources.',
            false,
          );
        }
        if (library.entries.isEmpty) {
          return ('Nothing scanned yet.', false);
        }
        final count = library.entries.length;
        final when = library.organizedAt;
        return (
          '$count files organized${library.truncated ? ' (scan stopped at its limit)' : ''}'
              '${when == null ? '' : ' · ${_ago(when)}'}',
          false,
        );
    }
  }

  static String _ago(DateTime when) {
    final elapsed = DateTime.now().difference(when);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
    if (elapsed.inHours < 24) {
      return '${elapsed.inHours} hour${elapsed.inHours == 1 ? '' : 's'} ago';
    }
    final month = when.month.toString().padLeft(2, '0');
    final day = when.day.toString().padLeft(2, '0');
    return 'on ${when.year}-$month-$day';
  }
}

/// The organized library, or an explanation of why there is none yet.
class _LibraryView extends StatelessWidget {
  const _LibraryView({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    if (library.entries.isNotEmpty) {
      return TreeViewer(
        // A fresh arrangement is a different tree, not the old one with new
        // rows, so it starts collapsed again.
        key: ValueKey(library.organizedAt),
        loadChildren: library.tree.childrenOf,
        emptyMessage: 'Nothing filed here',
      );
    }

    if (library.isBusy) {
      // The strip above is already counting; this keeps the body from reading
      // as empty while it works.
      return const EmptySection(
        icon: Icons.auto_awesome_outlined,
        message: 'Building your library…',
      );
    }

    if (!library.hasScannableFolders) {
      return const EmptySection(
        icon: Icons.folder_off_outlined,
        message:
            'No folders to scan yet.\n'
            'Add some to File System under Sources.',
      );
    }

    return const EmptySection(
      icon: Icons.auto_awesome_outlined,
      message: 'Nothing organized yet',
    );
  }
}

/// The connected sources, as a grid of icon buttons.
class _IntegrationGrid extends StatelessWidget {
  const _IntegrationGrid({
    required this.sources,
    required this.selectedId,
    required this.onSelected,
  });

  final List<SourceDescriptor> sources;
  final String? selectedId;
  final ValueChanged<SourceDescriptor> onSelected;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(32, 0, 32, 24),
        child: Text(
          'No sources connected yet. Connect one from Sources.',
          style: TextStyle(fontSize: 13, color: KandooColors.textSecondary),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Connected',
            style: TextStyle(
              fontFamily: KandooFonts.mono,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              color: KandooColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final source in sources)
                _IntegrationButton(
                  source: source,
                  selected: source.id == selectedId,
                  onTap: () => onSelected(source),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IntegrationButton extends StatefulWidget {
  const _IntegrationButton({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final SourceDescriptor source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_IntegrationButton> createState() => _IntegrationButtonState();
}

class _IntegrationButtonState extends State<_IntegrationButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.source.tagline,
          waitDuration: const Duration(milliseconds: 600),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 96,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: selected
                  ? KandooColors.selectedFill
                  : (_hovered ? KandooColors.surface : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? KandooColors.accent
                    : (_hovered ? KandooColors.lineStrong : Colors.transparent),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SourceLogo(source: widget.source, size: 38),
                const SizedBox(height: 9),
                Text(
                  widget.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? KandooColors.textPrimary
                        : KandooColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The step between picking a source and seeing its tree, for a source that
/// was narrowed to more than one folder.
class _FolderChoice extends StatelessWidget {
  const _FolderChoice({
    required this.source,
    required this.folders,
    required this.onChosen,
  });

  final SourceDescriptor source;
  final List<String> folders;
  final ValueChanged<String> onChosen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
      children: [
        Text(
          'Which ${source.name} folder?',
          style: const TextStyle(
            fontFamily: KandooFonts.heading,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: KandooColors.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 14),
        for (final folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _FolderOption(folder: folder, onTap: () => onChosen(folder)),
          ),
      ],
    );
  }
}

class _FolderOption extends StatefulWidget {
  const _FolderOption({required this.folder, required this.onTap});

  final String folder;
  final VoidCallback onTap;

  @override
  State<_FolderOption> createState() => _FolderOptionState();
}

class _FolderOptionState extends State<_FolderOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: KandooColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered ? KandooColors.lineStrong : KandooColors.divider,
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.folder_outlined,
                size: 16,
                color: KandooColors.accentDeep,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.folder,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: KandooFonts.mono,
                    fontSize: 12,
                    color: KandooColors.textPrimary,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 17,
                color: KandooColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says which folder the tree below is rooted at, and offers the way back to
/// the folder choice.
class _BrowsingBar extends StatelessWidget {
  const _BrowsingBar({
    required this.path,
    required this.onChange,
    required this.onLibrary,
  });

  final String path;
  final VoidCallback? onChange;

  /// Back to the organized view, which is where the section starts.
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 24, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KandooColors.divider)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onLibrary,
            icon: const Icon(Icons.chevron_left, size: 17),
            label: const Text('Library', style: TextStyle(fontSize: 12.5)),
            style: TextButton.styleFrom(
              foregroundColor: KandooColors.textSecondary,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              path,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: KandooFonts.mono,
                fontSize: 12,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
          if (onChange != null)
            TextButton(
              onPressed: onChange,
              style: TextButton.styleFrom(
                foregroundColor: KandooColors.accentDeep,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text(
                'Change folder',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}
