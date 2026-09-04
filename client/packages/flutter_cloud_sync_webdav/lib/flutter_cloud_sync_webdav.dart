/// WebDAV provider for flutter_cloud_sync.
///
/// This library provides WebDAV integration for the flutter_cloud_sync package,
/// enabling cloud synchronization using WebDAV protocol with Basic Auth.
///
/// To use this library:
///
/// ```dart
/// import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
///
/// final provider = WebDAVProvider();
/// await provider.initialize({
///   'url': 'https://webdav.example.com',
///   'username': 'your-username',
///   'password': 'your-password',
///   'remotePath': '/sync/', // optional, defaults to '/'
/// });
/// ```
library;

export 'src/webdav_provider.dart';
export 'src/webdav_auth_service.dart';
export 'src/webdav_storage_service.dart';
