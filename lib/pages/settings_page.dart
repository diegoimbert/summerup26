import 'package:flutter/material.dart';

import '../settings/profile.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';
import 'welcome_dialog.dart';

/// The Settings section: the few things Kandoo cannot work out for itself.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.profile});

  final ProfileController profile;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile.firstName ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _changed =>
      _name.text.trim() != (widget.profile.firstName ?? '').trim();

  Future<void> _save() async {
    if (!_changed) return;

    final name = _name.text.trim();
    await widget.profile.setFirstName(name);
    if (!mounted) return;

    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          name.isEmpty ? 'Your name has been cleared.' : 'Saved. Hello, $name.',
        ),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.profile,
      builder: (context, _) {
        return PageShell(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
            children: [
              const Text(
                'Settings',
                style: TextStyle(
                  fontFamily: KandooFonts.heading,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: KandooColors.textPrimary,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  decoration: BoxDecoration(
                    color: KandooColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: KandooColors.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your name',
                        style: TextStyle(
                          fontFamily: KandooFonts.heading,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: KandooColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Used to greet you on Today. It stays on this Mac.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: KandooColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: NameField(
                              controller: _name,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: _save,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _changed ? _save : null,
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
            ],
          ),
        );
      },
    );
  }
}
