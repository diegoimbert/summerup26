import 'package:flutter/material.dart';

import '../theme.dart';

/// Common chrome for a section: an optional toolbar row above the body.
///
/// No title: the sidebar already says which section is open, and a heading
/// repeating it costs the top of every screen.
class PageShell extends StatelessWidget {
  const PageShell({super.key, this.toolbar, required this.child});

  final Widget? toolbar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (toolbar != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 22, 32, 16),
            child: toolbar,
          )
        else
          const SizedBox(height: 22),
        Expanded(child: child),
      ],
    );
  }
}

/// Placeholder body for sections that have no content yet.
class EmptySection extends StatelessWidget {
  const EmptySection({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: KandooColors.textMuted),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(
              color: KandooColors.textMuted,
              fontSize: 13.5,
            ),
          ),
        ],
      ),
    );
  }
}
