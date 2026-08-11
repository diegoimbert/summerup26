import 'package:flutter/material.dart';

import '../sources/connections.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';
import '../widgets/search_field.dart';
import '../widgets/source_logo.dart';
import 'source_connect_dialog.dart';

/// The Sources section: every provider Kandoo can draw from, with search.
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.connections});

  final ConnectionsController connections;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (!widget.connections.isLoaded) widget.connections.load();
  }

  List<SourceDescriptor> get _visibleSources {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return kSourceCatalog;
    return kSourceCatalog
        .where(
          (source) =>
              source.name.toLowerCase().contains(query) ||
              source.tagline.toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _openSource(SourceDescriptor source) async {
    if (!source.isConnectable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${source.name} is not available yet.'),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
      return;
    }

    await showSourceConnectDialog(
      context,
      source: source,
      connections: widget.connections,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.connections,
      builder: (context, _) {
        final sources = _visibleSources;

        return PageShell(
          title: 'Sources',
          subtitle: 'Connect the places your work already lives.',
          toolbar: SizedBox(
            width: 320,
            child: SearchField(
              hintText: 'Search sources',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          child: sources.isEmpty
              ? const EmptySection(
                  icon: Icons.search_off,
                  message: 'No sources match that search',
                )
              : _SourceGrid(
                  sources: sources,
                  connections: widget.connections,
                  onTap: _openSource,
                ),
        );
      },
    );
  }
}

class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.sources,
    required this.connections,
    required this.onTap,
  });

  final List<SourceDescriptor> sources;
  final ConnectionsController connections;
  final ValueChanged<SourceDescriptor> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cards stay readable rather than stretching on a wide window.
        final columns = (constraints.maxWidth / 300).floor().clamp(1, 4);

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 96,
          ),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return _SourceCard(
              source: source,
              credentials: connections.connectionFor(source.id),
              busy: connections.isBusy(source.id),
              onTap: () => onTap(source),
            );
          },
        );
      },
    );
  }
}

class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.source,
    required this.credentials,
    required this.busy,
    required this.onTap,
  });

  final SourceDescriptor source;
  final SourceCredentials? credentials;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final connected = widget.credentials != null;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: KandooColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered ? KandooColors.lineStrong : KandooColors.divider,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SourceLogo(source: widget.source),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.source.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: KandooFonts.heading,
                        color: KandooColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connected
                          ? (widget.credentials!.accountLabel ?? 'Connected')
                          : widget.source.tagline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: KandooColors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(connected: connected, busy: widget.busy),
            ],
          ),
        ),
      ),
    );
  }
}

/// Right-hand affordance: a spinner while signing in, a check once connected,
/// otherwise the connect chevron.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.connected, required this.busy});

  final bool connected;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (connected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: KandooColors.selectedFill,
          borderRadius: BorderRadius.circular(100),
        ),
        child: const Text(
          'Connected',
          style: TextStyle(
            fontFamily: KandooFonts.mono,
            color: KandooColors.accentDeep,
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return const Icon(
      Icons.add,
      size: 17,
      color: KandooColors.textMuted,
    );
  }
}
