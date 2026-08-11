import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    // The window and the FlutterView hold separate background colors. Without
    // this the view defaults to opaque black, which shows up as a black box
    // behind the overlay card no matter how transparent the window is.
    flutterViewController.backgroundColor = .clear

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Make the window a transparent, chrome-less overlay.
    //
    // The window stays `.titled`: swapping the style mask to `.borderless`
    // rebuilds the window's frame view and the Flutter Metal layer stops
    // drawing entirely (the window survives with no backing store). Hiding the
    // title bar over a full-size content view gives the same look and keeps
    // rendering intact.
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.styleMask = [.titled, .fullSizeContentView]
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.standardWindowButton(.closeButton)?.isHidden = true
    self.standardWindowButton(.miniaturizeButton)?.isHidden = true
    self.standardWindowButton(.zoomButton)?.isHidden = true
    self.isMovableByWindowBackground = false

    // Float above normal windows and stay visible across all Spaces,
    // including over full-screen apps.
    self.level = .floating
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    super.awakeFromNib()
  }

  // Borderless windows can't become key/main by default; allow it so
  // the overlay can receive input when needed.
  override var canBecomeKey: Bool { return true }
  override var canBecomeMain: Bool { return true }
}
