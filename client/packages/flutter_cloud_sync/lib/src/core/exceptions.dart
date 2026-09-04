/// Base exception for all cloud sync errors
class CloudSyncException implements Exception {
  final String message;
  final dynamic originalError;

  CloudSyncException(this.message, [this.originalError]);

  @override
  String toString() {
    if (originalError != null) {
      return 'CloudSyncException: $message (Original error: $originalError)';
    }
    return 'CloudSyncException: $message';
  }
}

/// Thrown when user is not authenticated
class CloudNotAuthenticatedException extends CloudSyncException {
  CloudNotAuthenticatedException([String? message])
      : super(message ?? 'User not authenticated');
}

/// Thrown when cloud service configuration is invalid
class CloudConfigurationException extends CloudSyncException {
  CloudConfigurationException(String message, [dynamic error])
      : super(message, error);
}

/// Thrown when storage operations fail
class CloudStorageException extends CloudSyncException {
  CloudStorageException(String message, [dynamic error])
      : super(message, error);
}

/// Thrown when authentication operations fail
class CloudAuthException extends CloudSyncException {
  CloudAuthException(String message, [dynamic error]) : super(message, error);
}
