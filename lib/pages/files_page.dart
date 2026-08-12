import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/library_controller.dart';
import '../library/library_store.dart';
import '../library/library_tree.dart';
import '../sources/connections.dart';
import '../sources/file_system_browser.dart';
import '../sources/google_drive_api.dart';
import '../sources/google_drive_browser.dart';
import '../sources/item_actions.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';
import '../widgets/search_field.dart';
import '../widgets/source_logo.dart';
import '../widgets/tree_viewer.dart';

/// The sources whose contents Kandoo can actually list today. The rest are
/// connected and scoped, but their APIs are not wired up yet.
const Set<String> kBrowsableSources = {'file_system', 'google_drive'};

/// Builds the loader that browses [source] from [root]. Called only for the
/// sources in [kBrowsableSources].
typedef SourceTreeLoader =
    TreeChildrenLoader Function(
      SourceDescriptor source,
      String root,
      ConnectionsController connections,
    );

/// Where a source's rows come from when it is browsed as it really is.
TreeChildrenLoader defaultTreeLoader(
  SourceDescriptor source,
  String root,
  ConnectionsController connections,
) {
  switch (source.id) {
    case 'google_drive':
      // Credentials are fetched per call rather than captured: an access token
      // lasts an hour, and a tree can be left open for longer than that.
      return (parent) async {
        final credentials = await connections.freshCredentials(source.id);
        if (credentials == null) {
          throw const TreeLoadException('Google Drive is not connected.');
        }
        return GoogleDriveBrowser(
          api: GoogleDriveApi(accessToken: credentials.accessToken),
          rootPath: root,
        ).children(parent);
      };

    default:
      return FileSystemBrowser(rootPath: root).children;
  }
}

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
    required this.onOpenSources,
    this.treeLoader = defaultTreeLoader,
    this.openUrl = openWithSystem,
  });

  final ConnectionsController connections;
  final LibraryController library;

  /// Takes the user to Sources, which is where sources are connected and
  /// pointed at folders.
  final VoidCallback onOpenSources;

  /// How a file or a link is handed to the desktop. Replaced in tests, which
  /// have no desktop.
  final UrlOpener openUrl;

  /// Where a source's raw tree comes from. Overridden in tests, which cannot
  /// wait on real disk reads.
  final SourceTreeLoader treeLoader;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  SourceDescriptor? _source;

  /// What the user is looking for. A search is always of the library: a source
  /// browsed as it really is would have to be walked to be searched.
  String _query = '';

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

  void _search(String query) {
    setState(() {
      _query = query;
      // Looking for something means looking in the library, so a source being
      // browsed steps aside.
      if (query.trim().isNotEmpty) {
        _source = null;
        _root = null;
      }
    });
  }

  /// The filed away files matching the search, if there is one.
  List<LibraryEntry> get _matches {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return const [];

    return [
      for (final entry in widget.library.entries)
        if (entry.title.toLowerCase().contains(query) ||
            entry.organizedPath.toLowerCase().contains(query) ||
            entry.file.path.toLowerCase().contains(query))
          entry,
    ];
  }

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

  /// What the search turned up, as a flat list: a result is worth showing
  /// where it was filed, not worth burying in the folder it was filed into.
  Widget _results() {
    final matches = _matches;
    if (matches.isEmpty) {
      return const EmptySection(
        icon: Icons.search_off,
        message: 'No files match that search',
      );
    }

    final rows = LibraryTree.resultsFor(matches);
    return TreeViewer(
      key: ValueKey('search:${_query.trim()}:${widget.library.revision}'),
      loadChildren: (parent) async => parent == null ? rows : const [],
      onActivate: (entry) {
        final held = entry.payload;
        if (held is LibraryEntry) _open(_urlFor(held), what: held.title);
      },
      actionsFor: _libraryActions,
    );
  }

  /// Opens what a row stands for: a local file in whatever handles it, a Drive
  /// item in the browser.
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

  /// What a row of a source's own tree offers.
  ///
  /// The file system has files to open and folders to show; Drive has neither
  /// on this Mac, so its rows lead to the browser instead.
  List<TreeAction> _sourceActions(SourceDescriptor source, TreeEntry entry) {
    if (source.id == 'google_drive') {
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

  /// What a row of the organized library offers.
  ///
  /// A folder there exists only in the library, so it has nothing to open; a
  /// file is a real file on a real source, and acts like one.
  List<TreeAction> _libraryActions(TreeEntry entry) {
    final held = entry.payload;
    if (held is! LibraryEntry) {
      return [
        TreeAction(
          label: 'Copy folder path',
          icon: Icons.content_copy,
          onSelected: () => _copy(entry.id, what: 'Path'),
        ),
      ];
    }

    final url = _urlFor(held);
    return [
      TreeAction(
        // What opening means depends on where the thing lives, so the menu
        // says which.
        label: switch (held.file.sourceName) {
          'Google Drive' => 'Open in Drive',
          'Notion' => 'Open in Notion',
          _ => 'Open',
        },
        icon: Icons.open_in_new,
        onSelected: () => _open(url, what: held.title),
      ),
      if (held.file.externalId == null)
        TreeAction(
          label: 'Show in Finder',
          icon: Icons.folder_open_outlined,
          onSelected: () =>
              _open(enclosingFolderUrl(held.file.path), what: 'that folder'),
        ),
      TreeAction(
        label: 'Copy path',
        icon: Icons.content_copy,
        onSelected: () => _copy(held.file.path, what: 'Path'),
      ),
    ];
  }

  /// Where a filed away file actually is, which depends on where it came
  /// from: this Mac, a drive, or a workspace.
  static Uri _urlFor(LibraryEntry entry) {
    final id = entry.file.externalId;
    if (id == null) return localFileUrl(entry.file.path);

    return switch (entry.file.sourceName) {
      'Notion' => notionPageUrl(id),
      _ => driveItemUrl(id, isFolder: false),
    };
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The sources are their own section, and the line under them
              // says so: everything below is what they hold.
              _IntegrationGrid(
                sources: sources,
                selectedId: _source?.id,
                onSelected: _select,
                onAdd: widget.onOpenSources,
              ),
              const Divider(height: 1, color: KandooColors.divider),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 16, 32, 14),
                child: SizedBox(
                  width: 320,
                  child: SearchField(
                    hintText: 'Search your files',
                    onChanged: _search,
                  ),
                ),
              ),
              Expanded(child: _body()),
              const Divider(height: 1, color: KandooColors.divider),
              // Out of the way at the foot of the section: it is a status, and
              // the files are what the user came for.
              ScanStatusStrip(library: widget.library),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    if (_query.trim().isNotEmpty) return _results();

    final source = _source;
    // Nothing picked out of the grid means the organized library, which is the
    // point of the section.
    if (source == null) {
      return _LibraryView(
        library: widget.library,
        onActivate: (entry) {
          final held = entry.payload;
          if (held is LibraryEntry) _open(_urlFor(held), what: held.title);
        },
        actionsFor: _libraryActions,
      );
    }

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
            loadChildren: widget.treeLoader(source, root, widget.connections),
            onActivate: (entry) => _open(
              source.id == 'google_drive'
                  ? driveItemUrl(entry.id, isFolder: false)
                  : localFileUrl(entry.id),
              what: entry.label,
            ),
            actionsFor: (entry) => _sourceActions(source, entry),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 26, 8),
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
          if (!library.isBusy && library.canScan)
            TextButton(
              onPressed: () => library.refresh(force: true),
              style: TextButton.styleFrom(
                foregroundColor: KandooColors.accentDeep,
                // A button that only has to be readable, not tappable with a
                // thumb, so it takes the height of its own text.
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          'Organizing ${library.scannedCount} files'
              '${placed == 0 ? '…' : ' — $placed placed'}',
          false,
        );

      case LibraryStage.failed:
        return (library.error ?? 'Something went wrong.', true);

      case LibraryStage.idle:
      case LibraryStage.ready:
        if (!library.canScan) {
          return (
            'Nothing to scan yet — connect a source, or give one folders.',
            false,
          );
        }
        if (library.entries.isEmpty) {
          return ('Nothing scanned yet.', false);
        }
        final count = library.entries.length;
        final when = library.organizedAt;
        final warnings = library.warnings;
        return (
          '$count files organized'
              '${library.truncated ? ' (scan stopped at its limit)' : ''}'
              '${when == null ? '' : ' · ${_ago(when)}'}'
              // One folder that could not be found is worth naming; several
              // are worth counting.
              '${switch (warnings.length) {
                0 => '',
                1 => ' · ${warnings.single}',
                _ => ' · ${warnings.length} folders could not be found',
              }}',
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
  const _LibraryView({
    required this.library,
    required this.onActivate,
    required this.actionsFor,
  });

  final LibraryController library;
  final ValueChanged<TreeEntry> onActivate;
  final List<TreeAction> Function(TreeEntry) actionsFor;

  @override
  Widget build(BuildContext context) {
    if (library.entries.isNotEmpty) {
      return TreeViewer(
        // Told about changes rather than rebuilt for them, so a file arriving
        // on disk does not close everything the user had open.
        revision: library.revision,
        loadChildren: library.tree.childrenOf,
        onActivate: onActivate,
        actionsFor: actionsFor,
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

    if (!library.canScan) {
      return const EmptySection(
        icon: Icons.folder_off_outlined,
        message:
            'Nothing to scan yet.\n'
            'Connect a source under Sources, or give one folders.',
      );
    }

    return const EmptySection(
      icon: Icons.auto_awesome_outlined,
      message: 'Nothing organized yet',
    );
  }
}

/// The connected sources, as a grid of icon buttons, ending in the way to add
/// another.
class _IntegrationGrid extends StatelessWidget {
  const _IntegrationGrid({
    required this.sources,
    required this.selectedId,
    required this.onSelected,
    required this.onAdd,
  });

  final List<SourceDescriptor> sources;
  final String? selectedId;
  final ValueChanged<SourceDescriptor> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final source in sources)
            _IntegrationButton(
              source: source,
              selected: source.id == selectedId,
              onTap: () => onSelected(source),
            ),
          _AddSourceButton(onTap: onAdd),
        ],
      ),
    );
  }
}

/// The last tile in the grid: where sources come from.
class _AddSourceButton extends StatefulWidget {
  const _AddSourceButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AddSourceButton> createState() => _AddSourceButtonState();
}

class _AddSourceButtonState extends State<_AddSourceButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: 'Connect a source',
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _hovered ? KandooColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _hovered ? KandooColors.lineStrong : Colors.transparent,
              ),
            ),
            // Sized to match a brand mark exactly, so the row of tiles keeps
            // its rhythm.
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: KandooColors.hoverFill,
                borderRadius: BorderRadius.circular(40 * 0.26),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.add,
                size: 20,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
        ),
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
          // The mark stands for the source; the tooltip is where its name
          // lives, so the row of buttons stays a row of marks.
          message: widget.source.name,
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(10),
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
            child: SourceLogo(source: widget.source, size: 40),
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
        Row(
          children: [
            // The mark says which source this is; the heading only has to ask
            // the question.
            SourceLogo(source: source, size: 24),
            const SizedBox(width: 10),
            const Text(
              'Which folder?',
              style: TextStyle(
                fontFamily: KandooFonts.heading,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: KandooColors.textPrimary,
                letterSpacing: -0.2,
              ),
            ),
          ],
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
