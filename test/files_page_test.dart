import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
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

  TreeChildrenLoader loaderFor(
    SourceDescriptor source,
    String root,
    ConnectionsController connections,
  ) {
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

/// A stored library with no disk under it. Widget tests run in a fake async
/// zone, where a real file read never comes back.
class _MemoryLibraryStore extends LibraryStore {
  _MemoryLibraryStore(this.snapshot);

  final LibrarySnapshot? snapshot;

  @override
  Future<LibrarySnapshot?> readLibrary() async => snapshot;

  @override
  Future<void> writeLibrary(LibrarySnapshot snapshot) async {}

  @override
  Future<void> writeScan(
    List<ScannedFile> files, {
    DateTime? scannedAt,
  }) async {}
}

/// A library holding [entries], without a scan or a model behind it.
Future<LibraryController> _libraryHolding(
  ConnectionsController connections,
  List<LibraryEntry> entries,
) async {
  final library = LibraryController(
    connections: connections,
    store: _MemoryLibraryStore(
      LibrarySnapshot(
        entries: entries,
        fingerprint: 'test',
        organizedAt: DateTime(2026, 8, 12),
      ),
    ),
  );
  await library.load();
  return library;
}

/// A page filed away from a workspace rather than a file from this Mac.
LibraryEntry _filedFromNotion(String id, String title, String organized) =>
    LibraryEntry(
      file: ScannedFile(
        path: '/Projects/$title',
        sourceName: 'Notion',
        externalId: id,
        modified: DateTime(2026, 8, 4),
      ),
      organizedPath: organized,
    );

LibraryEntry _filed(String path, String organized) => LibraryEntry(
  file: ScannedFile(
    path: path,
    sourceName: 'File System',
    modified: DateTime(2026, 8, 4),
  ),
  organizedPath: organized,
);

/// Where the page asked the desktop to look, instead of a desktop.
class _Opened {
  final List<Uri> urls = [];

  Future<bool> call(Uri url) async {
    urls.add(url);
    return true;
  }
}

late _Opened _opened;

/// How often the page asked to be taken to Sources.
late int _sourcesOpened;

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
  _opened = _Opened();
  _sourcesOpened = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: FilesPage(
          connections: connections,
          library: library,
          onOpenSources: () => _sourcesOpened += 1,
          treeLoader: tree.loaderFor,
          openUrl: _opened.call,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tree;
}

/// Two clicks close enough together to count as one gesture.
Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(target);
}

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await gesture.removePointer();
}

void main() {
  testWidgets('the grid holds the connected sources, and only those', (
    tester,
  ) async {
    await _pumpFiles(
      tester,
      _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    // Marks, not names: the tooltip is where each source is spelled out.
    expect(find.byTooltip('File System'), findsOneWidget);
    expect(find.byTooltip('Notion'), findsOneWidget);
    expect(find.text('File System'), findsNothing);
    // Connectable but not signed in, and not built at all, respectively.
    expect(find.byTooltip('Google Drive'), findsNothing);
    expect(find.byTooltip('Dropbox'), findsNothing);

    // The grid ends in the way to connect one more.
    await tester.tap(find.byTooltip('Connect a source'));
    await tester.pumpAndSettle();
    expect(_sourcesOpened, 1);

    // With nothing picked, the section shows the organized library. Notion is
    // connected and needs no folders, so there is something to scan — just
    // nothing scanned yet.
    expect(find.text('Nothing organized yet'), findsOneWidget);
    expect(find.text('Nothing scanned yet.'), findsOneWidget);
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

    await tester.tap(find.byTooltip('File System'));
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

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which folder?'), findsNothing);
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

  testWidgets('double-clicking a file opens it', (tester) async {
    await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': ['/Users/diegoimbert/Desktop'],
        },
      ),
    );

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    // One click does nothing to a file; it takes two.
    await tester.tap(find.text('todo.md'));
    await tester.pumpAndSettle();
    expect(_opened.urls, isEmpty);

    await _doubleTap(tester, find.text('todo.md'));
    await tester.pumpAndSettle();

    expect(_opened.urls, [Uri.file('/Users/diegoimbert/Desktop/todo.md')]);
  });

  testWidgets('a folder answers clicks rather than double-clicks', (
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

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    // One click opens it, without waiting to see whether a second is coming.
    await tester.tap(find.text('Invoices'));
    await tester.pumpAndSettle();
    expect(find.text('march.pdf'), findsOneWidget);

    // So a double-click is two answers — closed, then open again — rather
    // than one gesture the folder waits for.
    await _doubleTap(tester, find.text('Invoices'));
    await tester.pumpAndSettle();
    expect(find.text('march.pdf'), findsOneWidget);

    // And a folder is never handed to the desktop to open.
    expect(_opened.urls, isEmpty);
  });

  testWidgets('right-clicking a file offers what can be done with it', (
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

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('todo.md'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);

    await tester.tap(find.text('Show in Finder'));
    await tester.pumpAndSettle();

    // Finder shows a file by opening the folder it is in.
    expect(_opened.urls, [Uri.file('/Users/diegoimbert/Desktop')]);
  });

  testWidgets('a folder has no Open, since there is nothing to open', (
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

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('Invoices'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsNothing);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
  });

  testWidgets('searching looks through the filed away files', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final connections = ConnectionsController(store: _MemoryStore());
    await connections.load();
    final library = await _libraryHolding(connections, [
      _filed('/Users/d/Desktop/tax_2025.pdf', 'Self/Finance/Tax return.pdf'),
      _filed('/Users/d/Desktop/deck.pdf', 'Career/Pitch deck.pdf'),
    ]);
    addTearDown(library.dispose);

    _opened = _Opened();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKandooTheme(),
        home: Scaffold(
          body: FilesPage(
            connections: connections,
            library: library,
            onOpenSources: () {},
            openUrl: _opened.call,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The library as filed, until something is asked for.
    expect(find.text('Self'), findsOneWidget);
    expect(find.text('Career'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'tax');
    await tester.pumpAndSettle();

    // Results are flat, and say where each one was filed.
    expect(find.text('Tax return.pdf'), findsOneWidget);
    expect(find.text('Pitch deck.pdf'), findsNothing);
    expect(find.text('Self / Finance'), findsOneWidget);

    // And they behave like the rows they stand for.
    await _doubleTap(tester, find.text('Tax return.pdf'));
    await tester.pumpAndSettle();
    expect(_opened.urls, [Uri.file('/Users/d/Desktop/tax_2025.pdf')]);

    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No files match that search'), findsOneWidget);

    // Clearing it puts the library back.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Self'), findsOneWidget);
  });

  testWidgets('a page from a workspace opens in Notion', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final connections = ConnectionsController(store: _MemoryStore());
    await connections.load();
    final library = await _libraryHolding(connections, [
      _filedFromNotion(
        'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'Kick-off notes',
        'Career/Projects/Kick-off notes',
      ),
    ]);
    addTearDown(library.dispose);

    _opened = _Opened();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKandooTheme(),
        home: Scaffold(
          body: FilesPage(
            connections: connections,
            library: library,
            onOpenSources: () {},
            openUrl: _opened.call,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Career'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('Kick-off notes'));
    await tester.pumpAndSettle();

    // A page is read where it lives, not downloaded to this Mac.
    expect(_opened.urls, [
      Uri.parse('https://www.notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee'),
    ]);

    await _rightClick(tester, find.text('Kick-off notes'));
    await tester.pumpAndSettle();
    expect(find.text('Open in Notion'), findsOneWidget);
    // Nothing to show in Finder: it is not on this Mac.
    expect(find.text('Show in Finder'), findsNothing);
  });

  testWidgets('searching steps out of a source being browsed', (tester) async {
    await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': ['/Users/diegoimbert/Desktop'],
        },
      ),
    );

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();
    expect(find.text('todo.md'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'todo');
    await tester.pumpAndSettle();

    // The raw tree is gone: a search is a search of the library.
    expect(find.text('todo.md'), findsNothing);
    expect(find.text('No files match that search'), findsOneWidget);
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

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which folder?'), findsOneWidget);
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
    expect(find.text('Which folder?'), findsOneWidget);
  });

  testWidgets('no configured folders browses from the root', (tester) async {
    final tree = await _pumpFiles(tester, _MemoryStore());

    await tester.tap(find.byTooltip('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which folder?'), findsNothing);
    expect(tree.roots, ['/']);
    expect(find.byType(TreeViewer), findsOneWidget);
  });

  testWidgets('a source without a browser yet says so', (tester) async {
    final tree = await _pumpFiles(
      tester,
      _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    await tester.tap(find.byTooltip('Notion'));
    await tester.pumpAndSettle();

    expect(find.text('Browsing Notion is not built yet'), findsOneWidget);
    expect(find.byType(TreeViewer), findsNothing);
    expect(tree.roots, isEmpty);
  });
}
