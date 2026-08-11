import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overlay_app/sources/file_system_browser.dart';
import 'package:overlay_app/sources/google_drive_api.dart';
import 'package:overlay_app/sources/google_drive_browser.dart';
import 'package:overlay_app/theme.dart';
import 'package:overlay_app/widgets/tree_viewer.dart';

/// A tree held in memory, which records what the viewer asked for so the tests
/// can tell a fetch from a cache hit.
class _FakeTree {
  _FakeTree(this.children);

  /// Keyed by parent id; the null key is the top level.
  final Map<String?, List<TreeEntry>> children;

  final List<String?> calls = [];

  /// Ids that should fail the next time they are asked for.
  final Set<String?> failOnce = {};

  /// Ids whose load is left hanging until [release] is called.
  final Map<String?, Completer<void>> _held = {};

  void hold(String id) => _held[id] = Completer<void>();

  void release(String id) => _held.remove(id)?.complete();

  Future<List<TreeEntry>> load(TreeEntry? parent) async {
    calls.add(parent?.id);
    final held = _held[parent?.id];
    if (held != null) await held.future;
    if (failOnce.remove(parent?.id)) {
      throw const TreeLoadException(
        'Kandoo is not allowed to read this folder.',
      );
    }
    return children[parent?.id] ?? const [];
  }
}

Future<void> _pumpTree(WidgetTester tester, TreeChildrenLoader loader) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: TreeViewer(loadChildren: loader),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _docs = TreeEntry(id: '/docs', label: 'Docs', isFolder: true);

_FakeTree _sampleTree() => _FakeTree({
  null: const [_docs, TreeEntry(id: '/notes.md', label: 'notes.md')],
  '/docs': const [
    TreeEntry(id: '/docs/2025', label: '2025', isFolder: true),
    TreeEntry(id: '/docs/report.pdf', label: 'report.pdf'),
  ],
  '/docs/2025': const [TreeEntry(id: '/docs/2025/q1.md', label: 'q1.md')],
});

void main() {
  testWidgets('only the top level is loaded, and folders start collapsed', (
    tester,
  ) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    // Nothing below the top level has been asked for, let alone drawn.
    expect(find.text('report.pdf'), findsNothing);
    expect(tree.calls, [null]);
  });

  testWidgets('opening a folder loads it, and only once', (tester) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(tree.calls, [null, '/docs']);
    // The folder that just appeared is itself still closed.
    expect(find.text('q1.md'), findsNothing);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsNothing);

    // Reopening draws from what was already fetched.
    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsOneWidget);
    expect(tree.calls, [null, '/docs']);
  });

  testWidgets('folders nest as they are opened', (tester) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025'));
    await tester.pumpAndSettle();

    expect(find.text('q1.md'), findsOneWidget);
    expect(tree.calls, [null, '/docs', '/docs/2025']);
  });

  testWidgets('a folder that cannot be read says so, and retries on click', (
    tester,
  ) async {
    final tree = _sampleTree()..failOnce.add('/docs');
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();

    expect(
      find.text('Kandoo is not allowed to read this folder.'),
      findsOneWidget,
    );

    // Clicking the failed folder retries rather than collapsing it.
    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(tree.calls, [null, '/docs', '/docs']);
  });

  testWidgets('a folder grows into place rather than appearing', (
    tester,
  ) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    // What sits below the folder is pushed down as the folder grows, so its
    // position is the height of what has come out so far.
    double below() => tester.getTopLeft(find.text('notes.md')).dy;

    final closed = below();

    await tester.tap(find.text('Docs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final early = below();
    expect(early, greaterThan(closed), reason: 'it should have started moving');

    await tester.pump(const Duration(milliseconds: 60));
    final middle = below();
    expect(middle, greaterThan(early), reason: 'and kept moving');

    await tester.pumpAndSettle();
    expect(below(), greaterThan(middle));
    // Two rows came out, so that is how far everything below moved.
    expect(below() - closed, closeTo(72, 0.5));
  });

  testWidgets('a folder shrinks before its rows leave', (tester) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.tap(find.text('Docs'));
    await tester.pump(const Duration(milliseconds: 40));
    // Still there, on its way out.
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsNothing);
  });

  testWidgets('a folder being read says so on its own row', (tester) async {
    final tree = _sampleTree()..hold('/docs');
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pump();

    // The spinner sits on the folder, so what arrives can grow into place.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('report.pdf'), findsNothing);

    tree.release('/docs');
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('report.pdf'), findsOneWidget);
  });

  testWidgets('an empty folder is called out', (tester) async {
    final tree = _FakeTree({
      null: const [_docs],
      '/docs': const [],
    });
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();

    expect(find.text('This folder is empty'), findsOneWidget);
  });

  testWidgets('a tapped file stays put', (tester) async {
    final tree = _sampleTree();
    await _pumpTree(tester, tree.load);

    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();

    expect(tree.calls, [null]);
  });

  group('FileSystemBrowser', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kandoo_tree_');
      await Directory('${root.path}/Zebra').create();
      await Directory('${root.path}/apples').create();
      await File('${root.path}/notes.md').writeAsString('hi');
      await File('${root.path}/.hidden').writeAsString('secret');
      await File('${root.path}/apples/one.txt').writeAsString('1');
    });

    tearDown(() => root.delete(recursive: true));

    test('lists folders first, then files, and hides dotfiles', () async {
      final browser = FileSystemBrowser(rootPath: root.path);
      final entries = await browser.children(null);

      expect(entries.map((entry) => entry.label), [
        'apples',
        'Zebra',
        'notes.md',
      ]);
      expect(entries.map((entry) => entry.isFolder), [true, true, false]);
    });

    test('reads a subfolder only when asked for it', () async {
      final browser = FileSystemBrowser(rootPath: root.path);
      final entries = await browser.children(
        TreeEntry(id: '${root.path}/apples', label: 'apples', isFolder: true),
      );

      expect(entries.single.label, 'one.txt');
      expect(entries.single.isFolder, isFalse);
    });

    test('a missing folder fails with a readable message', () async {
      final browser = FileSystemBrowser(rootPath: '${root.path}/gone');

      expect(
        () => browser.children(null),
        throwsA(
          isA<TreeLoadException>().having(
            (error) => error.message,
            'message',
            'This folder no longer exists.',
          ),
        ),
      );
    });
  });

  group('GoogleDriveBrowser', () {
    /// A drive held in memory: folder id to the rows Drive would return.
    MockClient driveOf(Map<String, List<Map<String, dynamic>>> folders) {
      return MockClient((request) async {
        final query = request.url.queryParameters['q']!;
        final parent = RegExp(r"'([^']+)' in parents").firstMatch(query)![1]!;
        var rows = folders[parent] ?? const <Map<String, dynamic>>[];

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

    Map<String, dynamic> doc(String id, String name) => {
      'id': id,
      'name': name,
      'mimeType': 'application/pdf',
    };

    test('the drive itself lists folders first, then files', () async {
      final browser = GoogleDriveBrowser(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [
              doc('d1', 'zebra.pdf'),
              folder('f1', 'Work'),
              doc('d2', 'Apples.pdf'),
              folder('f2', 'archive'),
            ],
          }),
        ),
      );

      final entries = await browser.children(null);

      expect(entries.map((entry) => entry.label), [
        'archive',
        'Work',
        'Apples.pdf',
        'zebra.pdf',
      ]);
      expect(entries.map((entry) => entry.isFolder), [
        true,
        true,
        false,
        false,
      ]);
      // Rows carry Drive ids, which is what opening one asks Drive about.
      expect(entries.first.id, 'f2');
    });

    test('a folder is opened by its id', () async {
      final browser = GoogleDriveBrowser(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [folder('f1', 'Work')],
            'f1': [doc('d1', 'Deck.pdf')],
          }),
        ),
      );

      final work = (await browser.children(null)).single;
      final inside = await browser.children(work);

      expect(inside.single.label, 'Deck.pdf');
    });

    test('a configured folder becomes the top of the tree', () async {
      final browser = GoogleDriveBrowser(
        api: GoogleDriveApi(
          accessToken: 'token',
          client: driveOf({
            'root': [folder('f1', 'Work')],
            'f1': [folder('f2', 'Invoices')],
            'f2': [doc('d1', 'March.pdf')],
          }),
        ),
        rootPath: '/Work/Invoices',
      );

      final entries = await browser.children(null);
      expect(entries.single.label, 'March.pdf');
    });

    test('a folder that is gone says so', () async {
      final browser = GoogleDriveBrowser(
        api: GoogleDriveApi(accessToken: 'token', client: driveOf(const {})),
        rootPath: '/Nowhere',
      );

      expect(
        () => browser.children(null),
        throwsA(
          isA<TreeLoadException>().having(
            (error) => error.message,
            'message',
            'No Google Drive folder at /Nowhere.',
          ),
        ),
      );
    });

    test('an expired connection reads as one', () async {
      final browser = GoogleDriveBrowser(
        api: GoogleDriveApi(
          accessToken: 'stale',
          client: MockClient((request) async => http.Response('nope', 401)),
        ),
      );

      expect(
        () => browser.children(null),
        throwsA(
          isA<TreeLoadException>().having(
            (error) => error.message,
            'message',
            'Google Drive needs connecting again from Sources.',
          ),
        ),
      );
    });
  });
}
