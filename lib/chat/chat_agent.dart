import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../library/library_store.dart';
import '../library/organizer.dart' show BuiltInDeepSeek;
import 'document_reader.dart';
import 'library_navigator.dart';

/// What the assistant did on the way to an answer.
enum ChatStepKind {
  /// Opened a folder of the library.
  listed,

  /// Looked for files by name.
  searched,

  /// Read a file.
  read,

  /// Tried to read a file and could not.
  failed,
}

/// One thing the assistant did, in words the user could be shown.
@immutable
class ChatStep {
  const ChatStep(this.kind, this.detail);

  final ChatStepKind kind;
  final String detail;
}

/// An answer, and the work behind it.
@immutable
class ChatAnswer {
  const ChatAnswer({
    required this.text,
    this.sources = const [],
    this.steps = const [],
  });

  final String text;

  /// The files the answer was actually read out of, so the user can check it
  /// against the document rather than take it on faith.
  final List<LibraryEntry> sources;

  final List<ChatStep> steps;
}

/// A question already asked and answered, for the assistant to follow on from.
@immutable
class ChatExchange {
  const ChatExchange({required this.question, required this.answer});

  final String question;
  final String answer;
}

/// Thrown when the caller asks for the answer to be abandoned mid-way.
///
/// Not a [ChatException]: nothing went wrong and the user knows what happened,
/// so there is nothing to tell them.
class ChatCancelled implements Exception {
  const ChatCancelled();

  @override
  String toString() => 'The question was stopped before it was answered.';
}

/// Thrown when a question cannot be answered at all — no key, no library, or
/// DeepSeek refusing. The message is written to be shown to the user.
class ChatException implements Exception {
  const ChatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Answers questions about the user's files by looking through them.
///
/// The model is never handed the library: it is given the top of it and a way
/// to walk down — list a folder, search for a name, open a few files — and each
/// answer comes back with the files it was read out of. That is what keeps the
/// bill and the reading bounded, and what makes an answer checkable: every
/// figure in it came from a document the user can open.
///
/// Everything the model sends is JSON with one action in it, which is trivially
/// validated and, when it is wrong, handed straight back for another go.
class DeepSeekChat {
  DeepSeekChat({
    required this.documents,
    http.Client? client,
    String? apiKey,
    Uri? endpoint,
    this.model = 'deepseek-chat',
    this.maxSteps = 8,
    this.maxFilesPerStep = 4,
    this.maxCharsPerFile = 12000,
    this.readBudget = 40000,
  }) : _client = client ?? http.Client(),
       _apiKey = apiKey ?? BuiltInDeepSeek.apiKey,
       _endpoint =
           endpoint ?? Uri.parse('https://api.deepseek.com/chat/completions');

  /// How a file is opened, whichever source it is on.
  final DocumentReaders documents;

  final http.Client _client;
  final String _apiKey;
  final Uri _endpoint;
  final String model;

  /// How many times the model may look before it has to answer. A question
  /// that cannot be settled in this many steps is one the files do not hold the
  /// answer to.
  final int maxSteps;

  /// A cap per step, so one reply cannot ask for the whole library.
  final int maxFilesPerStep;

  /// How much of a single file is sent. Long documents are read from the top.
  final int maxCharsPerFile;

  /// How much may be read across the whole question. Reached, it says so and
  /// asks for an answer from what it has.
  final int readBudget;

  /// Answers [question] from [library].
  ///
  /// [history] is what has already been said in this conversation, so a
  /// follow-up can lean on the answer before it. [onStep] is called as the
  /// assistant works, for the line that says what it is doing.
  ///
  /// [isCancelled] is asked between steps, and answering true throws
  /// [ChatCancelled] rather than working on for an answer nobody is waiting
  /// for. A request already at the wire is seen through — it is the looking
  /// that takes the time, not the last reply.
  Future<ChatAnswer> ask({
    required String question,
    required List<LibraryEntry> library,
    List<ChatExchange> history = const [],
    void Function(ChatStep step)? onStep,
    bool Function()? isCancelled,
  }) async {
    if (_apiKey.isEmpty) {
      throw const ChatException(
        'This build of Kandoo has no DeepSeek key configured.',
      );
    }
    if (library.isEmpty) {
      throw const ChatException(
        'There are no organized files to look through yet — scan a source '
        'under Files first.',
      );
    }

    final navigator = LibraryNavigator(library);
    final steps = <ChatStep>[];
    // Kept by number so a file read twice is only credited once, and in the
    // order it was read.
    final sources = <int, LibraryEntry>{};
    var budget = readBudget;

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt(maxFilesPerStep)},
      for (final exchange in history) ...[
        {'role': 'user', 'content': 'Question: ${exchange.question}'},
        {
          'role': 'assistant',
          'content': jsonEncode({'action': 'answer', 'text': exchange.answer}),
        },
      ],
      {
        'role': 'user',
        'content':
            'Question: $question\n\n'
            'The library holds ${library.length} files. Its top level:\n'
            '${navigator.overview}\n\n'
            'Reply with one JSON action.',
      },
    ];

    void record(ChatStep step) {
      steps.add(step);
      onStep?.call(step);
    }

    for (var step = 0; step < maxSteps; step += 1) {
      if (isCancelled?.call() ?? false) throw const ChatCancelled();

      final reply = await _send(messages);
      if (isCancelled?.call() ?? false) throw const ChatCancelled();
      messages.add({'role': 'assistant', 'content': reply});

      final action = _actionIn(reply);
      final left = maxSteps - step - 1;

      if (action == null) {
        messages.add({
          'role': 'user',
          'content':
              'That was not one of the JSON actions. Reply with exactly one '
              'of list, search, open or answer.',
        });
        continue;
      }

      switch (action['action']) {
        case 'answer':
          final text = (action['text'] as String?)?.trim();
          if (text != null && text.isNotEmpty) {
            return ChatAnswer(
              text: text,
              sources: _sourcesOf(action, sources, navigator),
              steps: steps,
            );
          }
          messages.add({
            'role': 'user',
            'content': 'That answer had no text in it. Answer the question.',
          });

        case 'list':
          final path = (action['path'] as String?) ?? '';
          final listing = navigator.listing(path);
          record(
            ChatStep(
              ChatStepKind.listed,
              path.trim().isEmpty ? 'the library' : path,
            ),
          );
          messages.add({
            'role': 'user',
            'content': _observation(
              listing ?? 'There is no folder called "$path".',
              left,
            ),
          });

        case 'search':
          final query = (action['query'] as String?) ?? '';
          record(ChatStep(ChatStepKind.searched, query));
          messages.add({
            'role': 'user',
            'content': _observation(navigator.search(query), left),
          });

        case 'open':
          final ids = _idsIn(action['files']);
          if (ids.isEmpty) {
            messages.add({
              'role': 'user',
              'content':
                  'Opening needs the numbers of files you have seen listed, '
                  'as in {"action": "open", "files": [3]}.',
            });
            continue;
          }

          final read = await _open(
            ids.take(maxFilesPerStep).toList(),
            navigator: navigator,
            sources: sources,
            budget: budget,
            record: record,
          );
          budget = read.budget;

          messages.add({
            'role': 'user',
            'content': _observation(
              budget > 0
                  ? read.text
                  : '${read.text}\n\nThat is all the reading there is room '
                        'for. Answer from what you have.',
              left,
            ),
          });

        default:
          messages.add({
            'role': 'user',
            'content':
                '"${action['action']}" is not an action. Use list, search, '
                'open or answer.',
          });
      }
    }

    if (isCancelled?.call() ?? false) throw const ChatCancelled();

    // Out of steps. One last ask, so the work already done still produces
    // something rather than nothing.
    messages.add({
      'role': 'user',
      'content':
          'That is the last look you get. Reply now with '
          '{"action": "answer", "text": "..."} using what you have read, and '
          'say plainly if it was not enough to answer.',
    });

    final last = _actionIn(await _send(messages));
    final text = (last?['text'] as String?)?.trim();
    if (last?['action'] == 'answer' && text != null && text.isNotEmpty) {
      return ChatAnswer(
        text: text,
        sources: _sourcesOf(last!, sources, navigator),
        steps: steps,
      );
    }

    throw const ChatException(
      'The assistant kept looking without settling on an answer. Try asking '
      'more specifically.',
    );
  }

  /// Reads [ids], and says what it found in the shape the model reads back.
  Future<({String text, int budget})> _open(
    List<int> ids, {
    required LibraryNavigator navigator,
    required Map<int, LibraryEntry> sources,
    required int budget,
    required void Function(ChatStep) record,
  }) async {
    final blocks = <String>[];
    var left = budget;

    for (final id in ids) {
      final entry = navigator.at(id);
      if (entry == null) {
        blocks.add('#$id is not a file in this library.');
        continue;
      }

      if (left <= 0) {
        blocks.add(
          '#$id ${entry.title}: not read — there was no reading budget left.',
        );
        continue;
      }

      try {
        final document = await documents.read(
          entry.file,
          maxChars: left < maxCharsPerFile ? left : maxCharsPerFile,
        );

        left -= document.text.length;
        sources[id] = entry;
        record(ChatStep(ChatStepKind.read, entry.title));

        blocks.add(
          '#$id ${entry.organizedPath} '
          '(${entry.file.sourceName}'
          '${document.truncated ? ', first ${document.text.length} characters' : ''}):\n'
          '${document.text}',
        );
      } on DocumentUnavailable catch (failure) {
        record(ChatStep(ChatStepKind.failed, entry.title));
        blocks.add('#$id ${entry.title}: ${failure.message}');
      }
    }

    return (text: blocks.join('\n\n---\n\n'), budget: left);
  }

  /// The files an answer says it rests on, falling back to everything that was
  /// read when it names none.
  static List<LibraryEntry> _sourcesOf(
    Map<String, dynamic> answer,
    Map<int, LibraryEntry> read,
    LibraryNavigator navigator,
  ) {
    final claimed = _idsIn(answer['files']);
    // Only files that were actually opened count: a number the model adds at
    // the end is a citation of something it never looked at.
    final cited = [
      for (final id in claimed)
        if (read[id] != null) read[id]!,
    ];
    return cited.isNotEmpty ? cited : read.values.toList();
  }

  static String _observation(String result, int stepsLeft) =>
      '$result\n\n'
      '${stepsLeft <= 1 ? 'This is your last look — reply with an answer action.' : '$stepsLeft steps left. Reply with one JSON action.'}';

  /// One request, returning the model's raw reply.
  Future<String> _send(List<Map<String, dynamic>> messages) async {
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
          'messages': messages,
          'response_format': {'type': 'json_object'},
          // Low: a question about a document has a right answer, and the same
          // question twice should not wander off to a different file.
          'temperature': 0.2,
        }),
      );
    } catch (error) {
      throw ChatException('Could not reach DeepSeek: $error');
    }

    if (response.statusCode != 200) {
      throw ChatException(_failureFor(response));
    }

    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final content =
          (body as Map)['choices']?[0]?['message']?['content'] as String?;
      if (content == null) throw const ChatException('DeepSeek said nothing.');
      return content;
    } on ChatException {
      rethrow;
    } catch (_) {
      throw const ChatException('DeepSeek returned something unreadable.');
    }
  }

  /// The action in a reply, or null when there is not one to be had.
  static Map<String, dynamic>? _actionIn(String reply) {
    // JSON mode is asked for, but a model that wraps it in a code fence or adds
    // a sentence is not worth losing a step over.
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return null;

    try {
      final decoded = jsonDecode(reply.substring(start, end + 1));
      if (decoded is! Map) return null;
      final action = decoded['action'];
      if (action is! String) return null;
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// File numbers out of whatever the model put in `files`.
  static List<int> _idsIn(Object? raw) {
    if (raw is num) return [raw.toInt()];
    if (raw is String) return [?int.tryParse(raw.replaceAll('#', '').trim())];
    if (raw is! List) return const [];

    return [
      for (final value in raw)
        if (value is num)
          value.toInt()
        else if (value is String)
          ?int.tryParse(value.replaceAll('#', '').trim()),
    ];
  }

  static String _failureFor(http.Response response) => switch (
    response.statusCode
  ) {
    401 || 403 => 'DeepSeek rejected the key in this build.',
    402 => 'The DeepSeek account has no balance left.',
    429 => 'DeepSeek is rate limiting; try again shortly.',
    >= 500 => 'DeepSeek is unavailable right now.',
    _ => 'DeepSeek refused the request (${response.statusCode}).',
  };

  static String _systemPrompt(int maxFilesPerStep) =>
      '''
You are Kandoo's assistant. You answer a person's questions about their own
files, and you answer them out of the files rather than out of your own head.

Their files are in a library: folders a librarian model built out of everything
found on their Mac and their connected accounts. You cannot see inside a file
until you open it, and opening one costs a fetch — so look at names and folders
first, and open only what the question needs.

Every reply you send is JSON holding exactly one action, and nothing else:
{"action": "list", "path": "Self/Finance"}   the folders and files in a folder;
                                             "" is the top of the library
{"action": "search", "query": "tax 2025"}    files whose name or original path
                                             matches those words
{"action": "open", "files": [3, 12]}         read those files
{"action": "answer", "text": "...",          the answer, and the files it came
                     "files": [3]}            from

Rules:
- Refer to a file by the number it was listed with. Never invent a number, and
  never open a file you have not seen listed.
- Open at most $maxFilesPerStep files in one action.
- Answer from what the files say. Give the figure, and say which file it came
  from and what it was called there.
- If the files do not answer the question, say so and say what you did look at.
  Never estimate a number the documents do not contain.
- If a file will not open, note it and try the next best candidate.
- "text" is the whole of what the user reads: plain sentences, no JSON, no
  markdown headings, no mention of actions or file numbers.
''';
}
