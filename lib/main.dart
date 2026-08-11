import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Size of the overlay panel, in logical pixels.
const Size _overlaySize = Size(320, 120);

/// Gap between the overlay and the screen edges.
const double _screenMargin = 16;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // No `titleBarStyle` here: MainFlutterWindow already uses a `.borderless`
  // style mask, so the window has no standard window buttons and
  // window_manager's setTitleBarStyle force-unwraps the (nil) close button.
  const windowOptions = WindowOptions(
    size: _overlaySize,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Not setAsFrameless(): it forces `isOpaque = true`, which would undo the
    // transparency configured natively. The window is already frameless.
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setHasShadow(false);
    await _positionBottomRight();
    await windowManager.show();
  });

  runApp(const OverlayApp());
}

/// Places the window in the bottom-right corner of the primary display,
/// respecting the visible work area (i.e. above the Dock).
Future<void> _positionBottomRight() async {
  final display = await screenRetriever.getPrimaryDisplay();
  final visible = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;

  final x = visible.dx + visibleSize.width - _overlaySize.width - _screenMargin;
  final y = visible.dy + visibleSize.height - _overlaySize.height - _screenMargin;

  await windowManager.setPosition(Offset(x, y));
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      // Transparent so only the overlay card is painted.
      color: Colors.transparent,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: OverlayPanel(),
      ),
    );
  }
}

class OverlayPanel extends StatelessWidget {
  const OverlayPanel({super.key});

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
                children: const [
                  Text(
                    'Overlay running',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Bottom-right • always on top',
                    style: TextStyle(
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
