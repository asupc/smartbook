import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 'icloud_method_channel.dart';

/// iCloud storage service implementation
class ICloudStorageService implements CloudStorageService {
  final ICloudMethodChannel _methodChannel;

  ICloudStorageService(this._methodChannel);

  /// Safely convert a dynamic map to Map<String, dynamic>
  Map<String, dynamic>? _convertToStringDynamicMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // Encode data as Base64 to avoid JSON escape issues
      final encodedData = base64Encode(utf8.encode(data));

      await _methodChannel.uploadFile(
        path: path,
        data: encodedData,
        metadata: metadata,
      );
    } catch (e) {
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final encodedData = await _methodChannel.downloadFile(path: path);

      if (encodedData == null) {
        return null;
      }

      // Decode Base64 data
      final bytes = base64Decode(encodedData);
      return utf8.decode(bytes);
    } catch (e) {
      // Return null for "not found" errors
      if (e.toString().contains('404') ||
          e.toString().contains('not found') ||
          e.toString().contains('does not exist') ||
          e.toString().contains('NSFileReadNoSuchFileError')) {
        return null;
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    try {
      await _methodChannel.deleteFile(path: path);
    } catch (e) {
      // Ignore "not found" errors for idempotent delete
      if (!e.toString().contains('404') &&
          !e.toString().contains('not found') &&
          !e.toString().contains('NSFileNoSuchFileError')) {
        throw CloudStorageException('Delete failed: $e', e);
      }
    }
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      final files = await _methodChannel.listFiles(path: path);
      return files.map((fileInfo) {
        return CloudFile(
          name: fileInfo['name'] as String,
          path: fileInfo['path'] as String,
          size: fileInfo['size'] as int?,
          lastModified: fileInfo['lastModified'] != null
              ? DateTime.tryParse(fileInfo['lastModified'] as String)
              : null,
          metadata: _convertToStringDynamicMap(fileInfo['metadata']),
        );
      }).toList();
    } catch (e) {
      // Return empty list if directory doesn't exist
      if (e.toString().contains('not found') ||
          e.toString().contains('does not exist')) {
        return [];
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    try {
      return await _methodChannel.fileExists(path: path);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final metadata = await _methodChannel.getFileMetadata(path: path);
      if (metadata == null) {
        return null;
      }

      return CloudFile(
        name: metadata['name'] as String,
        path: metadata['path'] as String,
        size: metadata['size'] as int?,
        lastModified: metadata['lastModified'] != null
            ? DateTime.tryParse(metadata['lastModified'] as String)
            : null,
        metadata: _convertToStringDynamicMap(metadata['customMetadata']),
      );
    } catch (e) {
      if (e.toString().contains('404') ||
          e.toString().contains('not found') ||
          e.toString().contains('NSFileReadNoSuchFileError')) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }
}
