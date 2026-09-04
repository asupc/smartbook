# flutter_cloud_sync_webdav

WebDAV provider for [flutter_cloud_sync](../flutter_cloud_sync), enabling cloud synchronization using WebDAV protocol with Basic Auth.

## Features

- ✅ WebDAV protocol support with Basic Auth
- ✅ Automatic directory creation
- ✅ Custom metadata storage as JSON files
- ✅ File upload, download, delete, and list operations
- ✅ Type-safe CloudProvider implementation
- ✅ Compatible with any WebDAV server (Nextcloud, ownCloud, etc.)

## Installation

Add this to your package's `pubspec.yaml`:

```yaml
dependencies:
  flutter_cloud_sync: ^0.1.0
  flutter_cloud_sync_webdav: ^0.1.0
```

## Setup

WebDAV is a protocol supported by many file hosting services. You can use:
- **Nextcloud** - Self-hosted or managed
- **ownCloud** - Self-hosted or managed
- **Box.com** - WebDAV enabled
- **4shared** - WebDAV support
- Any other WebDAV-compatible server

## Usage

### Initialize Provider

```dart
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';

final provider = WebDAVProvider();
await provider.initialize({
  'url': 'https://your-webdav-server.com',
  'username': 'your-username',
  'password': 'your-password',
  'remotePath': '/sync/', // optional, defaults to '/'
});
```

### Authentication

WebDAV uses Basic Auth, so authentication is handled during initialization:

```dart
// Authentication happens during initialization
await provider.initialize({
  'url': 'https://nextcloud.example.com',
  'username': 'user@example.com',
  'password': 'your-app-password',
  'remotePath': '/SmartBook/', // optional
});

// After initialization, you're authenticated
final user = await provider.auth.currentUser;
print('Authenticated as: ${user?.email}');

// Sign out (clears credentials)
await provider.auth.signOut();
```

### Sync Data

```dart
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

final syncManager = CloudSyncManager<YourDataType>(
  provider: provider,
  serializer: YourDataSerializer(),
);

// Upload
await syncManager.upload(
  data: yourData,
  path: 'ledgers/123.json',
);

// Download
final data = await syncManager.download(
  path: 'ledgers/123.json',
);

// Check sync status
final status = await syncManager.getStatus(
  data: yourData,
  path: 'ledgers/123.json',
);
```

## Path Structure

Files are stored relative to the `remotePath`:

```
{remotePath}/{your-path}
```

Example with `remotePath: '/SmartBook/'`:
- You specify: `ledgers/123.json`
- Actual path: `/SmartBook/ledgers/123.json`

## Configuration Options

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `url` | String | ✅ | - | WebDAV server URL |
| `username` | String | ✅ | - | Username for Basic Auth |
| `password` | String | ✅ | - | Password for Basic Auth |
| `remotePath` | String | ❌ | `'/'` | Remote path prefix |

## Error Handling

All operations throw standard `flutter_cloud_sync` exceptions:

```dart
try {
  await syncManager.upload(data: data, path: path);
} on CloudStorageException catch (e) {
  // Storage operation failed
  print('Storage error: ${e.message}');
} on CloudConfigurationException catch (e) {
  // Configuration error
  print('Config error: ${e.message}');
}
```

## Nextcloud Setup

1. **Generate App Password**:
   - Settings → Security → Devices & sessions
   - Create new app password
   - Copy the generated password

2. **Get WebDAV URL**:
   - Usually: `https://your-nextcloud.com/remote.php/dav/files/USERNAME/`
   - Or check: Settings → (bottom left) → WebDAV

3. **Initialize**:
```dart
await provider.initialize({
  'url': 'https://your-nextcloud.com/remote.php/dav/files/username',
  'username': 'username',
  'password': 'your-app-password', // Use app password, not account password
  'remotePath': '/SmartBook/',
});
```

## ownCloud Setup

Similar to Nextcloud:

1. Generate app password in Security settings
2. Get WebDAV URL (Settings → WebDAV)
3. Initialize with credentials

## Best Practices

1. **Use app passwords** instead of account passwords
2. **Store credentials securely** using flutter_secure_storage or similar
3. **Handle network errors** with retry logic
4. **Test connectivity** before syncing
5. **Use specific remote paths** to organize data

## Example

See the [example app](../flutter_cloud_sync/example/) for a complete implementation.

## Limitations

- **No streaming uploads/downloads** - Files are loaded into memory
- **Basic Auth only** - OAuth not supported
- **No server-side encryption** - Encryption must be done at application level
- **Metadata stored separately** - Custom metadata stored as `.metadata.json` files

## Additional Resources

- [flutter_cloud_sync Documentation](../flutter_cloud_sync/README.md)
- [WebDAV Wikipedia](https://en.wikipedia.org/wiki/WebDAV)
- [Nextcloud WebDAV](https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html)
- [ownCloud WebDAV](https://doc.owncloud.com/server/admin_manual/configuration/files/external_storage/webdav.html)

## License

This package is part of the SmartBook project and uses the same license.
