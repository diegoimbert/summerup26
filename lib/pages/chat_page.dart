import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_agent.dart';
import '../chat/chat_controller.dart';
import '../library/library_controller.dart';
import '../library/library_store.dart';
import '../sources/item_actions.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';

/// The Chat section: questions about the user's own files, answered out of
/// them.
///
/// The assistant walks the organized library the Files section shows, opens
/// what the question needs and answers from what it read. Every answer carries
/// the files behind it, so the user can go and look for themselves.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.chat, this.openUrl = openWithSystem});

  /// The conversation, which outlives this page: switching to Files and back
  /// should not lose what was said.
  final ChatController chat;

  /// How a source file is handed to the desktop, as on the Files page.
  final UrlOpener openUrl;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  ChatController get _chat => widget.chat;
  LibraryController get _library => widget.chat.library;

  final TextEditingController _question = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _composer = FocusNode();

  /// How much conversation there was last time this rebuilt, so a new message
  /// scrolls into view and a rebuild for anything else does not.
  int _seen = 0;

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final question = text ?? _question.text;
    if (question.trim().isEmpty || _chat.isThinking) return;

    _question.clear();
    _composer.requestFocus();
    _chat.send(question);
  }

  /// Keeps the newest message in view, without fighting a user who has
  /// scrolled up to read something.
  void _followConversation(int messages) {
    if (messages == _seen) return;
    _seen = messages;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _open(LibraryEntry entry) async {
    final id = entry.file.externalId;
    final url = id == null
        ? localFileUrl(entry.file.path)
        : driveItemUrl(id, isFolder: false);

    if (await widget.openUrl(url) || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open ${entry.title}.'),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_chat, _library]),
      builder: (context, _) {
        final messages = _chat.messages;
        _followConversation(messages.length);

        return PageShell(
          toolbar: _Toolbar(
            files: _library.entries.length,
            onClear: messages.isEmpty || _chat.isThinking ? null : _chat.clear,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: messages.isEmpty
                    ? _Opening(onAsk: _send)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) => _Message(
                          message: messages[index],
                          onOpen: _open,
                        ),
                      ),
              ),
              if (_chat.isThinking) _Working(activity: _chat.activity),
              _Composer(
                controller: _question,
                focusNode: _composer,
                enabled: !_chat.isThinking,
                onSend: _send,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Says what the assistant has to work with, and offers a fresh start.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.files, required this.onClear});

  final int files;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.auto_awesome_outlined,
          size: 15,
          color: KandooColors.textMuted,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            files == 0
                ? 'No files organized yet — scan a source under Files first.'
                : 'Asking about your $files organized files',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              color: KandooColors.textSecondary,
            ),
          ),
        ),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              foregroundColor: KandooColors.accentDeep,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'New conversation',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}

/// What fills the section before anything has been asked: what this is for, and
/// a few questions to start from.
class _Opening extends StatelessWidget {
  const _Opening({required this.onAsk});

  final ValueChanged<String> onAsk;

  static const List<String> suggestions = [
    'How much did I earn in 2025 in my tax report?',
    'What did I pay for my last insurance renewal?',
    'Summarize the contract I signed most recently',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.chat_bubble_outline,
              size: 28,
              color: KandooColors.textMuted,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ask about anything in your files',
              style: TextStyle(
                fontFamily: KandooFonts.heading,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: KandooColors.textPrimary,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Kandoo looks through your library, opens what it needs and\n'
              'answers from what the documents actually say.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: KandooColors.textMuted),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final suggestion in suggestions)
                  _Suggestion(text: suggestion, onTap: () => onAsk(suggestion)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Suggestion extends StatefulWidget {
  const _Suggestion({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  State<_Suggestion> createState() => _SuggestionState();
}

class _SuggestionState extends State<_Suggestion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: _hovered ? KandooColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _hovered ? KandooColors.lineStrong : KandooColors.divider,
            ),
          ),
          child: Text(
            widget.text,
            style: const TextStyle(
              fontSize: 12.5,
              color: KandooColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One turn of the conversation.
class _Message extends StatelessWidget {
  const _Message({required this.message, required this.onOpen});

  final ChatMessage message;
  final ValueChanged<LibraryEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    if (message.isFromUser) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: KandooColors.selectedFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                message.text,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: KandooColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              message.isError
                  ? Icons.error_outline
                  : Icons.auto_awesome_outlined,
              size: 15,
              color: message.isError
                  ? const Color(0xFFC0392B)
                  : KandooColors.accentDeep,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.text,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: message.isError
                        ? const Color(0xFFC0392B)
                        : KandooColors.textPrimary,
                  ),
                ),
                if (message.sources.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final source in message.sources)
                        _SourceChip(
                          entry: source,
                          onTap: () => onOpen(source),
                        ),
                    ],
                  ),
                ],
                if (message.steps.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _Trace(steps: message.steps),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A file an answer was read out of, and the way into it.
class _SourceChip extends StatefulWidget {
  const _SourceChip({required this.entry, required this.onTap});

  final LibraryEntry entry;
  final VoidCallback onTap;

  @override
  State<_SourceChip> createState() => _SourceChipState();
}

class _SourceChipState extends State<_SourceChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          // The chip has room for the name; where it was filed and what it
          // came from belong in the tooltip.
          message:
              '${widget.entry.organizedPath}\n${widget.entry.file.sourceName}',
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _hovered ? KandooColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _hovered
                    ? KandooColors.lineStrong
                    : KandooColors.divider,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.insert_drive_file_outlined,
                  size: 13,
                  color: KandooColors.textMuted,
                ),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    widget.entry.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: KandooColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the assistant did on the way to the answer, folded away until asked
/// for.
class _Trace extends StatefulWidget {
  const _Trace({required this.steps});

  final List<ChatStep> steps;

  @override
  State<_Trace> createState() => _TraceState();
}

class _TraceState extends State<_Trace> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final looked = widget.steps
        .where((step) => step.kind != ChatStepKind.read)
        .length;
    final read = widget.steps
        .where((step) => step.kind == ChatStepKind.read)
        .length;

    final summary = [
      if (looked > 0) '$looked look${looked == 1 ? '' : 's'}',
      if (read > 0) '$read file${read == 1 ? '' : 's'} read',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 140),
                  child: const Icon(
                    Icons.chevron_right,
                    size: 15,
                    color: KandooColors.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  summary.isEmpty ? 'How this was answered' : summary,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: KandooColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(19, 6, 0, 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final step in widget.steps)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            _wordsFor(step),
                            style: TextStyle(
                              fontFamily: KandooFonts.mono,
                              fontSize: 11,
                              color: step.kind == ChatStepKind.failed
                                  ? const Color(0xFFC0392B)
                                  : KandooColors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  static String _wordsFor(ChatStep step) => switch (step.kind) {
    ChatStepKind.listed => 'listed  ${step.detail}',
    ChatStepKind.searched => 'searched  ${step.detail}',
    ChatStepKind.read => 'read  ${step.detail}',
    ChatStepKind.failed => 'could not read  ${step.detail}',
  };
}

/// The line that says the assistant is still working, and on what.
class _Working extends StatelessWidget {
  const _Working({required this.activity});

  final String? activity;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 2, 32, 10),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activity ?? 'Thinking…',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the question is typed.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() => _focused = widget.focusNode.hasFocus);

  /// Enter sends; shift-enter is a new line, as it is everywhere else a message
  /// is typed.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;

    widget.onSend();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.trim().isNotEmpty;
    final canSend = hasText && widget.enabled;

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
        decoration: BoxDecoration(
          color: KandooColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? KandooColors.accent : KandooColors.divider,
            width: _focused ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 1,
                  maxLines: 5,
                  cursorColor: KandooColors.accent,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: KandooColors.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                    hintText: 'Ask about your files',
                    hintStyle: TextStyle(
                      fontSize: 13.5,
                      color: KandooColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _SendButton(enabled: canSend, onTap: widget.onSend),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.only(bottom: 3),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: enabled ? KandooColors.accent : KandooColors.hoverFill,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            Icons.arrow_upward,
            size: 17,
            color: enabled ? Colors.white : KandooColors.textMuted,
          ),
        ),
      ),
    );
  }
}
