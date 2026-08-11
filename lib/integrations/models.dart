import 'dart:convert';
import 'dart:typed_data';

/// Whether a [Node] holds content or holds other nodes.
///
/// Providers that blur the line (a Notion page is both a document and a
/// container) are reported as [NodeKind.file]; use [Node.hasChildren] to know
/// whether it can also be listed.
enum NodeKind { file, folder }

/// A single addressable item in a provider: a Drive file, a Notion page, a
/// note or folder in an Obsidian vault.
///
/// [id] is opaque and only meaningful to the provider that produced it:
/// a Drive file id, a Notion page id, a vault-relative path.
class Node {
  const Node({
    required this.providerId,
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.mimeType,
    this.sizeBytes,
    this.modifiedAt,
    this.webUrl,
    this.hasChildren = false,
    this.raw = const <String, dynamic>{},
  });

  /// Id of the [ContentSource] this node came from.
  final String providerId;

  /// Provider-scoped identifier. Stable across reads for Drive and Notion;
  /// for Obsidian it is the vault-relative path, so it changes on move.
  final String id;

  /// Display name, e.g. `Meeting notes` or `todo.md`.
  final String name;

  final NodeKind kind;

  /// Parent container id, or `null` for the provider root.
  final String? parentId;

  /// Best-effort MIME type. Notes and pages report `text/markdown`.
  final String? mimeType;

  final int? sizeBytes;
  final DateTime? modifiedAt;

  /// Link that opens the item in its native app, when the provider exposes one.
  final String? webUrl;

  /// True when the node can be passed to `children()` even if it is a
  /// [NodeKind.file] (Notion pages nest).
  final bool hasChildren;

  /// Untouched provider payload, for callers that need a field this model
  /// does not expose.
  final Map<String, dynamic> raw;

  bool get isFolder => kind == NodeKind.folder;

  Node copyWith({
    String? id,
    String? name,
    NodeKind? kind,
    String? parentId,
    String? mimeType,
    int? sizeBytes,
    DateTime? modifiedAt,
    String? webUrl,
    bool? hasChildren,
    Map<String, dynamic>? raw,
  }) {
    return Node(
      providerId: providerId,
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      parentId: parentId ?? this.parentId,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      webUrl: webUrl ?? this.webUrl,
      hasChildren: hasChildren ?? this.hasChildren,
      raw: raw ?? this.raw,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Node && other.providerId == providerId && other.id == id;

  @override
  int get hashCode => Object.hash(providerId, id);

  @override
  String toString() => 'Node($providerId:$id, $name, ${kind.name})';
}

/// Bytes plus enough metadata to interpret them.
///
/// Text-shaped providers (Notion, Obsidian) always produce UTF-8 markdown;
/// Drive can produce anything, so content is carried as bytes and decoded on
/// demand via [text].
class NodeContent {
  const NodeContent({required this.bytes, this.mimeType});

  /// Wraps a UTF-8 string, defaulting to markdown — the interchange format
  /// used between providers.
  factory NodeContent.text(String text, {String mimeType = 'text/markdown'}) {
    return NodeContent(
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: mimeType,
    );
  }

  final Uint8List bytes;
  final String? mimeType;

  int get length => bytes.length;

  /// Decodes as UTF-8, replacing malformed sequences rather than throwing:
  /// a partially-corrupt note is more useful than an exception.
  String get text => utf8.decode(bytes, allowMalformed: true);

  /// Heuristic used to decide whether [text] is meaningful — Drive hands back
  /// PDFs and images through the same call as documents.
  bool get isText {
    final type = mimeType;
    if (type == null) return true;
    return type.startsWith('text/') ||
        type == 'application/json' ||
        type == 'application/xml' ||
        type.endsWith('+json') ||
        type.endsWith('+xml');
  }

  @override
  String toString() => 'NodeContent(${bytes.length} bytes, $mimeType)';
}

/// What a provider actually supports, so UI can hide what would only fail.
class SourceCapabilities {
  const SourceCapabilities({
    this.canWrite = true,
    this.canCreate = true,
    this.canMove = true,
    this.canRename = true,
    this.canDelete = true,
    this.canCreateFolders = true,
    this.canSearch = true,
    this.storesBinary = true,
  });

  final bool canWrite;
  final bool canCreate;
  final bool canMove;
  final bool canRename;
  final bool canDelete;
  final bool canCreateFolders;
  final bool canSearch;

  /// False for providers that can only hold text, i.e. Notion.
  final bool storesBinary;
}
