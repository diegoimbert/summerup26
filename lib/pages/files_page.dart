import 'package:flutter/material.dart';

import '../widgets/page_shell.dart';

/// The Files section.
class FilesPage extends StatelessWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageShell(
      title: 'Files',
      subtitle: 'Everything Kandoo has gathered',
      child: EmptySection(icon: Icons.insert_drive_file_outlined, message: 'No files yet'),
    );
  }
}
