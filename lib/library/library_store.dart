import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A file found on a source, before anything has been made of it.
@immutable
class ScannedFile {
  const ScannedFile({
    required this.path,
    required this.sourceName,
    this.modified,
  });

  /// Where the file actually lives: an absolute path for the file system, and
  /// whatever identifies it on the source for everything else.
  final String path;

  /// The source it came from, as the user knows it — 'File System' today.
  final String sourceName;

  /// Last modified, when the source reports one. Kept so the organized view
  /// can show dates without asking a model to invent them.
  final DateTime? modified;

  String get name => path.split('/').last;

  Map<String, dynamic> toJson() => {
    'path': path,
    'source': sourceName,
    if (modified != null) 'modified': modified!.toIso8601String(),
  };

  static ScannedFile fromJson(Map<String, dynamic> json) => ScannedFile(
    path: json['path'] as String,
    sourceName: json['source'] as String,
    modified: json['modified'] == null
        ? null
        : DateTime.tryParse(json['modified'] as String),
  );
}

/// A scanned file once the model has said where it belongs.
@immutable
class LibraryEntry {
  const LibraryEntry({required this.file, required this.organizedPath});

  final ScannedFile file;

  /// Slash-separated place in the organized tree, ending in a readable title:
  /// `Self/Finance/Tax return 2025.pdf`.
  final String organizedPath;

  List<String> get segments =>
      organizedPath.split('/').where((part) => part.isNotEmpty).toList();

  /// The last segment: what the file is called once tidied up.
  String get title => segments.isEmpty ? file.name : segments.last;

  /// The folders it sits in, outermost first.
  List<String> get folders => segments.take(segments.length - 1).toList();

  Map<String, dynamic> toJson() => {
    ...file.toJson(),
    'organizedPath': organizedPath,
  };

  static LibraryEntry fromJson(Map<String, dynamic> json) => LibraryEntry(
    file: ScannedFile.fromJson(json),
    organizedPath: json['organizedPath'] as String,
  );
}

/// The organized library as last agreed with the model.
@immutable
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.entries,
    required this.fingerprint,
    required this.organizedAt,
  });

  final List<LibraryEntry> entries;

  /// Identifies the scan this was built from, so an unchanged set of files is
  /// never sent to the model — and paid for — twice.
  final String fingerprint;

  final DateTime organizedAt;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'fingerprint': fingerprint,
    'organizedAt': organizedAt.toIso8601String(),
    'entries': [for (final entry in entries) entry.toJson()],
  };

  static LibrarySnapshot fromJson(Map<String, dynamic> json) => LibrarySnapshot(
    entries: [
      for (final raw in (json['entries'] as List? ?? const []))
        LibraryEntry.fromJson((raw as Map).cast<String, dynamic>()),
    ],
    fingerprint: json['fingerprint'] as String? ?? '',
    organizedAt:
        DateTime.tryParse(json['organizedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Holds the scan and its organized form on disk, beside the connections.
///
/// Two files rather than one: `scan.json` is the raw record of what exists on
/// the sources, and `library.json` is what the model made of it. Keeping them
/// apart means a failed or skipped organize still leaves an honest scan behind.
class LibraryStore {
  const LibraryStore({this.directory});

  /// Overridden in tests; otherwise Application Support, as for credentials.
  final Directory? directory;

  static const String scanFileName = 'scan.json';
  static const String libraryFileName = 'library.json';

  Future<File> _file(String name) async {
    final home = directory ?? await getApplicationSupportDirectory();
    await home.create(recursive: true);
    return File('${home.path}/$name');
  }

  /// Where the scan is written, for display in the UI.
  Future<String> scanLocation() async => (await _file(scanFileName)).path;

  Future<void> writeScan(List<ScannedFile> files, {DateTime? scannedAt}) async {
    final file = await _file(scanFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'scannedAt': (scannedAt ?? DateTime.now()).toIso8601String(),
        'files': [for (final scanned in files) scanned.toJson()],
      }),
      flush: true,
    );
  }

  Future<List<ScannedFile>> readScan() async {
    final file = await _file(scanFileName);
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      return [
        for (final raw in ((decoded as Map)['files'] as List? ?? const []))
          ScannedFile.fromJson((raw as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      // A corrupt scan is worth no more than a missing one: it will be
      // rewritten by the next pass.
      return const [];
    }
  }

  Future<void> writeLibrary(LibrarySnapshot snapshot) async {
    final file = await _file(libraryFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
      flush: true,
    );
  }

  Future<LibrarySnapshot?> readLibrary() async {
    final file = await _file(libraryFileName);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return LibrarySnapshot.fromJson((decoded as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
