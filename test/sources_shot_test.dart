import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/pages/sources_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/theme.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationSupportPath() async =>
      Directory.systemTemp.createTempSync('kandoo_test').path;
}

void main() {
  testWidgets('sources page', (tester) async {
    PathProviderPlatform.instance = _FakePathProvider();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKandooTheme(),
        home: SourcesPage(connections: ConnectionsController()),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(SourcesPage),
      matchesGoldenFile('shots/sources.png'),
    );
  });
}
