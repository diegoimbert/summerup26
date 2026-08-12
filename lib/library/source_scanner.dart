import 'library_store.dart';

/// Lists everything a source holds, so the organizer has something to file.
///
/// One implementation per source: the disk, a drive, whatever comes next. The
/// controller knows only this, which is what keeps adding a source to a scanner
/// and a line in its table rather than a new branch through the library.
abstract class SourceScanner {
  const SourceScanner();

  /// Everything under [roots], or everything the source holds when [roots] is
  /// empty and the source is one that can be read whole.
  ///
  /// [sourceName] is stamped on every file found, so the library can say where
  /// something came from. [onProgress] is called with a running count.
  ///
  /// Throws [ScanException] when the source cannot be read at all.
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  });
}

/// A source that cannot tell Kandoo when something happens, and has to be
/// asked instead.
///
/// The question is deliberately cheap and vague — *has anything changed?* — so
/// that a quiet source costs one request. Working out what changed is the
/// scan's job, and only worth doing once the answer is yes.
abstract class PollableScanner {
  Future<bool> hasChangesSince(DateTime? watermark);
}

/// Thrown when a source cannot be read: no credentials, no network, a refusal.
/// The message is shown to the user, so it should say what to do about it.
class ScanException implements Exception {
  const ScanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a scan found, and anything the user should know about how it went.
class ScanResult {
  const ScanResult({
    required this.files,
    this.truncated = false,
    this.warnings = const [],
  });

  final List<ScannedFile> files;

  /// Whether the scan stopped at its limit, making the count a floor.
  final bool truncated;

  /// Things worth saying that were not worth failing over — a configured
  /// folder that no longer exists, say.
  final List<String> warnings;
}
