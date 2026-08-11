import 'app.dart';
import 'overlay_toast.dart';

/// Entrypoint for the main application window.
void main() {
  runKandooApp();
}

/// Entrypoint for the floating overlay toast.
///
/// The toast runs on a second Flutter engine, created natively by
/// `OverlayWindowController`. `FlutterEngine.runWithEntrypoint:` resolves the
/// entrypoint name against the library that declares `main()`, so this function
/// has to stay in this file; the `vm:entry-point` pragma keeps it from being
/// tree-shaken in release builds.
@pragma('vm:entry-point')
void overlayMain() {
  runOverlayToast();
}
