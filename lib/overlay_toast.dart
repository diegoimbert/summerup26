import 'package:flutter/material.dart';

import 'overlay_bridge.dart';

/// Runs the toast UI shown inside the floating native panel.
void runOverlayToast() {
  runApp(const OverlayToastApp());
}

class OverlayToastApp extends StatelessWidget {
  const OverlayToastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      // Transparent throughout so only the card below is painted; the panel
      // itself and its FlutterView are cleared natively.
      color: Colors.transparent,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: OverlayToast(),
      ),
    );
  }
}

class OverlayToast extends StatefulWidget {
  const OverlayToast({super.key});

  @override
  State<OverlayToast> createState() => _OverlayToastState();
}

class _OverlayToastState extends State<OverlayToast> {
  String _shortcut = '';

  @override
  void initState() {
    super.initState();
    _loadShortcut();
  }

  Future<void> _loadShortcut() async {
    final shortcut = await OverlayBridge.instance.shortcutLabel();
    if (mounted) setState(() => _shortcut = shortcut);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xE61E1E22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFF4ADE80),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Listening',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _shortcut.isEmpty
                        ? 'Press the shortcut again to dismiss'
                        : 'Press $_shortcut again to dismiss',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
