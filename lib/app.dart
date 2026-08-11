import 'package:flutter/material.dart';

import 'theme.dart';

/// Runs the main application window.
void runKandooApp() {
  runApp(const KandooApp());
}

class KandooApp extends StatelessWidget {
  const KandooApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kandoo',
      debugShowCheckedModeBanner: false,
      theme: buildKandooTheme(),
      home: const HomePage(),
    );
  }
}

/// One entry in the left side menu.
class NavSection {
  const NavSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

const List<NavSection> kNavSections = [
  NavSection('Today', Icons.wb_sunny_outlined),
  NavSection('Chat', Icons.chat_bubble_outline),
  NavSection('Files', Icons.insert_drive_file_outlined),
  NavSection('Sources', Icons.storage_outlined),
  NavSection('Pattern recognized', Icons.grid_view_outlined),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(
            selectedIndex: _selectedIndex,
            onSelected: (index) => setState(() => _selectedIndex = index),
          ),
          // Content area, intentionally empty for now.
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selectedIndex, required this.onSelected});

  static const double width = 232;

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: KandooColors.sidebar,
        border: Border(right: BorderSide(color: KandooColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Text(
              'Kandoo',
              style: TextStyle(
                fontFamily: KandooFonts.heading,
                color: KandooColors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: kNavSections.length,
              itemBuilder: (context, index) {
                return _NavTile(
                  section: kNavSections[index],
                  selected: index == selectedIndex,
                  onTap: () => onSelected(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final NavSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final foreground = selected
        ? KandooColors.accent
        : KandooColors.textSecondary;

    final Color background;
    if (selected) {
      background = KandooColors.selectedFill;
    } else if (_hovered) {
      background = KandooColors.hoverFill;
    } else {
      background = Colors.transparent;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                Icon(widget.section.icon, size: 18, color: foreground),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    widget.section.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? KandooColors.textPrimary : foreground,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
