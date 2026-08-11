import 'package:flutter/material.dart';

import '../sources/connections.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/source_logo.dart';

/// Opens the folder scope sheet for a connected source.
Future<void> showSourceFoldersDialog(
  BuildContext context, {
  required SourceDescriptor source,
  required ConnectionsController connections,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _SourceFoldersDialog(source: source, connections: connections),
  );
}

class _SourceFoldersDialog extends StatefulWidget {
  const _SourceFoldersDialog({required this.source, required this.connections});

  final SourceDescriptor source;
  final ConnectionsController connections;

  @override
  State<_SourceFoldersDialog> createState() => _SourceFoldersDialogState();
}

class _SourceFoldersDialogState extends State<_SourceFoldersDialog> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// Edited in place and only written back on Save, so backing out of the
  /// sheet leaves the stored scope untouched.
  late final List<String> _folders = [
    ...widget.connections.foldersFor(widget.source.id),
  ];

  String? _inputError;
  bool _saving = false;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _add() {
    // Trailing separators are easy to paste in from Finder or a terminal and
    // would otherwise read as a different folder to the same path without one.
    var path = _input.text.trim();
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    if (path.isEmpty) {
      setState(() => _inputError = 'Enter a folder path.');
      return;
    }
    if (_folders.contains(path)) {
      setState(() => _inputError = 'That folder is already in the list.');
      return;
    }

    setState(() {
      _folders.add(path);
      _inputError = null;
      _input.clear();
    });
    _inputFocus.requestFocus();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.connections.setFolders(widget.source.id, _folders);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: KandooColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SourceLogo(source: widget.source, size: 40),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${widget.source.name} folders',
                          style: const TextStyle(
                            fontFamily: KandooFonts.heading,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: KandooColors.textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'Kandoo looks inside these folders only.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: KandooColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              _FolderList(
                folders: _folders,
                onRemove: (index) => setState(() => _folders.removeAt(index)),
              ),
              const SizedBox(height: 14),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      autofocus: true,
                      cursorColor: KandooColors.accent,
                      onChanged: (_) {
                        if (_inputError != null) {
                          setState(() => _inputError = null);
                        }
                      },
                      onSubmitted: (_) => _add(),
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: KandooFonts.mono,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: KandooColors.surface,
                        hintText: '/Users/diegoimbert/Desktop',
                        errorText: _inputError,
                        hintStyle: const TextStyle(
                          fontSize: 12.5,
                          fontFamily: KandooFonts.mono,
                          color: KandooColors.textMuted,
                        ),
                        errorStyle: const TextStyle(fontSize: 11.5),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: _inputBorder(KandooColors.divider),
                        enabledBorder: _inputBorder(KandooColors.divider),
                        focusedBorder: _inputBorder(KandooColors.accent, 1.5),
                        errorBorder: _inputBorder(const Color(0xFFC0392B)),
                        focusedErrorBorder: _inputBorder(
                          const Color(0xFFC0392B),
                          1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    // Keeps the button level with the field rather than with
                    // the field plus its error line.
                    padding: const EdgeInsets.only(top: 1),
                    child: OutlinedButton(
                      onPressed: _add,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: KandooColors.textPrimary,
                        side: const BorderSide(color: KandooColors.divider),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 13,
                        ),
                      ),
                      child: const Text('Add'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: KandooColors.textSecondary,
                    ),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 13,
                      ),
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, [double width = 1]) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}

/// The folders chosen so far, or an explanation of what an empty list means.
class _FolderList extends StatelessWidget {
  const _FolderList({required this.folders, required this.onRemove});

  final List<String> folders;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          color: KandooColors.sidebar,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KandooColors.divider),
        ),
        child: const Text(
          'No folders yet. Until you add one, Kandoo reads the whole source.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: KandooColors.textSecondary,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KandooColors.divider),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: folders.length,
        separatorBuilder: (context, _) =>
            const Divider(height: 1, color: KandooColors.divider),
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: KandooColors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    folders[index],
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KandooFonts.mono,
                      fontSize: 12,
                      color: KandooColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => onRemove(index),
                  icon: const Icon(Icons.close, size: 15),
                  color: KandooColors.textMuted,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove ${folders[index]}',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
