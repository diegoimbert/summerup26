import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/pages/files_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/sources/source_catalog.dart';
import 'package:overlay_app/theme.dart';
import 'package:overlay_app/widgets/tree_viewer.dart';

/// Keeps connections and folder scope in memory, so the tests never touch the
/// real Application Support file.
class _MemoryStore extends CredentialStore {
  _MemoryStore({this.connections = const {}, this.folders = const {}});

  final Map<String, SourceCredentials> connections;
  final Map<String, List<String>> folders;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => connections;

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;
}

SourceCredentials _connected(String sourceId) => SourceCredentials(
  sourceId: sourceId,
  accessToken: 'token',
  accountLabel: 'diego@windmill.dev',
);

/// Stands in for the disk. Real file reads never complete inside the fake async
/// zone a widget test runs in, so the page is handed a tree it can resolve
/// without leaving that zone; [FileSystemBrowser] is covered against real
/// directories in tree_viewer_test.dart.
class _FakeTree {
  final List<String> roots = [];

  TreeChildrenLoader loaderFor(SourceDescriptor source, String root) {
    return (parent) async {
      // Recorded on the read rather than on the build, so a rebuild of the
      // page does not look like a second visit to the folder.
      if (parent == null) roots.add(root);

      return switch (parent) {
        null => [
          TreeEntry(id: '$root/Invoices', label: 'Invoices', isFolder: true),
          TreeEntry(id: '$root/todo.md', label: 'todo.md'),
        ],
        _ => [TreeEntry(id: '${parent.id}/march.pdf', label: 'march.pdf')],
      };
    };
  }
}

Future<_FakeTree> _pumpFiles(WidgetTester tester, CredentialStore store) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final connections = ConnectionsController(store: store);
  await connections.load();

  // Left idle: the library's own behaviour is covered in library_test.dart,
  // and these tests are about the grid and the sources behind it.
  final library = LibraryController(connections: connections);
  addTearDown(library.dispose);

  final tree = _FakeTree();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: FilesPage(
          connections: connections,
          library: library,
          treeLoader: tree.loaderFor,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tree;
}

void main() {
  testWidgets('the grid holds the connected sources, and only those', (
    tester,
  ) async {
    await _pumpFiles(
      tester,
      _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    // Reachable without a sign-in, so it is always there.
    expect(find.text('File System'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    // Connectable but not signed in, and not built at all, respectively.
    expect(find.text('Google Drive'), findsNothing);
    expect(find.text('Dropbox'), findsNothing);

    // With nothing picked, the section shows the organized library — which
    // here has nothing in it and no folders to fill it from.
    expect(
      find.text(
        'No folders to scan yet.\nAdd some to File System under Sources.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Nothing to scan yet — add folders to a source under Sources.'),
      findsOneWidget,
    );
  });

  testWidgets('picking the open source again returns to the library', (
    tester,
  ) async {
    await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': ['/Users/diegoimbert/Desktop'],
        },
      ),
    );

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();
    expect(find.byType(TreeViewer), findsOneWidget);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();

    expect(find.byType(TreeViewer), findsNothing);
    expect(find.text('Nothing organized yet'), findsOneWidget);
  });

  testWidgets('one configured folder goes straight to the tree', (
    tester,
  ) async {
    final tree = await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': ['/Users/diegoimbert/Desktop'],
        },
      ),
    );

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which File System folder?'), findsNothing);
    expect(tree.roots, ['/Users/diegoimbert/Desktop']);
    expect(find.text('/Users/diegoimbert/Desktop'), findsOneWidget);

    // Folders come first, and stay closed until they are opened.
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('todo.md'), findsOneWidget);
    expect(find.text('march.pdf'), findsNothing);

    await tester.tap(find.text('Invoices'));
    await tester.pumpAndSettle();
    expect(find.text('march.pdf'), findsOneWidget);

    // With nothing to choose between, there is no way back to a choice.
    expect(find.text('Change folder'), findsNothing);
  });

  testWidgets('several folders are chosen between first', (tester) async {
    final tree = await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': [
            '/Users/diegoimbert/Desktop',
            '/Users/diegoimbert/Code',
          ],
        },
      ),
    );

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which File System folder?'), findsOneWidget);
    expect(find.byType(TreeViewer), findsNothing);
    // Nothing is read until the user has said where to look.
    expect(tree.roots, isEmpty);

    await tester.tap(find.text('/Users/diegoimbert/Code'));
    await tester.pumpAndSettle();

    expect(find.byType(TreeViewer), findsOneWidget);
    expect(tree.roots, ['/Users/diegoimbert/Code']);
    expect(find.text('Invoices'), findsOneWidget);

    // And back again, since there was a choice to make.
    await tester.tap(find.text('Change folder'));
    await tester.pumpAndSettle();
    expect(find.text('Which File System folder?'), findsOneWidget);
  });

  testWidgets('no configured folders browses from the root', (tester) async {
    final tree = await _pumpFiles(tester, _MemoryStore());

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which File System folder?'), findsNothing);
    expect(tree.roots, ['/']);
    expect(find.byType(TreeViewer), findsOneWidget);
  });

  testWidgets('a source without a browser yet says so', (tester) async {
    final tree = await _pumpFiles(
      tester,
      _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    await tester.tap(find.text('Notion'));
    await tester.pumpAndSettle();

    expect(find.text('Browsing Notion is not built yet'), findsOneWidget);
    expect(find.byType(TreeViewer), findsNothing);
    expect(tree.roots, isEmpty);
  });
}
