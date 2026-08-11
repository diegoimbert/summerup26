import 'models.dart';

/// One connected place the app can read and write documents.
///
/// The contract is deliberately filesystem-shaped — list, read, write, move,
/// delete — because that is the intersection of what Drive, Notion and a
/// local vault can all do. Markdown is the interchange format: every provider
/// accepts and returns it, converting to its native representation
/// (Drive files, Notion blocks, `.md` on disk) internally.
///
/// Ids are opaque strings scoped to the provider; never build one by hand
/// except for the root, which is `null`.
abstract class ContentSource {
  /// Stable key for this connection, e.g. `google_drive`, `notion`,
  /// `obsidian:Personal`. Used to route a [Node] back to its source.
  String get providerId;

  /// Human-facing name for settings and pickers.
  String get displayName;

  SourceCapabilities get capabilities;

  /// Checks that credentials/paths are usable. Throws the same exceptions as
  /// any other call, so settings screens can show a real error.
  Future<void> verifyAccess();

  /// Direct children of [parentId], or of the provider root when it is `null`.
  ///
  /// [limit] caps the number of items fetched across pages; `null` means walk
  /// every page.
  Future<List<Node>> children({String? parentId, int? limit});

  /// Metadata for a single node.
  Future<Node> stat(String id);

  /// Full content of [id]. Folders throw [UnsupportedOperationException].
  Future<NodeContent> read(String id);

  /// Replaces the content of an existing node and returns its refreshed
  /// metadata.
  Future<Node> write(String id, NodeContent content);

  /// Creates a new document under [parentId] (root when `null`).
  ///
  /// Providers do not deduplicate: Drive and Obsidian happily hold two items
  /// with the same name, so check [children] first if that matters.
  Future<Node> create({
    String? parentId,
    required String name,
    NodeContent? content,
  });

  Future<Node> createFolder({String? parentId, required String name});

  /// Moves and/or renames [id]. Passing only [name] renames in place; passing
  /// only [parentId] moves while keeping the name.
  Future<Node> move(String id, {String? parentId, String? name});

  /// Sends [id] to the provider's trash. [permanent] skips the trash where
  /// the provider supports it; Notion only ever archives.
  Future<void> delete(String id, {bool permanent = false});

  /// Full-text or name search, provider-defined. Ordering is whatever the
  /// provider considers most relevant.
  Future<List<Node>> search(String query, {int limit});

  /// Releases sockets/handles. Safe to call more than once.
  Future<void> close();
}

/// Text-first helpers, since most callers deal in markdown.
extension ContentSourceText on ContentSource {
  Future<String> readText(String id) async => (await read(id)).text;

  Future<Node> writeText(String id, String text) =>
      write(id, NodeContent.text(text));

  Future<Node> createText({
    String? parentId,
    required String name,
    String text = '',
  }) =>
      create(parentId: parentId, name: name, content: NodeContent.text(text));

  /// Appends to the end of an existing document, preserving what is there.
  ///
  /// Read-modify-write, so it is not safe against concurrent editors — good
  /// enough for appending a capture to a daily note, not for collaborative
  /// editing.
  Future<Node> appendText(String id, String text, {String separator = '\n'}) async {
    final existing = await readText(id);
    final joined = existing.isEmpty ? text : '$existing$separator$text';
    return writeText(id, joined);
  }
}
