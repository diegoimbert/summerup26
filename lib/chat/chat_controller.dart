import 'package:flutter/foundation.dart';

import '../library/library_controller.dart';
import '../library/library_store.dart';
import '../sources/connections.dart';
import '../sources/google_drive_api.dart';
import '../sources/oauth.dart';
import 'chat_agent.dart';
import 'document_reader.dart';
import 'drive_document_reader.dart';
import 'file_document_reader.dart';

/// One turn in the conversation.
@immutable
class ChatMessage {
  const ChatMessage.fromUser(this.text)
    : isFromUser = true,
      isError = false,
      steps = const [],
      sources = const [];

  const ChatMessage.fromAssistant(
    this.text, {
    this.steps = const [],
    this.sources = const [],
  }) : isFromUser = false,
       isError = false;

  /// Something that went wrong, said in the assistant's place — the question
  /// was asked, so the conversation owes an answer of some kind.
  const ChatMessage.failure(this.text)
    : isFromUser = false,
      isError = true,
      steps = const [],
      sources = const [];

  final String text;
  final bool isFromUser;
  final bool isError;

  /// What the assistant did to answer: the folders it opened, the files it
  /// read.
  final List<ChatStep> steps;

  /// The files the answer was read out of, for the user to check it against.
  final List<LibraryEntry> sources;
}

/// Holds the conversation for the Chat section.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.library,
    required ConnectionsController connections,
    DeepSeekChat? agent,
  }) : _agent = agent ?? _defaultAgent(connections);

  /// Where the files come from: the assistant looks through the same organized
  /// library the Files section shows.
  final LibraryController library;

  final DeepSeekChat _agent;

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  bool _thinking = false;
  bool get isThinking => _thinking;

  /// What the assistant is doing right now, for the line under the question.
  String? _activity;
  String? get activity => _activity;

  bool _disposed = false;

  /// Which question is being answered, counted up so a turn that has been
  /// stopped can tell that it is no longer the one being waited on.
  int _turn = 0;

  /// How much of the conversation the assistant is reminded of. Enough for a
  /// follow-up to mean something, short of resending an afternoon's chat with
  /// every question.
  static const int _remembered = 6;

  /// Asks [question] and adds both sides of it to the conversation.
  Future<void> send(String question) async {
    final asked = question.trim();
    if (asked.isEmpty || _thinking) return;

    // Everything already said, before this question joins it.
    final history = _history();

    final turn = ++_turn;
    _messages.add(ChatMessage.fromUser(asked));
    _thinking = true;
    _activity = 'Looking through your files…';
    notifyListeners();

    // True once this turn has been stopped, or overtaken by a later question.
    bool abandoned() => _disposed || _turn != turn;

    try {
      final answer = await _agent.ask(
        question: asked,
        library: library.entries,
        history: history,
        onStep: (step) {
          if (abandoned()) return;
          _activity = _wordsFor(step);
          notifyListeners();
        },
        isCancelled: abandoned,
      );

      if (abandoned()) return;
      _messages.add(
        ChatMessage.fromAssistant(
          answer.text,
          steps: answer.steps,
          sources: answer.sources,
        ),
      );
    } on ChatCancelled {
      // Stopped on purpose. The question stays where it is, unanswered.
      return;
    } on ChatException catch (failure) {
      if (!abandoned()) _messages.add(ChatMessage.failure(failure.message));
    } catch (failure) {
      if (!abandoned()) {
        _messages.add(ChatMessage.failure('Something went wrong: $failure'));
      }
    } finally {
      // A turn that was stopped, or overtaken, has no say over what the chat is
      // doing now.
      if (!abandoned()) {
        _thinking = false;
        _activity = null;
        notifyListeners();
      }
    }
  }

  /// Gives up on the question being answered.
  ///
  /// The work already at the wire cannot be recalled, so it is orphaned rather
  /// than waited on: whatever it comes back with is dropped.
  void stop() {
    if (!_thinking) return;

    _turn += 1;
    _thinking = false;
    _activity = null;
    notifyListeners();
  }

  /// Starts the conversation over.
  void clear() {
    if (_thinking) return;
    _messages.clear();
    notifyListeners();
  }

  /// The last few questions and the answers they got.
  List<ChatExchange> _history() {
    final exchanges = <ChatExchange>[];

    for (var index = 0; index + 1 < _messages.length; index += 1) {
      final question = _messages[index];
      final answer = _messages[index + 1];
      if (!question.isFromUser || answer.isFromUser || answer.isError) continue;
      exchanges.add(
        ChatExchange(question: question.text, answer: answer.text),
      );
    }

    return exchanges.length <= _remembered
        ? exchanges
        : exchanges.sublist(exchanges.length - _remembered);
  }

  static String _wordsFor(ChatStep step) => switch (step.kind) {
    ChatStepKind.listed => 'Looking in ${step.detail}…',
    ChatStepKind.searched => 'Searching for "${step.detail}"…',
    ChatStepKind.read => 'Reading ${step.detail}…',
    ChatStepKind.failed => 'Could not read ${step.detail}',
  };

  /// The assistant a running app gets: DeepSeek, reading files off this Mac and
  /// out of the user's Drive.
  static DeepSeekChat _defaultAgent(ConnectionsController connections) {
    return DeepSeekChat(
      documents: DocumentReaders([
        const FileSystemDocumentReader(),
        GoogleDriveDocumentReader(
          api: () async {
            try {
              final credentials = await connections.freshCredentials(
                'google_drive',
              );
              if (credentials == null) return null;
              return GoogleDriveApi(accessToken: credentials.accessToken);
            } on OAuthException {
              // A connection that will not renew is, as far as reading a file
              // goes, no connection: the reader says so in its own words.
              return null;
            }
          },
        ),
      ]),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
