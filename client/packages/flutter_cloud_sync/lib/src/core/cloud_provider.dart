import 'auth_service.dart';
import 'storage_service.dart';

/// Abstract interface for cloud service providers
///
/// Each cloud service (Supabase, WebDAV, S3, etc.) implements this interface
/// to provide a unified way to access authentication and storage services.
abstract class CloudProvider {
  /// Unique provider identifier
  ///
  /// Used for configuration storage, logging, etc.
  /// Examples: 'supabase', 'webdav', 's3'
  String get providerId;

  /// Provider display name
  ///
  /// Used for UI display.
  /// Examples: 'Supabase', 'WebDAV', 'AWS S3'
  String get providerName;

  /// Authentication service instance
  CloudAuthService get auth;

  /// Storage service instance
  CloudStorageService get storage;

  /// Initialize the provider with configuration
  ///
  /// [config] - Configuration parameters (provider-specific)
  ///
  /// Different providers require different configurations:
  /// - Supabase: {'url': String, 'anonKey': String, 'bucket': String?}
  /// - WebDAV: {'url': String, 'username': String, 'password': String, 'remotePath': String?}
  /// - S3: {'region': String, 'accessKey': String, 'secretKey': String, 'bucket': String}
  ///
  /// Throws [CloudConfigurationException] if configuration is invalid.
  Future<void> initialize(Map<String, dynamic> config);

  /// Validate configuration before initialization
  ///
  /// Call this before [initialize] to avoid runtime errors.
  ///
  /// Returns true if configuration is valid, false otherwise.
  bool validateConfig(Map<String, dynamic> config);

  /// Dispose resources
  ///
  /// Close connections, clear caches, etc.
  /// Should be called when switching providers or app shutdown.
  Future<void> dispose();
}
