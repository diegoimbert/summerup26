import Carbon.HIToolbox
import Cocoa

/// A system-wide keyboard shortcut registered through Carbon's
/// `RegisterEventHotKey`.
///
/// Carbon hot keys fire while the app is in the background and, unlike a
/// `CGEventTap`, require no Accessibility permission and work inside the app
/// sandbox.
final class GlobalHotKey {
  /// Identifies this app's hot keys so the shared handler can ignore others.
  private static let signature = OSType(0x4F_56_4C_59)  // 'OVLY'

  private static var handlers: [UInt32: () -> Void] = [:]
  private static var nextIdentifier: UInt32 = 1
  private static var eventHandler: EventHandlerRef?

  private let identifier: UInt32
  private var hotKeyRef: EventHotKeyRef?

  /// Symbols matching how macOS renders the shortcut in menus, e.g. `⇧⌘Space`.
  let label: String

  /// - Parameters:
  ///   - keyCode: A virtual key code, e.g. `kVK_Space`.
  ///   - modifiers: Carbon modifier flags, e.g. `cmdKey | shiftKey`.
  init?(keyCode: UInt32, modifiers: UInt32, label: String, onPress: @escaping () -> Void) {
    self.label = label
    identifier = GlobalHotKey.nextIdentifier
    GlobalHotKey.nextIdentifier += 1

    GlobalHotKey.installSharedHandlerIfNeeded()

    let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: identifier)
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)

    // Registration fails when another app already owns the combination.
    guard status == noErr, hotKeyRef != nil else {
      NSLog("Overlay: could not register hot key \(label) (OSStatus \(status))")
      return nil
    }

    GlobalHotKey.handlers[identifier] = onPress
  }

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    GlobalHotKey.handlers[identifier] = nil
  }

  /// Installs the single process-wide handler that dispatches to each hot key.
  private static func installSharedHandlerIfNeeded() {
    guard eventHandler == nil else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, _ -> OSStatus in
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

        guard status == noErr, hotKeyID.signature == GlobalHotKey.signature,
          let handler = GlobalHotKey.handlers[hotKeyID.id]
        else {
          return OSStatus(eventNotHandledErr)
        }

        handler()
        return noErr
      }, 1, &eventType, nil, &eventHandler)
  }
}
