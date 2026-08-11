import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var overlay: OverlayWindowController?
  private var hotKey: GlobalHotKey?
  private var channels: [FlutterMethodChannel] = []

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let overlay = OverlayWindowController()
    self.overlay = overlay

    overlay.onVisibilityChanged = { [weak self] visible in
      self?.broadcast("visibilityChanged", arguments: visible)
    }

    hotKey = GlobalHotKey(
      keyCode: UInt32(kVK_Space),
      modifiers: UInt32(cmdKey | shiftKey),
      label: "⇧⌘Space"
    ) { [weak self] in
      self?.overlay?.toggle()
    }

    // The channel is registered on both engines: the main window drives the
    // toast, and the toast reads the shortcut label back.
    registerChannel(on: overlay.binaryMessenger)
    if let messenger = mainWindowMessenger() {
      registerChannel(on: messenger)
    }

    super.applicationDidFinishLaunching(notification)
  }

  /// Keeps the app (and therefore the global shortcut) alive after the main
  /// window is closed. Clicking the Dock icon brings the window back.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      mainWindow()?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func mainWindow() -> NSWindow? {
    return NSApp.windows.first { $0 is MainFlutterWindow }
  }

  private func mainWindowMessenger() -> FlutterBinaryMessenger? {
    guard let controller = mainWindow()?.contentViewController as? FlutterViewController else {
      return nil
    }
    return controller.engine.binaryMessenger
  }

  private func registerChannel(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "overlay_app/overlay", binaryMessenger: messenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, let overlay = self.overlay else {
        result(FlutterError(code: "unavailable", message: "Overlay not ready", details: nil))
        return
      }

      switch call.method {
      case "show":
        overlay.show()
        result(nil)
      case "hide":
        overlay.hide()
        result(nil)
      case "toggle":
        overlay.toggle()
        result(nil)
      case "isVisible":
        result(overlay.isVisible)
      case "shortcutLabel":
        result(self.hotKey?.label ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    channels.append(channel)
  }

  private func broadcast(_ method: String, arguments: Any?) {
    for channel in channels {
      channel.invokeMethod(method, arguments: arguments)
    }
  }
}
