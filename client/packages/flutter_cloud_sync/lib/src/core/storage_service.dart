import 'package:meta/meta.dart';

/// Represents a file in cloud storage
@immutable
class CloudFile {
  /// File name
  final String name;

  /// Full file path
  final String path;

  /// File size in bytes (optional)
  final int? size;

  /// Last modified timestamp (optional)
  final DateTime? lastModified;

  /// Custom metadata (optional)
  ///
  /// Used to store fingerprint, version, etc.
  final Map<String, dynamic>? metadata;

  const CloudFile({
    required this.name,
    required this.path,
    this.size,
    this.lastModified,
    this.metadata,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudFile &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'CloudFile(name: $name, path: $path, size: $size)';
}

/// Abstract interface for cloud storage services
abstract class CloudStorageService {
  /// Upload data to cloud storage
  ///
  /// [path] - File path (e.g., 'users/123/data.json')
  /// [data] - File content as string
  /// [metadata] - Optional metadata map
  ///
  /// Throws [CloudStorageException] if upload fails.
  /// If file exists, it will be overwritten (upsert semantics).
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  });

  /// Download data from cloud storage
  ///
  /// [path] - File path
  ///
  /// Returns file content as string, or null if file doesn't exist.
  /// Throws [CloudStorageException] if download fails (except 404).
  Future<String?> download({required String path});

  /// Delete file from cloud storage
  ///
  /// [path] - File path
  ///
  /// Throws [CloudStorageException] if deletion fails.
  /// Should be idempotent (no error if file doesn't exist).
  Future<void> delete({required String path});

  /// List files in a directory
  ///
  /// [path] - Directory path (e.g., 'users/123/')
  ///
  /// Returns list of files in the directory.
  /// Throws [CloudStorageException] if listing fails.
  Future<List<CloudFile>> list({required String path});

  /// Check if file exists
  ///
  /// [path] - File path
  ///
  /// Returns true if file exists, false otherwise.
  /// Throws [CloudStorageException] if check fails.
  Future<bool> exists({required String path});

  /// Get file metadata
  ///
  /// [path] - File path
  ///
  /// Returns file metadata, or null if file doesn't exist.
  /// Throws [CloudStorageException] if operation fails.
  Future<CloudFile?> getMetadata({required String path});
}

/// No-op implementation for local-only mode
class NoopStorageService implements CloudStorageService {
  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<String?> download({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<void> delete({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<bool> exists({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }
}
