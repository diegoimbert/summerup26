import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'document_reader.dart';

/// Turns the bytes of a file into text a model can read.
///
/// Only text is ever sent to DeepSeek, so every format has to come through
/// here. A format that cannot be read is refused by name — an answer built on
/// rubble decoded out of a binary file would still look like an answer, which
/// is worse than saying the file could not be opened.
abstract final class TextExtraction {
  /// Extensions whose bytes are already text.
  static const Set<String> textExtensions = {
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'yaml',
    'yml',
    'xml',
    'html',
    'htm',
    'log',
    'ini',
    'cfg',
    'conf',
    'toml',
    'rtf',
    'srt',
    'vtt',
    'tex',
  };

  /// Extensions that hold text but need unpacking first.
  static const Set<String> extractedExtensions = {'pdf'};

  /// Whether a file called [name] is one this can make text of at all.
  ///
  /// Asked before a file is fetched, so a spreadsheet or a photo costs nothing
  /// to rule out.
  static bool canRead(String name) {
    final extension = extensionOf(name);
    return textExtensions.contains(extension) ||
        extractedExtensions.contains(extension);
  }

  static String extensionOf(String name) {
    final cut = name.lastIndexOf('.');
    if (cut <= 0 || cut == name.length - 1) return '';
    return name.substring(cut + 1).toLowerCase();
  }

  /// The text of [bytes], which came from a file called [name].
  ///
  /// Throws [DocumentUnavailable] when the bytes are not something this knows
  /// how to read.
  static String of(Uint8List bytes, {required String name}) {
    final extension = extensionOf(name);

    if (extractedExtensions.contains(extension)) {
      final text = fromPdf(bytes);
      if (!_looksLikeProse(text)) {
        throw DocumentUnavailable(
          '$name is a PDF Kandoo could not read as text — it is probably a '
          'scan or an image.',
        );
      }
      return text;
    }

    final text = _decode(bytes);
    if (text == null) {
      throw DocumentUnavailable(
        'Kandoo cannot read '
        '${extension.isEmpty ? 'that kind of file' : '.$extension files'} '
        'yet ($name).',
      );
    }
    return text;
  }

  /// Bytes as characters, or null when they are plainly not text.
  static String? _decode(Uint8List bytes) {
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // Plenty of documents on a real disk are still in a single-byte encoding;
      // latin1 decodes any byte at all, so what it returns is judged below
      // rather than trusted.
      text = latin1.decode(bytes);
    }

    return _looksLikeProse(text) ? text : null;
  }

  /// Whether a string reads as writing rather than as decoded rubble.
  ///
  /// Binary files decode into control characters and stray symbols; anything a
  /// person wrote is mostly letters, digits, spaces and punctuation.
  static bool _looksLikeProse(String text) {
    if (text.trim().length < 16) return false;

    var readable = 0;
    for (final unit in text.codeUnits) {
      final isControl = unit < 32 && unit != 9 && unit != 10 && unit != 13;
      if (!isControl && unit != 0xFFFD) readable += 1;
    }

    return readable / text.codeUnits.length > 0.9;
  }

  // ---------------------------------------------------------------- PDF ----

  /// The text drawn by a PDF, in the order the file draws it.
  ///
  /// A PDF is a set of objects, and its text lives inside compressed content
  /// streams as arguments to the show-text operators. This inflates every
  /// stream it can and keeps what those operators were given, which is enough
  /// for the PDFs a person keeps — statements, invoices, tax returns — without
  /// taking on a font-decoding library. A PDF that defies it comes back as too
  /// little text to be prose, and is refused rather than guessed at.
  static String fromPdf(Uint8List bytes) {
    final out = StringBuffer();

    for (final stream in _streamsIn(bytes)) {
      final content = _inflate(stream);
      if (content == null) continue;
      _appendShownText(latin1.decode(content, allowInvalid: true), out);
    }

    return out
        .toString()
        // Positioning operators leave a lot of run-together spacing behind.
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The raw bytes between each `stream` / `endstream` pair.
  static Iterable<Uint8List> _streamsIn(Uint8List bytes) sync* {
    const stream = [115, 116, 114, 101, 97, 109]; // 'stream'
    const endStream = [101, 110, 100, 115, 116, 114, 101, 97, 109]; // 'endstream'

    var at = 0;
    while (true) {
      final open = _indexOf(bytes, stream, at);
      if (open < 0) return;

      // 'stream' is followed by CR LF or LF before the data begins.
      var start = open + stream.length;
      if (start < bytes.length && bytes[start] == 13) start += 1;
      if (start < bytes.length && bytes[start] == 10) start += 1;

      final close = _indexOf(bytes, endStream, start);
      if (close < 0) return;

      yield Uint8List.sublistView(bytes, start, close);
      at = close + endStream.length;
    }
  }

  /// [data] inflated, or [data] itself when it was never compressed.
  static Uint8List? _inflate(Uint8List data) {
    if (data.isEmpty) return null;

    for (final raw in [false, true]) {
      try {
        return Uint8List.fromList(ZLibDecoder(raw: raw).convert(data));
      } catch (_) {
        // Streams hold images and fonts as well as text; one that will not
        // inflate either way is simply not ours.
      }
    }

    return data;
  }

  /// Reads a content stream and appends whatever it draws to [out].
  ///
  /// Only what is inside a text object — between `BT` and `ET` — counts, and
  /// only once an operator has actually shown it. A PDF also carries fonts and
  /// colour profiles as streams, and those inflate into bytes that are full of
  /// bracketed rubble; nothing here is kept unless the file drew it on a page.
  ///
  /// Strings are collected as they are met and flushed by the operator that
  /// shows them, which is what makes `TJ` — an array of fragments and kerning
  /// numbers — come out as one run of words rather than as loose letters.
  static void _appendShownText(String content, StringBuffer out) {
    // A stream with no text object in it has nothing this wants.
    if (!content.contains('BT')) return;

    final pending = StringBuffer();
    var inText = false;
    var at = 0;

    /// Ends the current run of text. [newLine] for the operators that also
    /// move down the page.
    void flush({bool newLine = false}) {
      if (pending.isNotEmpty) {
        out.write(pending);
        pending.clear();
        if (!newLine) out.write(' ');
      }
      if (newLine) out.write('\n');
    }

    while (at < content.length) {
      final char = content[at];

      switch (char) {
        case '(':
          final (text, next) = _literalAt(content, at);
          // Outside a text object the string is an argument to something else
          // — a file name, a marked-content tag — and is stepped over rather
          // than kept.
          if (inText) pending.write(text);
          at = next;

        case '<':
          final (text, next) = _hexAt(content, at);
          if (inText) pending.write(text);
          at = next;

        case '%':
          // A comment runs to the end of the line.
          final end = content.indexOf('\n', at);
          at = end < 0 ? content.length : end + 1;

        // `'` and `"` both show a string and move to the next line.
        case "'" || '"':
          flush(newLine: true);
          at += 1;

        default:
          if (!_isLetter(char)) {
            at += 1;
            break;
          }

          final start = at;
          while (at < content.length && _isLetter(content[at])) {
            at += 1;
          }

          switch (content.substring(start, at)) {
            case 'BT':
              inText = true;
            case 'Tj' || 'TJ':
              flush();
            // 'T' is 'T*': the next line. 'Td' and 'TD' move the text position,
            // which in practice is also a new line.
            case 'T' || 'Td' || 'TD':
              flush(newLine: true);
            case 'ET':
              flush(newLine: true);
              inText = false;
          }
      }
    }

    // Anything still pending was never shown, so it was never text.
  }

  /// The PDF literal string starting at `content[at]`, and where it ends.
  static (String, int) _literalAt(String content, int at) {
    final text = StringBuffer();
    // Literals nest: '(a (b) c)' is one string.
    var depth = 0;
    var index = at;

    while (index < content.length) {
      final char = content[index];

      if (char == r'\') {
        index += 1;
        if (index >= content.length) break;
        final escaped = content[index];
        final unit = escaped.codeUnitAt(0);

        switch (escaped) {
          case 'n':
            text.write('\n');
          case 'r':
            text.write('\r');
          case 't':
            text.write('\t');
          case 'b' || 'f':
            text.write(' ');
          case '(' || ')' || r'\':
            text.write(escaped);
          // A backslash before a line break continues the string.
          case '\n' || '\r':
            break;
          default:
            if (unit >= 0x30 && unit <= 0x37) {
              final start = index;
              while (index < content.length &&
                  index - start < 3 &&
                  content.codeUnitAt(index) >= 0x30 &&
                  content.codeUnitAt(index) <= 0x37) {
                index += 1;
              }
              final octal = int.tryParse(
                content.substring(start, index),
                radix: 8,
              );
              if (octal != null) text.writeCharCode(octal);
              // The step below advances past the last digit read.
              index -= 1;
            } else {
              text.write(escaped);
            }
        }

        index += 1;
        continue;
      }

      if (char == '(') {
        depth += 1;
        if (depth > 1) text.write(char);
        index += 1;
        continue;
      }

      if (char == ')') {
        depth -= 1;
        index += 1;
        if (depth == 0) return (text.toString(), index);
        text.write(char);
        continue;
      }

      text.write(char);
      index += 1;
    }

    return (text.toString(), index);
  }

  /// The PDF hex string starting at `content[at]`, and where it ends.
  ///
  /// A hex string holds nothing but hex digits and space. Anything else means
  /// this `<` was never the start of one — a dictionary, or a byte that only
  /// looks like a bracket — and the character is stepped over instead.
  static (String, int) _hexAt(String content, int at) {
    final digits = StringBuffer();

    for (var index = at + 1; index < content.length; index += 1) {
      final char = content[index];
      if (char == '>') break;

      final unit = char.codeUnitAt(0);
      if (unit == 32 || unit == 9 || unit == 10 || unit == 13) continue;

      final isHex =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x46) ||
          (unit >= 0x61 && unit <= 0x66);
      if (!isHex) return ('', at + 1);

      digits.write(char);
    }

    final hex = digits.toString();
    final text = StringBuffer();
    for (var index = 0; index + 1 < hex.length; index += 2) {
      text.writeCharCode(int.parse(hex.substring(index, index + 2), radix: 16));
    }

    final end = content.indexOf('>', at);
    return (text.toString(), end < 0 ? content.length : end + 1);
  }

  static bool _isLetter(String char) {
    final unit = char.codeUnitAt(0);
    return (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);
  }

  static int _indexOf(Uint8List haystack, List<int> needle, int from) {
    final last = haystack.length - needle.length;
    outer:
    for (var start = from; start <= last; start += 1) {
      for (var offset = 0; offset < needle.length; offset += 1) {
        if (haystack[start + offset] != needle[offset]) continue outer;
      }
      return start;
    }
    return -1;
  }
}
