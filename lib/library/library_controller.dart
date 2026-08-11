import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../sources/connections.dart';
import '../sources/source_catalog.dart';
import 'file_scanner.dart';
import 'library_store.dart';
import 'library_tree.dart';
import 'organizer.dart';

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

/// Scans the connected sources on launch and keeps the organized library.
///
/// The scan is cheap and local, so it runs every time. The organize step costs
/// a paid API call, so it runs only when the scan actually differs from the one
/// behind the stored library.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.connections,
    LibraryStore? store,
    FileSystemScanner? scanner,
    DeepSeekOrganizer? organizer,
  }) : _store = store ?? LibraryStore(),
       _scanner = scanner ?? const FileSystemScanner(),
       _organizer = organizer ?? DeepSeekOrganizer();

  final ConnectionsController connections;
  final LibraryStore _store;
  final FileSystemScanner _scanner;
  final DeepSeekOrganizer _organizer;

  /// The sources this can scan today. The others are connected and scoped, but
  /// nothing reads them yet.
  static const Set<String> scannableSources = {'file_system'};

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

  List<LibraryEntry> _entries = const [];
  List<LibraryEntry> get entries => _entries;

  DateTime? _organizedAt;
  DateTime? get organizedAt => _organizedAt;

  LibraryTree _tree = LibraryTree.from(const []);
  LibraryTree get tree => _tree;

  String _fingerprint = '';

  /// Whether anything can be scanned at all: a scannable source that has been
  /// pointed at some folders.
  bool get hasScannableFolders => _scanTargets().isNotEmpty;

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
    } catch (failure) {
      _error = 'Scanning failed: $failure';
      _stage = LibraryStage.failed;
    } finally {
      _currentSource = null;
      notifyListeners();
    }
  }

  Future<List<ScannedFile>> _scan() async {
    final files = <ScannedFile>[];

    for (final target in _scanTargets()) {
      _currentSource = target.source.name;
      notifyListeners();

      final found = await _scanner.scan(
        roots: target.folders,
        sourceName: target.source.name,
        onProgress: (count) {
          _scannedCount = files.length + count;
          notifyListeners();
        },
      );

      files.addAll(found.files);
      _truncated = _truncated || found.truncated;
      _scannedCount = files.length;
      notifyListeners();
    }

    return files;
  }

  /// The connected, scannable sources and the folders each was narrowed to.
  ///
  /// A source with no folders configured is skipped rather than read whole:
  /// for the file system that would mean walking the entire disk.
  List<({SourceDescriptor source, List<String> folders})> _scanTargets() {
    final targets = <({SourceDescriptor source, List<String> folders})>[];

    for (final source in kSourceCatalog) {
      if (!scannableSources.contains(source.id)) continue;
      if (source.needsSignIn && !connections.isConnected(source.id)) continue;

      final folders = connections.foldersFor(source.id);
      if (folders.isEmpty) continue;
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
        '${file.sourceName}|${file.path}|'
            '${file.modified?.millisecondsSinceEpoch ?? 0}',
    ]..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }
}
