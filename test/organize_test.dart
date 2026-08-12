import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/organize/drive_organizer.dart';
import 'package:overlay_app/organize/file_system_organizer.dart';
import 'package:overlay_app/organize/organize_plan.dart';
import 'package:overlay_app/organize/source_organizer.dart';
import 'package:overlay_app/pages/files_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/sources/google_drive_api.dart';
import 'package:overlay_app/theme.dart';
import 'package:overlay_app/widgets/tree_viewer.dart';

LibraryEntry _filed(String path, String organized, {String? source, String? id}) =>
    LibraryEntry(
      file: ScannedFile(
        path: path,
        sourceName: source ?? 'File System',
        modified: DateTime(2026, 8, 1),
        externalId: id,
      ),
      organizedPath: organized,
    );

void main() {
  group('what is out of place', () {
    test('a file already where the library says is left alone', () {
      final plan = planFor(
        sourceName: 'File System',
        entries: [
          _filed(
            '/Users/d/Documents/Finance/Taxes/2026/Tax return.pdf',
            'Finance/Taxes/2026/Tax return.pdf',
          ),
        ],
        roots: ['/Users/d/Documents'],
      );

      expect(plan.isTidy, isTrue);
      expect(plan.inPlace, 1);
    });

    test('a file that is not is a move, said in relative terms', () {
      final plan = planFor(
        sourceName: 'File System',
        entries: [
          _filed(
            '/Users/d/Documents/Downloads/xc_2026_tax.pdf',
            'Finance/Taxes/2026/Tax return 2026.pdf',
          ),
        ],
        roots: ['/Users/d/Documents/'],
      );

      final move = plan.moves.single;
      expect(move.root, '/Users/d/Documents');
      expect(move.from, 'Downloads/xc_2026_tax.pdf');
      expect(move.to, 'Finance/Taxes/2026/Tax return 2026.pdf');
      expect(plan.inPlace, 0);
    });

    test('the innermost configured folder is the one it is measured from', () {
      final plan = planFor(
        sourceName: 'File System',
        entries: [_filed('/Users/d/Docs/Work/note.txt', 'Career/Note.txt')],
        roots: ['/Users/d', '/Users/d/Docs'],
      );

      expect(plan.moves.single.root, '/Users/d/Docs');
      expect(plan.moves.single.from, 'Work/note.txt');
    });

    test('a source taken whole is measured from its own top', () {
      final plan = planFor(
        sourceName: 'Google Drive',
        entries: [
          _filed('/Work/notes.txt', 'Career/Notes.txt', source: 'Google Drive', id: 'd1'),
        ],
        roots: const [],
      );

      expect(plan.moves.single.root, '');
      expect(plan.moves.single.from, 'Work/notes.txt');
    });

    test('other sources are not this plan\'s business', () {
      final plan = planFor(
        sourceName: 'File System',
        entries: [
          _filed('/Work/notes.txt', 'Career/Notes.txt', source: 'Google Drive', id: 'd1'),
        ],
        roots: const [],
      );

      expect(plan.total, 0);
    });
  });

  group('moving a file on this Mac', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('kandoo-organize');
      addTearDown(() => home.delete(recursive: true));
    });

    test('it is renamed into folders that are made on the way', () async {
      final file = File('${home.path}/xc_2026_tax.pdf');
      await file.writeAsString('a tax return');

      final landed = await const FileSystemOrganizer().move(
        ScannedFile(path: file.path, sourceName: 'File System'),
        root: home.path,
        relative: 'Finance/Taxes/2026/Tax return 2026.pdf',
      );

      expect(landed.relative, 'Finance/Taxes/2026/Tax return 2026.pdf');
      expect(landed.file.path, '${home.path}/Finance/Taxes/2026/Tax return 2026.pdf');
      expect(await File(landed.file.path).readAsString(), 'a tax return');
      expect(await file.exists(), isFalse);
    });

    test('nothing is ever overwritten, and the library is told where it went', () async {
      await Directory('${home.path}/Finance').create(recursive: true);
      await File('${home.path}/Finance/Tax return.pdf').writeAsString('the first one');

      final second = File('${home.path}/other.pdf');
      await second.writeAsString('the second one');

      final landed = await const FileSystemOrganizer().move(
        ScannedFile(path: second.path, sourceName: 'File System'),
        root: home.path,
        relative: 'Finance/Tax return.pdf',
      );

      expect(landed.relative, 'Finance/Tax return (2).pdf');
      expect(
        await File('${home.path}/Finance/Tax return.pdf').readAsString(),
        'the first one',
      );
      expect(await File(landed.file.path).readAsString(), 'the second one');
    });

    test('a file that has gone says so rather than failing quietly', () {
      expect(
        () => const FileSystemOrganizer().move(
          ScannedFile(path: '${home.path}/gone.pdf', sourceName: 'File System'),
          root: home.path,
          relative: 'Finance/Gone.pdf',
        ),
        throwsA(
          isA<OrganizeFailure>().having(
            (error) => error.message,
            'message',
            contains('no longer'),
          ),
        ),
      );
    });

    test('a folder it cannot make says why, rather than just that', () async {
      // A file where a folder has to go: the commonest way a move fails that
      // is nothing to do with permissions.
      await File('${home.path}/Finance').writeAsString('not a folder');
      final file = File('${home.path}/tax.pdf');
      await file.writeAsString('a tax return');

      await expectLater(
        const FileSystemOrganizer().move(
          ScannedFile(path: file.path, sourceName: 'File System'),
          root: home.path,
          relative: 'Finance/Tax return.pdf',
        ),
        throwsA(
          isA<OrganizeFailure>().having(
            (error) => error.message,
            'message',
            allOf(contains('Finance'), contains('already in the way')),
          ),
        ),
      );

      // And the file it could not file is still where it was.
      expect(await file.exists(), isTrue);
    });

    test('a file outside every configured folder is not moved', () {
      expect(
        () => const FileSystemOrganizer().move(
          const ScannedFile(path: '/tmp/loose.pdf', sourceName: 'File System'),
          root: '',
          relative: 'Finance/Loose.pdf',
        ),
        throwsA(isA<OrganizeFailure>()),
      );
    });
  });

  group('moving a file in a drive', () {
    test('the folders are made, then the file is re-parented and renamed', () async {
      final made = <String>[];
      Map<String, dynamic>? patched;
      Uri? patchedUrl;

      final client = MockClient((request) async {
        final body = request.body.isEmpty
            ? const <String, dynamic>{}
            : (jsonDecode(request.body) as Map).cast<String, dynamic>();

        switch (request.method) {
          case 'POST':
            made.add(body['name'] as String);
            return _json({'id': 'folder-${made.length}'});

          case 'PATCH':
            patched = body;
            patchedUrl = request.url;
            return _json({'id': 'file-1'});

          default:
            // The item being moved, then the folder lookups, which find
            // nothing until they are created.
            if (request.url.path.endsWith('/file-1')) {
              return _json({
                'id': 'file-1',
                'name': 'xc_2026_tax.pdf',
                'mimeType': 'application/pdf',
                'parents': ['inbox'],
              });
            }
            return _json({'files': <dynamic>[]});
        }
      });

      final landed = await GoogleDriveOrganizer(
        api: () async => GoogleDriveApi(accessToken: 'token', client: client),
      ).move(
        const ScannedFile(
          path: '/Inbox/xc_2026_tax.pdf',
          sourceName: 'Google Drive',
          externalId: 'file-1',
        ),
        root: '',
        relative: 'Finance/Taxes/Tax return 2026.pdf',
      );

      expect(made, ['Finance', 'Taxes']);
      expect(patched, {'name': 'Tax return 2026.pdf'});
      expect(patchedUrl!.queryParameters['addParents'], 'folder-2');
      expect(patchedUrl!.queryParameters['removeParents'], 'inbox');
      expect(landed.relative, 'Finance/Taxes/Tax return 2026.pdf');
      expect(landed.file.path, '/Finance/Taxes/Tax return 2026.pdf');
      expect(landed.file.externalId, 'file-1');
    });

    test('a drive that is no longer connected says so', () {
      expect(
        () => GoogleDriveOrganizer(api: () async => null).move(
          const ScannedFile(
            path: '/Inbox/x.pdf',
            sourceName: 'Google Drive',
            externalId: 'file-1',
          ),
          root: '',
          relative: 'Finance/X.pdf',
        ),
        throwsA(
          isA<OrganizeFailure>().having(
            (error) => error.message,
            'message',
            contains('not connected'),
          ),
        ),
      );
    });
  });

  group('carrying out a plan', () {
    test('what worked and what did not are both reported', () async {
      final organizer = _FakeOrganizer(refuses: {'stuck.pdf'});
      final plan = planFor(
        sourceName: 'File System',
        entries: [
          _filed('/root/a.pdf', 'Self/Finance/Tax.pdf'),
          _filed('/root/stuck.pdf', 'Self/Finance/Stuck.pdf'),
        ],
        roots: ['/root'],
      );

      final progress = <int>[];
      final outcome = await applyMoves(
        plan.moves,
        organizers: SourceOrganizers([organizer]),
        onProgress: (done, total) => progress.add(done),
      );

      expect(outcome.moved.keys, ['/root/a.pdf']);
      expect(outcome.moved['/root/a.pdf']!.organizedPath, 'Self/Finance/Tax.pdf');
      expect(outcome.failures.values.single, contains('would not budge'));
      expect(outcome.isClean, isFalse);
      expect(progress, [1, 2]);
    });

    test('a source with no organizer is said to be beyond us', () async {
      final plan = planFor(
        sourceName: 'Notion',
        entries: [
          _filed('/Projects/Todo', 'Career/Todo', source: 'Notion', id: 'p1'),
        ],
        roots: const [],
      );

      final outcome = await applyMoves(
        plan.moves,
        organizers: const SourceOrganizers([]),
      );

      expect(outcome.moved, isEmpty);
      expect(outcome.failures.values.single, contains('cannot move'));
    });
  });

  group('the library after a move', () {
    test('it points at where the file is now', () async {
      final connections = ConnectionsController(store: _MemoryCredentials());
      await connections.load();

      final library = LibraryController(
        connections: connections,
        store: const _MemoryLibrary(),
      );
      addTearDown(library.dispose);
      await library.load();

      await library.filesMoved({
        '/root/xc_2026_tax.pdf': _filed(
          '/root/Finance/Taxes/Tax return 2026.pdf',
          'Finance/Taxes/Tax return 2026.pdf',
        ),
      });

      final entry = library.entries.single;
      expect(entry.file.path, '/root/Finance/Taxes/Tax return 2026.pdf');
      expect(entry.organizedPath, 'Finance/Taxes/Tax return 2026.pdf');
      // The tree that the section draws follows it.
      expect(await library.tree.childrenOf(null), hasLength(1));
    });
  });

  group('Auto-organize, in the sheet', () {
    testWidgets('it counts what is out of place, and puts it right', (
      tester,
    ) async {
      final organizer = _FakeOrganizer();
      final library = await _pumpFilesOver(tester, organizer);

      await tester.tap(find.byTooltip('File System'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 files not organized'), findsOneWidget);

      await tester.tap(find.text('Fix'));
      await tester.pumpAndSettle();

      // Every change is shown before any of them is made.
      expect(find.text('Move 2 files into place'), findsOneWidget);
      expect(find.text('Downloads/xc_2026_tax.pdf'), findsOneWidget);
      expect(find.text('Finance/Taxes/2026/Tax return 2026.pdf'), findsOneWidget);
      expect(organizer.moved, isEmpty);

      await tester.tap(find.text('Move 2 files'));
      await tester.pumpAndSettle();

      expect(organizer.moved, hasLength(2));
      expect(
        library.entries.map((entry) => entry.file.path),
        containsAll([
          '/root/Finance/Taxes/2026/Tax return 2026.pdf',
          '/root/Career/Notes.txt',
        ]),
      );

      // And the sheet now says so.
      expect(find.text('Every file is where your library says it is.'),
          findsOneWidget);
    });

    testWidgets('backing out of the preview moves nothing', (tester) async {
      final organizer = _FakeOrganizer();
      await _pumpFilesOver(tester, organizer);

      await tester.tap(find.byTooltip('File System'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(organizer.moved, isEmpty);
      expect(find.textContaining('2 files not organized'), findsOneWidget);
    });

    testWidgets('a tidy source has nothing to fix', (tester) async {
      await _pumpFilesOver(
        tester,
        _FakeOrganizer(),
        entries: [_filed('/root/Career/Notes.txt', 'Career/Notes.txt')],
      );

      await tester.tap(find.byTooltip('File System'));
      await tester.pumpAndSettle();

      expect(find.text('Every file is where your library says it is.'),
          findsOneWidget);
      expect(find.text('Fix'), findsNothing);
    });
  });
}

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// An organizer with no disk behind it, which files things exactly where it is
/// asked to unless the test said otherwise.
class _FakeOrganizer extends SourceOrganizer {
  _FakeOrganizer({this.refuses = const {}});

  /// File names this will not move, and the failure the user then sees.
  final Set<String> refuses;

  final List<String> moved = [];

  @override
  String get sourceName => 'File System';

  @override
  bool canMove(ScannedFile file) => file.externalId == null;

  @override
  Future<Relocation> move(
    ScannedFile file, {
    required String root,
    required String relative,
  }) async {
    if (refuses.contains(file.name)) {
      throw OrganizeFailure('${file.name} would not budge.');
    }

    moved.add(relative);
    return (
      file: ScannedFile(
        path: '$root/$relative',
        sourceName: file.sourceName,
        modified: file.modified,
      ),
      relative: relative,
    );
  }
}

class _MemoryCredentials extends CredentialStore {
  _MemoryCredentials({this.folders = const {}});

  final Map<String, List<String>> folders;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => const {};

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;
}

class _MemoryLibrary extends LibraryStore {
  const _MemoryLibrary([this.entries]);

  final List<LibraryEntry>? entries;

  @override
  Future<LibrarySnapshot?> readLibrary() async => LibrarySnapshot(
    entries:
        entries ??
        [
          _filed('/root/xc_2026_tax.pdf', 'Finance/Taxes/Tax return 2026.pdf'),
        ],
    fingerprint: 'test',
    organizedAt: DateTime(2026, 8, 12),
  );

  @override
  Future<void> writeLibrary(LibrarySnapshot snapshot) async {}

  @override
  Future<void> writeScan(List<ScannedFile> files, {DateTime? scannedAt}) async {}
}

/// The Files section over a library that is partly out of place.
Future<LibraryController> _pumpFilesOver(
  WidgetTester tester,
  SourceOrganizer organizer, {
  List<LibraryEntry>? entries,
}) async {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final connections = ConnectionsController(
    store: _MemoryCredentials(
      folders: {
        'file_system': ['/root'],
      },
    ),
  );
  await connections.load();

  final library = LibraryController(
    connections: connections,
    store: _MemoryLibrary(
      entries ??
          [
            _filed(
              '/root/Downloads/xc_2026_tax.pdf',
              'Finance/Taxes/2026/Tax return 2026.pdf',
            ),
            _filed('/root/notes.txt', 'Career/Notes.txt'),
          ],
    ),
  );
  addTearDown(library.dispose);
  await library.load();

  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: FilesPage(
          connections: connections,
          library: library,
          onOpenSources: () {},
          organizers: SourceOrganizers([organizer]),
          openUrl: (url) async => true,
          treeLoader: (source, root, connections) => (parent) async => [
            TreeEntry(id: '$root/notes.txt', label: 'notes.txt'),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return library;
}
