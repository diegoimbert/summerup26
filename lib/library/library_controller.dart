import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../sources/connections.dart';
import '../sources/google_drive_api.dart';
import '../sources/oauth.dart';
import '../sources/source_catalog.dart';
import 'drive_scanner.dart';
import 'file_scanner.dart';
import 'library_store.dart';
import 'library_tree.dart';
import 'organizer.dart';
import 'source_scanner.dart';

/// Where the library has got to. The Files section reads this to say what is
/// happening, so every stage the user might be kept waiting by has a name.
enum LibraryStage {
  /// Nothing has been asked for yet.
  idle,

  /// Walking the sources for files.
  scanning,

  /// The model is placing what the scan found.
  organizing,

  /// An organized library is on screen.
  ready,

  /// Something went wrong; [LibraryController.error] says what.
  failed,
}

/// Builds the scanner for [source], or returns null when this build cannot
/// read it after all — a connection that has gone, typically.
typedef SourceScannerFactory =
    Future<SourceScanner?> Function(SourceDescriptor source);

/// Scans the connected sources and keeps the organized library.
///
/// A library that was stored is the library that shows: [start] scans only when
/// there is nothing to show, so relaunching is instant and never walks the disk
/// behind the user's back. Picking the files up again is [refresh], which the
/// Rescan button calls.
///
/// Within a scan, the organize step costs a paid API call, so it runs only when
/// the files actually differ from the ones behind the stored library.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.connections,
    LibraryStore? store,
    SourceScannerFactory? scanners,
    DeepSeekOrganizer? organizer,
  }) : _store = store ?? const LibraryStore(),
       _organizer = organizer ?? DeepSeekOrganizer() {
    _scannerFor = scanners ?? _defaultScannerFor;
  }

  final ConnectionsController connections;
  final LibraryStore _store;
  final DeepSeekOrganizer _organizer;
  late final SourceScannerFactory _scannerFor;

  /// The sources this can read, and whether each waits to be pointed at
  /// folders first.
  ///
  /// The file system is the whole disk, so it scans nothing until the user says
  /// where to look. A drive is the user's own and bounded by what they put in
  /// it, so an unset scope means all of it — which is what an unset scope means
  /// everywhere else in Kandoo.
  static const Map<String, bool> scannableSources = {
    'file_system': true,
    'google_drive': false,
  };

  LibraryStage _stage = LibraryStage.idle;
  LibraryStage get stage => _stage;

  bool get isBusy =>
      _stage == LibraryStage.scanning || _stage == LibraryStage.organizing;

  /// Files found so far, or in total once the scan is done.
  int _scannedCount = 0;
  int get scannedCount => _scannedCount;

  /// How far the organizer has got through them.
  int _organizedCount = 0;
  int get organizedCount => _organizedCount;

  /// The source being scanned right now, for the progress line.
  String? _currentSource;
  String? get currentSource => _currentSource;

  String? _error;
  String? get error => _error;

  /// True when the scan stopped at its limit, so the count is a floor.
  bool _truncated = false;
  bool get truncated => _truncated;

  /// Anything the last scan got past but the user should know about, such as a
  /// configured folder that no longer exists.
  List<String> _warnings = const [];
  List<String> get warnings => _warnings;

  List<LibraryEntry> _entries = const [];
  List<LibraryEntry> get entries => _entries;

  DateTime? _organizedAt;
  DateTime? get organizedAt => _organizedAt;

  LibraryTree _tree = LibraryTree.from(const []);
  LibraryTree get tree => _tree;

  String _fingerprint = '';

  /// Whether there is any source to read: one that is connected, and pointed
  /// at folders if it is the kind that waits to be.
  bool get canScan => _scanTargets().isNotEmpty;

  /// What launch does: show the stored library, and go looking only if there
  /// is none.
  ///
  /// A user who already has a library gets it at once, and decides for
  /// themselves when to pick the files up again — a launch is not a reason to
  /// walk their folders, nor to spend a request re-filing what is already
  /// filed.
  Future<void> start() async {
    await load();
    if (_entries.isNotEmpty) return;
    await refresh();
  }

  /// Reads the stored library, so a returning user sees their files before any
  /// scanning begins.
  Future<void> load() async {
    final stored = await _store.readLibrary();
    if (stored == null) return;

    _apply(stored);
    if (_stage == LibraryStage.idle && _entries.isNotEmpty) {
      _stage = LibraryStage.ready;
    }
    notifyListeners();
  }

  /// Scans every connected source, then organizes what changed.
  ///
  /// [force] sends the scan to the model even when it matches the stored
  /// library, for when the user wants a fresh arrangement of the same files.
  Future<void> refresh({bool force = false}) async {
    if (isBusy) return;

    _error = null;
    _truncated = false;
    _scannedCount = 0;
    _organizedCount = 0;
    _stage = LibraryStage.scanning;
    notifyListeners();

    try {
      final files = await _scan();
      await _store.writeScan(files);

      final fingerprint = _fingerprintOf(files);

      if (files.isEmpty) {
        _apply(
          LibrarySnapshot(
            entries: const [],
            fingerprint: fingerprint,
            organizedAt: DateTime.now(),
          ),
        );
        _stage = LibraryStage.ready;
        notifyListeners();
        return;
      }

      // The same files as last time already have a home; sending them again
      // would cost a request to be told the same thing.
      if (!force && fingerprint == _fingerprint && _entries.isNotEmpty) {
        _stage = LibraryStage.ready;
        notifyListeners();
        return;
      }

      _stage = LibraryStage.organizing;
      notifyListeners();

      final paths = await _organizer.organize(
        files,
        onProgress: (organized, total) {
          _organizedCount = organized;
          notifyListeners();
        },
      );

      final snapshot = LibrarySnapshot(
        entries: [
          for (var index = 0; index < files.length; index += 1)
            LibraryEntry(file: files[index], organizedPath: paths[index]),
        ],
        fingerprint: fingerprint,
        organizedAt: DateTime.now(),
      );

      await _store.writeLibrary(snapshot);
      _apply(snapshot);
      _stage = LibraryStage.ready;
    } on OrganizerException catch (failure) {
      // The scan still stands, and so does any library from before it.
      _error = failure.message;
      _stage = LibraryStage.failed;
    } on ScanException catch (failure) {
      _error = failure.message;
      _stage = LibraryStage.failed;
    } on OAuthException catch (failure) {
      _error = failure.message;
      _stage = LibraryStage.failed;
    } catch (failure) {
      _error = 'Scanning failed: $failure';
      _stage = LibraryStage.failed;
    } finally {
      _currentSource = null;
      notifyListeners();
    }
  }

  /// The scanner each source is read with. Only the file system needs nothing
  /// from anywhere; a drive needs a token that has not lapsed.
  Future<SourceScanner?> _defaultScannerFor(SourceDescriptor source) async {
    switch (source.id) {
      case 'file_system':
        return const FileSystemScanner();

      case 'google_drive':
        final credentials = await connections.freshCredentials(source.id);
        if (credentials == null) return null;
        return GoogleDriveScanner(
          api: GoogleDriveApi(accessToken: credentials.accessToken),
        );

      default:
        return null;
    }
  }

  Future<List<ScannedFile>> _scan() async {
    final files = <ScannedFile>[];
    _warnings = const [];

    for (final target in _scanTargets()) {
      _currentSource = target.source.name;
      notifyListeners();

      final scanner = await _scannerFor(target.source);
      if (scanner == null) continue;

      final found = await scanner.scan(
        roots: target.folders,
        sourceName: target.source.name,
        onProgress: (count) {
          _scannedCount = files.length + count;
          notifyListeners();
        },
      );

      files.addAll(found.files);
      _truncated = _truncated || found.truncated;
      if (found.warnings.isNotEmpty) {
        _warnings = [..._warnings, ...found.warnings];
      }
      _scannedCount = files.length;
      notifyListeners();
    }

    return files;
  }

  /// The connected, scannable sources and the folders each was narrowed to.
  List<({SourceDescriptor source, List<String> folders})> _scanTargets() {
    final targets = <({SourceDescriptor source, List<String> folders})>[];

    for (final source in kSourceCatalog) {
      final needsFolders = scannableSources[source.id];
      if (needsFolders == null) continue;
      if (source.needsSignIn && !connections.isConnected(source.id)) continue;

      final folders = connections.foldersFor(source.id);
      if (folders.isEmpty && needsFolders) continue;
      targets.add((source: source, folders: folders));
    }

    return targets;
  }

  void _apply(LibrarySnapshot snapshot) {
    _entries = snapshot.entries;
    _fingerprint = snapshot.fingerprint;
    _organizedAt = snapshot.organizedAt;
    _tree = LibraryTree.from(_entries);
  }

  /// Identifies a set of files by what they are and when they last changed, so
  /// a rename or an edit counts as a change and a reboot does not.
  static String _fingerprintOf(List<ScannedFile> files) {
    final lines = [
      for (final file in files)
        '${file.sourceName}|${file.identity}|'
            '${file.modified?.millisecondsSinceEpoch ?? 0}',
    ]..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }
}
