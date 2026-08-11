import 'package:flutter/material.dart';

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

/// The Files section: pick a connected source, then browse it.
class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.connections,
    this.treeLoader = defaultTreeLoader,
  });

  final ConnectionsController connections;

  /// Where the tree's rows come from. Overridden in tests, which cannot wait
  /// on real disk reads.
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

  void _select(SourceDescriptor source) {
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
      animation: widget.connections,
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
    if (source == null) {
      return const EmptySection(
        icon: Icons.folder_open_outlined,
        message: 'Choose a source above to browse it',
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
  const _BrowsingBar({required this.path, required this.onChange});

  final String path;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 12, 24, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KandooColors.divider)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.subdirectory_arrow_right,
            size: 15,
            color: KandooColors.textMuted,
          ),
          const SizedBox(width: 9),
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
