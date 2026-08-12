import 'package:flutter/material.dart';

import '../settings/profile.dart';
import '../theme.dart';

/// Asks the user what to call them, which is all Kandoo wants to know before it
/// starts.
///
/// Shown once, on the first launch that finds no name. Dismissing it is allowed
/// — the app works perfectly well greeting nobody — and Settings is where a
/// name arrives or changes afterwards.
Future<void> showWelcomeDialog(
  BuildContext context, {
  required ProfileController profile,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _WelcomeDialog(profile: profile),
  );
}

class _WelcomeDialog extends StatefulWidget {
  const _WelcomeDialog({required this.profile});

  final ProfileController profile;

  @override
  State<_WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends State<_WelcomeDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;

    await widget.profile.setFirstName(name);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: KandooColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Welcome to Kandoo',
                style: TextStyle(
                  fontFamily: KandooFonts.heading,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: KandooColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'What should I call you? Only your first name, and only so the '
                'app can say hello.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: KandooColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              NameField(
                controller: _name,
                autofocus: true,
                onSubmitted: _save,
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: KandooColors.textSecondary,
                    ),
                    child: const Text('Not now'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
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
}

/// The field a first name is typed into, here and in Settings.
class NameField extends StatelessWidget {
  const NameField({
    super.key,
    required this.controller,
    required this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  /// For a caller whose Save button wakes up once the name has changed.
  final ValueChanged<String>? onChanged;

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      cursorColor: KandooColors.accent,
      textCapitalization: TextCapitalization.words,
      onChanged: onChanged,
      onSubmitted: (_) => onSubmitted(),
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: KandooColors.surface,
        hintText: 'First name',
        hintStyle: const TextStyle(
          fontSize: 13,
          color: KandooColors.textMuted,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: _border(KandooColors.divider),
        enabledBorder: _border(KandooColors.divider),
        focusedBorder: _border(KandooColors.accent, 1.5),
      ),
    );
  }

  static OutlineInputBorder _border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: color, width: width),
      );
}
