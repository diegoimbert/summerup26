import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/sources/file_system_browser.dart';
import 'package:overlay_app/widgets/tree_viewer.dart';

void main() {
  testWidgets('debug real io in tree', (tester) async {
    final root = await Directory.systemTemp.createTemp('kandoo_dbg_');
    await File('${root.path}/todo.md').writeAsString('todo');
    addTearDown(() => root.delete(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: TreeViewer(
              loadChildren: FileSystemBrowser(rootPath: root.path).children,
            ),
          ),
        ),
      ),
    );

    debugPrint('after pumpWidget: spinner=${find.byType(CircularProgressIndicator).evaluate().length}');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    debugPrint('after runAsync+pump: spinner=${find.byType(CircularProgressIndicator).evaluate().length} todo=${find.text('todo.md').evaluate().length}');

    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('after pump 100ms: spinner=${find.byType(CircularProgressIndicator).evaluate().length} todo=${find.text('todo.md').evaluate().length}');
  });
}
