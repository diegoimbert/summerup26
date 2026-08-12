import '../chat/drive_document_reader.dart' show DriveApiFactory;
import 'connections.dart';
import 'google_drive_api.dart';
import 'oauth.dart';

/// A way in to the user's Drive that renews itself.
///
/// An access token lasts an hour and the things Kandoo does with a drive —
/// answering a question, tidying a folder — can outlast one, so callers are
/// given a way to ask for a fresh API rather than an API.
DriveApiFactory driveApiFor(ConnectionsController connections) {
  return () async {
    try {
      final credentials = await connections.freshCredentials('google_drive');
      if (credentials == null) return null;
      return GoogleDriveApi(accessToken: credentials.accessToken);
    } on OAuthException {
      // A connection that will not renew is, as far as the caller is
      // concerned, no connection: it says so in its own words.
      return null;
    }
  };
}
