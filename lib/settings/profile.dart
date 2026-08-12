import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// What Kandoo knows about the person using it.
///
/// A first name, so the app can say hello to somebody rather than to nobody.
/// It sits beside the connections and the library in Application Support, and
/// goes no further than this Mac.
class ProfileStore {
  const ProfileStore({this.directory, this.fileName = 'profile.json'});

  /// Overridden in tests; otherwise Application Support, as everywhere else.
  final Directory? directory;

  final String fileName;

  Future<File> _file() async {
    final home = directory ?? await getApplicationSupportDirectory();
    await home.create(recursive: true);
    return File('${home.path}/$fileName');
  }

  /// Where the profile is written, for display in Settings.
  Future<String> location() async => (await _file()).path;

  Future<String?> readFirstName() async {
    final file = await _file();
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      final name = (decoded as Map)['firstName'];
      return name is String && name.trim().isNotEmpty ? name.trim() : null;
    } catch (_) {
      // A corrupt profile costs a greeting, not a launch.
      return null;
    }
  }

  Future<void> writeFirstName(String? name) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        if (name != null && name.trim().isNotEmpty) 'firstName': name.trim(),
      }),
      flush: true,
    );
  }
}

/// Holds the user's own details for whatever wants to greet them.
class ProfileController extends ChangeNotifier {
  ProfileController({ProfileStore? store}) : _store = store ?? const ProfileStore();

  final ProfileStore _store;

  String? _firstName;

  /// What to call the user, or null while they have not said.
  String? get firstName => _firstName;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// True once the app has looked and found no name. The one thing Kandoo asks
  /// for on a first launch, and only then: everything else it works out for
  /// itself.
  bool get needsFirstName => _loaded && _firstName == null;

  Future<String> storeLocation() => _store.location();

  Future<void> load() async {
    _firstName = await _store.readFirstName();
    _loaded = true;
    notifyListeners();
  }

  /// Saves what the user wants to be called. An empty name clears it, which is
  /// how somebody takes their name back out of the app.
  Future<void> setFirstName(String? name) async {
    final trimmed = name?.trim();
    final kept = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (kept == _firstName && _loaded) return;

    await _store.writeFirstName(kept);
    _firstName = kept;
    _loaded = true;
    notifyListeners();
  }
}
