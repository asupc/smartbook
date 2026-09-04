/// Path helper utilities for cloud storage paths
class PathHelper {
  /// Normalize a cloud storage path
  ///
  /// - Removes leading slashes
  /// - Removes duplicate slashes
  /// - Removes trailing slashes
  ///
  /// Example:
  /// ```dart
  /// PathHelper.normalize('//users/123/data.json/') // 'users/123/data.json'
  /// PathHelper.normalize('users//123///data.json') // 'users/123/data.json'
  /// ```
  static String normalize(String path) {
    if (path.isEmpty) return path;

    // Remove leading slashes
    path = path.replaceFirst(RegExp(r'^/+'), '');

    // Remove trailing slashes
    path = path.replaceFirst(RegExp(r'/+$'), '');

    // Replace multiple slashes with single slash
    path = path.replaceAll(RegExp(r'/+'), '/');

    return path;
  }

  /// Join multiple path segments
  ///
  /// Automatically normalizes the result.
  ///
  /// Example:
  /// ```dart
  /// PathHelper.join('users', '123', 'data.json') // 'users/123/data.json'
  /// PathHelper.join('users/', '/123/', '/data.json') // 'users/123/data.json'
  /// ```
  static String join(List<String> segments) {
    if (segments.isEmpty) return '';
    return normalize(segments.join('/'));
  }

  /// Get the directory path from a file path
  ///
  /// Returns the parent directory path, or empty string if no parent.
  ///
  /// Example:
  /// ```dart
  /// PathHelper.dirname('users/123/data.json') // 'users/123'
  /// PathHelper.dirname('data.json') // ''
  /// ```
  static String dirname(String path) {
    path = normalize(path);
    if (path.isEmpty) return '';

    final lastSlashIndex = path.lastIndexOf('/');
    if (lastSlashIndex == -1) return '';

    return path.substring(0, lastSlashIndex);
  }

  /// Get the filename from a file path
  ///
  /// Returns the last segment of the path.
  ///
  /// Example:
  /// ```dart
  /// PathHelper.basename('users/123/data.json') // 'data.json'
  /// PathHelper.basename('data.json') // 'data.json'
  /// ```
  static String basename(String path) {
    path = normalize(path);
    if (path.isEmpty) return '';

    final lastSlashIndex = path.lastIndexOf('/');
    if (lastSlashIndex == -1) return path;

    return path.substring(lastSlashIndex + 1);
  }

  /// Get the file extension
  ///
  /// Returns the extension including the dot, or empty string if no extension.
  ///
  /// Example:
  /// ```dart
  /// PathHelper.extension('data.json') // '.json'
  /// PathHelper.extension('archive.tar.gz') // '.gz'
  /// PathHelper.extension('noextension') // ''
  /// ```
  static String extension(String path) {
    final filename = basename(path);
    final lastDotIndex = filename.lastIndexOf('.');

    if (lastDotIndex == -1 || lastDotIndex == 0) return '';
    return filename.substring(lastDotIndex);
  }

  /// Build a user-specific path
  ///
  /// Convenience method for creating paths under a user directory.
  ///
  /// Example:
  /// ```dart
  /// PathHelper.userPath('user123', ['ledgers', '456.json'])
  /// // 'users/user123/ledgers/456.json'
  /// ```
  static String userPath(String userId, List<String> segments) {
    return join(['users', userId, ...segments]);
  }

  /// Check if path is absolute (starts with /)
  static bool isAbsolute(String path) {
    return path.startsWith('/');
  }

  /// Make path absolute by adding leading slash
  static String makeAbsolute(String path) {
    if (isAbsolute(path)) return path;
    return '/$path';
  }

  /// Make path relative by removing leading slash
  static String makeRelative(String path) {
    return normalize(path);
  }
}
