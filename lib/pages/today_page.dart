import 'package:flutter/material.dart';

import '../widgets/page_shell.dart';

/// The Today section.
class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageShell(
      title: 'Today',
      subtitle: 'What needs your attention right now',
      child: EmptySection(icon: Icons.wb_sunny_outlined, message: 'Nothing scheduled yet'),
    );
  }
}
