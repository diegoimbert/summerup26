import 'dart:convert';

/// Translates between markdown and Notion's block model.
///
/// Notion has no markdown endpoint: a page is a tree of typed block objects,
/// and text inside a block is an array of "rich text" runs carrying
/// annotations. Since the rest of the app speaks markdown, every read and
/// write goes through here.
///
/// The mapping is lossy in both directions — Notion has block types with no
/// markdown equivalent (databases, synced blocks, columns) and markdown has
/// constructs Notion flattens (nested emphasis, reference links). The subset
/// covered is the one that shows up in notes: headings, lists, to-dos, code,
/// quotes, callouts, dividers, images and links.
class NotionMarkdown {
  const NotionMarkdown._();

  /// Where [NotionSource] stashes eagerly-fetched child blocks, since Notion
  /// returns `has_children: true` but not the children themselves.
  static const childrenKey = '_children';

  /// Hard limits from the Notion API: a rich text run cannot exceed 2000
  /// characters, and one request cannot carry more than 100 blocks.
  static const maxTextLength = 2000;
  static const maxBlocksPerRequest = 100;

  /// Indent applied per nesting level when flattening children back to
  /// markdown. Two spaces keeps nested bullets valid CommonMark.
  static const _indent = '  ';

  // ---------------------------------------------------------------------
  // markdown -> blocks
  // ---------------------------------------------------------------------

  /// Parses [markdown] into Notion block objects ready to POST.
  ///
  /// Nesting is intentionally not reconstructed: an indented bullet becomes a
  /// top-level bullet rather than a child block. Round-tripping a deep
  /// outline therefore flattens it, which is a fair trade for not shipping a
  /// full markdown parser.
  static List<Map<String, dynamic>> toBlocks(String markdown) {
    final blocks = <Map<String, dynamic>>[];
    final paragraph = <String>[];
    final code = <String>[];
    var inFence = false;
    var fenceLanguage = '';

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_block('paragraph', {'rich_text': richText(paragraph.join('\n'))}));
      paragraph.clear();
    }

    void flushCode() {
      blocks.add(_block('code', {
        'rich_text': richText(code.join('\n'), literal: true),
        'language': _notionLanguage(fenceLanguage),
      }));
      code.clear();
    }

    for (final rawLine in const LineSplitter().convert(markdown)) {
      final line = rawLine.trimRight();
      final trimmed = line.trimLeft();

      if (inFence) {
        if (trimmed.startsWith('```')) {
          flushCode();
          inFence = false;
        } else {
          code.add(rawLine); // Indentation is content inside a fence.
        }
        continue;
      }

      if (trimmed.startsWith('```')) {
        flushParagraph();
        inFence = true;
        fenceLanguage = trimmed.substring(3).trim();
        continue;
      }

      if (trimmed.isEmpty) {
        flushParagraph();
        continue;
      }

      final block = _lineToBlock(trimmed);
      if (block != null) {
        flushParagraph();
        blocks.add(block);
        continue;
      }

      // Consecutive plain lines are one paragraph, as in markdown proper.
      paragraph.add(trimmed);
    }

    // An unterminated fence still holds real content; keep it rather than
    // dropping the tail of the document.
    if (inFence && code.isNotEmpty) flushCode();
    flushParagraph();
    return blocks;
  }

  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _divider = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
  static final _todo = RegExp(r'^[-*+]\s+\[([ xX])\]\s*(.*)$');
  static final _bullet = RegExp(r'^[-*+]\s+(.*)$');
  static final _numbered = RegExp(r'^\d+[.)]\s+(.*)$');
  static final _quote = RegExp(r'^>\s?(.*)$');

  static Map<String, dynamic>? _lineToBlock(String line) {
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      // Notion stops at three heading levels; deeper ones collapse to h3.
      final level = heading.group(1)!.length.clamp(1, 3);
      return _block('heading_$level', {'rich_text': richText(heading.group(2)!)});
    }

    if (_divider.hasMatch(line)) return _block('divider', const {});

    final todo = _todo.firstMatch(line);
    if (todo != null) {
      return _block('to_do', {
        'rich_text': richText(todo.group(2)!),
        'checked': todo.group(1)!.toLowerCase() == 'x',
      });
    }

    final bullet = _bullet.firstMatch(line);
    if (bullet != null) {
      return _block('bulleted_list_item', {'rich_text': richText(bullet.group(1)!)});
    }

    final numbered = _numbered.firstMatch(line);
    if (numbered != null) {
      return _block('numbered_list_item', {'rich_text': richText(numbered.group(1)!)});
    }

    final quote = _quote.firstMatch(line);
    if (quote != null) {
      return _block('quote', {'rich_text': richText(quote.group(1)!)});
    }

    return null;
  }

  static Map<String, dynamic> _block(String type, Map<String, dynamic> value) => {
        'object': 'block',
        'type': type,
        type: value,
      };

  /// Inline constructs, longest-first so `**bold**` is not eaten by the
  /// single-asterisk italic alternative.
  static final _inline = RegExp(
    r'\[([^\]]*)\]\(([^)\s]*)\)' // 1 label, 2 href
    r'|`([^`]+)`' // 3 code
    r'|\*\*([^*]+)\*\*' // 4 bold
    r'|__([^_]+)__' // 5 bold
    r'|~~([^~]+)~~' // 6 strikethrough
    r'|\*([^*]+)\*' // 7 italic
    r'|(?<![\w])_([^_]+)_(?![\w])', // 8 italic, not inside snake_case
  );

  /// Builds a Notion rich text array from an inline markdown string.
  ///
  /// [literal] skips inline parsing, for code blocks where `*` and `_` are
  /// just characters.
  static List<Map<String, dynamic>> richText(String text, {bool literal = false}) {
    if (text.isEmpty) return const [];
    if (literal) return _runs(text, const {});

    final runs = <Map<String, dynamic>>[];
    var cursor = 0;

    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        runs.addAll(_runs(text.substring(cursor, match.start), const {}));
      }

      if (match.group(1) != null) {
        runs.addAll(_runs(match.group(1)!, const {}, link: match.group(2)));
      } else if (match.group(3) != null) {
        runs.addAll(_runs(match.group(3)!, const {'code': true}));
      } else if (match.group(4) != null || match.group(5) != null) {
        runs.addAll(_runs(match.group(4) ?? match.group(5)!, const {'bold': true}));
      } else if (match.group(6) != null) {
        runs.addAll(_runs(match.group(6)!, const {'strikethrough': true}));
      } else {
        final italic = match.group(7) ?? match.group(8)!;
        runs.addAll(_runs(italic, const {'italic': true}));
      }

      cursor = match.end;
    }

    if (cursor < text.length) {
      runs.addAll(_runs(text.substring(cursor), const {}));
    }
    return runs;
  }

  /// One or more rich text objects for [text], split to respect Notion's
  /// 2000-character-per-run limit.
  static List<Map<String, dynamic>> _runs(
    String text,
    Map<String, bool> annotations, {
    String? link,
  }) {
    final runs = <Map<String, dynamic>>[];
    for (var start = 0; start < text.length; start += maxTextLength) {
      final end = (start + maxTextLength).clamp(0, text.length);
      runs.add({
        'type': 'text',
        'text': {
          'content': text.substring(start, end),
          if (link != null && link.isNotEmpty) 'link': {'url': link},
        },
        if (annotations.isNotEmpty) 'annotations': annotations,
      });
    }
    return runs;
  }

  /// Notion validates `language` against a fixed enum, so unknown fence
  /// labels have to fall back rather than be passed through.
  static String _notionLanguage(String fence) {
    const aliases = {
      'js': 'javascript',
      'jsx': 'javascript',
      'ts': 'typescript',
      'tsx': 'typescript',
      'py': 'python',
      'rb': 'ruby',
      'sh': 'shell',
      'zsh': 'shell',
      'bash': 'bash',
      'yml': 'yaml',
      'md': 'markdown',
      'rs': 'rust',
      'kt': 'kotlin',
      'cs': 'c#',
      'cpp': 'c++',
      'objc': 'objective-c',
    };
    const known = {
      'bash', 'c', 'c#', 'c++', 'css', 'dart', 'diff', 'docker', 'elixir',
      'go', 'graphql', 'html', 'java', 'javascript', 'json', 'kotlin', 'latex',
      'less', 'lua', 'makefile', 'markdown', 'matlab', 'nix', 'objective-c',
      'ocaml', 'perl', 'php', 'plain text', 'powershell', 'protobuf', 'python',
      'r', 'ruby', 'rust', 'scala', 'scss', 'shell', 'sql', 'swift', 'toml',
      'typescript', 'vb.net', 'xml', 'yaml',
    };

    final label = fence.toLowerCase().trim();
    final resolved = aliases[label] ?? label;
    return known.contains(resolved) ? resolved : 'plain text';
  }

  // ---------------------------------------------------------------------
  // blocks -> markdown
  // ---------------------------------------------------------------------

  /// Renders a block tree as markdown. Children are read from
  /// [childrenKey] when the caller has fetched them.
  static String fromBlocks(List<Map<String, dynamic>> blocks) {
    final buffer = StringBuffer();
    _render(blocks, buffer, 0);
    return buffer.toString().trimRight();
  }

  static void _render(
    List<Map<String, dynamic>> blocks,
    StringBuffer out,
    int depth,
  ) {
    final prefix = _indent * depth;
    var ordinal = 1;
    String? previousType;

    for (final block in blocks) {
      final type = block['type'] as String?;
      if (type == null) continue;
      final value = (block[type] as Map<String, dynamic>?) ?? const {};

      // Numbering restarts whenever a run of numbered items is broken.
      if (type == 'numbered_list_item') {
        if (previousType != 'numbered_list_item') ordinal = 1;
      }

      // Lists stay tight; everything else gets a blank line between blocks.
      final isList = _listTypes.contains(type);
      if (out.isNotEmpty) {
        out.write(isList && previousType == type ? '\n' : '\n\n');
      }

      switch (type) {
        case 'paragraph':
          out.write('$prefix${plainText(value)}');
        case 'heading_1':
          out.write('$prefix# ${plainText(value)}');
        case 'heading_2':
          out.write('$prefix## ${plainText(value)}');
        case 'heading_3':
          out.write('$prefix### ${plainText(value)}');
        case 'bulleted_list_item':
          out.write('$prefix- ${plainText(value)}');
        case 'numbered_list_item':
          out.write('$prefix${ordinal++}. ${plainText(value)}');
        case 'to_do':
          final checked = value['checked'] == true ? 'x' : ' ';
          out.write('$prefix- [$checked] ${plainText(value)}');
        case 'toggle':
          out.write('$prefix- ${plainText(value)}');
        case 'quote':
          out.write('$prefix> ${plainText(value)}');
        case 'callout':
          // The icon carries meaning (⚠️, 💡), so keep it inline.
          final icon = value['icon'];
          final emoji = icon is Map ? icon['emoji'] as String? : null;
          final marker = emoji == null ? '' : '$emoji ';
          out.write('$prefix> $marker${plainText(value)}');
        case 'code':
          final language = value['language'] as String? ?? '';
          final body = plainText(value);
          out.write('$prefix```$language\n$body\n$prefix```');
        case 'divider':
          out.write('$prefix---');
        case 'equation':
          out.write('$prefix\$\$${value['expression'] ?? ''}\$\$');
        case 'image':
        case 'video':
        case 'file':
        case 'pdf':
          out.write('$prefix${_renderFile(type, value)}');
        case 'bookmark':
        case 'embed':
        case 'link_preview':
          final url = value['url'] as String? ?? '';
          out.write('$prefix<$url>');
        case 'child_page':
          final title = value['title'] as String? ?? 'Untitled';
          final id = (block['id'] as String?)?.replaceAll('-', '') ?? '';
          out.write('$prefix- [$title](https://www.notion.so/$id)');
        case 'child_database':
          out.write('$prefix- ${value['title'] ?? 'Untitled database'} (database)');
        case 'table_of_contents':
        case 'breadcrumb':
        case 'unsupported':
          continue; // Nothing meaningful to render; skip without a gap.
        default:
          // Unknown or future block types: emit their text if they have any,
          // so content is never silently lost.
          final text = plainText(value);
          if (text.isEmpty) continue;
          out.write('$prefix$text');
      }

      final children = block[childrenKey];
      if (children is List && children.isNotEmpty) {
        out.write('\n');
        final rendered = StringBuffer();
        _render(children.cast<Map<String, dynamic>>(), rendered, depth + 1);
        out.write(rendered);
      }

      previousType = type;
    }
  }

  static const _listTypes = {
    'bulleted_list_item',
    'numbered_list_item',
    'to_do',
    'toggle',
  };

  static String _renderFile(String type, Map<String, dynamic> value) {
    final file = value['file'] ?? value['external'];
    final url = file is Map ? (file['url'] as String? ?? '') : '';
    final caption = _richTextToMarkdown(value['caption']);
    return type == 'image' ? '![$caption]($url)' : '[${caption.isEmpty ? type : caption}]($url)';
  }

  /// Markdown for a block's `rich_text` array, re-applying annotations.
  static String plainText(Map<String, dynamic> value) =>
      _richTextToMarkdown(value['rich_text']);

  static String _richTextToMarkdown(Object? richTextArray) {
    if (richTextArray is! List) return '';

    final buffer = StringBuffer();
    for (final item in richTextArray) {
      if (item is! Map) continue;
      var text = item['plain_text'] as String? ??
          (item['text'] is Map ? item['text']['content'] as String? ?? '' : '');
      if (text.isEmpty) continue;

      final annotations = item['annotations'];
      if (annotations is Map) {
        // Innermost first so markers nest correctly: ***`x`***.
        if (annotations['code'] == true) text = '`$text`';
        if (annotations['strikethrough'] == true) text = '~~$text~~';
        if (annotations['italic'] == true) text = '*$text*';
        if (annotations['bold'] == true) text = '**$text**';
      }

      final href = item['href'] as String? ??
          (item['text'] is Map && item['text']['link'] is Map
              ? item['text']['link']['url'] as String?
              : null);
      if (href != null && href.isNotEmpty) text = '[$text]($href)';

      buffer.write(text);
    }
    return buffer.toString();
  }
}
