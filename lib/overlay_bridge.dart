import 'dart:async';

import 'package:flutter/services.dart';

/// Talks to the native overlay panel.
///
/// The panel is an `NSPanel` owned by `OverlayWindowController` and driven by
/// its own Flutter engine, so showing and hiding it is a platform call rather
/// than a widget rebuild. The same channel is registered on both engines, which
/// lets the toast read the shortcut label too.
class OverlayBridge {
  OverlayBridge._() {
    _channel.setMethodCallHandler(_handleCall);
  }

  static final OverlayBridge instance = OverlayBridge._();

  static const MethodChannel _channel = MethodChannel('overlay_app/overlay');

  final StreamController<bool> _visibility = StreamController<bool>.broadcast();

  /// Emits whenever the panel is shown or hidden, including via the shortcut.
  Stream<bool> get onVisibilityChanged => _visibility.stream;

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'visibilityChanged') {
      _visibility.add(call.arguments as bool? ?? false);
    }
  }

  /// Whether the panel is currently on screen.
  Future<bool> isVisible() async =>
      await _channel.invokeMethod<bool>('isVisible') ?? false;

  /// A display label for the global shortcut, e.g. `⇧⌘Space`.
  Future<String> shortcutLabel() async =>
      await _channel.invokeMethod<String>('shortcutLabel') ?? '';

  Future<void> show() => _channel.invokeMethod<void>('show');

  Future<void> hide() => _channel.invokeMethod<void>('hide');

  Future<void> toggle() => _channel.invokeMethod<void>('toggle');
}
