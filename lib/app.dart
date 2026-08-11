import 'dart:async';

import 'package:flutter/material.dart';

import 'overlay_bridge.dart';

/// Runs the main application window.
void runOverlayApp() {
  runApp(const OverlayApp());
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4ADE80),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Overlay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF141417),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final OverlayBridge _bridge = OverlayBridge.instance;

  StreamSubscription<bool>? _visibilitySub;
  bool _visible = false;
  String _shortcut = '';

  @override
  void initState() {
    super.initState();
    _visibilitySub = _bridge.onVisibilityChanged.listen((visible) {
      if (mounted) setState(() => _visible = visible);
    });
    _load();
  }

  @override
  void dispose() {
    _visibilitySub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final shortcut = await _bridge.shortcutLabel();
    final visible = await _bridge.isVisible();
    if (!mounted) return;
    setState(() {
      _shortcut = shortcut;
      _visible = visible;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Overlay',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A floating toast that stays above your other windows.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 28),
            _ShortcutCard(shortcut: _shortcut),
            const SizedBox(height: 16),
            _StatusCard(
              visible: _visible,
              onToggle: () => _bridge.toggle(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the global shortcut that summons the toast.
class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({required this.shortcut});

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('Global shortcut'),
          const SizedBox(height: 4),
          const Text(
            'Works from any app, even when Overlay is in the background.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (shortcut.isEmpty)
            const SizedBox(
              height: 34,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            Wrap(
              spacing: 6,
              children: [
                for (final key in _splitShortcut(shortcut)) _KeyCap(key),
              ],
            ),
        ],
      ),
    );
  }

  /// Splits `⇧⌘Space` into its individual caps: the modifiers are single
  /// symbols, and whatever trails them is the key name.
  static List<String> _splitShortcut(String shortcut) {
    const modifiers = {'⌃', '⌥', '⇧', '⌘'};
    final caps = <String>[];
    final buffer = StringBuffer();

    for (final rune in shortcut.runes) {
      final char = String.fromCharCode(rune);
      if (modifiers.contains(char)) {
        caps.add(char);
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) caps.add(buffer.toString());
    return caps;
  }
}

/// Shows whether the toast is on screen, with a manual toggle.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.visible, required this.onToggle});

  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: visible ? const Color(0xFF4ADE80) : Colors.white24,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _CardTitle('Toast'),
                const SizedBox(height: 2),
                Text(
                  visible ? 'Showing' : 'Hidden',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: onToggle,
            child: Text(visible ? 'Hide' : 'Show'),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
