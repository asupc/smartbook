# flutter_cloud_sync_supabase

Supabase provider for [flutter_cloud_sync](../flutter_cloud_sync), enabling cloud synchronization using Supabase's storage and authentication services.

## Features

- ✅ Full Supabase authentication integration
- ✅ Supabase Storage support with user-specific paths
- ✅ Automatic metadata management
- ✅ PKCE authentication flow
- ✅ Type-safe CloudProvider implementation

## Installation

Add this to your package's `pubspec.yaml`:

```yaml
dependencies:
  flutter_cloud_sync: ^0.1.0
  flutter_cloud_sync_supabase: ^0.1.0
```

## Setup

### 1. Configure Supabase Project

1. Create a project on [Supabase](https://supabase.com)
2. Create a storage bucket (e.g., `user-data`)
3. Set up bucket policies for authenticated users:

```sql
-- Allow authenticated users to upload/download their own files
CREATE POLICY "Users can manage their own files"
ON storage.objects
FOR ALL
TO authenticated
USING (bucket_id = 'user-data' AND (storage.foldername(name))[1] = 'users' AND (storage.foldername(name))[2] = auth.uid()::text);
```

### 2. Optional: Create Metadata Table

For custom metadata support, create a table:

```sql
CREATE TABLE file_metadata (
  path TEXT PRIMARY KEY,
  metadata JSONB,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE file_metadata ENABLE ROW LEVEL SECURITY;

-- Allow users to manage their own metadata
CREATE POLICY "Users can manage their own metadata"
ON file_metadata
FOR ALL
TO authenticated
USING (path LIKE 'users/' || auth.uid()::text || '/%');
```

## Usage

### Initialize Provider

```dart
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';

final provider = SupabaseProvider();
await provider.initialize({
  'url': 'https://your-project.supabase.co',
  'anonKey': 'your-anon-key',
  'bucket': 'user-data', // optional, defaults to 'storage'
});
```

### Authentication

```dart
// Sign up
final user = await provider.auth.signUpWithEmail(
  email: 'user@example.com',
  password: 'password123',
);

// Sign in
final user = await provider.auth.signInWithEmail(
  email: 'user@example.com',
  password: 'password123',
);

// Listen to auth state
provider.auth.authStateChanges.listen((user) {
  if (user != null) {
    print('Signed in: ${user.email}');
  } else {
    print('Signed out');
  }
});

// Sign out
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

Files are automatically stored in user-specific paths:

```
users/{userId}/{your-path}
```

Example:
- You specify: `ledgers/123.json`
- Actual path: `users/abc-123-def/ledgers/123.json`

This ensures users can only access their own files when proper RLS policies are configured.

## Configuration Options

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `url` | String | ✅ | - | Supabase project URL |
| `anonKey` | String | ✅ | - | Supabase anonymous key |
| `bucket` | String | ❌ | `'storage'` | Storage bucket name |

## Error Handling

All operations throw standard `flutter_cloud_sync` exceptions:

```dart
try {
  await syncManager.upload(data: data, path: path);
} on CloudNotAuthenticatedException {
  // User needs to sign in
} on CloudStorageException catch (e) {
  // Storage operation failed
  print('Storage error: ${e.message}');
} on CloudAuthException catch (e) {
  // Auth operation failed
  print('Auth error: ${e.message}');
}
```

## Best Practices

1. **Always check authentication** before sync operations
2. **Use RLS policies** to secure your storage bucket
3. **Handle errors gracefully** with try-catch blocks
4. **Cache sync status** to reduce API calls
5. **Use retry logic** for network operations

## Example

See the [example app](example/) for a complete implementation.

## Additional Resources

- [flutter_cloud_sync Documentation](../flutter_cloud_sync/README.md)
- [Supabase Docs](https://supabase.com/docs)
- [Supabase Flutter Docs](https://supabase.com/docs/reference/dart/introduction)

## License

This package is part of the SmartBook project and uses the same license.
