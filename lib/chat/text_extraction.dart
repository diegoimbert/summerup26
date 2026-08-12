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

  /// What a media type stands for, where the type is not already the name of
  /// one — `text/anything` is text, and needs no entry here.
  static const Map<String, String> typeExtensions = {
    'application/pdf': 'pdf',
    'application/json': 'json',
    'application/xml': 'xml',
    'application/rtf': 'rtf',
    'application/yaml': 'yaml',
    'application/x-yaml': 'yaml',
    'application/toml': 'toml',
  };

  /// Whether a file called [name] is one this can make text of at all.
  ///
  /// Asked before a file is fetched, so a spreadsheet or a photo costs nothing
  /// to rule out.
  static bool canRead(String name, {String? mimeType}) {
    final extension = extensionFor(name, mimeType: mimeType);
    return textExtensions.contains(extension) ||
        extractedExtensions.contains(extension);
  }

  /// What kind of file this is, by its name where the name says, and by what
  /// the source calls it where it does not.
  ///
  /// Drive lets a file be called anything: a PDF printed straight into it is
  /// called something like `diego CDI - 3/25/25, 6:58 PM` — slashes and all,
  /// with no extension anywhere. Going by the name alone, a file like that
  /// would be turned away without ever being opened.
  static String extensionFor(String name, {String? mimeType}) {
    final named = extensionOf(name);
    if (textExtensions.contains(named) || extractedExtensions.contains(named)) {
      return named;
    }
    return _extensionForType(mimeType);
  }

  static String _extensionForType(String? mimeType) {
    if (mimeType == null) return '';

    // 'text/plain; charset=utf-8' is the same type as 'text/plain'.
    final type = mimeType.split(';').first.trim().toLowerCase();
    final known = typeExtensions[type];
    if (known != null) return known;

    return type.startsWith('text/') ? 'txt' : '';
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
  static String of(Uint8List bytes, {required String name, String? mimeType}) {
    final extension = extensionFor(name, mimeType: mimeType);

    if (extractedExtensions.contains(extension)) {
      final text = fromPdf(bytes);
      if (!_looksLikeProse(text)) {
        throw DocumentUnavailable(
          '$name is a PDF Kandoo could not read as text — it is probably a '
          'scan, or drawn in fonts that do not say what they spell.',
        );
      }
      return text;
    }

    final text = _decode(bytes);
    if (text == null) {
      // Said with the extension the file was called by, which is the part the
      // user would recognise.
      final named = extensionOf(name);
      throw DocumentUnavailable(
        'Kandoo cannot read '
        '${named.isEmpty ? 'that kind of file' : '.$named files'} '
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
  ///
  /// What a string holds is not the text, though: with the subset fonts nearly
  /// every producer now embeds, the bytes are numbers for glyphs in that one
  /// font, and it is the font's `/ToUnicode` map that says which letters those
  /// glyphs stand for. So the objects are parsed far enough to find each page's
  /// fonts, and the strings are read through them.
  static String fromPdf(Uint8List bytes) {
    final objects = _objectsIn(bytes);
    final out = StringBuffer();

    if (objects.isEmpty) {
      // Nothing parsed as an object. Read every stream in the file instead,
      // which is what a PDF too malformed to walk still gives up.
      for (final stream in _streamsIn(bytes)) {
        final content = _inflate(stream);
        if (content == null) continue;
        _appendShownText(
          latin1.decode(content, allowInvalid: true),
          out,
          const {},
        );
      }
      return _tidied(out.toString());
    }

    final fonts = _fontsByStream(objects);

    for (final object in objects.values) {
      final stream = object.stream;
      if (stream == null) continue;
      final content = _inflate(stream);
      if (content == null) continue;
      _appendShownText(
        latin1.decode(content, allowInvalid: true),
        out,
        fonts[object.number] ?? const {},
      );
    }

    return _tidied(out.toString());
  }

  /// Spacing left behind by operators that move around the page.
  static String _tidied(String text) => text
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  /// Every `N G obj … endobj` in the file, by object number and in file order.
  ///
  /// The bytes are read as latin1 so that a character index is a byte offset,
  /// which is what lets a stream be sliced back out of [bytes] unchanged.
  static Map<int, _PdfObject> _objectsIn(Uint8List bytes) {
    final text = latin1.decode(bytes, allowInvalid: true);
    final objects = <int, _PdfObject>{};

    for (final match in RegExp(r'(\d+)\s+\d+\s+obj\b').allMatches(text)) {
      final number = int.tryParse(match.group(1)!);
      if (number == null) continue;

      final from = match.end;
      var end = text.indexOf('endobj', from);
      if (end < 0) end = text.length;

      final streamAt = text.indexOf('stream', from);
      final hasStream = streamAt >= 0 && streamAt < end;

      Uint8List? stream;
      if (hasStream) {
        // 'stream' is followed by CR LF or LF before the data begins.
        var start = streamAt + 'stream'.length;
        if (start < bytes.length && bytes[start] == 13) start += 1;
        if (start < bytes.length && bytes[start] == 10) start += 1;

        final close = text.indexOf('endstream', start);
        if (close > start) stream = Uint8List.sublistView(bytes, start, close);
      }

      objects[number] = _PdfObject(
        number: number,
        dict: text.substring(from, hasStream ? streamAt : end),
        stream: stream,
      );
    }

    _unpackObjectStreams(objects);
    return objects;
  }

  /// Adds the objects that a PDF 1.5 file packs away inside `/ObjStm` streams.
  ///
  /// Fonts are usually in there, so a file whose object streams stayed shut
  /// would come back as glyph numbers however well the rest went.
  static void _unpackObjectStreams(Map<int, _PdfObject> objects) {
    for (final holder in objects.values.toList()) {
      final stream = holder.stream;
      if (stream == null || !holder.dict.contains('/ObjStm')) continue;

      final data = _inflate(stream);
      if (data == null) continue;
      final content = latin1.decode(data, allowInvalid: true);

      final count = _numberFor(holder.dict, '/N');
      final first = _numberFor(holder.dict, '/First');
      if (count == null || first == null || first > content.length) continue;

      // The stream opens with `number offset` pairs, then the objects
      // themselves, each starting at /First plus its offset.
      final header = content
          .substring(0, first)
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .toList();

      for (var pair = 0; pair < count; pair += 1) {
        final at = pair * 2;
        if (at + 1 >= header.length) break;

        final number = header[at];
        final offset = header[at + 1];
        if (number == null || offset == null) continue;
        // An object written out in full is the newer one; this is a fallback.
        if (objects.containsKey(number)) continue;

        final start = first + offset;
        final next = at + 3 < header.length ? header[at + 3] : null;
        final end = next == null ? content.length : first + next;
        if (start >= content.length || end <= start) continue;

        objects[number] = _PdfObject(
          number: number,
          dict: content.substring(start, end.clamp(start, content.length)),
        );
      }
    }
  }

  /// The fonts each content stream draws with, by the number of the object
  /// that holds the stream.
  ///
  /// A page hands its resources to the streams it names as its contents, and a
  /// form XObject — a header, a letterhead — is a stream carrying its own.
  static Map<int, Map<String, _Glyphs>> _fontsByStream(
    Map<int, _PdfObject> objects,
  ) {
    final read = <int, _Glyphs?>{};
    _Glyphs? glyphsOf(int number) {
      final font = objects[number];
      if (font == null) return null;
      return read.putIfAbsent(number, () => _glyphsFor(font, objects));
    }

    final byStream = <int, Map<String, _Glyphs>>{};

    for (final object in objects.values) {
      final isPage = RegExp(r'/Type\s*/Page[^s]').hasMatch(object.dict);
      if (!isPage && object.stream == null) continue;

      final resources = _resourcesOf(object, objects);
      if (resources == null) continue;

      final fonts = _fontsIn(resources, objects, glyphsOf);
      if (fonts.isEmpty) continue;

      if (object.stream != null) byStream[object.number] = fonts;
      for (final content in _contentsOf(object.dict)) {
        byStream[content] = fonts;
      }
    }

    return byStream;
  }

  /// The object numbers a page names as its contents, which is one stream or
  /// an array of them.
  static Iterable<int> _contentsOf(String dict) sync* {
    final at = _valueAt(dict, '/Contents');
    if (at < 0) return;

    final rest = dict.substring(at);
    final single = RegExp(r'^(\d+)\s+\d+\s+R').firstMatch(rest);
    if (single != null) {
      yield int.parse(single.group(1)!);
      return;
    }

    if (!rest.startsWith('[')) return;
    final close = rest.indexOf(']');
    if (close < 0) return;
    for (final ref in RegExp(
      r'(\d+)\s+\d+\s+R',
    ).allMatches(rest.substring(0, close))) {
      yield int.parse(ref.group(1)!);
    }
  }

  /// The `/Resources` dictionary that applies to [object].
  ///
  /// A page can leave its resources to the page tree above it, so an absent one
  /// is looked for up the `/Parent` chain rather than given up on.
  static String? _resourcesOf(
    _PdfObject object,
    Map<int, _PdfObject> objects, {
    int depth = 0,
  }) {
    final own = _dictValue(object.dict, '/Resources', objects);
    if (own != null || depth > 8) return own;

    final parent = _refFor(object.dict, '/Parent');
    final above = parent == null ? null : objects[parent];
    return above == null
        ? null
        : _resourcesOf(above, objects, depth: depth + 1);
  }

  /// The fonts a resources dictionary names, as `/F4` to what `/F4` can spell.
  static Map<String, _Glyphs> _fontsIn(
    String resources,
    Map<int, _PdfObject> objects,
    _Glyphs? Function(int) glyphsOf,
  ) {
    final dict = _dictValue(resources, '/Font', objects);
    if (dict == null) return const {};

    final fonts = <String, _Glyphs>{};
    for (final entry in RegExp(
      r'/([A-Za-z0-9#+._-]+)\s+(\d+)\s+\d+\s+R',
    ).allMatches(dict)) {
      final glyphs = glyphsOf(int.parse(entry.group(2)!));
      if (glyphs != null) fonts[entry.group(1)!] = glyphs;
    }

    return fonts;
  }

  /// What one font's strings say, or null when its bytes are already the text.
  static _Glyphs? _glyphsFor(_PdfObject font, Map<int, _PdfObject> objects) {
    // Not every producer writes `/Type /Font`, but a font always names the one
    // it was cut from.
    if (!font.dict.contains('/Font') && !font.dict.contains('/BaseFont')) {
      return null;
    }

    // Identity encodings address glyphs two bytes at a time, and mean nothing
    // at all without the map below.
    final identity = font.dict.contains('/Identity-H') ||
        font.dict.contains('/Identity-V');

    final toUnicode = _refFor(font.dict, '/ToUnicode');
    final stream = toUnicode == null ? null : objects[toUnicode]?.stream;
    final data = stream == null ? null : _inflate(stream);

    if (data == null) {
      // A simple font's bytes are usually its characters already; a subset font
      // with no map is glyph numbers, and there is no reading those.
      return identity ? const _Glyphs(twoByte: true, map: {}) : null;
    }

    return _cmapIn(latin1.decode(data, allowInvalid: true), identity: identity);
  }

  /// A `/ToUnicode` CMap: which characters each code in a font stands for.
  static _Glyphs _cmapIn(String cmap, {required bool identity}) {
    var twoByte = identity;

    final codespace = RegExp(
      r'begincodespacerange([\s\S]*?)endcodespacerange',
    ).firstMatch(cmap);
    if (codespace != null) {
      final low = RegExp(r'<([0-9A-Fa-f]+)>').firstMatch(codespace.group(1)!);
      if (low != null) twoByte = low.group(1)!.length > 2;
    }

    final map = <int, String>{};

    for (final block in RegExp(
      r'beginbfchar([\s\S]*?)endbfchar',
    ).allMatches(cmap)) {
      for (final pair in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>',
      ).allMatches(block.group(1)!)) {
        final code = int.tryParse(pair.group(1)!, radix: 16);
        if (code != null) map[code] = _charactersIn(pair.group(2)!);
      }
    }

    for (final block in RegExp(
      r'beginbfrange([\s\S]*?)endbfrange',
    ).allMatches(cmap)) {
      for (final range in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:<([0-9A-Fa-f]*)>|\[([\s\S]*?)\])',
      ).allMatches(block.group(1)!)) {
        final low = int.tryParse(range.group(1)!, radix: 16);
        final high = int.tryParse(range.group(2)!, radix: 16);
        if (low == null || high == null || high < low) continue;
        // A range covering the whole of a two-byte space is a producer being
        // careless, not sixty thousand characters worth reading.
        if (high - low > 0xFFFF) continue;

        final from = range.group(3);
        final list = range.group(4);

        if (from != null) {
          // The range counts up from one character, one per code.
          final units = _unitsIn(from);
          if (units.isEmpty) continue;
          for (var code = low; code <= high; code += 1) {
            map[code] = String.fromCharCodes([
              ...units.take(units.length - 1),
              units.last + code - low,
            ]);
          }
          continue;
        }

        if (list == null) continue;
        var code = low;
        for (final item in RegExp(r'<([0-9A-Fa-f]*)>').allMatches(list)) {
          if (code > high) break;
          map[code] = _charactersIn(item.group(1)!);
          code += 1;
        }
      }
    }

    return _Glyphs(twoByte: twoByte, map: map);
  }

  /// A CMap destination — UTF-16 written out in hex — as the text it stands for.
  static String _charactersIn(String hex) =>
      String.fromCharCodes(_unitsIn(hex));

  static List<int> _unitsIn(String hex) {
    if (hex.isEmpty) return const [];
    if (hex.length <= 2) {
      final value = int.tryParse(hex, radix: 16);
      return value == null ? const [] : [value];
    }

    final units = <int>[];
    for (var at = 0; at + 4 <= hex.length; at += 4) {
      final value = int.tryParse(hex.substring(at, at + 4), radix: 16);
      if (value != null) units.add(value);
    }
    return units;
  }

  /// Where the value of [key] starts in [dict], or -1 when it is not there.
  static int _valueAt(String dict, String key) {
    final at = RegExp('$key(?![A-Za-z0-9])\\s*').firstMatch(dict);
    return at == null ? -1 : at.end;
  }

  /// The object number `/Key 12 0 R` points at.
  static int? _refFor(String dict, String key) {
    final at = _valueAt(dict, key);
    if (at < 0) return null;
    final ref = RegExp(r'^(\d+)\s+\d+\s+R').firstMatch(dict.substring(at));
    return ref == null ? null : int.tryParse(ref.group(1)!);
  }

  static int? _numberFor(String dict, String key) {
    final at = _valueAt(dict, key);
    if (at < 0) return null;
    final value = RegExp(r'^(\d+)').firstMatch(dict.substring(at));
    return value == null ? null : int.tryParse(value.group(1)!);
  }

  /// The dictionary under [key], whether it is written out or referred to.
  static String? _dictValue(
    String dict,
    String key,
    Map<int, _PdfObject> objects,
  ) {
    final at = _valueAt(dict, key);
    if (at < 0) return null;

    final rest = dict.substring(at);
    if (rest.startsWith('<<')) return _balanced(rest);

    final ref = RegExp(r'^(\d+)\s+\d+\s+R').firstMatch(rest);
    if (ref == null) return null;

    final target = objects[int.parse(ref.group(1)!)];
    if (target == null) return null;

    final start = target.dict.indexOf('<<');
    return start < 0 ? null : _balanced(target.dict.substring(start));
  }

  /// A dictionary starting at `<<`, up to the `>>` that closes it.
  static String? _balanced(String text) {
    var depth = 0;
    for (var at = 0; at + 1 < text.length; at += 1) {
      if (text.startsWith('<<', at)) {
        depth += 1;
        at += 1;
      } else if (text.startsWith('>>', at)) {
        depth -= 1;
        if (depth == 0) return text.substring(0, at + 2);
        at += 1;
      }
    }
    return null;
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
  ///
  /// Lines are told apart by where text lands, not by the operators used to get
  /// there. A file may draw a paragraph in one go, or set a matrix and a fresh
  /// offset for every single word — Google's exports do the latter — and only
  /// the baseline the text actually sits on tells those apart from a real line.
  ///
  /// [fonts] says what the strings drawn with each font actually spell. A font
  /// that is not in it draws its own bytes, which is how the plainer PDFs work.
  static void _appendShownText(
    String content,
    StringBuffer out,
    Map<String, _Glyphs> fonts,
  ) {
    // A stream with no text object in it has nothing this wants.
    if (!content.contains('BT')) return;

    final pending = StringBuffer();
    var inText = false;
    var inArray = false;
    var at = 0;

    // A line break is owed rather than written, so that moving about the page
    // without drawing anything does not leave blank lines behind.
    var owedBreak = false;
    var written = false;

    _Glyphs? font;
    String? named;
    // The numbers an operator was given, oldest first.
    final operands = <double>[];

    // The text line matrix, as far as how far down the page it puts things:
    // the baseline itself, and the two terms that move it.
    var my = 0.0, mb = 0.0, md = 1.0;
    // How far down the page one line is from the next.
    var leading = 0.0;
    // The baseline the last drawn text sat on.
    double? drawnAt;
    // Whether what is drawn next opens a text object of its own.
    var newRun = false;

    void write(String text) {
      if (text.isEmpty) return;
      if (owedBreak && written) out.write('\n');
      owedBreak = false;
      out.write(text);
      written = true;
    }

    void breakLine() => owedBreak = true;

    /// Draws what has been collected, starting a line first if it does not
    /// belong on the one before it.
    void show() {
      if (pending.isEmpty) return;

      // Half a unit of slack: what sits a hair off the baseline — a comma, a
      // font a shade larger — is still on that line.
      if (drawnAt != null && (my - drawnAt!).abs() > 0.5) {
        breakLine();
      } else if (newRun && written) {
        // Same line, but a text object of its own: another cell of a table,
        // another word in a file that positions each one. Whatever it is, it
        // did not carry on from the last, so it does not read as one word with
        // it. Moving about inside a single text object is a different matter —
        // that is a file spacing out the glyphs of one word.
        write(' ');
      }

      write(pending.toString());
      pending.clear();
      drawnAt = my;
      newRun = false;
    }

    /// Moves the line along by [tx] and down by [ty], as `Td` does.
    void move(double tx, double ty) => my += mb * tx + md * ty;

    while (at < content.length) {
      final char = content[at];

      switch (char) {
        case '(':
          final (text, next) = _literalAt(content, at);
          // Outside a text object the string is an argument to something else
          // — a file name, a marked-content tag — and is stepped over rather
          // than kept.
          if (inText) pending.write(_spelled(text, font));
          at = next;

        case '<':
          final (text, next) = _hexAt(content, at);
          if (inText) pending.write(_spelled(text, font));
          at = next;

        case '%':
          // A comment runs to the end of the line.
          final end = content.indexOf('\n', at);
          at = end < 0 ? content.length : end + 1;

        case '[':
          inArray = true;
          at += 1;

        case ']':
          inArray = false;
          at += 1;

        // `'` and `"` both move to the next line and show a string there.
        case "'" || '"':
          if (leading != 0) {
            move(0, -leading);
          } else {
            breakLine();
          }
          show();
          at += 1;

        default:
          if (_isNumber(char)) {
            final start = at;
            while (at < content.length && _isNumber(content[at])) {
              at += 1;
            }
            final value = double.tryParse(content.substring(start, at));
            if (value != null) {
              operands.add(value);
              // Inside a `TJ` array the numbers close up the space between
              // fragments. A large one is not kerning — it is a word gap the
              // file draws by moving rather than by a space.
              if (inArray && inText && value <= -120 && pending.isNotEmpty) {
                pending.write(' ');
              }
            }
            break;
          }

          if (char == '/') {
            final start = at + 1;
            at = start;
            while (at < content.length && _isNameCharacter(content[at])) {
              at += 1;
            }
            named = content.substring(start, at);
            break;
          }

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
              newRun = true;
              // A text object starts from nothing, whatever the last one did.
              my = 0.0;
              mb = 0.0;
              md = 1.0;
            case 'Tj' || 'TJ':
              show();
            case 'Tf':
              font = fonts[named];
            case 'Td' || 'TD':
              if (operands.length >= 2) {
                move(operands[operands.length - 2], operands.last);
              }
              if (content.substring(start, at) == 'TD' &&
                  operands.length >= 2) {
                leading = -operands.last;
              }
            case 'TL':
              if (operands.isNotEmpty) leading = operands.last;
            // 'T' is 'T*': down to the next line.
            case 'T':
              if (leading != 0) {
                move(0, -leading);
              } else {
                breakLine();
              }
            case 'Tm':
              if (operands.length >= 6) {
                final six = operands.length - 6;
                mb = operands[six + 1];
                md = operands[six + 3];
                my = operands[six + 5];
              }
            // Ending a text object is not the end of a line: a producer that
            // positions every word draws each one in its own, and breaking
            // there would leave a page one word wide.
            case 'ET':
              show();
              inText = false;
          }

          operands.clear();
      }
    }

    // Anything still pending was never shown, so it was never text.

    // Whatever is drawn next belongs to another page, or to another thing on
    // this one, and starts its own line.
    if (written) out.write('\n');
  }

  /// What a string drawn in [font] spells.
  ///
  /// Without a font, or with one whose bytes are its characters, the string is
  /// already the text. A subset font's are numbers for glyphs, and the ones its
  /// map does not cover are dropped: a glyph nobody can name is not a letter,
  /// and guessing at it would put words in the file's mouth.
  static String _spelled(String raw, _Glyphs? font) {
    if (font == null) return raw;
    if (font.map.isEmpty) return font.twoByte ? '' : raw;

    final text = StringBuffer();
    final width = font.twoByte ? 2 : 1;

    for (var at = 0; at + width <= raw.length; at += width) {
      final code = width == 2
          ? (raw.codeUnitAt(at) << 8) | raw.codeUnitAt(at + 1)
          : raw.codeUnitAt(at);

      final spelled = font.map[code];
      if (spelled != null) {
        text.write(spelled);
      } else if (width == 1) {
        // A single-byte font with gaps in its map is still using the character
        // its byte stands for.
        text.writeCharCode(code);
      }
    }

    return text.toString();
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

  /// A character a number can be written with, sign and point included.
  static bool _isNumber(String char) {
    final unit = char.codeUnitAt(0);
    return (unit >= 48 && unit <= 57) || char == '-' || char == '+' ||
        char == '.';
  }

  /// A character a PDF name can hold, as in `/F4` or `/TT1+0`.
  static bool _isNameCharacter(String char) {
    final unit = char.codeUnitAt(0);
    return (unit >= 48 && unit <= 57) ||
        (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        char == '+' ||
        char == '-' ||
        char == '.' ||
        char == '_' ||
        char == '#';
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

/// One `N G obj … endobj` out of a PDF: what it says, and what it holds.
class _PdfObject {
  const _PdfObject({required this.number, required this.dict, this.stream});

  final int number;

  /// The object itself, as written — everything before any `stream` keyword.
  final String dict;

  /// The bytes between `stream` and `endstream`, still as the file stored them.
  final Uint8List? stream;
}

/// What the strings drawn in one font spell.
class _Glyphs {
  const _Glyphs({required this.twoByte, required this.map});

  /// Whether codes are two bytes wide, as they are under an identity encoding.
  final bool twoByte;

  /// Each code, and the characters it stands for. Empty when the font said
  /// nothing about what its glyphs mean.
  final Map<int, String> map;
}
