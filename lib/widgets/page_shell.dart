import 'package:flutter/material.dart';

import '../theme.dart';

/// Common chrome for a section: padded column with a title, optional subtitle
/// and an optional toolbar row under the header.
class PageShell extends StatelessWidget {
  const PageShell({
    super.key,
    required this.title,
    this.subtitle,
    this.toolbar,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? toolbar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: KandooFonts.heading,
                  color: KandooColors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: KandooColors.textSecondary,
                    fontSize: 13.5,
                  ),
                ),
              ],
              if (toolbar != null) ...[const SizedBox(height: 20), toolbar!],
            ],
          ),
        ),
        const SizedBox(height: 20),
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
