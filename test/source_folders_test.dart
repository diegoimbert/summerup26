import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/pages/source_connect_dialog.dart';
import 'package:overlay_app/pages/sources_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/sources/source_catalog.dart';
import 'package:overlay_app/theme.dart';

/// Keeps the folder scope in memory so the tests never touch the real
/// Application Support file.
class _MemoryStore extends CredentialStore {
  _MemoryStore({this.connections = const {}, this.folders = const {}});

  final Map<String, SourceCredentials> connections;
  Map<String, List<String>> folders;

  @override
  Future<Map<String, SourceCredentials>> readAll() async => connections;

  @override
  Future<Map<String, List<String>>> readAllFolders() async => folders;

  @override
  Future<void> saveFolders(String sourceId, List<String> paths) async {
    folders = {...folders, sourceId: paths};
  }
}

/// The rows in the folder list, identified by their remove buttons — matching
/// on the path text alone would also hit the input's placeholder.
final Finder _folderRows = find.widgetWithIcon(IconButton, Icons.close);

SourceDescriptor _source(String id) =>
    kSourceCatalog.firstWhere((source) => source.id == id);

Future<ConnectionsController> _openConnectDialog(
  WidgetTester tester, {
  required String sourceId,
  required CredentialStore store,
}) async {
  tester.view.physicalSize = const Size(1100, 1500);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final connections = ConnectionsController(store: store);
  await connections.load();

  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showSourceConnectDialog(
                context,
                source: _source(sourceId),
                connections: connections,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return connections;
}

SourceCredentials _connected(String sourceId) => SourceCredentials(
  sourceId: sourceId,
  accessToken: 'token',
  accountLabel: 'diego@windmill.dev',
);

void main() {
  test('the file system leads the catalog and needs no sign-in', () {
    final fileSystem = kSourceCatalog.first;

    expect(fileSystem.id, 'file_system');
    expect(fileSystem.support, SourceSupport.builtIn);
    expect(fileSystem.isAvailable, isTrue);
    expect(fileSystem.needsSignIn, isFalse);
    expect(fileSystem.hasFolders, isTrue);
  });

  testWidgets('the file system opens its folders, skipping any sign-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1500);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final connections = ConnectionsController(store: _MemoryStore());
    await connections.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKandooTheme(),
        home: Scaffold(body: SourcesPage(connections: connections)),
      ),
    );
    await tester.pumpAndSettle();

    // Connected without ever signing in, so it offers no connect affordance.
    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();

    expect(find.text('File System folders'), findsOneWidget);
    expect(find.text('Continue with File System'), findsNothing);
  });

  testWidgets('a source with nothing behind it still says so', (tester) async {
    tester.view.physicalSize = const Size(1400, 1500);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final connections = ConnectionsController(store: _MemoryStore());
    await connections.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKandooTheme(),
        home: Scaffold(body: SourcesPage(connections: connections)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dropbox'));
    await tester.pumpAndSettle();

    expect(find.text('Dropbox is not available yet.'), findsOneWidget);
    expect(find.text('Dropbox folders'), findsNothing);
  });

  test('every folder-shaped source is marked, and no other', () {
    final withFolders = kSourceCatalog
        .where((source) => source.hasFolders)
        .map((source) => source.id)
        .toSet();

    expect(withFolders, {
      'file_system',
      'google_drive',
      'icloud_drive',
      'onedrive',
      'dropbox',
    });
  });

  testWidgets('a connected folder source offers Configure folders', (
    tester,
  ) async {
    await _openConnectDialog(
      tester,
      sourceId: 'google_drive',
      store: _MemoryStore(
        connections: {'google_drive': _connected('google_drive')},
      ),
    );

    expect(find.text('Configure folders'), findsOneWidget);
    expect(find.text('Reading every folder.'), findsOneWidget);
  });

  testWidgets('a disconnected source does not', (tester) async {
    await _openConnectDialog(
      tester,
      sourceId: 'google_drive',
      store: _MemoryStore(),
    );

    expect(find.text('Configure folders'), findsNothing);
  });

  testWidgets('a page-shaped source does not, even when connected', (
    tester,
  ) async {
    await _openConnectDialog(
      tester,
      sourceId: 'notion',
      store: _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    expect(find.text('Configure folders'), findsNothing);
  });

  testWidgets('folders can be added, removed and saved', (tester) async {
    final store = _MemoryStore(
      connections: {'google_drive': _connected('google_drive')},
      folders: {
        'google_drive': ['/Users/diegoimbert/Desktop'],
      },
    );
    final connections = await _openConnectDialog(
      tester,
      sourceId: 'google_drive',
      store: store,
    );

    expect(find.text('Reading 1 folder.'), findsOneWidget);

    await tester.tap(find.text('Configure folders'));
    await tester.pumpAndSettle();
    // Counted by their remove buttons: the path itself also appears as the
    // input's placeholder.
    expect(_folderRows, findsOneWidget);

    // The trailing separator should not survive into the stored path.
    await tester.enterText(find.byType(TextField), '/Users/diegoimbert/Notes/');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/Users/diegoimbert/Code');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // Drop the middle entry to prove removal targets the right row.
    await tester.tap(_folderRows.at(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(connections.foldersFor('google_drive'), [
      '/Users/diegoimbert/Desktop',
      '/Users/diegoimbert/Code',
    ]);
    expect(store.folders['google_drive'], [
      '/Users/diegoimbert/Desktop',
      '/Users/diegoimbert/Code',
    ]);
    expect(find.text('Reading 2 folders.'), findsOneWidget);
  });

  testWidgets('cancelling leaves the stored scope alone', (tester) async {
    final store = _MemoryStore(
      connections: {'google_drive': _connected('google_drive')},
      folders: {
        'google_drive': ['/Users/diegoimbert/Desktop'],
      },
    );
    final connections = await _openConnectDialog(
      tester,
      sourceId: 'google_drive',
      store: store,
    );

    await tester.tap(find.text('Configure folders'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/tmp/scratch');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(connections.foldersFor('google_drive'), [
      '/Users/diegoimbert/Desktop',
    ]);
  });

  testWidgets('a duplicate folder is refused', (tester) async {
    await _openConnectDialog(
      tester,
      sourceId: 'google_drive',
      store: _MemoryStore(
        connections: {'google_drive': _connected('google_drive')},
        folders: {
          'google_drive': ['/Users/diegoimbert/Desktop'],
        },
      ),
    );

    await tester.tap(find.text('Configure folders'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '/Users/diegoimbert/Desktop',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('That folder is already in the list.'), findsOneWidget);
    expect(_folderRows, findsOneWidget);
  });
}
