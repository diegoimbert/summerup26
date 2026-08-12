import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/pages/settings_page.dart';
import 'package:overlay_app/pages/today_page.dart';
import 'package:overlay_app/pages/welcome_dialog.dart';
import 'package:overlay_app/settings/profile.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/theme.dart';
import 'package:overlay_app/widgets/source_logo.dart';

LibraryEntry _filed(String path, String organized, {DateTime? modified}) =>
    LibraryEntry(
      file: ScannedFile(
        path: path,
        sourceName: 'File System',
        modified: modified,
      ),
      organizedPath: organized,
    );

/// Keeps connections in memory, so the tests never touch Application Support.
class _MemoryCredentials extends CredentialStore {
  @override
  Future<Map<String, SourceCredentials>> readAll() async => const {};

  @override
  Future<Map<String, List<String>>> readAllFolders() async => const {};
}

class _MemoryLibrary extends LibraryStore {
  const _MemoryLibrary(this.entries);

  final List<LibraryEntry> entries;

  @override
  Future<LibrarySnapshot?> readLibrary() async => LibrarySnapshot(
    entries: entries,
    fingerprint: 'test',
    organizedAt: DateTime(2026, 8, 12),
  );
}

Future<LibraryController> _libraryHolding(List<LibraryEntry> entries) async {
  final connections = ConnectionsController(store: _MemoryCredentials());
  await connections.load();

  final library = LibraryController(
    connections: connections,
    store: _MemoryLibrary(entries),
  );
  await library.load();
  addTearDown(library.dispose);
  return library;
}

/// A profile with no file behind it. A real one is read off the disk, which
/// never completes inside the fake async zone a widget test runs in; the store
/// itself is covered against a real folder below.
class _MemoryProfileStore extends ProfileStore {
  _MemoryProfileStore(this.name);

  String? name;

  @override
  Future<String?> readFirstName() async => name;

  @override
  Future<void> writeFirstName(String? name) async => this.name = name?.trim();
}

Future<ProfileController> _profileNamed(String? name) async {
  final profile = ProfileController(
    store: _MemoryProfileStore(name),
  );
  await profile.load();
  addTearDown(profile.dispose);
  return profile;
}

Future<void> _pumpToday(
  WidgetTester tester, {
  required ProfileController profile,
  required LibraryController library,
  DateTime? now,
  Future<bool> Function(Uri)? onOpen,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: TodayPage(
          profile: profile,
          library: library,
          now: now ?? DateTime(2026, 8, 12, 9),
          openUrl: onOpen ?? (url) async => true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the greeting', () {
    test('follows the clock', () {
      expect(greetingFor(DateTime(2026, 8, 12, 7)), 'Good morning');
      expect(greetingFor(DateTime(2026, 8, 12, 12)), 'Good afternoon');
      expect(greetingFor(DateTime(2026, 8, 12, 18)), 'Good evening');
    });
  });

  group('recently filed', () {
    test('the newest come first, and only as many as asked for', () {
      final entries = [
        _filed('/a/old.pdf', 'Self/Finance/Old.pdf', modified: DateTime(2024)),
        _filed('/a/new.pdf', 'Self/Finance/New.pdf', modified: DateTime(2026)),
        _filed('/a/mid.pdf', 'Self/Finance/Mid.pdf', modified: DateTime(2025)),
      ];

      expect(
        recentlyFiled(entries, limit: 2).map((entry) => entry.file.name),
        ['new.pdf', 'mid.pdf'],
      );
    });

    test('a file with no date is left out rather than dated for it', () {
      final entries = [
        _filed('/a/undated.pdf', 'Self/Undated.pdf'),
        _filed('/a/dated.pdf', 'Self/Dated.pdf', modified: DateTime(2026)),
      ];

      expect(recentlyFiled(entries).map((entry) => entry.file.name), [
        'dated.pdf',
      ]);
    });
  });

  group('the profile', () {
    test('a name survives being put down and picked up again', () async {
      final home = await Directory.systemTemp.createTemp('kandoo-profile');
      addTearDown(() => home.delete(recursive: true));

      final store = ProfileStore(directory: home);
      final first = ProfileController(store: store);
      await first.load();
      expect(first.needsFirstName, isTrue);

      await first.setFirstName('  Chris  ');
      expect(first.firstName, 'Chris');

      final second = ProfileController(store: store);
      await second.load();
      expect(second.firstName, 'Chris');
      expect(second.needsFirstName, isFalse);
    });

    test('a name can be taken back out', () async {
      final profile = await _profileNamed('Chris');
      await profile.setFirstName('');

      expect(profile.firstName, isNull);
      expect(profile.needsFirstName, isTrue);
    });
  });

  group('the Today section', () {
    testWidgets('greets the user by name, at the hour it is', (tester) async {
      await _pumpToday(
        tester,
        profile: await _profileNamed('Chris'),
        library: await _libraryHolding(const []),
      );

      expect(find.text('Good morning Chris!'), findsOneWidget);
      expect(find.text('Wednesday, 12 August 2026'), findsOneWidget);
    });

    testWidgets('greets nobody in particular when there is no name', (
      tester,
    ) async {
      await _pumpToday(
        tester,
        profile: await _profileNamed(null),
        library: await _libraryHolding(const []),
        now: DateTime(2026, 8, 12, 20),
      );

      expect(find.text('Good evening!'), findsOneWidget);
    });

    testWidgets('says what is coming to the sections that are not built', (
      tester,
    ) async {
      await _pumpToday(
        tester,
        profile: await _profileNamed('Chris'),
        library: await _libraryHolding(const []),
      );

      expect(find.text("Today's reminders"), findsOneWidget);
      expect(find.text('Worth your attention'), findsOneWidget);
      expect(find.textContaining('Todoist'), findsOneWidget);
    });

    testWidgets('recent events say what turned up and where it went', (
      tester,
    ) async {
      final opened = <Uri>[];

      await _pumpToday(
        tester,
        profile: await _profileNamed('Chris'),
        library: await _libraryHolding([
          _filed(
            '/Users/d/Downloads/xc_2026_tax.pdf',
            'Finance/Taxes/2026/Tax return 2026.pdf',
            modified: DateTime(2026, 8, 11),
          ),
        ]),
        onOpen: (url) async {
          opened.add(url);
          return true;
        },
      );

      expect(find.text('xc_2026_tax.pdf'), findsOneWidget);
      expect(find.text('Finance/Taxes/2026'), findsOneWidget);

      // The date and the source mark end the row, in that order, against its
      // right edge rather than adrift in the middle of it.
      final date = tester.getRect(find.text('2026-08-11'));
      final mark = tester.getRect(find.byType(SourceMarks));
      final page = tester.getRect(find.byType(TodayPage));

      expect(date.left, greaterThan(tester.getRect(find.text('Finance/Taxes/2026')).right));
      expect(date.right, lessThanOrEqualTo(mark.left));
      expect(mark.right, greaterThan(page.right - 80));

      await tester.tap(find.text('xc_2026_tax.pdf'));
      await tester.pumpAndSettle();
      expect(opened.single.path, '/Users/d/Downloads/xc_2026_tax.pdf');
    });

    testWidgets('an empty library says how it gets filled', (tester) async {
      await _pumpToday(
        tester,
        profile: await _profileNamed('Chris'),
        library: await _libraryHolding(const []),
      );

      expect(find.textContaining('Nothing filed yet'), findsOneWidget);
    });
  });

  group('asking for a name', () {
    testWidgets('the welcome dialog saves what is typed', (tester) async {
      final profile = await _profileNamed(null);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildKandooTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWelcomeDialog(context, profile: profile),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Chris');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(profile.firstName, 'Chris');
      expect(find.text('Welcome to Kandoo'), findsNothing);
    });

    testWidgets('backing out of it leaves the app without a name', (
      tester,
    ) async {
      final profile = await _profileNamed(null);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildKandooTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWelcomeDialog(context, profile: profile),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(profile.firstName, isNull);
    });
  });

  group('the Settings section', () {
    testWidgets('the name can be changed, and sticks', (tester) async {
      final profile = await _profileNamed('Chris');

      await tester.pumpWidget(
        MaterialApp(
          theme: buildKandooTheme(),
          home: Scaffold(body: SettingsPage(profile: profile)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Chris',
      );

      await tester.enterText(find.byType(TextField), 'Diego');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(profile.firstName, 'Diego');
      expect(find.text('Saved. Hello, Diego.'), findsOneWidget);
    });
  });
}
