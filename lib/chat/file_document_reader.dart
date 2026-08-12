import 'dart:io';
import 'dart:typed_data';

import '../library/library_store.dart';
import 'document_reader.dart';
import 'text_extraction.dart';

/// Reads a file that is on this Mac.
///
/// The simple case: the library already holds the path, so there is nothing to
/// fetch and nothing to authenticate — only the question of whether the bytes
/// are text.
class FileSystemDocumentReader extends DocumentReader {
  const FileSystemDocumentReader({this.maxBytes = 12 * 1024 * 1024});

  /// Past this, a file is not a document. Reading it would cost memory for
  /// something no model is going to be sent anyway.
  final int maxBytes;

  @override
  String get sourceName => 'File System';

  /// A file on this Mac is one the library found by path rather than by a
  /// source's own handle.
  @override
  bool canRead(ScannedFile file) => file.externalId == null;

  @override
  Future<DocumentText> read(ScannedFile file, {required int maxChars}) async {
    if (!TextExtraction.canRead(file.name)) {
      throw DocumentUnavailable(
        'Kandoo cannot read ${file.name} — it is not a kind of file it can '
        'turn into text.',
      );
    }

    final handle = File(file.path);

    final int length;
    try {
      length = await handle.length();
    } on FileSystemException {
      throw DocumentUnavailable('${file.name} is no longer on this Mac.');
    }

    if (length > maxBytes) {
      throw DocumentUnavailable(
        '${file.name} is too large to read (${(length / 1024 / 1024).round()} '
        'MB).',
      );
    }

    final Uint8List bytes;
    try {
      bytes = await handle.readAsBytes();
    } on FileSystemException catch (error) {
      throw DocumentUnavailable(
        error.osError?.errorCode == 13
            ? 'Kandoo is not allowed to read ${file.name}.'
            : '${file.name} could not be opened.',
      );
    }

    return DocumentText.trimmed(
      TextExtraction.of(bytes, name: file.name),
      maxChars: maxChars,
    );
  }
}
