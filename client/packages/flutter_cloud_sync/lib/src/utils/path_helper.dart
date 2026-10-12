/// Path helper utilities for cloud storage paths
///
/// Object keys are POSIX-style: '/' is the only separator and '\\' is an
/// ordinary character. Two distinct operations are provided:
///
/// * [normalize] canonicalizes a full path (POSIX segment resolution:
///   collapses repeated slashes, drops '.' segments, resolves '..' against
///   the root; a '..' that would escape the root is dropped).
/// * [join] composes namespace prefixes (e.g. a configured WebDAV remote path)
///   with caller supplied segments. Instead of resolving '..' by popping the
///   prefix, '..' pieces are **dropped** so a joined path can never escape the
///   namespace it was built from.
class PathHelper {
  /// Normalize a cloud storage path (POSIX canonicalization)
  ///
  /// - Removes leading slashes
  /// - Removes duplicate slashes
  /// - Removes trailing slashes
  /// - Drops '.' segments
  /// - Resolves '..' segments against the root (cannot escape the root)
  ///
  /// Example:
  /// ```dart
  /// PathHelper.normalize('//users/123/data.json/') // 'users/123/data.json'
  /// PathHelper.normalize('users//123///data.json') // 'users/123/data.json'
  /// PathHelper.normalize('users/../../etc/passwd') // 'etc/passwd'
  /// PathHelper.normalize('a/./b')                  // 'a/b'
  /// ```
  static String normalize(String path) {
    if (path.isEmpty) return path;

    final output = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        // Resolve against the root: '..' above the root is dropped, never
        // allowed to survive as a traversal segment.
        if (output.isNotEmpty) {
          output.removeLast();
        }
        continue;
      }
      output.add(segment);
    }
    return output.join('/');
  }

  /// Join multiple path segments
  ///
  /// Segment-level sanitization: every input segment has its own '.'/'..'
  /// pieces removed, so the joined result always stays inside the namespace the
  /// first segment defines (a '..' can never pop a parent prefix).
  ///
  /// Example:
  /// ```dart
  /// PathHelper.join('users', '123', 'data.json') // 'users/123/data.json'
  /// PathHelper.join('users/', '/123/', '/data.json') // 'users/123/data.json'
  /// PathHelper.join(['/smartbook', '../loot.json']) // 'smartbook/loot.json'
  /// ```
  static String join(List<String> segments) {
    if (segments.isEmpty) return '';

    final parts = <String>[];
    for (final segment in segments) {
      final sanitized = _stripDotSegments(segment);
      if (sanitized.isNotEmpty) {
        parts.add(sanitized);
      }
    }
    return normalize(parts.join('/'));
  }

  /// Remove a path's '.' / '..' / empty pieces while preserving everything
  /// else verbatim (including '\' which is an ordinary object-key character).
  ///
  /// Returns the sanitized segment, or '' when nothing meaningful remains.
  static String _stripDotSegments(String segment) {
    if (segment.isEmpty) return '';
    final pieces = <String>[];
    for (final piece in segment.split('/')) {
      if (piece.isEmpty || piece == '.' || piece == '..') {
        continue;
      }
      pieces.add(piece);
    }
    return pieces.join('/');
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
  /// The `userId` and every segment are sanitized so the result can never
  /// escape the `users/` namespace (a '..' userId yields `users/<segment>`
  /// rather than a traversal).
  ///
  /// Example:
  /// ```dart
  /// PathHelper.userPath('user123', ['ledgers', '456.json'])
  /// // 'users/user123/ledgers/456.json'
  /// ```
  static String userPath(String userId, List<String> segments) {
    final safeUserId = _stripDotSegments(userId);
    final safeSegments = <String>[];
    for (final segment in segments) {
      final sanitized = _stripDotSegments(segment);
      if (sanitized.isNotEmpty) {
        safeSegments.add(sanitized);
      }
    }

    // join() already sanitizes each piece; the explicit check below is a
    // defensive assertion that the namespace prefix survived.
    final result = join(<String>['users', safeUserId, ...safeSegments]);
    if (result == 'users' || result.startsWith('users/')) {
      return result;
    }
    return join(<String>['users', result]);
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
