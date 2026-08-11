import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'content_source.dart';
import 'exceptions.dart';
import 'models.dart';

/// An Obsidian vault, which is just a directory of markdown files on disk.
///
/// There is no Obsidian API to speak to — the vault format *is* the
/// interface, and Obsidian picks up external edits on its own. Node ids are
/// vault-relative POSIX paths (`Projects/Roadmap.md`), with the empty string
/// standing for the vault root. Ids therefore change when an item moves.
class ObsidianSource implements ContentSource {
  ObsidianSource({
    required String vaultPath,
    String? vaultName,
    this.defaultExtension = '.md',
    this.includeHidden = false,
  })  : _vaultPath = p.normalize(p.absolute(vaultPath)),
        _vaultName = vaultName ?? p.basename(p.normalize(vaultPath));

  final String _vaultPath;
  final String _vaultName;

  /// Appended by [create] when the requested name has no extension.
  final String defaultExtension;

  /// Whether to surface dot-files. Off by default so `.obsidian` (the vault's
  /// own config) and `.trash` stay out of pickers.
  final bool includeHidden;

  /// Extensions Obsidian itself treats as notes.
  static const _textExtensions = <String, String>{
    '.md': 'text/markdown',
    '.markdown': 'text/markdown',
    '.txt': 'text/plain',
    '.canvas': 'application/json',
    '.json': 'application/json',
    '.csv': 'text/csv',
  };

  @override
  String get providerId => 'obsidian:$_vaultName';

  @override
  String get displayName => 'Obsidian — $_vaultName';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities();

  String get vaultPath => _vaultPath;

  @override
  Future<void> verifyAccess() async {
    final dir = Directory(_vaultPath);
    if (!await dir.exists()) {
      throw IntegrationException(providerId, 'Vault not found at $_vaultPath');
    }
    // Existence is not access: a vault on an unmounted share or in a
    // sandbox-denied location fails only when actually read.
    try {
      await dir.list().first;
    } on StateError {
      // Empty vault — readable, just has nothing in it.
    } on FileSystemException catch (error) {
      throw PermissionException(
        providerId,
        'Vault at $_vaultPath is not readable: ${error.message}',
      );
    }
  }

  @override
  Future<List<Node>> children({String? parentId, int? limit}) async {
    final dir = Directory(_fsPath(parentId ?? ''));
    if (!await dir.exists()) {
      throw NodeNotFoundException(providerId, parentId ?? '');
    }

    final nodes = <Node>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;
      nodes.add(await _toNode(entity));
      if (limit != null && nodes.length >= limit) break;
    }

    // Directory listing order is filesystem-dependent; folders first then
    // alphabetical matches how Obsidian shows the file explorer.
    nodes.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return nodes;
  }

  @override
  Future<Node> stat(String id) async {
    final path = _fsPath(id);
    final type = await FileSystemEntity.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        return _toNode(File(path));
      case FileSystemEntityType.directory:
        return _toNode(Directory(path));
      default:
        throw NodeNotFoundException(providerId, id);
    }
  }

  @override
  Future<NodeContent> read(String id) async {
    final file = File(_fsPath(id));
    if (!await file.exists()) {
      if (await Directory(_fsPath(id)).exists()) {
        throw UnsupportedOperationException(
            providerId, 'Cannot read a folder: "$id"');
      }
      throw NodeNotFoundException(providerId, id);
    }

    try {
      return NodeContent(bytes: await file.readAsBytes(), mimeType: _mimeFor(id));
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
  }

  @override
  Future<Node> write(String id, NodeContent content) async {
    final file = File(_fsPath(id));
    if (!await file.exists()) throw NodeNotFoundException(providerId, id);
    await _writeBytes(file, content.bytes, id);
    return _toNode(file);
  }

  @override
  Future<Node> create({
    String? parentId,
    required String name,
    NodeContent? content,
  }) async {
    final fileName = _withExtension(_validName(name));
    final id = _childId(parentId, fileName);
    final file = File(_fsPath(id));

    if (await file.exists()) {
      throw ConflictException(providerId, 'A note named "$fileName" already exists');
    }

    await file.parent.create(recursive: true);
    await _writeBytes(file, content?.bytes ?? Uint8List(0), id);
    return _toNode(file);
  }

  @override
  Future<Node> createFolder({String? parentId, required String name}) async {
    final id = _childId(parentId, _validName(name));
    final dir = Directory(_fsPath(id));
    if (await dir.exists()) {
      throw ConflictException(providerId, 'A folder named "$name" already exists');
    }
    try {
      await dir.create(recursive: true);
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
    return _toNode(dir);
  }

  @override
  Future<Node> move(String id, {String? parentId, String? name}) async {
    if (parentId == null && name == null) return stat(id);

    final source = _fsPath(id);
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw NodeNotFoundException(providerId, id);
    }

    final newParent = parentId ?? p.posix.dirname(_normalizeId(id));
    final newName = name == null ? p.basename(source) : _validName(name);
    final targetId = _childId(newParent == '.' ? '' : newParent, newName);
    final target = _fsPath(targetId);

    if (source == target) return stat(id);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ConflictException(providerId, 'Something already exists at "$targetId"');
    }
    // Moving a folder into itself would detach the subtree from the vault.
    if (type == FileSystemEntityType.directory &&
        p.isWithin(source, target)) {
      throw IntegrationException(
          providerId, 'Cannot move "$id" into its own subtree');
    }

    try {
      await Directory(p.dirname(target)).create(recursive: true);
      final moved = type == FileSystemEntityType.directory
          ? await Directory(source).rename(target)
          : await File(source).rename(target);
      return _toNode(moved);
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
  }

  @override
  Future<void> delete(String id, {bool permanent = false}) async {
    final path = _fsPath(id);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw NodeNotFoundException(providerId, id);
    }

    if (!permanent) {
      await _moveToVaultTrash(id, path);
      return;
    }

    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
  }

  @override
  Future<List<Node>> search(String query, {int limit = 25}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];

    final byName = <Node>[];
    final byContent = <Node>[];

    await for (final entity
        in Directory(_vaultPath).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final id = _toId(entity.path);
      if (!includeHidden && _hasHiddenSegment(id)) continue;

      if (p.basename(id).toLowerCase().contains(needle)) {
        byName.add(await _toNode(entity));
      } else if (_textExtensions.containsKey(p.extension(id).toLowerCase())) {
        // Only text files are scanned; reading an attachment to grep it would
        // be pointless and slow.
        try {
          final body = await entity.readAsString();
          if (body.toLowerCase().contains(needle)) {
            byContent.add(await _toNode(entity));
          }
        } on FileSystemException {
          continue; // Unreadable file: skip rather than fail the whole search.
        }
      }

      if (byName.length >= limit) break;
    }

    // Name matches are near-always what the user meant, so they rank first.
    return [...byName, ...byContent].take(limit).toList();
  }

  @override
  Future<void> close() async {}

  /// Obsidian's own soft delete: files go to `.trash` inside the vault, where
  /// the app's "Deleted files" view can restore them.
  Future<void> _moveToVaultTrash(String id, String path) async {
    final trash = Directory(p.join(_vaultPath, '.trash'));
    await trash.create(recursive: true);

    var target = p.join(trash.path, p.basename(path));
    // Two notes with the same name deleted from different folders would
    // collide; suffix until free.
    var suffix = 1;
    while (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      final base = p.basenameWithoutExtension(path);
      target = p.join(trash.path, '$base ($suffix)${p.extension(path)}');
      suffix++;
    }

    try {
      if (await Directory(path).exists()) {
        await Directory(path).rename(target);
      } else {
        await File(path).rename(target);
      }
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
  }

  Future<void> _writeBytes(File file, Uint8List bytes, String id) async {
    try {
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (error) {
      throw _translate(error, id);
    }
  }

  Future<Node> _toNode(FileSystemEntity entity) async {
    final id = _toId(entity.path);
    final isDir = entity is Directory;
    FileStat? stats;
    try {
      stats = await entity.stat();
    } on FileSystemException {
      stats = null; // Raced with an external delete; report what we know.
    }

    final parent = p.posix.dirname(id);
    return Node(
      providerId: providerId,
      id: id,
      name: p.basename(id),
      kind: isDir ? NodeKind.folder : NodeKind.file,
      parentId: (parent == '.' || parent == id) ? null : parent,
      mimeType: isDir ? null : _mimeFor(id),
      sizeBytes: isDir ? null : stats?.size,
      modifiedAt: stats?.modified,
      hasChildren: isDir,
    );
  }

  /// Vault-relative POSIX id for an absolute filesystem path.
  String _toId(String fsPath) =>
      p.split(p.relative(p.normalize(fsPath), from: _vaultPath)).join('/');

  /// Absolute filesystem path for a node id, refusing anything that would
  /// escape the vault.
  String _fsPath(String id) {
    final normalized = _normalizeId(id);
    if (normalized.isEmpty || normalized == '.') return _vaultPath;

    final segments = normalized.split('/').where((s) => s.isNotEmpty);
    if (segments.contains('..')) {
      throw IntegrationException(providerId, 'Path escapes the vault: "$id"');
    }
    final resolved = p.joinAll([_vaultPath, ...segments]);

    // Belt and braces: symlinks and normalization quirks could still land
    // outside the vault.
    if (!p.equals(resolved, _vaultPath) && !p.isWithin(_vaultPath, resolved)) {
      throw IntegrationException(providerId, 'Path escapes the vault: "$id"');
    }
    return resolved;
  }

  /// Strips leading slashes so an absolute-looking id is read as
  /// vault-relative rather than rooted at the filesystem.
  String _normalizeId(String id) {
    final unified = id.replaceAll(r'\', '/');
    return p.posix.normalize(unified).replaceAll(RegExp(r'^/+'), '');
  }

  String _childId(String? parentId, String name) {
    final parent = _normalizeId(parentId ?? '');
    return (parent.isEmpty || parent == '.') ? name : '$parent/$name';
  }

  String _validName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw IntegrationException(providerId, 'Name cannot be empty');
    }
    if (trimmed.contains('/') || trimmed.contains(r'\')) {
      throw IntegrationException(
          providerId, 'Name cannot contain a path separator: "$name"');
    }
    if (trimmed == '.' || trimmed == '..') {
      throw IntegrationException(providerId, 'Invalid name: "$name"');
    }
    return trimmed;
  }

  String _withExtension(String name) =>
      p.extension(name).isEmpty ? '$name$defaultExtension' : name;

  bool _hasHiddenSegment(String id) =>
      id.split('/').any((segment) => segment.startsWith('.'));

  String _mimeFor(String id) =>
      _textExtensions[p.extension(id).toLowerCase()] ??
      'application/octet-stream';

  IntegrationException _translate(FileSystemException error, String id) {
    // errno 13 EACCES / 1 EPERM on POSIX, 5 ERROR_ACCESS_DENIED on Windows.
    const denied = {1, 5, 13};
    if (denied.contains(error.osError?.errorCode)) {
      return PermissionException(providerId, '${error.message} ("$id")');
    }
    if (error.osError?.errorCode == 2) {
      return NodeNotFoundException(providerId, id);
    }
    return IntegrationException(
      providerId,
      '${error.message} ("$id")',
      cause: error,
    );
  }
}
