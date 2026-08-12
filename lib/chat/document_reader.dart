import 'package:flutter/foundation.dart';

import '../library/library_store.dart';

/// What a reader got out of a file.
@immutable
class DocumentText {
  const DocumentText({required this.text, this.truncated = false});

  /// [text] cut to [maxChars], saying so when it had to be.
  ///
  /// Where the text came from makes no difference to how much of it a model is
  /// given, so every reader ends here.
  factory DocumentText.trimmed(String text, {required int maxChars}) =>
      text.length <= maxChars
      ? DocumentText(text: text)
      : DocumentText(text: text.substring(0, maxChars), truncated: true);

  final String text;

  /// True when the file was longer than the caller allowed, so what is here is
  /// the beginning of it rather than all of it. Worth saying out loud: an
  /// answer drawn from the first pages of a document is not the same as an
  /// answer drawn from the document.
  final bool truncated;
}

/// Thrown when a file cannot be turned into text.
///
/// The message is written for the model as much as for the user: it says which
/// file and why, so the assistant can go and look somewhere else rather than
/// give up on the question.
class DocumentUnavailable implements Exception {
  const DocumentUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens a file the library knows about and hands back its text.
///
/// A library entry says where a file was found but nothing about how to fetch
/// it: one lives on this Mac and another only exists inside somebody's Drive.
/// This is the seam between the two — the assistant asks for the contents of a
/// file, and the implementation that owns that kind of file answers.
///
/// Google Drive and the file system are what is implemented today. A new source
/// becomes readable by adding a [DocumentReader] for it and nothing else.
abstract class DocumentReader {
  const DocumentReader();

  /// The source this reader speaks for, as the user knows it.
  String get sourceName;

  /// Whether this reader is the one that owns [file].
  bool canRead(ScannedFile file);

  /// The text of [file], at most [maxChars] of it.
  ///
  /// Throws [DocumentUnavailable] when the file exists but cannot be made into
  /// text — a format Kandoo cannot parse, a scan with no text layer, a
  /// permission it does not have.
  Future<DocumentText> read(ScannedFile file, {required int maxChars});
}

/// The readers this build has, asked in turn.
class DocumentReaders {
  const DocumentReaders(this.readers);

  final List<DocumentReader> readers;

  /// The text of [file], from whichever reader owns it.
  Future<DocumentText> read(ScannedFile file, {int maxChars = 12000}) async {
    for (final reader in readers) {
      if (reader.canRead(file)) return reader.read(file, maxChars: maxChars);
    }

    throw DocumentUnavailable(
      '${file.name} is on ${file.sourceName}, which Kandoo cannot open yet.',
    );
  }
}
