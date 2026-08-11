import 'package:flutter/material.dart';

import '../sources/connections.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/source_logo.dart';
import 'source_folders_dialog.dart';

/// What Kandoo will be able to do once a source is connected, in plain words.
///
/// Deliberately not the raw OAuth scope strings: the point is that someone
/// non-technical can read this and decide.
const Map<String, List<String>> _permissionSummary = {
  'google_drive': [
    'See the files and folders in your Drive',
    'Open and organise the files Kandoo gathers for you',
  ],
  'notion': [
    'Read the pages and databases you choose to share',
    'Create and update notes on your behalf',
  ],
};

/// Opens the authorize sheet for a source.
Future<void> showSourceConnectDialog(
  BuildContext context, {
  required SourceDescriptor source,
  required ConnectionsController connections,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _SourceConnectDialog(source: source, connections: connections),
  );
}

class _SourceConnectDialog extends StatelessWidget {
  const _SourceConnectDialog({required this.source, required this.connections});

  final SourceDescriptor source;
  final ConnectionsController connections;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: connections,
      builder: (context, _) {
        final credentials = connections.connectionFor(source.id);
        final busy = connections.isBusy(source.id);
        final error = connections.errorFor(source.id);
        final configured = connections.isConfigured(source.id);

        return Dialog(
          backgroundColor: KandooColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Column(
                      children: [
                        SourceLogo(source: source, size: 52),
                        const SizedBox(height: 14),
                        Text(
                          credentials == null
                              ? 'Connect ${source.name}'
                              : '${source.name} is connected',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: KandooFonts.heading,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: KandooColors.textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          credentials == null
                              ? 'You will be taken to ${source.name} to sign in. '
                                    'Kandoo never sees your password.'
                              : credentials.accountLabel ??
                                    'Signed in and ready to use.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: KandooColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),

                  if (credentials == null)
                    _PermissionList(sourceId: source.id)
                  else ...[
                    const _ConnectedSummary(),
                    if (source.hasFolders) ...[
                      const SizedBox(height: 10),
                      _FolderScope(source: source, connections: connections),
                    ],
                  ],

                  if (!configured && credentials == null) ...[
                    const SizedBox(height: 14),
                    const _Notice(
                      message:
                          'This copy of Kandoo was packaged without sign-in '
                          'credentials for this source, so connecting is '
                          'unavailable.',
                    ),
                  ],

                  if (error != null) ...[
                    const SizedBox(height: 14),
                    _Notice(message: error, isError: true),
                  ],

                  const SizedBox(height: 22),
                  if (credentials == null)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy || !configured
                            ? null
                            : () => connections.connect(source.id),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                          busy
                              ? 'Waiting for ${source.name}…'
                              : 'Continue with ${source.name}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => connections.disconnect(source.id),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFC0392B),
                          side: const BorderSide(color: KandooColors.divider),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Disconnect'),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: KandooColors.textSecondary,
                      ),
                      child: Text(credentials == null ? 'Not now' : 'Done'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Plain-language list of what access is being granted.
class _PermissionList extends StatelessWidget {
  const _PermissionList({required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context) {
    final permissions = _permissionSummary[sourceId] ?? const <String>[];
    if (permissions.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KandooColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kandoo will be able to',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: KandooColors.textPrimary,
            ),
          ),
          const SizedBox(height: 9),
          for (final permission in permissions)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: KandooColors.accent,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      permission,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: KandooColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Reassures the user where access lives, without showing any token.
class _ConnectedSummary extends StatelessWidget {
  const _ConnectedSummary();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KandooColors.divider),
      ),
      child: const Row(
        children: [
          Icon(Icons.lock_outline, size: 15, color: KandooColors.accent),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Access is stored on this Mac only.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How much of a folder-shaped source is in scope, and the way into changing
/// it.
class _FolderScope extends StatelessWidget {
  const _FolderScope({required this.source, required this.connections});

  final SourceDescriptor source;
  final ConnectionsController connections;

  @override
  Widget build(BuildContext context) {
    final folders = connections.foldersFor(source.id);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KandooColors.divider),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.folder_outlined,
            size: 15,
            color: KandooColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              switch (folders.length) {
                0 => 'Reading every folder.',
                1 => 'Reading 1 folder.',
                final count => 'Reading $count folders.',
              },
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => showSourceFoldersDialog(
              context,
              source: source,
              connections: connections,
            ),
            style: TextButton.styleFrom(
              foregroundColor: KandooColors.accentDeep,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
            // Styled on the label rather than through styleFrom's textStyle,
            // which drops the theme's font family.
            child: const Text(
              'Configure folders',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? const Color(0xFF922B21)
        : KandooColors.textSecondary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: isError
            ? const Color(0xFFC0392B).withValues(alpha: 0.08)
            : KandooColors.sidebar,
        borderRadius: BorderRadius.circular(9),
        border: isError ? null : Border.all(color: KandooColors.divider),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12.5, height: 1.4, color: color),
      ),
    );
  }
}
