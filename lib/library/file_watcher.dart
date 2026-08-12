import 'dart:async';
import 'dart:io';

/// Reports where something changed under the folders it was given.
///
/// Neither what changed nor what happened to it is promised. macOS reports the
/// folder a change happened in as often as the file itself, turns a rename into
/// a delete here and a create there, and coalesces a burst into one event. A
/// reader that tries to classify events will be wrong; a reader that treats
/// each path as "look here again" will not.
abstract class SourceWatcher {
  /// Starts watching [roots], replacing anything watched before, and returns
  /// the batches of paths that change.
  Stream<Set<String>> watch(List<String> roots);

  /// Stops watching, without ending the stream.
  Future<void> stop();

  Future<void> dispose();
}

/// Watches the folders the File System source was narrowed to.
///
/// Events are gathered until they stop coming: a single save can be three
/// events, and unzipping a folder is hundreds. Acting per event would mean a
/// paid request per event.
class FileSystemWatcher implements SourceWatcher {
  FileSystemWatcher({this.settle = const Duration(milliseconds: 750)});

  /// How long the folders must be quiet before a batch is reported.
  final Duration settle;

  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();
  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];
  final Set<String> _touched = {};

  Timer? _timer;

  @override
  Stream<Set<String>> watch(List<String> roots) {
    stop();

    for (final root in roots) {
      try {
        _subscriptions.add(
          Directory(root)
              .watch(recursive: true)
              .listen(
                _onEvent,
                // A folder that goes away takes its watch with it; the others
                // carry on.
                onError: (Object _) {},
                cancelOnError: true,
              ),
        );
      } on FileSystemException {
        // Nothing to watch here — an unreadable or missing folder is the
        // scan's problem to report, not the watcher's.
        continue;
      }
    }

    return _changes.stream;
  }

  void _onEvent(FileSystemEvent event) {
    _touched.add(event.path);
    if (event is FileSystemMoveEvent) {
      final destination = event.destination;
      if (destination != null) _touched.add(destination);
    }

    _timer?.cancel();
    _timer = Timer(settle, _flush);
  }

  void _flush() {
    _timer = null;
    if (_touched.isEmpty) return;

    final batch = Set<String>.unmodifiable(_touched);
    _touched.clear();
    if (!_changes.isClosed) _changes.add(batch);
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _touched.clear();

    final subscriptions = [..._subscriptions];
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}
