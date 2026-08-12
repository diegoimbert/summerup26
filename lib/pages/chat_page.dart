import 'package:flutter/material.dart';

import '../widgets/page_shell.dart';

/// The Chat section.
class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageShell(
      child: EmptySection(icon: Icons.chat_bubble_outline, message: 'No conversations yet'),
    );
  }
}
