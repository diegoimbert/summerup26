import 'dart:convert';

import 'package:http/http.dart' as http;

import 'library_store.dart';

/// The DeepSeek key baked in at build time, like the OAuth clients.
///
/// Supplied with `--dart-define-from-file=oauth.json` (see
/// `oauth.example.json`). A build without one can still scan; it just cannot
/// organize, and says so rather than failing quietly.
abstract final class BuiltInDeepSeek {
  static const String apiKey = String.fromEnvironment('DEEPSEEK_API_KEY');

  static bool get isConfigured => apiKey.isNotEmpty;
}

class OrganizerException implements Exception {
  const OrganizerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns a messy scan into a tidy hierarchy by asking DeepSeek where each file
/// belongs.
///
/// The model is asked for one thing only — a path per file, by index — so the
/// result is trivially checked and can be repaired locally. Everything else the
/// organized view shows (dates, sources, counts) comes from the scan, so no
/// part of what the user reads is invented.
class DeepSeekOrganizer {
  DeepSeekOrganizer({
    http.Client? client,
    String? apiKey,
    Uri? endpoint,
    this.model = 'deepseek-chat',
    this.batchSize = 150,
    this.maxFiles = 1000,
  }) : _client = client ?? http.Client(),
       _apiKey = apiKey ?? BuiltInDeepSeek.apiKey,
       _endpoint =
           endpoint ?? Uri.parse('https://api.deepseek.com/chat/completions');

  final http.Client _client;
  final String _apiKey;
  final Uri _endpoint;
  final String model;

  /// How many files go in one request. Small enough to keep each reply within
  /// the model's output budget, large enough that it can see groupings.
  final int batchSize;

  /// A ceiling on what is sent at all, so one enormous folder cannot run up an
  /// unbounded bill. Anything past it is filed under Unsorted.
  final int maxFiles;

  static const String _unsorted = 'Unsorted';

  /// A path for every file in [files], in the same order and the same number.
  ///
  /// [existingFolders] is the shape the library already has. Pass it when
  /// filing something into a library that exists — a file that appears while
  /// Kandoo is running belongs in the folders the user already knows, not in a
  /// new one that means the same thing.
  Future<List<String>> organize(
    List<ScannedFile> files, {
    Set<String> existingFolders = const {},
    void Function(int organized, int total)? onProgress,
  }) async {
    if (files.isEmpty) return const [];
    if (_apiKey.isEmpty) {
      throw const OrganizerException(
        'This build of Kandoo has no DeepSeek key configured.',
      );
    }

    final sent = files.length > maxFiles ? files.sublist(0, maxFiles) : files;

    // Filled in as batches come back; whatever is still missing at the end is
    // repaired below, so the result is always the same length as the input.
    final paths = List<String?>.filled(files.length, null);

    // Categories already in play, so later batches join the hierarchy the
    // earlier ones established instead of inventing a parallel one.
    final known = <String>{...existingFolders};

    for (var start = 0; start < sent.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, sent.length);
      final batch = sent.sublist(start, end);

      final organized = await _organizeBatch(batch, start, known);
      organized.forEach((index, path) {
        paths[index] = path;
        final folders = path.split('/');
        if (folders.length > 1) {
          known.add(folders.take(folders.length - 1).join('/'));
        }
      });

      onProgress?.call(end, sent.length);
    }

    return [
      for (var index = 0; index < files.length; index += 1)
        paths[index] ?? '$_unsorted/${files[index].name}',
    ];
  }

  /// One request. Returns the paths it managed to place, keyed by their index
  /// in the whole scan.
  Future<Map<int, String>> _organizeBatch(
    List<ScannedFile> batch,
    int offset,
    Set<String> known,
  ) async {
    final listing = [
      for (var index = 0; index < batch.length; index += 1)
        '${offset + index} | ${batch[index].sourceName} | ${batch[index].path}',
    ].join('\n');

    final existing = known.isEmpty
        ? ''
        : 'Folders already in use — reuse one whenever it fits, rather than '
              'inventing a near-duplicate:\n${known.join('\n')}\n\n';

    final http.Response response;
    try {
      response = await _client.post(
        _endpoint,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'messages': [
            {'role': 'system', 'content': _systemPrompt},
            {'role': 'user', 'content': '$existing Files:\n$listing'},
          ],
          'response_format': {'type': 'json_object'},
          // Low, because the same scan twice should not reshuffle the library.
          'temperature': 0.2,
        }),
      );
    } catch (error) {
      throw OrganizerException('Could not reach DeepSeek: $error');
    }

    if (response.statusCode != 200) {
      throw OrganizerException(_failureFor(response));
    }

    final Map<String, dynamic> payload;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final content =
          (body as Map)['choices']?[0]?['message']?['content'] as String?;
      if (content == null) {
        throw const OrganizerException('DeepSeek returned no answer.');
      }
      payload = (jsonDecode(content) as Map).cast<String, dynamic>();
    } on OrganizerException {
      rethrow;
    } catch (_) {
      throw const OrganizerException('DeepSeek returned something unreadable.');
    }

    final placed = <int, String>{};
    final rows = payload['files'];
    if (rows is! List) return placed;

    final lowest = offset;
    final highest = offset + batch.length - 1;

    for (final row in rows) {
      if (row is! Map) continue;
      final index = (row['index'] as num?)?.toInt();
      final path = row['path'];
      if (index == null || path is! String) continue;
      // An index outside this batch is the model losing track, not a placement.
      if (index < lowest || index > highest) continue;

      final cleaned = _clean(path, batch[index - offset]);
      if (cleaned != null) placed[index] = cleaned;
    }

    return placed;
  }

  /// Keeps a returned path to something that can be shown as a tree: relative,
  /// a few levels at most, and never empty.
  static String? _clean(String path, ScannedFile file) {
    final segments = path
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty && segment != '.')
        // '..' would climb out of the library, and a model asked for a tidy
        // name has no reason to send one.
        .where((segment) => segment != '..')
        .toList();

    if (segments.isEmpty) return null;
    if (segments.length == 1) return '$_unsorted/${segments.single}';

    // Four levels of folders is already more than the eye can follow; deeper
    // suggestions are flattened onto the last folder that fits.
    const maxSegments = 5;
    if (segments.length > maxSegments) {
      final title = segments.last;
      return [...segments.take(maxSegments - 1), title].join('/');
    }

    return segments.join('/');
  }

  static String _failureFor(http.Response response) {
    final reason = switch (response.statusCode) {
      401 || 403 => 'DeepSeek rejected the key in this build.',
      402 => 'The DeepSeek account has no balance left.',
      429 => 'DeepSeek is rate limiting; try again shortly.',
      >= 500 => 'DeepSeek is unavailable right now.',
      _ => 'DeepSeek refused the request (${response.statusCode}).',
    };
    return reason;
  }

  static const String _systemPrompt = '''
You are Kandoo's librarian. You are given files that were found on a user's
devices and accounts. Their names and folders are messy, abbreviated and
inconsistent. Your job is to file each one where a person would look for it.

Reply with JSON in exactly this shape, and nothing else:
{"files": [{"index": 0, "path": "Area/Category/Readable name.pdf"}]}

Rules:
- Return one entry for every index you are given, and no others.
- "path" is folders separated by "/", ending with the file's display name.
- Use two or three folder levels: a broad life area first (for example Self,
  Life, Career), then a category (for example Finance, Health, Travel,
  Projects), and a further level only when a category truly needs one.
- Group aggressively: a category holding one file usually belongs merged into a
  neighbour. Aim for categories of a few files each.
- Rewrite the display name so a person can read it: expand abbreviations, fix
  casing and separators, drop noise like "final", "v3", "copy" and dates that
  are already metadata. Keep the file extension where there is one; a page from
  a workspace has none, and inventing one would be a lie about what it is.
- Judge from the whole path, not just the file name: the folders a file sits in
  usually say what it is.
- Never invent files, never drop files, never return an index twice.
''';
}
