import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 'icloud_auth_service.dart';
import 'icloud_method_channel.dart';
import 'icloud_storage_service.dart';

/// iCloud provider for flutter_cloud_sync
///
/// Provides iCloud Document Storage support for iOS/iPadOS.
/// Uses the user's private iCloud space - zero configuration required.
class ICloudProvider implements CloudProvider {
  ICloudAuthService? _authService;
  ICloudStorageService? _storageService;
  final _methodChannel = ICloudMethodChannel();

  @override
  String get providerId => 'icloud';

  @override
  String get providerName => 'iCloud';

  @override
  CloudAuthService get auth {
    if (_authService == null) {
      throw CloudConfigurationException(
          'Provider not initialized. Call initialize() first.');
    }
    return _authService!;
  }

  @override
  CloudStorageService get storage {
    if (_storageService == null) {
      throw CloudConfigurationException(
          'Provider not initialized. Call initialize() first.');
    }
    return _storageService!;
  }

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    if (!validateConfig(config)) {
      throw CloudConfigurationException(
          'Invalid configuration for iCloud provider');
    }

    try {
      // Check iCloud availability
      final isAvailable = await _methodChannel.isICloudAvailable();
      if (!isAvailable) {
        throw CloudConfigurationException(
          'iCloud is not available. Please sign in to iCloud in Settings.',
        );
      }

      // Create service instances
      _authService = ICloudAuthService(_methodChannel);
      _storageService = ICloudStorageService(_methodChannel);

      // Initialize iCloud container
      await _methodChannel.initializeContainer();
    } catch (e) {
      if (e is CloudConfigurationException) {
        rethrow;
      }
      throw CloudConfigurationException('Failed to initialize iCloud: $e', e);
    }
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    // iCloud requires no configuration - always valid
    // Could add optional container ID validation here
    return true;
  }

  @override
  Future<void> dispose() async {
    _authService = null;
    _storageService = null;
  }

  /// Check if iCloud is available without initializing
  /// Returns false if there's any error
  Future<bool> isAvailable() async {
    try {
      return await _methodChannel.isICloudAvailable();
    } catch (e) {
      // Any error means iCloud is not available
      return false;
    }
  }

  /// Get detailed iCloud diagnostics for debugging
  Future<Map<String, dynamic>> getDiagnostics() async {
    try {
      return await _methodChannel.getICloudDiagnostics();
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
