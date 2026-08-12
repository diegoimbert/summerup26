import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/file_watcher.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/library/organizer.dart';
import 'package:overlay_app/library/source_scanner.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';

/// Connections held in memory, and changeable while the test runs — which is
/// what a user connecting or disconnecting a source amounts to.
class _MemoryStore extends CredentialStore {
  _MemoryStore({
    Map<String, SourceCredentials> connections = const {},
    this.folders = const {},
  }) : connections = {...connections};

  Map<String, SourceCredentials> connections;
  final Map<String, List<String>> folders;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => connections;

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;

  @override
  Future<void> save(SourceCredentials credentials) async =>
      connections = {...connections, credentials.sourceId: credentials};

  @override
  Future<void> delete(String sourceId) async =>
      connections = {...connections}..remove(sourceId);

  @override
  Future<void> saveFolders(String sourceId, List<String> folders) async {}
}

SourceCredentials _credentials(String sourceId) =>
    SourceCredentials(sourceId: sourceId, accessToken: 'token');

/// A library that is never written anywhere.
class _MemoryLibraryStore extends LibraryStore {
  const _MemoryLibraryStore();

  @override
  Future<LibrarySnapshot?> readLibrary() async => null;

  @override
  Future<void> writeLibrary(LibrarySnapshot snapshot) async {}

  @override
  Future<void> writeScan(List<ScannedFile> files, {DateTime? scannedAt}) async {}
}

/// A scan with no disk behind it. What it finds is whatever the test last put
/// in [files], and it says which sources it was asked to walk.
class _FakeScanner extends SourceScanner {
  _FakeScanner(this.files, this.gate);

  final List<ScannedFile> files;

  /// Held open by a test that wants to catch the scan mid-flight.
  final Completer<void>? gate;

  final List<String> walked = [];

  @override
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  }) async {
    walked.add(sourceName);
    final held = gate;
    if (held != null) await held.future;
    return ScanResult(
      files: [
        for (final file in files)
          if (file.sourceName == sourceName) file,
      ],
    );
  }
}

/// Files everything under one folder, and remembers what it was asked to file.
class _FakeOrganizer extends DeepSeekOrganizer {
  _FakeOrganizer();

  int calls = 0;
  List<String> lastAsked = const [];

  @override
  Future<List<String>> organize(
    List<ScannedFile> files, {
    Set<String> existingFolders = const {},
    void Function(int organized, int total)? onProgress,
  }) async {
    calls += 1;
    lastAsked = [for (final file in files) file.name];
    return [for (final file in files) 'Self/Finance/${file.name}'];
  }
}

/// A watcher with no disk behind it.
class _FakeWatcher implements SourceWatcher {
  @override
  Stream<Set<String>> watch(List<String> roots) =>
      const Stream<Set<String>>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

ScannedFile _file(String path, String source) => ScannedFile(
  path: path,
  sourceName: source,
  modified: DateTime(2026, 8, 1),
  externalId: source == 'Google Drive' ? path : null,
);

/// A library over [files], with the sources in [store] connected.
///
/// Returns before anything has been scanned, so a test says for itself what
/// happens first.
({
  LibraryController library,
  _FakeScanner scanner,
  _FakeOrganizer organizer,
  ConnectionsController connections,
})
_libraryOver(
  List<ScannedFile> files, {
  required _MemoryStore store,
  Completer<void>? gate,
}) {
  final connections = ConnectionsController(store: store);
  final scanner = _FakeScanner(files, gate);
  final organizer = _FakeOrganizer();

  final library = LibraryController(
    connections: connections,
    store: const _MemoryLibraryStore(),
    scanners: (source) async => scanner,
    organizer: organizer,
    watcher: _FakeWatcher(),
  );
  addTearDown(library.dispose);

  return (
    library: library,
    scanner: scanner,
    organizer: organizer,
    connections: connections,
  );
}

void main() {
  group('a source coming or going', () {
    test('a source that arrives is scanned there and then', () async {
      final store = _MemoryStore(folders: {'file_system': _folder});
      final over = _libraryOver([
        _file('/Users/d/tax.pdf', 'File System'),
        _file('/Work/notes.txt', 'Google Drive'),
      ], store: store);

      await over.connections.load();
      await over.library.start();

      expect(over.scanner.walked, ['File System']);
      expect(over.library.entries.length, 1);

      // What signing in to a drive leaves behind: credentials where there were
      // none, and everybody told about it.
      store.connections = {'google_drive': _credentials('google_drive')};
      await over.connections.load();
      await pumpEventQueue();

      expect(over.scanner.walked, ['File System', 'File System', 'Google Drive']);
      expect(
        over.library.entries.map((entry) => entry.file.sourceName),
        containsAll(['File System', 'Google Drive']),
      );
    });

    test('a source that is disconnected takes its files with it', () async {
      final store = _MemoryStore(
        connections: {'google_drive': _credentials('google_drive')},
        folders: {'file_system': _folder},
      );
      final over = _libraryOver([
        _file('/Users/d/tax.pdf', 'File System'),
        _file('/Work/notes.txt', 'Google Drive'),
      ], store: store);

      await over.connections.load();
      await over.library.start();
      expect(over.library.entries.length, 2);

      await over.connections.disconnect('google_drive');
      await pumpEventQueue();

      expect(
        over.library.entries.map((entry) => entry.file.sourceName),
        ['File System'],
      );
      // Nothing was filed again: what is left was already where it belongs.
      expect(over.organizer.calls, 1);
    });

    test('the sources found at launch are not news', () async {
      final store = _MemoryStore(
        connections: {'google_drive': _credentials('google_drive')},
        folders: {'file_system': _folder},
      );
      // Built before the stored connections have been read, as it is in the
      // app: the window is up before the disk has answered.
      final over = _libraryOver([
        _file('/Work/notes.txt', 'Google Drive'),
      ], store: store);

      await over.connections.load();
      await pumpEventQueue();

      expect(
        over.scanner.walked,
        isEmpty,
        reason: 'finding out what was already connected is not a change',
      );
    });

    test('a source that arrives mid-scan is picked up after it', () async {
      final gate = Completer<void>();
      final store = _MemoryStore(folders: {'file_system': _folder});
      final over = _libraryOver([
        _file('/Users/d/tax.pdf', 'File System'),
        _file('/Work/notes.txt', 'Google Drive'),
      ], store: store, gate: gate);

      await over.connections.load();
      final scanning = over.library.refresh();
      await pumpEventQueue();

      // Signed in while the first scan is still walking the disk, which that
      // scan has no way of noticing.
      store.connections = {'google_drive': _credentials('google_drive')};
      await over.connections.load();
      await pumpEventQueue();
      expect(over.scanner.walked, ['File System']);

      gate.complete();
      await scanning;
      await pumpEventQueue();

      expect(over.scanner.walked, ['File System', 'File System', 'Google Drive']);
    });

    test('a folder being edited is left to the watcher', () async {
      final store = _MemoryStore(folders: {'file_system': _folder});
      final over = _libraryOver([
        _file('/Users/d/tax.pdf', 'File System'),
      ], store: store);

      await over.connections.load();
      await over.library.start();
      final walked = [...over.scanner.walked];

      await over.connections.setFolders('file_system', ['/Users/d/Documents']);
      await pumpEventQueue();

      expect(over.scanner.walked, walked);
    });
  });

  group('a rescan', () {
    test('sends the model only what it has not seen', () async {
      final store = _MemoryStore(folders: {'file_system': _folder});
      final files = [_file('/Users/d/tax.pdf', 'File System')];
      final over = _libraryOver(files, store: store);

      await over.connections.load();
      await over.library.start();
      expect(over.organizer.lastAsked, ['tax.pdf']);

      files.add(_file('/Users/d/invoice.pdf', 'File System'));
      await over.library.refresh();

      expect(over.organizer.calls, 2);
      expect(over.organizer.lastAsked, ['invoice.pdf']);
      expect(over.library.entries.length, 2);
    });

    test('files nothing again when only files have gone', () async {
      final store = _MemoryStore(folders: {'file_system': _folder});
      final files = [
        _file('/Users/d/tax.pdf', 'File System'),
        _file('/Users/d/invoice.pdf', 'File System'),
      ];
      final over = _libraryOver(files, store: store);

      await over.connections.load();
      await over.library.start();

      files.removeLast();
      await over.library.refresh();

      expect(over.organizer.calls, 1);
      expect(over.library.entries.single.file.name, 'tax.pdf');
    });

    test('forced, it files the whole library again', () async {
      final store = _MemoryStore(folders: {'file_system': _folder});
      final files = [_file('/Users/d/tax.pdf', 'File System')];
      final over = _libraryOver(files, store: store);

      await over.connections.load();
      await over.library.start();

      files.add(_file('/Users/d/invoice.pdf', 'File System'));
      await over.library.refresh(force: true);

      expect(over.organizer.lastAsked, ['tax.pdf', 'invoice.pdf']);
    });
  });
}

const List<String> _folder = ['/Users/d'];
