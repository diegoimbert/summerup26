import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overlay_app/library/drive_scanner.dart';
import 'package:overlay_app/library/file_scanner.dart';
import 'package:overlay_app/library/file_watcher.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/library/library_tree.dart';
import 'package:overlay_app/library/notion_scanner.dart';
import 'package:overlay_app/library/organizer.dart';
import 'package:overlay_app/library/source_scanner.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/sources/google_drive_api.dart';
import 'package:overlay_app/sources/notion_api.dart';

/// Keeps folder scope in memory, so the tests never touch Application Support.
class _MemoryStore extends CredentialStore {
  _MemoryStore({this.folders = const {}, this.connections = const {}});

  final Map<String, List<String>> folders;
  final Map<String, SourceCredentials> connections;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => connections;

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;
}

/// A scan with no disk behind it.
class _FakeScanner extends SourceScanner implements PollableScanner {
  _FakeScanner(this.files);

  List<ScannedFile> files;
  final List<List<String>> calls = [];

  /// What the source says when asked whether anything has happened.
  bool changed = false;

  /// The watermarks it was asked about, so a test can tell a cheap question
  /// from a full listing.
  final List<DateTime?> asked = [];

  @override
  Future<bool> hasChangesSince(DateTime? watermark) async {
    asked.add(watermark);
    return changed;
  }

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

  /// The structure it was last asked to file into.
  Set<String> knownFolders = const {};

  @override
  Future<List<String>> organize(
    List<ScannedFile> files, {
    Set<String> existingFolders = const {},
    void Function(int organized, int total)? onProgress,
  }) async {
    calls += 1;
    knownFolders = existingFolders;
    if (failure != null) throw OrganizerException(failure!);
    onProgress?.call(files.length, files.length);
    return [for (final file in files) 'Self/Finance/${file.name}'];
  }
}

/// A watcher with no disk behind it: the test says what changed.
class _FakeWatcher implements SourceWatcher {
  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();

  List<String> roots = const [];
  bool stopped = false;

  @override
  Stream<Set<String>> watch(List<String> roots) {
    this.roots = roots;
    stopped = false;
    return _changes.stream;
  }

  /// Reports a batch and waits for it to be dealt with.
  ///
  /// Working out what a change means involves real reads, so this waits on the
  /// clock. Where there is something to wait *for*, [until] says so, which
  /// keeps a slow machine from being mistaken for a broken one.
  Future<void> report(Set<String> paths, {bool Function()? until}) async {
    _changes.add(paths);

    for (var wait = 0; wait < 120; wait += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (until == null) {
        if (wait >= 3) return;
      } else if (until()) {
        return;
      }
    }
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}

/// Hands every source the same scanner, which is all a controller test needs.
SourceScannerFactory _only(SourceScanner scanner) =>
    (source) async => scanner;

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

  group('GoogleDriveScanner', () {
    /// A drive held in memory: folder id to the rows Drive would return.
    MockClient driveOf(
      Map<String, List<Map<String, dynamic>>> folders, {
      List<Uri>? seen,
    }) {
      return MockClient((request) async {
        seen?.add(request.url);
        final query = request.url.queryParameters['q']!;
        final parent = RegExp(r"'([^']+)' in parents").firstMatch(query)![1]!;
        var rows = folders[parent] ?? const <Map<String, dynamic>>[];

        // Resolving a folder by name asks for one named child.
        final named = RegExp(r"name = '([^']+)'").firstMatch(query);
        if (named != null) {
          rows = rows
              .where((row) => row['name'] == named[1])
              .toList(growable: false);
        }

        return http.Response(jsonEncode({'files': rows}), 200);
      });
    }

    Map<String, dynamic> folder(String id, String name) => {
      'id': id,
      'name': name,
      'mimeType': GoogleDriveApi.folderMimeType,
    };

    Map<String, dynamic> doc(String id, String name, String modified) => {
      'id': id,
      'name': name,
      'mimeType': 'application/pdf',
      'modifiedTime': modified,
    };

    test('walks the whole drive when no folder was chosen', () async {
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [
              folder('f1', 'Work'),
              doc('d1', 'Passport.pdf', '2026-06-01T10:00:00.000Z'),
            ],
            'f1': [doc('d2', 'Pitch deck.pdf', '2026-05-11T09:00:00.000Z')],
          }),
        ),
      );

      final result = await scanner.scan(
        roots: const [],
        sourceName: 'Google Drive',
      );

      expect(result.files.map((file) => file.path), [
        '/Passport.pdf',
        '/Work/Pitch deck.pdf',
      ]);
      // Drive's id is what identifies the file, since names repeat.
      expect(result.files.first.externalId, 'd1');
      expect(result.files.first.sourceName, 'Google Drive');
      expect(result.files.last.modified, DateTime.utc(2026, 5, 11, 9));
      expect(result.warnings, isEmpty);
    });

    test('a chosen folder is resolved by name and scanned alone', () async {
      final seen = <Uri>[];
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [folder('f1', 'Work'), folder('f2', 'Personal')],
            'f1': [folder('f3', 'Invoices')],
            'f3': [doc('d1', 'March.pdf', '2026-03-01T10:00:00.000Z')],
            'f2': [
              doc(
                'd2',
                'Nothing to do with it.pdf',
                '2026-03-01T10:00:00.000Z',
              ),
            ],
          }, seen: seen),
        ),
      );

      final result = await scanner.scan(
        roots: const ['/Work/Invoices'],
        sourceName: 'Google Drive',
      );

      expect(result.files.map((file) => file.path), [
        '/Work/Invoices/March.pdf',
      ]);
      // The other branch of the drive is never listed.
      expect(
        seen.map((url) => url.queryParameters['q']!).join(),
        isNot(contains("'f2'")),
      );
    });

    test('a folder that is gone is a warning, not a failure', () async {
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [folder('f1', 'Work')],
            'f1': [doc('d1', 'Deck.pdf', '2026-03-01T10:00:00.000Z')],
          }),
        ),
      );

      final result = await scanner.scan(
        roots: const ['/Work', '/Gone'],
        sourceName: 'Google Drive',
      );

      expect(result.files, hasLength(1));
      expect(result.warnings, ['No Google Drive folder at /Gone']);
    });

    test('a folder is read a page at a time', () async {
      var calls = 0;
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: MockClient((request) async {
            calls += 1;
            final token = request.url.queryParameters['pageToken'];
            return http.Response(
              jsonEncode({
                'files': [
                  {
                    'id': 'd$calls',
                    'name': 'File $calls.pdf',
                    'mimeType': 'application/pdf',
                  },
                ],
                if (token == null) 'nextPageToken': 'page-2',
              }),
              200,
            );
          }),
        ),
      );

      final result = await scanner.scan(
        roots: const [],
        sourceName: 'Google Drive',
      );

      expect(calls, 2);
      expect(result.files.map((file) => file.name), [
        'File 1.pdf',
        'File 2.pdf',
      ]);
    });

    test('an expired connection says to reconnect', () async {
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'stale',
          client: MockClient((request) async => http.Response('nope', 401)),
        ),
      );

      await expectLater(
        scanner.scan(roots: const [], sourceName: 'Google Drive'),
        throwsA(
          isA<ScanException>().having(
            (error) => error.message,
            'message',
            'Google Drive needs connecting again from Sources.',
          ),
        ),
      );
    });

    test('the scan stops at its ceiling', () async {
      final scanner = GoogleDriveScanner(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [
              doc('d1', 'One.pdf', '2026-03-01T10:00:00.000Z'),
              doc('d2', 'Two.pdf', '2026-03-01T10:00:00.000Z'),
              doc('d3', 'Three.pdf', '2026-03-01T10:00:00.000Z'),
            ],
          }),
        ),
        maxFiles: 2,
      );

      final result = await scanner.scan(
        roots: const [],
        sourceName: 'Google Drive',
      );

      expect(result.files, hasLength(2));
      expect(result.truncated, isTrue);
    });
  });

  group('NotionScanner', () {
    /// One page as Notion's search returns it.
    Map<String, dynamic> page(
      String id,
      String title, {
      String? parent,
      String parentType = 'page_id',
      String edited = '2026-07-02T10:00:00.000Z',
      bool archived = false,
    }) => {
      'object': 'page',
      'id': id,
      'archived': archived,
      'last_edited_time': edited,
      'parent': parent == null
          ? {'type': 'workspace', 'workspace': true}
          : {'type': parentType, parentType: parent},
      'properties': {
        'Name': {
          'type': 'title',
          'title': [
            {'plain_text': title},
          ],
        },
      },
    };

    Map<String, dynamic> database(String id, String title, {String? parent}) =>
        {
          'object': 'database',
          'id': id,
          'last_edited_time': '2026-07-02T10:00:00.000Z',
          'parent': parent == null
              ? {'type': 'workspace', 'workspace': true}
              : {'type': 'page_id', 'page_id': parent},
          'title': [
            {'plain_text': title},
          ],
        };

    /// A workspace that answers search with [pages], in as many pages of
    /// results as [perRequest] requires.
    MockClient workspaceOf(
      List<Map<String, dynamic>> results, {
      int perRequest = 100,
      List<http.Request>? seen,
    }) {
      return MockClient((request) async {
        seen?.add(request);
        final cursor = (jsonDecode(request.body) as Map)['start_cursor'];
        final start = cursor == null ? 0 : int.parse(cursor as String);
        final end = (start + perRequest).clamp(0, results.length);

        return http.Response(
          jsonEncode({
            'results': results.sublist(start, end),
            'has_more': end < results.length,
            'next_cursor': end < results.length ? '$end' : null,
          }),
          200,
        );
      });
    }

    test('a page is filed under the pages it lives in', () async {
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'token',
          client: workspaceOf([
            page('p1', 'Projects'),
            page('p2', 'Q3', parent: 'p1'),
            page('p3', 'Kick-off notes', parent: 'p2'),
          ]),
        ),
      );

      final result = await scanner.scan(roots: const [], sourceName: 'Notion');

      expect(result.files.map((file) => file.path), [
        '/Projects',
        '/Projects/Q3',
        '/Projects/Q3/Kick-off notes',
      ]);
      expect(result.files.last.externalId, 'p3');
      expect(result.files.last.sourceName, 'Notion');
      expect(result.files.first.modified, DateTime.utc(2026, 7, 2, 10));
    });

    test(
      'a database gives its pages a path without being filed itself',
      () async {
        final scanner = NotionScanner(
          api: NotionApi(
            accessToken: 'token',
            client: workspaceOf([
              database('d1', 'Reading list'),
              page(
                'p1',
                'Designing Data-Intensive Applications',
                parent: 'd1',
                parentType: 'database_id',
              ),
            ]),
          ),
        );

        final result = await scanner.scan(
          roots: const [],
          sourceName: 'Notion',
        );

        expect(result.files.map((file) => file.path), [
          '/Reading list/Designing Data-Intensive Applications',
        ]);
      },
    );

    test(
      'a page whose parent was not shared sits as high as Kandoo can see',
      () async {
        final scanner = NotionScanner(
          api: NotionApi(
            accessToken: 'token',
            client: workspaceOf([page('p1', 'Loose note', parent: 'unshared')]),
          ),
        );

        final result = await scanner.scan(
          roots: const [],
          sourceName: 'Notion',
        );

        expect(result.files.single.path, '/Loose note');
      },
    );

    test('archived pages and untitled ones are handled', () async {
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'token',
          client: workspaceOf([
            page('p1', 'Gone', archived: true),
            page('p2', ''),
            // A title with a slash would otherwise read as folders.
            page('p3', 'Notes / drafts'),
          ]),
        ),
      );

      final result = await scanner.scan(roots: const [], sourceName: 'Notion');

      expect(result.files.map((file) => file.path), [
        '/Untitled',
        '/Notes ∕ drafts',
      ]);
    });

    test('a long workspace is read a page of results at a time', () async {
      final seen = <http.Request>[];
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'token',
          client: workspaceOf(
            [
              for (var index = 0; index < 5; index += 1)
                page('p$index', 'Page $index'),
            ],
            perRequest: 2,
            seen: seen,
          ),
        ),
      );

      final result = await scanner.scan(roots: const [], sourceName: 'Notion');

      expect(result.files, hasLength(5));
      expect(seen, hasLength(3));
      expect(seen.first.headers['Notion-Version'], isNotEmpty);
      expect(seen.first.headers['Authorization'], 'Bearer token');
    });

    test('a rate limit is waited out rather than failed on', () async {
      var calls = 0;
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'token',
          client: MockClient((request) async {
            calls += 1;
            if (calls == 1) {
              return http.Response(
                'slow down',
                429,
                headers: {'retry-after': '0'},
              );
            }
            return http.Response(
              jsonEncode({
                'results': [page('p1', 'Survived')],
                'has_more': false,
              }),
              200,
            );
          }),
        ),
      );

      final result = await scanner.scan(roots: const [], sourceName: 'Notion');

      expect(calls, 2);
      expect(result.files.single.path, '/Survived');
    });

    test('an expired connection says to reconnect', () async {
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'stale',
          client: MockClient((request) async => http.Response('nope', 401)),
        ),
      );

      await expectLater(
        scanner.scan(roots: const [], sourceName: 'Notion'),
        throwsA(
          isA<ScanException>().having(
            (error) => error.message,
            'message',
            'Notion needs connecting again from Sources.',
          ),
        ),
      );
    });

    test('the scan stops at its ceiling', () async {
      final scanner = NotionScanner(
        api: NotionApi(
          accessToken: 'token',
          client: workspaceOf([
            page('p1', 'One'),
            page('p2', 'Two'),
            page('p3', 'Three'),
          ]),
        ),
        maxFiles: 2,
      );

      final result = await scanner.scan(roots: const [], sourceName: 'Notion');

      expect(result.files, hasLength(2));
      expect(result.truncated, isTrue);
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

  group('FileSystemWatcher', () {
    late Directory folder;
    late FileSystemWatcher watcher;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('kandoo_fsw_');
      watcher = FileSystemWatcher(settle: const Duration(milliseconds: 60));
    });

    tearDown(() async {
      await watcher.dispose();
      await folder.delete(recursive: true);
    });

    /// Waits for the folders to be reported as changed, or gives up.
    Future<Set<String>> awaited(List<Set<String>> batches) async {
      for (var wait = 0; wait < 100; wait += 1) {
        if (batches.isNotEmpty) {
          // Let any straggling events join this batch.
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return batches.expand((batch) => batch).toSet();
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return const {};
    }

    test('a change under a watched folder is reported', () async {
      final batches = <Set<String>>[];
      final subscription = watcher.watch([folder.path]).listen(batches.add);
      addTearDown(subscription.cancel);
      // The watch takes a moment to arm.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final file = File('${folder.path}/note.md');
      await file.writeAsString('hello');

      // macOS names the file or the folder it is in, depending on its mood.
      // Either is enough to know where to look again.
      final reported = await awaited(batches);
      expect(reported, isNotEmpty);
      expect(
        reported.every(
          (path) => path == folder.path || path.startsWith('${folder.path}/'),
        ),
        isTrue,
      );
    });

    test('a burst arrives as one batch, not one each', () async {
      final batches = <Set<String>>[];
      final subscription = watcher.watch([folder.path]).listen(batches.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      for (var index = 0; index < 5; index += 1) {
        await File('${folder.path}/file_$index.md').writeAsString('x');
      }

      expect(await awaited(batches), isNotEmpty);
      expect(
        batches.length,
        lessThan(5),
        reason: 'five files should not cost five rounds of filing',
      );
    });

    test('stopping ends the reports', () async {
      final batches = <Set<String>>[];
      final subscription = watcher.watch([folder.path]).listen(batches.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Anything still in flight from arming the watch is not what is being
      // tested here.
      batches.clear();

      await watcher.stop();
      await File('${folder.path}/after.md').writeAsString('hello');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(batches, isEmpty);
    });
  });

  group('watching for changes', () {
    late Directory folder;
    late Directory home;
    late LibraryStore store;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('kandoo_watch_');
      home = await Directory.systemTemp.createTemp('kandoo_watch_store_');
      store = LibraryStore(directory: home);
    });

    tearDown(() async {
      await folder.delete(recursive: true);
      await home.delete(recursive: true);
    });

    /// A library holding [paths], already filed, watching [folder].
    Future<(LibraryController, _FakeWatcher, _FakeOrganizer)> libraryOf(
      List<String> paths,
    ) async {
      final connections = ConnectionsController(
        store: _MemoryStore(
          folders: {
            'file_system': [folder.path],
          },
        ),
      );
      await connections.load();

      final watcher = _FakeWatcher();
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: connections,
        store: store,
        scanners: _only(_FakeScanner([for (final path in paths) _file(path)])),
        organizer: organizer,
        watcher: watcher,
      );
      addTearDown(library.dispose);

      await library.start();
      return (library, watcher, organizer);
    }

    test('the watch is pointed at the configured folders only', () async {
      final (library, watcher, _) = await libraryOf(['${folder.path}/a.pdf']);

      expect(watcher.roots, [folder.path]);
      expect(library.entries, hasLength(1));
    });

    test(
      'a file that has gone leaves the library, without a request',
      () async {
        final gone = '${folder.path}/gone.pdf';
        final (library, watcher, organizer) = await libraryOf([
          gone,
          '${folder.path}/stays.pdf',
        ]);
        final before = organizer.calls;
        final revision = library.revision;

        await watcher.report({gone}, until: () => library.entries.length == 1);

        expect(library.entries.map((entry) => entry.file.path), [
          '${folder.path}/stays.pdf',
        ]);
        expect(organizer.calls, before, reason: 'nothing to ask about');
        expect(library.revision, greaterThan(revision));
        // And the change outlives the app.
        expect((await store.readLibrary())!.entries, hasLength(1));
        expect(await store.readScan(), hasLength(1));
      },
    );

    test('a folder that has gone takes what was inside it', () async {
      final (library, watcher, _) = await libraryOf([
        '${folder.path}/Trip/flight.pdf',
        '${folder.path}/Trip/hotel.pdf',
        '${folder.path}/keep.pdf',
      ]);

      await watcher.report({
        '${folder.path}/Trip',
      }, until: () => library.entries.length == 1);

      expect(library.entries.map((entry) => entry.file.path), [
        '${folder.path}/keep.pdf',
      ]);
    });

    test('a folder event is reconciled against what it now holds', () async {
      final stays = File('${folder.path}/stays.pdf');
      final leaves = File('${folder.path}/leaves.pdf');
      await stays.writeAsString('x');
      await leaves.writeAsString('x');

      final (library, watcher, organizer) = await libraryOf([
        stays.path,
        leaves.path,
      ]);
      final before = organizer.calls;

      // What macOS actually reports: the folder, not the file.
      await leaves.delete();
      final arrival = File('${folder.path}/arrival.pdf');
      await arrival.writeAsString('x');
      await watcher.report({
        folder.path,
      }, until: () => organizer.calls == before + 1);

      expect(library.entries.map((entry) => entry.file.path), [
        stays.path,
        arrival.path,
      ]);
      expect(organizer.calls, before + 1, reason: 'one arrival to place');
    });

    test('a new file is filed into the structure that exists', () async {
      final (library, watcher, organizer) = await libraryOf([
        '${folder.path}/old.pdf',
      ]);

      final arrival = File('${folder.path}/new arrival.pdf');
      await arrival.writeAsString('hello');

      await watcher.report({arrival.path}, until: () => organizer.calls == 2);

      expect(organizer.calls, 2, reason: 'the scan, then this one file');
      // Asked to file into the library the user already knows.
      expect(organizer.knownFolders, contains('Self/Finance'));
      expect(
        library.entries.map((entry) => entry.file.path),
        contains(arrival.path),
      );
      expect(library.stage, LibraryStage.ready);
      expect((await store.readLibrary())!.entries, hasLength(2));
    });

    test('a file already in the library is left alone', () async {
      final known = File('${folder.path}/known.pdf');
      await known.writeAsString('hello');
      final (library, watcher, organizer) = await libraryOf([known.path]);
      final before = organizer.calls;

      // A save touches a file that is already filed.
      await watcher.report({known.path});

      expect(organizer.calls, before);
      expect(library.entries, hasLength(1));
    });

    test('changes outside the configured folders are ignored', () async {
      final outside = File('${home.path}/stranger.pdf');
      await outside.writeAsString('hello');
      final (library, watcher, organizer) = await libraryOf([
        '${folder.path}/a.pdf',
      ]);
      final before = organizer.calls;

      await watcher.report({outside.path});

      expect(organizer.calls, before);
      expect(library.entries, hasLength(1));
    });

    test('noise is passed over, as it is by the scan', () async {
      final hidden = File('${folder.path}/.DS_Store');
      await hidden.writeAsString('junk');
      final (library, watcher, organizer) = await libraryOf([
        '${folder.path}/a.pdf',
      ]);
      final before = organizer.calls;

      await watcher.report({hidden.path});

      expect(organizer.calls, before);
      expect(library.entries, hasLength(1));
    });

    test('a rename is a departure and an arrival', () async {
      final before = File('${folder.path}/IMG_4021.pdf');
      await before.writeAsString('hello');
      final (library, watcher, organizer) = await libraryOf([before.path]);

      final after = File('${folder.path}/Passport scan.pdf');
      await before.rename(after.path);

      await watcher.report({
        before.path,
        after.path,
      }, until: () => organizer.calls == 2);

      expect(library.entries.map((entry) => entry.file.path), [after.path]);
      expect(organizer.calls, 2);
    });

    test('a flood waits for a rescan rather than filing itself', () async {
      final (library, watcher, organizer) = await libraryOf([
        '${folder.path}/a.pdf',
      ]);
      final before = organizer.calls;

      final flood = <String>{};
      for (var index = 0; index < 120; index += 1) {
        final file = File('${folder.path}/copy_$index.pdf');
        await file.writeAsString('x');
        flood.add(file.path);
      }

      await watcher.report(flood, until: () => library.warnings.isNotEmpty);

      expect(organizer.calls, before, reason: 'a checkout is not a decision');
      expect(library.warnings.single, contains('120 new files'));
      expect(library.entries, hasLength(1));
    });
  });

  group('polling a source that cannot tell us anything', () {
    late Directory home;
    late LibraryStore store;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('kandoo_poll_');
      store = LibraryStore(directory: home);
    });

    tearDown(() => home.delete(recursive: true));

    ScannedFile page(String id, String path, {DateTime? edited}) => ScannedFile(
      path: path,
      sourceName: 'Notion',
      externalId: id,
      modified: edited ?? DateTime.utc(2026, 8, 10),
    );

    Future<(LibraryController, _FakeScanner, _FakeOrganizer)> workspaceOf(
      List<ScannedFile> pages,
    ) async {
      final connections = ConnectionsController(
        store: _MemoryStore(
          connections: {
            'notion': const SourceCredentials(
              sourceId: 'notion',
              accessToken: 'token',
            ),
          },
        ),
      );
      await connections.load();

      final scanner = _FakeScanner([...pages]);
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: connections,
        store: store,
        scanners: _only(scanner),
        organizer: organizer,
      );
      addTearDown(library.dispose);

      await library.start();
      return (library, scanner, organizer);
    }

    test('a quiet workspace costs one question and nothing else', () async {
      final (library, scanner, organizer) = await workspaceOf([
        page('p1', '/Projects/Todo'),
      ]);
      final scans = scanner.calls.length;
      final calls = organizer.calls;

      await library.pollSources();

      expect(scanner.asked, hasLength(1));
      // The watermark is what the scan already knew, so a launch does not start
      // by listing everything again.
      expect(scanner.asked.single, DateTime.utc(2026, 8, 10));
      expect(scanner.calls, hasLength(scans), reason: 'nothing to list');
      expect(organizer.calls, calls);
    });

    test('a renamed page is filed again under what it is now called', () async {
      final (library, scanner, organizer) = await workspaceOf([
        page('p1', '/Projects/Todo'),
        page('p2', '/Projects/Reading'),
      ]);
      final calls = organizer.calls;

      scanner
        ..changed = true
        ..files = [
          page('p1', '/Projects/Groceries', edited: DateTime.utc(2026, 8, 11)),
          page('p2', '/Projects/Reading'),
        ];
      await library.pollSources();

      expect(organizer.calls, calls + 1, reason: 'one page to file again');
      expect(library.entries, hasLength(2));
      expect(
        library.entries.map((entry) => entry.file.path),
        containsAll(['/Projects/Groceries', '/Projects/Reading']),
      );
      expect(
        library.entries
            .firstWhere((entry) => entry.file.externalId == 'p1')
            .title,
        'Groceries',
      );
      // And it was filed into the library that already exists rather than
      // beside it.
      expect(organizer.knownFolders, contains('Self/Finance'));
    });

    test('a new page is filed without disturbing the rest', () async {
      final (library, scanner, organizer) = await workspaceOf([
        page('p1', '/Projects/Todo'),
      ]);
      final calls = organizer.calls;

      scanner
        ..changed = true
        ..files = [
          page('p1', '/Projects/Todo'),
          page('p2', '/Projects/Shopping', edited: DateTime.utc(2026, 8, 11)),
        ];
      await library.pollSources();

      expect(organizer.calls, calls + 1);
      expect(library.entries.map((entry) => entry.file.externalId), [
        'p1',
        'p2',
      ]);
    });

    test('an edit that moves nothing costs no filing', () async {
      final (library, scanner, organizer) = await workspaceOf([
        page('p1', '/Projects/Todo'),
      ]);
      final calls = organizer.calls;

      scanner
        ..changed = true
        ..files = [
          page('p1', '/Projects/Todo', edited: DateTime.utc(2026, 8, 12)),
        ];
      await library.pollSources();

      expect(organizer.calls, calls, reason: 'it is where it was');
      // The date still follows, so the library does not go stale.
      expect(library.entries.single.file.modified, DateTime.utc(2026, 8, 12));
    });

    test('a deleted page is noticed by the sweep', () async {
      final (library, scanner, organizer) = await workspaceOf([
        page('p1', '/Projects/Todo'),
        page('p2', '/Projects/Shopping'),
      ]);
      final calls = organizer.calls;

      // Deleting leaves nothing behind to ask about, so the cheap question
      // keeps saying no.
      scanner.files = [page('p1', '/Projects/Todo')];
      for (var poll = 0; poll < 10; poll += 1) {
        await library.pollSources();
      }
      expect(library.entries, hasLength(2), reason: 'nothing has asked yet');

      // The eleventh lists the workspace rather than asking about it.
      await library.pollSources();

      expect(library.entries.map((entry) => entry.file.externalId), ['p1']);
      expect(organizer.calls, calls, reason: 'nothing to file, only to drop');
    });

    test('polling stays out of the way of a scan', () async {
      final (library, scanner, _) = await workspaceOf([
        page('p1', '/Projects/Todo'),
      ]);
      scanner.changed = true;

      final scanning = library.refresh(force: true);
      await library.pollSources();
      await scanning;

      expect(scanner.asked, isEmpty, reason: 'a scan sees everything anyway');
    });

    test('a workspace that has gone quiet stops being asked', () async {
      final connections = ConnectionsController(store: _MemoryStore());
      await connections.load();

      final library = LibraryController(
        connections: connections,
        store: store,
        scanners: _only(_FakeScanner(const [])),
        organizer: _FakeOrganizer(),
      );
      addTearDown(library.dispose);
      await library.start();

      // Nothing connected, so there is nothing to ask.
      await library.pollSources();
      expect(library.entries, isEmpty);
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
        scanners: _only(scanner),
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
        scanners: _only(scanner),
        organizer: organizer,
      );
      addTearDown(first.dispose);
      await first.refresh();
      expect(organizer.calls, 1);

      // A second run of the same app, reading what the first one left behind.
      final second = LibraryController(
        connections: connections,
        store: store,
        scanners: _only(scanner),
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
        scanners: _only(_FakeScanner([_file('/a.pdf')])),
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
        scanners: _only(scanner),
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
        scanners: _only(scanner),
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
        scanners: _only(_FakeScanner([_file('/a.pdf')])),
        organizer: organizer,
      );
      addTearDown(library.dispose);
      await library.refresh();

      final withMore = LibraryController(
        connections: connections,
        store: store,
        scanners: _only(_FakeScanner([_file('/a.pdf'), _file('/b.pdf')])),
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
          scanners: _only(_FakeScanner([_file('/a.pdf')])),
          organizer: _FakeOrganizer(),
        );
        addTearDown(first.dispose);
        await first.refresh();

        final failing = LibraryController(
          connections: connections,
          store: store,
          scanners: _only(_FakeScanner([_file('/a.pdf'), _file('/b.pdf')])),
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

    test('a connected Notion is scanned without waiting for folders', () async {
      final connections = ConnectionsController(
        store: _MemoryStore(
          connections: {
            'notion': const SourceCredentials(
              sourceId: 'notion',
              accessToken: 'token',
              accountLabel: 'Kandoo workspace',
            ),
          },
        ),
      );
      await connections.load();

      final asked = <String>[];
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: connections,
        store: store,
        scanners: (source) async {
          asked.add(source.id);
          return _FakeScanner([
            ScannedFile(
              path: '/Projects/Q3/Kick-off notes',
              sourceName: 'Notion',
              externalId: 'p3',
            ),
          ]);
        },
        organizer: organizer,
      );
      addTearDown(library.dispose);

      expect(library.canScan, isTrue);
      await library.refresh();

      // The file system has no folders, so it waits; Notion is scoped by what
      // was shared with the integration and does not.
      expect(asked, ['notion']);
      expect(library.entries.single.file.externalId, 'p3');
      expect(library.entries.single.file.sourceName, 'Notion');
    });

    test('a source with no folders configured is left alone', () async {
      final scanner = _FakeScanner([_file('/a.pdf')]);
      final organizer = _FakeOrganizer();
      final library = LibraryController(
        connections: await connectionsWith(const []),
        store: store,
        scanners: _only(scanner),
        organizer: organizer,
      );
      addTearDown(library.dispose);

      expect(library.canScan, isFalse);
      await library.refresh();

      // Scanning a whole disk is not what an unset scope means here.
      expect(scanner.calls, isEmpty);
      expect(organizer.calls, 0);
      expect(library.stage, LibraryStage.ready);
      expect(library.entries, isEmpty);
    });
  });
}
