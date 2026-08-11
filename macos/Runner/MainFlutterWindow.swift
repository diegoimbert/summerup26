import Cocoa
import FlutterMacOS

/// The regular application window. The floating toast is a separate panel,
/// managed by `OverlayWindowController`.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    self.title = "Overlay"
    self.minSize = NSSize(width: 420, height: 360)
    // The app outlives its window so the global shortcut keeps working; keep
    // the window around so the Dock icon can bring it back.
    self.isReleasedWhenClosed = false

    super.awakeFromNib()
  }
}
