import 'package:url_launcher/url_launcher.dart' as launcher;

/// Hands a URL to the system: a file to whatever opens that kind of file, a
/// web address to the browser.
///
/// Named so it can be swapped in tests, which have no desktop to open onto.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> openWithSystem(Uri url) =>
    launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication);

/// Where a file on this Mac lives, for the system to open.
Uri localFileUrl(String path) => Uri.file(path);

/// The folder a path sits in, which is how Finder is asked to show it: macOS
/// opens a folder in a window, and the file is in it.
Uri enclosingFolderUrl(String path) {
  final cut = path.lastIndexOf('/');
  return Uri.file(cut <= 0 ? '/' : path.substring(0, cut));
}

/// Where a Notion page can be read, since a page is not a file to open. Notion
/// takes its ids with or without the dashes; without is what its own links use.
Uri notionPageUrl(String id) =>
    Uri.parse('https://www.notion.so/${id.replaceAll('-', '')}');

/// Where a Drive item can be looked at, since a Drive file is not on this Mac
/// to open.
Uri driveItemUrl(String id, {required bool isFolder}) => Uri.parse(
  isFolder
      ? 'https://drive.google.com/drive/folders/$id'
      : 'https://drive.google.com/file/d/$id/view',
);
