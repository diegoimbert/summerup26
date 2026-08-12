import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overlay_app/chat/chat_agent.dart';
import 'package:overlay_app/chat/chat_controller.dart';
import 'package:overlay_app/chat/document_reader.dart';
import 'package:overlay_app/chat/drive_document_reader.dart';
import 'package:overlay_app/chat/file_document_reader.dart';
import 'package:overlay_app/chat/library_navigator.dart';
import 'package:overlay_app/chat/text_extraction.dart';
import 'package:overlay_app/library/library_controller.dart';
import 'package:overlay_app/library/library_store.dart';
import 'package:overlay_app/pages/chat_page.dart';
import 'package:overlay_app/sources/connections.dart';
import 'package:overlay_app/sources/credential_store.dart';
import 'package:overlay_app/sources/google_drive_api.dart';
import 'package:overlay_app/theme.dart';

LibraryEntry _local(String path, String organized) => LibraryEntry(
  file: ScannedFile(
    path: path,
    sourceName: 'File System',
    modified: DateTime(2026, 3, 2),
  ),
  organizedPath: organized,
);

LibraryEntry _drive(String path, String organized, String id) => LibraryEntry(
  file: ScannedFile(
    path: path,
    sourceName: 'Google Drive',
    modified: DateTime(2026, 4, 9),
    externalId: id,
  ),
  organizedPath: organized,
);

/// A small library with the shape a real one has: a couple of areas, files at
/// more than one level, and both sources represented.
final List<LibraryEntry> _library = [
  _local('/Users/d/docs/tr25.pdf', 'Self/Finance/Tax return 2025.pdf'),
  _local('/Users/d/docs/tr24.pdf', 'Self/Finance/Tax return 2024.pdf'),
  _drive('/Work/notes.txt', 'Career/Notes/Standup notes.txt', 'drive-1'),
  _local('/Users/d/readme.md', 'Readme.md'),
];

/// Answers with whatever text the test gave it, and refuses the rest.
class _FakeReader extends DocumentReader {
  _FakeReader(this.texts);

  final Map<String, String> texts;

  /// The files it was asked for, in order.
  final List<String> opened = [];

  @override
  String get sourceName => 'Test';

  @override
  bool canRead(ScannedFile file) => true;

  @override
  Future<DocumentText> read(ScannedFile file, {required int maxChars}) async {
    opened.add(file.path);
    final text = texts[file.path];
    if (text == null) {
      throw DocumentUnavailable('${file.name} could not be read.');
    }
    return DocumentText.trimmed(text, maxChars: maxChars);
  }
}

/// DeepSeek, replying with what the test scripted, in order.
class _Script {
  _Script(this.replies);

  final List<String> replies;
  final List<Map<String, dynamic>> requests = [];

  http.Client get client => MockClient((request) async {
    requests.add(jsonDecode(request.body) as Map<String, dynamic>);
    final reply = replies[requests.length.clamp(1, replies.length) - 1];

    return http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': reply},
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  /// The messages the model was sent on its [call]th turn.
  List<Map<String, dynamic>> messagesOn(int call) => [
    for (final message in requests[call]['messages'] as List)
      (message as Map).cast<String, dynamic>(),
  ];
}

String _action(Map<String, dynamic> action) => jsonEncode(action);

DeepSeekChat _agent(
  _Script script,
  DocumentReaders documents, {
  int maxSteps = 8,
}) => DeepSeekChat(
  documents: documents,
  client: script.client,
  apiKey: 'test-key',
  maxSteps: maxSteps,
);

void main() {
  group('walking the library', () {
    final navigator = LibraryNavigator(_library);

    test('the top level shows folders with what they hold, and loose files', () {
      final listing = navigator.listing('')!;

      expect(listing, contains('[folder] Career — 1 file'));
      expect(listing, contains('[folder] Self — 2 files'));
      // A file filed at the top is listed with the number it is opened by.
      expect(listing, contains('#3 | Readme.md | File System'));
    });

    test('a folder shows its files, numbered', () {
      final listing = navigator.listing('Self/Finance')!;

      expect(listing, contains('#0 | Tax return 2025.pdf'));
      expect(listing, contains('#1 | Tax return 2024.pdf'));
      expect(listing, isNot(contains('Standup')));
    });

    test('a folder path is forgiving of slashes', () {
      expect(navigator.listing('/Self/Finance/'), navigator.listing('Self/Finance'));
    });

    test('a folder that is not there is said to be missing', () {
      expect(navigator.listing('Self/Nonsense'), isNull);
    });

    test('search matches on words, and puts the best match first', () {
      final results = navigator.search('2025 tax');

      expect(results, contains('2 files match'));
      expect(results.indexOf('#0'), lessThan(results.indexOf('#1')));
      // A result says where it was filed, since there is no folder above it.
      expect(results, contains('Self/Finance/Tax return 2025.pdf'));
    });

    test('search says so when nothing matches', () {
      expect(navigator.search('mortgage'), contains('No files match'));
    });

    test('a file is fetched by the number it was listed with', () {
      expect(navigator.at(2)!.title, 'Standup notes.txt');
      expect(navigator.at(9), isNull);
    });
  });

  group('making text of a file', () {
    test('text files come back as they are', () {
      final bytes = Uint8List.fromList(utf8.encode('Total income: 48,250 EUR'));
      expect(
        TextExtraction.of(bytes, name: 'summary.txt'),
        'Total income: 48,250 EUR',
      );
    });

    test('a file that is not text is refused by name', () {
      final bytes = Uint8List.fromList([
        for (var index = 0; index < 200; index += 1) index % 256,
      ]);

      expect(
        () => TextExtraction.of(bytes, name: 'scan.png'),
        throwsA(
          isA<DocumentUnavailable>().having(
            (error) => error.message,
            'message',
            contains('.png'),
          ),
        ),
      );
    });

    test('a PDF gives up the text it draws', () {
      final text = TextExtraction.of(_pdfShowing([
        '(Tax return 2025) Tj',
        '(Total income: 48,250 EUR) Tj',
      ]), name: 'tax.pdf');

      expect(text, contains('Tax return 2025'));
      expect(text, contains('Total income: 48,250 EUR'));
    });

    test('what a PDF carries but never draws is left out', () {
      // Fonts and colour profiles are streams too, and they inflate into bytes
      // full of brackets that are not text.
      final pdf = latin1.encode(
        '%PDF-1.4\n'
        '5 0 obj\n<< /Length 40 >>\nstream\n'
        '(not drawn) /Font <</Name (Helvetica)>>\n'
        'endstream\nendobj\n',
      );

      expect(
        () => TextExtraction.of(Uint8List.fromList(pdf), name: 'font.pdf'),
        throwsA(isA<DocumentUnavailable>()),
      );
    });

    test('a PDF with no text layer is refused rather than guessed at', () {
      expect(
        () => TextExtraction.of(_pdfShowing(const []), name: 'scan.pdf'),
        throwsA(isA<DocumentUnavailable>()),
      );
    });
  });

  group('opening a file', () {
    test('each source is read by the reader that owns it', () async {
      final drive = _RecordingReader('Google Drive');
      final disk = _RecordingReader('File System');
      final readers = DocumentReaders([disk, drive]);

      await readers.read(_library[0].file);
      await readers.read(_library[2].file);

      expect(disk.opened, ['/Users/d/docs/tr25.pdf']);
      expect(drive.opened, ['/Work/notes.txt']);
    });

    test('a source with no reader says so instead of failing quietly', () {
      expect(
        () => const DocumentReaders([]).read(_library[0].file),
        throwsA(
          isA<DocumentUnavailable>().having(
            (error) => error.message,
            'message',
            contains('File System'),
          ),
        ),
      );
    });

    test('a file on this Mac is read off the disk, and trimmed to fit', () async {
      final home = await Directory.systemTemp.createTemp('kandoo-chat');
      addTearDown(() => home.delete(recursive: true));

      final file = File('${home.path}/notes.txt');
      await file.writeAsString('Earnings for 2025 were 48,250 EUR in total.');

      final document = await const FileSystemDocumentReader().read(
        ScannedFile(path: file.path, sourceName: 'File System'),
        maxChars: 17,
      );

      expect(document.text, 'Earnings for 2025');
      expect(document.truncated, isTrue);
    });

    test('a kind of file Kandoo cannot read is refused before it is opened', () {
      expect(
        () => const FileSystemDocumentReader().read(
          const ScannedFile(path: '/tmp/holiday.jpg', sourceName: 'File System'),
          maxChars: 100,
        ),
        throwsA(isA<DocumentUnavailable>()),
      );
    });

    test('a Google Doc is exported rather than downloaded', () async {
      final asked = <Uri>[];
      final client = MockClient((request) async {
        asked.add(request.url);
        if (request.url.path.endsWith('/export')) {
          return http.Response('Standup notes\nShipped the scanner.', 200);
        }
        return http.Response(
          jsonEncode({
            'id': 'drive-1',
            'name': 'Standup notes',
            'mimeType': 'application/vnd.google-apps.document',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final document = await GoogleDriveDocumentReader(
        api: () async =>
            GoogleDriveApi(accessToken: 'token', client: client),
      ).read(_library[2].file, maxChars: 500);

      expect(document.text, contains('Shipped the scanner'));
      expect(asked.last.queryParameters['mimeType'], 'text/plain');
    });

    test('an ordinary Drive file is downloaded and read', () async {
      final client = MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          return http.Response('Standup notes for the week.', 200);
        }
        return http.Response(
          jsonEncode({
            'id': 'drive-1',
            'name': 'notes.txt',
            'mimeType': 'text/plain',
            'size': '27',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final document = await GoogleDriveDocumentReader(
        api: () async =>
            GoogleDriveApi(accessToken: 'token', client: client),
      ).read(_library[2].file, maxChars: 500);

      expect(document.text, 'Standup notes for the week.');
    });

    test('a Drive that is no longer connected says so', () {
      expect(
        () => GoogleDriveDocumentReader(api: () async => null).read(
          _library[2].file,
          maxChars: 500,
        ),
        throwsA(
          isA<DocumentUnavailable>().having(
            (error) => error.message,
            'message',
            contains('not connected'),
          ),
        ),
      );
    });
  });

  group('answering a question', () {
    test('the assistant looks, reads and answers out of what it read', () async {
      final script = _Script([
        _action({'action': 'search', 'query': 'tax 2025'}),
        _action({'action': 'list', 'path': 'Self/Finance'}),
        _action({
          'action': 'open',
          'files': [0],
        }),
        _action({
          'action': 'answer',
          'text': 'You earned 48,250 EUR in 2025.',
          'files': [0],
        }),
      ]);

      final reader = _FakeReader({
        '/Users/d/docs/tr25.pdf': 'Total income 2025: 48,250 EUR',
      });

      final answer = await _agent(script, DocumentReaders([reader])).ask(
        question: 'How much did I earn in 2025 in my tax report?',
        library: _library,
      );

      expect(answer.text, 'You earned 48,250 EUR in 2025.');
      expect(answer.sources.single.title, 'Tax return 2025.pdf');
      expect(reader.opened, ['/Users/d/docs/tr25.pdf']);
      expect(
        answer.steps.map((step) => step.kind),
        [ChatStepKind.searched, ChatStepKind.listed, ChatStepKind.read],
      );

      // The question and the top of the library go out together, so the first
      // look is already informed.
      final opening = script.messagesOn(0).last['content'] as String;
      expect(opening, contains('How much did I earn'));
      expect(opening, contains('[folder] Self'));

      // What a step found is handed back for the next one.
      expect(
        script.messagesOn(3).map((message) => message['content']).join('\n'),
        contains('Total income 2025: 48,250 EUR'),
      );
    });

    test('only files that were actually opened are cited', () async {
      final script = _Script([
        _action({
          'action': 'open',
          'files': [0],
        }),
        _action({
          'action': 'answer',
          'text': 'It was 48,250 EUR.',
          // #1 was never read, so it is not evidence.
          'files': [0, 1],
        }),
      ]);

      final answer = await _agent(
        script,
        DocumentReaders([
          _FakeReader({'/Users/d/docs/tr25.pdf': 'Total income: 48,250 EUR'}),
        ]),
      ).ask(question: 'How much?', library: _library);

      expect(answer.sources.map((entry) => entry.title), [
        'Tax return 2025.pdf',
      ]);
    });

    test('a file that will not open is reported back, not swallowed', () async {
      final script = _Script([
        _action({
          'action': 'open',
          'files': [0, 1],
        }),
        _action({
          'action': 'answer',
          'text': 'The 2024 return says 41,000 EUR; the 2025 one would not open.',
          'files': [1],
        }),
      ]);

      final answer = await _agent(
        script,
        DocumentReaders([
          _FakeReader({'/Users/d/docs/tr24.pdf': 'Total income: 41,000 EUR'}),
        ]),
      ).ask(question: 'How much did I earn?', library: _library);

      expect(
        answer.steps.map((step) => step.kind),
        [ChatStepKind.failed, ChatStepKind.read],
      );
      expect(
        script.messagesOn(1).last['content'] as String,
        contains('could not be read'),
      );
      expect(answer.sources.single.title, 'Tax return 2024.pdf');
    });

    test('a reply that is not an action is handed straight back', () async {
      final script = _Script([
        'I would love to help!',
        _action({'action': 'answer', 'text': 'Nothing to report.'}),
      ]);

      final answer = await _agent(
        script,
        const DocumentReaders([]),
      ).ask(question: 'Anything?', library: _library);

      expect(answer.text, 'Nothing to report.');
      expect(
        script.messagesOn(1).last['content'] as String,
        contains('Reply with exactly one'),
      );
    });

    test('a model that will not stop looking is asked for an answer', () async {
      final script = _Script([
        _action({'action': 'list', 'path': ''}),
        _action({'action': 'list', 'path': 'Self'}),
        _action({'action': 'answer', 'text': 'I looked but found nothing.'}),
      ]);

      final answer = await _agent(
        script,
        const DocumentReaders([]),
        maxSteps: 2,
      ).ask(question: 'Anything?', library: _library);

      expect(answer.text, 'I looked but found nothing.');
      expect(
        script.messagesOn(2).last['content'] as String,
        contains('last look'),
      );
    });

    test('an empty library is said to be empty before anything is spent', () async {
      final script = _Script([]);

      await expectLater(
        _agent(script, const DocumentReaders([])).ask(
          question: 'How much did I earn?',
          library: const [],
        ),
        throwsA(
          isA<ChatException>().having(
            (error) => error.message,
            'message',
            contains('no organized files'),
          ),
        ),
      );
      expect(script.requests, isEmpty);
    });

    test('a build without a key says so rather than failing at the wire', () {
      expect(
        () => DeepSeekChat(
          documents: const DocumentReaders([]),
          apiKey: '',
        ).ask(question: 'How much?', library: _library),
        throwsA(
          isA<ChatException>().having(
            (error) => error.message,
            'message',
            contains('no DeepSeek key'),
          ),
        ),
      );
    });

    test('DeepSeek refusing is put in words the user can act on', () {
      final client = MockClient((request) async => http.Response('nope', 402));

      expect(
        () => DeepSeekChat(
          documents: const DocumentReaders([]),
          client: client,
          apiKey: 'test-key',
        ).ask(question: 'How much?', library: _library),
        throwsA(
          isA<ChatException>().having(
            (error) => error.message,
            'message',
            contains('balance'),
          ),
        ),
      );
    });
  });

  group('the conversation', () {
    test('a follow-up carries what was already answered', () async {
      final script = _Script([
        _action({'action': 'answer', 'text': 'You earned 48,250 EUR in 2025.'}),
        _action({'action': 'answer', 'text': 'In 2024 it was 41,000 EUR.'}),
      ]);

      final chat = await _controller(_agent(script, const DocumentReaders([])));
      addTearDown(chat.dispose);

      await chat.send('How much did I earn in 2025?');
      await chat.send('And in 2024?');

      expect(chat.messages.length, 4);
      expect(chat.messages[1].text, contains('48,250'));
      expect(
        script.messagesOn(1).map((message) => message['content']).join('\n'),
        contains('You earned 48,250 EUR in 2025.'),
      );
    });

    test('a failure becomes an answer that says what went wrong', () async {
      final chat = await _controller(
        DeepSeekChat(documents: const DocumentReaders([]), apiKey: ''),
      );
      addTearDown(chat.dispose);

      await chat.send('How much did I earn?');

      expect(chat.messages.last.isError, isTrue);
      expect(chat.messages.last.text, contains('no DeepSeek key'));
      expect(chat.isThinking, isFalse);
    });
  });

  group('the Chat section', () {
    testWidgets('a question gets an answer, and the files behind it', (
      tester,
    ) async {
      final script = _Script([
        _action({
          'action': 'open',
          'files': [0],
        }),
        _action({
          'action': 'answer',
          'text': 'You earned 48,250 EUR in 2025.',
          'files': [0],
        }),
      ]);

      final opened = <Uri>[];
      final chat = await _pumpChat(
        tester,
        _agent(
          script,
          DocumentReaders([
            _FakeReader({'/Users/d/docs/tr25.pdf': 'Total income: 48,250 EUR'}),
          ]),
        ),
        onOpen: (url) async {
          opened.add(url);
          return true;
        },
      );
      addTearDown(chat.dispose);

      await tester.enterText(
        find.byType(TextField),
        'How much did I earn in 2025 in my tax report?',
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text('How much did I earn in 2025 in my tax report?'),
          findsOneWidget);
      expect(find.text('You earned 48,250 EUR in 2025.'), findsOneWidget);

      // The answer says which file it came from, and that file opens.
      await tester.tap(find.text('Tax return 2025.pdf'));
      await tester.pumpAndSettle();
      expect(opened.single.path, '/Users/d/docs/tr25.pdf');
    });

    testWidgets('the work behind an answer can be unfolded', (tester) async {
      final script = _Script([
        _action({'action': 'list', 'path': 'Self/Finance'}),
        _action({'action': 'answer', 'text': 'Nothing in there says.'}),
      ]);

      final chat = await _pumpChat(
        tester,
        _agent(script, const DocumentReaders([])),
      );
      addTearDown(chat.dispose);

      await tester.enterText(find.byType(TextField), 'What did I earn?');
      // The send button wakes up when there is something to send.
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text('1 look'), findsOneWidget);
      expect(find.text('listed  Self/Finance'), findsNothing);

      await tester.tap(find.text('1 look'));
      await tester.pumpAndSettle();
      expect(find.text('listed  Self/Finance'), findsOneWidget);
    });

    testWidgets('a suggestion asks its question', (tester) async {
      final script = _Script([
        _action({'action': 'answer', 'text': 'You earned 48,250 EUR in 2025.'}),
      ]);

      final chat = await _pumpChat(
        tester,
        _agent(script, const DocumentReaders([])),
      );
      addTearDown(chat.dispose);

      await tester.tap(
        find.text('How much did I earn in 2025 in my tax report?'),
      );
      await tester.pumpAndSettle();

      expect(find.text('You earned 48,250 EUR in 2025.'), findsOneWidget);
    });
  });
}

/// A reader that says which files it was given, and hands back a line of text.
class _RecordingReader extends DocumentReader {
  _RecordingReader(this.sourceName);

  @override
  final String sourceName;

  /// The files it was asked for, in order.
  final List<String> opened = [];

  @override
  bool canRead(ScannedFile file) => file.sourceName == sourceName;

  @override
  Future<DocumentText> read(ScannedFile file, {required int maxChars}) async {
    opened.add(file.path);
    return const DocumentText(text: 'something readable');
  }
}

/// Keeps everything in memory, so the tests never touch Application Support.
class _MemoryCredentials extends CredentialStore {
  @override
  Future<Map<String, SourceCredentials>> readAll() async => const {};

  @override
  Future<Map<String, List<String>>> readAllFolders() async => const {};
}

class _MemoryLibrary extends LibraryStore {
  const _MemoryLibrary();

  @override
  Future<LibrarySnapshot?> readLibrary() async => LibrarySnapshot(
    entries: _library,
    fingerprint: 'test',
    organizedAt: DateTime(2026, 8, 12),
  );
}

/// A chat over [_library], asking [agent] rather than DeepSeek proper.
Future<ChatController> _controller(DeepSeekChat agent) async {
  final connections = ConnectionsController(store: _MemoryCredentials());
  await connections.load();

  final library = LibraryController(
    connections: connections,
    store: const _MemoryLibrary(),
  );
  await library.load();
  addTearDown(library.dispose);

  return ChatController(
    library: library,
    connections: connections,
    agent: agent,
  );
}

Future<ChatController> _pumpChat(
  WidgetTester tester,
  DeepSeekChat agent, {
  Future<bool> Function(Uri)? onOpen,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final chat = await _controller(agent);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildKandooTheme(),
      home: Scaffold(
        body: ChatPage(
          chat: chat,
          openUrl: onOpen ?? (url) async => true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return chat;
}

/// A PDF with one uncompressed content stream drawing [operators].
Uint8List _pdfShowing(List<String> operators) {
  final content = ['BT', ...operators, 'ET'].join('\n');

  return Uint8List.fromList(
    latin1.encode(
      '%PDF-1.4\n'
      '4 0 obj\n<< /Length ${content.length} >>\nstream\n'
      '$content\n'
      'endstream\nendobj\n'
      'trailer\n<< /Root 1 0 R >>\n%%EOF\n',
    ),
  );
}
