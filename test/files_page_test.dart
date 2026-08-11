import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/pages/files_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
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

/// Lets a directory listing land. Widget tests run in fake async, where real
/// file I/O only completes inside [WidgetTester.runAsync], so a plain
/// pumpAndSettle would spin on the tree's loading indicator forever.
Future<void> _settleTree(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpFiles(WidgetTester tester, CredentialStore store) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final connections = ConnectionsController(store: store);
  await connections.load();

  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(body: FilesPage(connections: connections)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kandoo_files_');
    await Directory('${root.path}/Invoices').create();
    await File('${root.path}/Invoices/march.pdf').writeAsString('pdf');
    await File('${root.path}/todo.md').writeAsString('todo');
  });

  tearDown(() => root.delete(recursive: true));

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

    expect(find.text('Choose a source above to browse it'), findsOneWidget);
  });

  testWidgets('one configured folder goes straight to the tree', (
    tester,
  ) async {
    await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': [root.path],
        },
      ),
    );

    await tester.tap(find.text('File System'));
    await _settleTree(tester);

    expect(find.text('Which File System folder?'), findsNothing);
    expect(find.text(root.path), findsOneWidget);
    // Folders first, and collapsed until they are opened.
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('todo.md'), findsOneWidget);
    expect(find.text('march.pdf'), findsNothing);

    await tester.tap(find.text('Invoices'));
    await _settleTree(tester);
    expect(find.text('march.pdf'), findsOneWidget);

    // With nothing to choose between, there is no way back to a choice.
    expect(find.text('Change folder'), findsNothing);
  });

  testWidgets('several folders are chosen between first', (tester) async {
    final other = await Directory('${root.path}/Invoices').create();

    await _pumpFiles(
      tester,
      _MemoryStore(
        folders: {
          'file_system': [root.path, other.path],
        },
      ),
    );

    await tester.tap(find.text('File System'));
    await tester.pumpAndSettle();

    expect(find.text('Which File System folder?'), findsOneWidget);
    expect(find.byType(TreeViewer), findsNothing);

    await tester.tap(find.text(other.path));
    await _settleTree(tester);

    expect(find.byType(TreeViewer), findsOneWidget);
    expect(find.text('march.pdf'), findsOneWidget);

    // And back again, since there was a choice to make.
    await tester.tap(find.text('Change folder'));
    await tester.pumpAndSettle();
    expect(find.text('Which File System folder?'), findsOneWidget);
  });

  testWidgets('no configured folders browses from the root', (tester) async {
    await _pumpFiles(tester, _MemoryStore());

    await tester.tap(find.text('File System'));
    await _settleTree(tester);

    expect(find.text('Which File System folder?'), findsNothing);
    expect(find.text('/'), findsOneWidget);
    expect(find.byType(TreeViewer), findsOneWidget);
  });

  testWidgets('a source without a browser yet says so', (tester) async {
    await _pumpFiles(
      tester,
      _MemoryStore(connections: {'notion': _connected('notion')}),
    );

    await tester.tap(find.text('Notion'));
    await tester.pumpAndSettle();

    expect(find.text('Browsing Notion is not built yet'), findsOneWidget);
    expect(find.byType(TreeViewer), findsNothing);
  });
}
