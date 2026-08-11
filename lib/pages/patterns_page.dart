import 'package:flutter/material.dart';

import '../widgets/page_shell.dart';

/// The Pattern recognized section.
class PatternsPage extends StatelessWidget {
  const PatternsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageShell(
      title: 'Pattern recognized',
      subtitle: 'Habits and themes Kandoo has noticed',
      child: EmptySection(icon: Icons.grid_view_outlined, message: 'No patterns yet'),
    );
  }
}
