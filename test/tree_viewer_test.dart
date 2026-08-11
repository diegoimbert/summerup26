import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/sources/file_system_browser.dart';
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

  Future<List<TreeEntry>> load(TreeEntry? parent) async {
    calls.add(parent?.id);
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
}
