import '../library/library_store.dart';
import '../sources/google_drive_api.dart';
import 'document_reader.dart';
import 'text_extraction.dart';

/// Builds a way in to Drive, or returns null when the connection has gone.
///
/// A function rather than an API object: an access token lasts an hour, and a
/// conversation can easily run longer than the one it started with.
typedef DriveApiFactory = Future<GoogleDriveApi?> Function();

/// Reads a file that lives in Google Drive.
///
/// Two kinds of file end up here. A PDF or a text file is downloaded as it is
/// and read the same way its equivalent on disk would be. A Doc or a Sheet has
/// no bytes to download — it exists only inside Drive — so Drive is asked to
/// export it as plain text or CSV first.
class GoogleDriveDocumentReader extends DocumentReader {
  const GoogleDriveDocumentReader({
    required this.api,
    this.maxBytes = 12 * 1024 * 1024,
  });

  final DriveApiFactory api;

  /// The most this will pull down for one file.
  final int maxBytes;

  /// What Drive can turn each of its own formats into. A Drawing or a Form has
  /// nothing text-shaped to ask for, so neither is here.
  static const Map<String, String> exportable = {
    'application/vnd.google-apps.document': 'text/plain',
    'application/vnd.google-apps.spreadsheet': 'text/csv',
    'application/vnd.google-apps.presentation': 'text/plain',
  };

  @override
  String get sourceName => 'Google Drive';

  @override
  bool canRead(ScannedFile file) =>
      file.externalId != null && file.sourceName == sourceName;

  @override
  Future<DocumentText> read(ScannedFile file, {required int maxChars}) async {
    final id = file.externalId;
    if (id == null) {
      throw DocumentUnavailable('${file.name} is not a Google Drive file.');
    }

    final drive = await api();
    if (drive == null) {
      throw const DocumentUnavailable(
        'Google Drive is not connected — connect it again under Sources.',
      );
    }

    try {
      final info = await drive.info(id);

      if (info.isGoogleFormat) {
        final format = exportable[info.mimeType];
        if (format == null) {
          throw DocumentUnavailable(
            '${file.name} is a Google ${_kindOf(info.mimeType)}, which Kandoo '
            'cannot read as text.',
          );
        }

        final text = await drive.exportText(id, mimeType: format);
        // An export always comes back as text, so there is nothing to sniff:
        // an empty one means an empty document.
        if (text.trim().isEmpty) {
          throw DocumentUnavailable('${file.name} is empty.');
        }
        return DocumentText.trimmed(text, maxChars: maxChars);
      }

      // What Drive says the file is comes into it as well as what it is called:
      // a file printed straight into Drive is named for the moment it was made,
      // with no extension to go by.
      if (!TextExtraction.canRead(info.name, mimeType: info.mimeType)) {
        throw DocumentUnavailable(
          'Kandoo cannot read ${file.name} — it is not a kind of file it can '
          'turn into text.',
        );
      }

      final size = info.size;
      if (size != null && size > maxBytes) {
        throw DocumentUnavailable(
          '${file.name} is too large to read (${(size / 1024 / 1024).round()} '
          'MB).',
        );
      }

      final bytes = await drive.download(id, maxBytes: maxBytes);
      return DocumentText.trimmed(
        TextExtraction.of(bytes, name: info.name, mimeType: info.mimeType),
        maxChars: maxChars,
      );
    } on DriveException catch (failure) {
      // Drive's own messages already say what the user should do about it.
      throw DocumentUnavailable(failure.message);
    }
  }

  /// 'application/vnd.google-apps.drawing' as the user would say it.
  static String _kindOf(String mimeType) => mimeType.split('.').last;
}
