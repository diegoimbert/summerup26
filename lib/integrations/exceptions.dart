/// Base class for every failure surfaced by a [ContentSource].
///
/// Providers translate their own error shapes (Drive's JSON error envelope,
/// Notion's `code` field, `dart:io` exceptions) into these so callers can
/// handle failures without knowing which backend they are talking to.
class IntegrationException implements Exception {
  IntegrationException(
    this.providerId,
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String providerId;
  final String message;

  /// HTTP status for remote providers, `null` for local ones.
  final int? statusCode;

  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' ($statusCode)';
    return '$runtimeType[$providerId]$status: $message';
  }
}

/// The item does not exist, or the caller has not been granted access to it.
///
/// Notion returns 404 for both cases by design, so the two are not
/// distinguishable there.
class NodeNotFoundException extends IntegrationException {
  NodeNotFoundException(super.providerId, this.nodeId, {super.statusCode})
      : super('No item with id "$nodeId"');

  final String nodeId;
}

/// Credentials are missing, expired beyond refresh, or rejected.
class AuthException extends IntegrationException {
  AuthException(super.providerId, super.message, {super.statusCode, super.cause});
}

/// Authenticated, but not allowed to perform this operation.
class PermissionException extends IntegrationException {
  PermissionException(super.providerId, super.message, {super.statusCode});
}

/// The provider cannot do this at all — moving a Notion page between
/// workspaces, storing a PNG in Notion, and so on.
class UnsupportedOperationException extends IntegrationException {
  UnsupportedOperationException(super.providerId, super.message);
}

/// Something already lives at the destination.
class ConflictException extends IntegrationException {
  ConflictException(super.providerId, super.message, {super.statusCode});
}

/// Throttled. [retryAfter] is populated when the provider tells us how long
/// to wait (Notion always does, Drive usually does not).
class RateLimitException extends IntegrationException {
  RateLimitException(super.providerId, super.message,
      {this.retryAfter, super.statusCode});

  final Duration? retryAfter;
}

/// Network trouble or a 5xx — worth retrying as-is.
class TransientException extends IntegrationException {
  TransientException(super.providerId, super.message,
      {super.statusCode, super.cause});
}
