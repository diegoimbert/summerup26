import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overlay_app/library/file_scanner.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/library/library_tree.dart';
import 'package:overlay_app/library/organizer.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';

/// Keeps folder scope in memory, so the tests never touch Application Support.
class _MemoryStore extends CredentialStore {
  _MemoryStore({this.folders = const {}});

  final Map<String, List<String>> folders;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => const {};

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;
}

/// A scan with no disk behind it.
class _FakeScanner extends FileSystemScanner {
  _FakeScanner(this.files);

  final List<ScannedFile> files;
  final List<List<String>> calls = [];

  @override
  Future<ScanResult> scan({
    required List<String> roots,
    required String sourceName,
    void Function(int found)? onProgress,
  }) async {
    calls.add(roots);
    onProgress?.call(files.length);
    return ScanResult(files: files);
  }
}

/// An organizer that files everything under a fixed path, and counts how often
/// it was asked to.
class _FakeOrganizer extends DeepSeekOrganizer {
  _FakeOrganizer({this.failure});

  final String? failure;
  int calls = 0;

  @override
  Future<List<String>> organize(
    List<ScannedFile> files, {
    void Function(int organized, int total)? onProgress,
  }) async {
    calls += 1;
    if (failure != null) throw OrganizerException(failure!);
    onProgress?.call(files.length, files.length);
    return [for (final file in files) 'Self/Finance/${file.name}'];
  }
}

ScannedFile _file(String path, {DateTime? modified}) => ScannedFile(
  path: path,
  sourceName: 'File System',
  modified: modified ?? DateTime(2026, 8, 4),
);

/// A DeepSeek reply carrying [content] as the model's answer.
http.Response _reply(String content) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': content},
      },
    ],
  }),
  200,
);

void main() {
  group('FileSystemScanner', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kandoo_scan_');
      await File('${root.path}/todo.md').writeAsString('todo');
      await Directory('${root.path}/Invoices/2026').create(recursive: true);
      await File('${root.path}/Invoices/march.pdf').writeAsString('pdf');
      await File('${root.path}/Invoices/2026/april.pdf').writeAsString('pdf');
      await File('${root.path}/.hidden').writeAsString('secret');
      await Directory('${root.path}/node_modules').create();
      await File('${root.path}/node_modules/index.js').writeAsString('js');
    });

    tearDown(() => root.delete(recursive: true));

    test('walks the whole folder, skipping noise', () async {
      final result = await const FileSystemScanner().scan(
        roots: [root.path],
        sourceName: 'File System',
      );

      expect(result.files.map((file) => file.name).toSet(), {
        'todo.md',
        'march.pdf',
        'april.pdf',
      });
      expect(result.truncated, isFalse);
      // Dates come off the disk, not out of a model.
      expect(result.files.every((file) => file.modified != null), isTrue);
      expect(
        result.files.every((file) => file.sourceName == 'File System'),
        isTrue,
      );
    });

    test('stops at its limit and says so', () async {
      final result = await const FileSystemScanner(
        maxFiles: 2,
      ).scan(roots: [root.path], sourceName: 'File System');

      expect(result.files, hasLength(2));
      expect(result.truncated, isTrue);
    });

    test('depth is bounded', () async {
      final result = await const FileSystemScanner(
        maxDepth: 1,
      ).scan(roots: [root.path], sourceName: 'File System');

      // Two levels down is past the limit.
      expect(
        result.files.map((file) => file.name),
        isNot(contains('april.pdf')),
      );
      expect(result.files.map((file) => file.name), contains('march.pdf'));
    });

    test('an unreadable root costs only that root', () async {
      final result = await const FileSystemScanner().scan(
        roots: ['${root.path}/gone', root.path],
        sourceName: 'File System',
      );

      expect(result.files, hasLength(3));
    });
  });

  group('LibraryStore', () {
    late Directory directory;
    late LibraryStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kandoo_store_');
      store = LibraryStore(directory: directory);
    });

    tearDown(() => directory.delete(recursive: true));

    test('the scan is written as path and source tuples', () async {
      await store.writeScan([
        _file('/Users/diegoimbert/Desktop/tax.pdf'),
        _file('/Users/diegoimbert/Desktop/notes.md'),
      ]);

      final written = jsonDecode(
        await File('${directory.path}/scan.json').readAsString(),
      );
      expect(written['files'], hasLength(2));
      expect(written['files'][0]['path'], '/Users/diegoimbert/Desktop/tax.pdf');
      expect(written['files'][0]['source'], 'File System');

      final read = await store.readScan();
      expect(read.map((file) => file.path), [
        '/Users/diegoimbert/Desktop/tax.pdf',
        '/Users/diegoimbert/Desktop/notes.md',
      ]);
    });

    test('the organized library survives a round trip', () async {
      final snapshot = LibrarySnapshot(
        entries: [
          LibraryEntry(
            file: _file('/Users/diegoimbert/Desktop/tax_2025_FINAL.pdf'),
            organizedPath: 'Self/Finance/Tax return 2025.pdf',
          ),
        ],
        fingerprint: 'abc',
        organizedAt: DateTime(2026, 8, 11, 12, 30),
      );
      await store.writeLibrary(snapshot);

      final read = await store.readLibrary();
      expect(read, isNotNull);
      expect(read!.fingerprint, 'abc');
      expect(
        read.entries.single.organizedPath,
        'Self/Finance/Tax return 2025.pdf',
      );
      expect(read.entries.single.title, 'Tax return 2025.pdf');
      expect(read.entries.single.folders, ['Self', 'Finance']);
      expect(
        read.entries.single.file.path,
        '/Users/diegoimbert/Desktop/tax_2025_FINAL.pdf',
      );
    });

    test('a missing or corrupt file reads as nothing', () async {
      expect(await store.readScan(), isEmpty);
      expect(await store.readLibrary(), isNull);

      await File('${directory.path}/library.json').writeAsString('{oh no');
      expect(await store.readLibrary(), isNull);
    });
  });

  group('DeepSeekOrganizer', () {
    test(
      'files are placed by index, and the request is what DeepSeek wants',
      () async {
        late http.Request sent;
        final organizer = DeepSeekOrganizer(
          apiKey: 'sk-test',
          client: MockClient((request) async {
            sent = request;
            return _reply(
              jsonEncode({
                'files': [
                  {'index': 0, 'path': 'Self/Finance/Tax return 2025.pdf'},
                  {'index': 1, 'path': 'Career/Projects/Pitch deck.pdf'},
                ],
              }),
            );
          }),
        );

        final paths = await organizer.organize([
          _file('/Users/diegoimbert/Desktop/tax_2025_FINAL.pdf'),
          _file('/Users/diegoimbert/Desktop/deck v3.pdf'),
        ]);

        expect(paths, [
          'Self/Finance/Tax return 2025.pdf',
          'Career/Projects/Pitch deck.pdf',
        ]);

        expect(sent.headers['Authorization'], 'Bearer sk-test');
        final body = jsonDecode(sent.body) as Map<String, dynamic>;
        expect(body['model'], 'deepseek-chat');
        expect(body['response_format'], {'type': 'json_object'});
        // The scan's own paths are what the model reasons from.
        expect(body['messages'][1]['content'], contains('tax_2025_FINAL.pdf'));
      },
    );

    test('the answer is always the same length as the scan', () async {
      final organizer = DeepSeekOrganizer(
        apiKey: 'sk-test',
        client: MockClient((request) async {
          return _reply(
            jsonEncode({
              'files': [
                {'index': 0, 'path': 'Self/Finance/Tax return 2025.pdf'},
                // Index 1 dropped, and an index that was never sent.
                {'index': 9, 'path': 'Made/Up.pdf'},
              ],
            }),
          );
        }),
      );

      final paths = await organizer.organize([
        _file('/Users/diegoimbert/Desktop/tax.pdf'),
        _file('/Users/diegoimbert/Desktop/forgotten.pdf'),
      ]);

      expect(paths, [
        'Self/Finance/Tax return 2025.pdf',
        'Unsorted/forgotten.pdf',
      ]);
    });

    test('a bare name is filed rather than left at the root', () async {
      final organizer = DeepSeekOrganizer(
        apiKey: 'sk-test',
        client: MockClient(
          (request) async => _reply(
            jsonEncode({
              'files': [
                {'index': 0, 'path': '/../Notes.md'},
              ],
            }),
          ),
        ),
      );

      expect(await organizer.organize([_file('/tmp/n.md')]), [
        'Unsorted/Notes.md',
      ]);
    });

    test(
      'long batches are split, and later ones see the folders already used',
      () async {
        final bodies = <String>[];
        final organizer = DeepSeekOrganizer(
          apiKey: 'sk-test',
          batchSize: 2,
          client: MockClient((request) async {
            bodies.add(request.body);
            final index = bodies.length == 1 ? 0 : 2;
            return _reply(
              jsonEncode({
                'files': [
                  {'index': index, 'path': 'Self/Finance/One.pdf'},
                  {'index': index + 1, 'path': 'Self/Finance/Two.pdf'},
                ],
              }),
            );
          }),
        );

        final paths = await organizer.organize([
          _file('/a.pdf'),
          _file('/b.pdf'),
          _file('/c.pdf'),
          _file('/d.pdf'),
        ]);

        expect(bodies, hasLength(2));
        expect(
          paths.where((path) => path.startsWith('Self/Finance')),
          hasLength(4),
        );
        expect(bodies[0], isNot(contains('already in use')));
        expect(bodies[1], contains('Self/Finance'));
      },
    );

    test('everything past the ceiling is filed as unsorted', () async {
      final organizer = DeepSeekOrganizer(
        apiKey: 'sk-test',
        maxFiles: 1,
        client: MockClient(
          (request) async => _reply(
            jsonEncode({
              'files': [
                {'index': 0, 'path': 'Self/Finance/One.pdf'},
              ],
            }),
          ),
        ),
      );

      final paths = await organizer.organize([
        _file('/a.pdf'),
        _file('/b.pdf'),
      ]);

      expect(paths, ['Self/Finance/One.pdf', 'Unsorted/b.pdf']);
    });

    test('a build without a key says so instead of calling out', () async {
      var called = false;
      final organizer = DeepSeekOrganizer(
        apiKey: '',
        client: MockClient((request) async {
          called = true;
          return _reply('{}');
        }),
      );

      await expectLater(
        organizer.organize([_file('/a.pdf')]),
        throwsA(
          isA<OrganizerException>().having(
            (error) => error.message,
            'message',
            contains('no DeepSeek key'),
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('a rejected key is reported as one', () async {
      final organizer = DeepSeekOrganizer(
        apiKey: 'sk-wrong',
        client: MockClient((request) async => http.Response('nope', 401)),
      );

      await expectLater(
        organizer.organize([_file('/a.pdf')]),
        throwsA(
          isA<OrganizerException>().having(
            (error) => error.message,
            'message',
            'DeepSeek rejected the key in this build.',
          ),
        ),
      );
    });
  });

  group('LibraryTree', () {
    LibraryEntry entry(String path, String organized, {DateTime? modified}) =>
        LibraryEntry(
          file: _file(path, modified: modified),
          organizedPath: organized,
        );

    test('folders nest, and carry what they hold', () async {
      final tree = LibraryTree.from([
        entry(
          '/a.pdf',
          'Self/Finance/Tax return 2025.pdf',
          modified: DateTime(2026, 8, 4),
        ),
        entry(
          '/b.xlsx',
          'Self/Finance/Q2 budget.xlsx',
          modified: DateTime(2026, 7, 21),
        ),
        entry(
          '/c.pdf',
          'Self/Health/Blood test results.pdf',
          modified: DateTime(2026, 7, 30),
        ),
        entry(
          '/d.pdf',
          'Career/Pitch deck.pdf',
          modified: DateTime(2026, 5, 11),
        ),
      ]);

      final top = await tree.childrenOf(null);
      expect(top.map((row) => row.label), ['Career', 'Self']);
      expect(top.every((row) => row.isFolder), isTrue);
      expect(top.last.detail, '3 files');

      final self = await tree.childrenOf(top.last);
      expect(self.map((row) => row.label), ['Finance', 'Health']);
      expect(self.first.detail, '2 files');

      final finance = await tree.childrenOf(self.first);
      // Newest first, the way a person looks for recent work.
      expect(finance.map((row) => row.label), [
        'Tax return 2025.pdf',
        'Q2 budget.xlsx',
      ]);
      expect(finance.first.isFolder, isFalse);
      expect(finance.first.detail, '2026-08-04');
    });

    test(
      'a folder holding both files and folders lists folders first',
      () async {
        final tree = LibraryTree.from([
          entry('/a.pdf', 'Self/Loose note.pdf'),
          entry('/b.pdf', 'Self/Finance/Tax.pdf'),
        ]);

        final self = await tree.childrenOf(
          (await tree.childrenOf(null)).single,
        );
        expect(self.map((row) => row.label), ['Finance', 'Loose note.pdf']);
      },
    );

    test('files the model gave the same title stay distinct', () async {
      final tree = LibraryTree.from([
        entry('/one/report.pdf', 'Self/Finance/Report.pdf'),
        entry('/two/report.pdf', 'Self/Finance/Report.pdf'),
      ]);

      final finance = await tree.childrenOf(
        (await tree.childrenOf((await tree.childrenOf(null)).single)).single,
      );
      expect(finance.map((row) => row.id).toSet(), hasLength(2));
    });
  });

  group('LibraryController', () {
    late Directory directory;
    late LibraryStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kandoo_library_');
      store = LibraryStore(directory: directory);
    });

    tearDown(() => directory.delete(recursive: true));

    Future<ConnectionsController> connectionsWith(List<String> folders) async {
      final connections = ConnectionsController(
        store: _MemoryStore(
          folders: folders.isEmpty ? const {} : {'file_system': folders},
        ),
      );
      await connections.load();
      return connections;
    }

    test('a scan is stored, organized and shown', () async {
      final scanner = _FakeScanner([
        _file('/Users/diegoimbert/Desktop/tax_2025_FINAL.pdf'),
      ]);
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: await connectionsWith(['/Users/diegoimbert/Desktop']),
        store: store,
        scanner: scanner,
        organizer: organizer,
      );
      addTearDown(library.dispose);

      final stages = <LibraryStage>[];
      library.addListener(() => stages.add(library.stage));

      await library.refresh();

      expect(
        stages,
        containsAllInOrder([
          LibraryStage.scanning,
          LibraryStage.organizing,
          LibraryStage.ready,
        ]),
      );
      expect(scanner.calls, [
        ['/Users/diegoimbert/Desktop'],
      ]);
      expect(
        library.entries.single.organizedPath,
        'Self/Finance/tax_2025_FINAL.pdf',
      );
      expect(library.scannedCount, 1);

      // Both halves are on disk: the raw scan and what was made of it.
      expect(await store.readScan(), hasLength(1));
      expect((await store.readLibrary())!.entries, hasLength(1));
    });

    test('an unchanged scan is not sent to the model twice', () async {
      final scanner = _FakeScanner([_file('/Users/diegoimbert/Desktop/a.pdf')]);
      final organizer = _FakeOrganizer();
      final connections = await connectionsWith(['/Users/diegoimbert/Desktop']);

      final first = LibraryController(
        connections: connections,
        store: store,
        scanner: scanner,
        organizer: organizer,
      );
      addTearDown(first.dispose);
      await first.refresh();
      expect(organizer.calls, 1);

      // A second run of the same app, reading what the first one left behind.
      final second = LibraryController(
        connections: connections,
        store: store,
        scanner: scanner,
        organizer: organizer,
      );
      addTearDown(second.dispose);
      await second.load();
      await second.refresh();

      expect(organizer.calls, 1, reason: 'the same files cost nothing again');
      expect(second.stage, LibraryStage.ready);
      expect(second.entries, hasLength(1));

      // Unless the user asks for a fresh arrangement.
      await second.refresh(force: true);
      expect(organizer.calls, 2);
    });

    test('launching with a stored library reads no folders at all', () async {
      final connections = await connectionsWith(['/Users/diegoimbert/Desktop']);
      final organizer = _FakeOrganizer();

      final first = LibraryController(
        connections: connections,
        store: store,
        scanner: _FakeScanner([_file('/a.pdf')]),
        organizer: organizer,
      );
      addTearDown(first.dispose);
      await first.start();
      expect(first.entries, hasLength(1));

      // The next launch: what was stored is what shows, and the disk is left
      // alone until the user asks.
      final scanner = _FakeScanner([_file('/a.pdf'), _file('/b.pdf')]);
      final relaunched = LibraryController(
        connections: connections,
        store: store,
        scanner: scanner,
        organizer: organizer,
      );
      addTearDown(relaunched.dispose);
      await relaunched.start();

      expect(scanner.calls, isEmpty);
      expect(organizer.calls, 1);
      expect(relaunched.stage, LibraryStage.ready);
      expect(relaunched.entries, hasLength(1));

      // Rescan is what picks the new file up.
      await relaunched.refresh();
      expect(scanner.calls, hasLength(1));
      expect(relaunched.entries, hasLength(2));
    });

    test('launching without one scans', () async {
      final scanner = _FakeScanner([_file('/a.pdf')]);
      final library = LibraryController(
        connections: await connectionsWith(['/Users/diegoimbert/Desktop']),
        store: store,
        scanner: scanner,
        organizer: _FakeOrganizer(),
      );
      addTearDown(library.dispose);

      await library.start();

      expect(scanner.calls, hasLength(1));
      expect(library.entries, hasLength(1));
    });

    test('a changed scan is organized again', () async {
      final connections = await connectionsWith(['/Users/diegoimbert/Desktop']);
      final organizer = _FakeOrganizer();

      final library = LibraryController(
        connections: connections,
        store: store,
        scanner: _FakeScanner([_file('/a.pdf')]),
        organizer: organizer,
      );
      addTearDown(library.dispose);
      await library.refresh();

      final withMore = LibraryController(
        connections: connections,
        store: store,
        scanner: _FakeScanner([_file('/a.pdf'), _file('/b.pdf')]),
        organizer: organizer,
      );
      addTearDown(withMore.dispose);
      await withMore.load();
      await withMore.refresh();

      expect(organizer.calls, 2);
      expect(withMore.entries, hasLength(2));
    });

    test(
      'a failed organize keeps the scan and the library from before',
      () async {
        final connections = await connectionsWith([
          '/Users/diegoimbert/Desktop',
        ]);

        final first = LibraryController(
          connections: connections,
          store: store,
          scanner: _FakeScanner([_file('/a.pdf')]),
          organizer: _FakeOrganizer(),
        );
        addTearDown(first.dispose);
        await first.refresh();

        final failing = LibraryController(
          connections: connections,
          store: store,
          scanner: _FakeScanner([_file('/a.pdf'), _file('/b.pdf')]),
          organizer: _FakeOrganizer(
            failure: 'DeepSeek is unavailable right now.',
          ),
        );
        addTearDown(failing.dispose);
        await failing.load();
        await failing.refresh();

        expect(failing.stage, LibraryStage.failed);
        expect(failing.error, 'DeepSeek is unavailable right now.');
        // The old arrangement is still worth showing.
        expect(failing.entries, hasLength(1));
        // And the new scan was still written.
        expect(await store.readScan(), hasLength(2));
      },
    );

    test('a source with no folders configured is left alone', () async {
      final scanner = _FakeScanner([_file('/a.pdf')]);
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: await connectionsWith(const []),
        store: store,
        scanner: scanner,
        organizer: organizer,
      );
      addTearDown(library.dispose);

      expect(library.hasScannableFolders, isFalse);
      await library.refresh();

      // Scanning a whole disk is not what an unset scope means here.
      expect(scanner.calls, isEmpty);
      expect(organizer.calls, 0);
      expect(library.stage, LibraryStage.ready);
      expect(library.entries, isEmpty);
    });
  });
}
