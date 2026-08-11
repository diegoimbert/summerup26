import Cocoa
import FlutterMacOS

/// Owns the floating toast: a transparent panel driven by its own Flutter
/// engine, pinned to the bottom-right of whichever screen the pointer is on.
///
/// The toast needs a second engine because a `FlutterEngine` drives a single
/// `FlutterViewController` at a time, and the main window already holds one.
/// The engine is started up front so the panel appears instantly.
final class OverlayWindowController {
  private static let panelSize = NSSize(width: 320, height: 120)
  private static let screenMargin: CGFloat = 16

  private let panel: NSPanel
  private let engine: FlutterEngine

  /// Called whenever the panel is shown or hidden, for whatever reason.
  var onVisibilityChanged: ((Bool) -> Void)?

  /// The toast engine's messenger, so the overlay channel can be registered on
  /// it as well as on the main window's engine.
  var binaryMessenger: FlutterBinaryMessenger { engine.binaryMessenger }

  var isVisible: Bool { panel.isVisible }

  init() {
    engine = FlutterEngine(name: "overlay", project: nil, allowHeadlessExecution: true)
    engine.run(withEntrypoint: "overlayMain")
    RegisterGeneratedPlugins(registry: engine)

    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    // The view defaults to opaque black; clearing it lets the panel show
    // through so only the toast card is painted.
    viewController.backgroundColor = .clear

    panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: OverlayWindowController.panelSize),
      // `.nonactivatingPanel` keeps the user's current app frontmost when the
      // toast appears. The panel stays `.titled` with hidden chrome rather than
      // `.borderless`, matching the main window's working configuration.
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)

    panel.contentViewController = viewController

    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = false
    panel.isReleasedWhenClosed = false

    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .floating
    // NSPanel hides itself when the app deactivates by default, which would
    // pull the toast away the moment it is shown over another app.
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
  }

  func show() {
    guard !panel.isVisible else { return }
    moveToActiveScreenCorner()
    // Order in without activating the app, so the user keeps their focus and
    // whatever they were typing into.
    panel.orderFrontRegardless()
    onVisibilityChanged?(true)
  }

  func hide() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    onVisibilityChanged?(false)
  }

  func toggle() {
    if panel.isVisible {
      hide()
    } else {
      show()
    }
  }

  /// Pins the panel to the bottom-right of the screen holding the pointer,
  /// inside the visible frame so it clears the Dock and the menu bar.
  private func moveToActiveScreenCorner() {
    let pointer = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
      ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }

    let size = OverlayWindowController.panelSize
    let margin = OverlayWindowController.screenMargin
    let origin = NSPoint(
      x: visible.maxX - size.width - margin,
      y: visible.minY + margin)

    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }
}
