# flutter_cloud_sync Example

This example demonstrates how to use the `flutter_cloud_sync` package to implement cloud synchronization in your Flutter application.

## What This Example Shows

1. **Implementing DataSerializer** - How to serialize your business data for cloud storage
2. **Creating a CloudProvider** - A mock provider implementation for testing
3. **Using CloudSyncManager** - Complete sync workflow including upload, download, and status checking
4. **Error Handling** - Using RetryHelper for robust network operations
5. **Path Management** - Using PathHelper for organizing cloud storage paths

## Running the Example

```bash
cd example
flutter pub get
dart run lib/main.dart
```

Expected output:
```
=== Flutter Cloud Sync Example ===

--- Authentication ---
[LogLevel.info] Authenticating...
Current user: demo@example.com

--- Creating a note ---
Note created: My First Note

--- Uploading to cloud ---
Upload path: users/demo-user/notes/1.json
[LogLevel.info] Starting upload: users/demo-user/notes/1.json
[LogLevel.debug] Data serialized: 156 bytes
[LogLevel.debug] Fingerprint: a1b2c3...
[LogLevel.info] Upload completed: users/demo-user/notes/1.json
Upload completed!

--- Checking sync status ---
Sync state: SyncState.synced
Is synced: true
Local fingerprint: a1b2c3...
Cloud fingerprint: a1b2c3...

... (continues with full workflow)
```

## Code Walkthrough

### 1. Define Your Data Model

```dart
class Note {
  final int id;
  final String title;
  final String content;
  final DateTime createdAt;

  // ... toJson(), fromJson(), copyWith() methods
}
```

### 2. Implement DataSerializer

```dart
class NoteSerializer implements DataSerializer<Note> {
  @override
  Future<String> serialize(Note data) async {
    return jsonEncode(data.toJson());
  }

  @override
  Future<Note> deserialize(String data) async {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return Note.fromJson(json);
  }

  @override
  String fingerprint(String data) {
    final bytes = utf8.encode(data);
    return sha256.convert(bytes).toString();
  }
}
```

### 3. Initialize CloudProvider

```dart
final provider = YourCloudProvider(); // Supabase, WebDAV, etc.
await provider.initialize({
  'url': 'your-cloud-url',
  'key': 'your-api-key',
});
```

### 4. Create CloudSyncManager

```dart
final syncManager = CloudSyncManager<Note>(
  provider: provider,
  serializer: NoteSerializer(),
  logger: CloudSyncLogger(onLog: (level, message) {
    print('[$level] $message');
  }),
);
```

### 5. Use the Manager

```dart
// Upload
await syncManager.upload(data: note, path: 'notes/1.json');

// Check status
final status = await syncManager.getStatus(data: note, path: 'notes/1.json');
if (status.needsSync) {
  await syncManager.upload(data: note, path: 'notes/1.json');
}

// Download
final downloadedNote = await syncManager.download(path: 'notes/1.json');

// Delete
await syncManager.deleteRemote(path: 'notes/1.json');
```

## Key Concepts

### Sync States

- `notConfigured` - Cloud service not set up
- `notAuthenticated` - User needs to sign in
- `localOnly` - No cloud backup exists
- `synced` - Local and cloud match
- `outOfSync` - Local and cloud differ
- `uploading` - Upload in progress
- `downloading` - Download in progress
- `error` - Operation failed

### Path Management

Use `PathHelper` to organize cloud storage paths:

```dart
// Build user-specific paths
final path = PathHelper.userPath('user123', ['notes', '1.json']);
// Result: 'users/user123/notes/1.json'

// Join path segments
final path = PathHelper.join(['folder', 'subfolder', 'file.json']);

// Get filename
final filename = PathHelper.basename('folder/file.json'); // 'file.json'
```

### Retry Logic

Use `RetryHelper` for robust network operations:

```dart
final result = await RetryHelper.executeWithBackoff(
  () => cloudOperation(),
  maxAttempts: 3,
  initialDelay: Duration(seconds: 1),
  maxDelay: Duration(seconds: 30),
);
```

## Next Steps

1. **Choose a Cloud Provider** - Install `flutter_cloud_sync_supabase` or `flutter_cloud_sync_webdav`
2. **Implement Your Serializer** - Adapt the NoteSerializer to your data model
3. **Handle Authentication** - Implement proper login/logout flows
4. **Integrate with Riverpod** - Use StreamProvider and FutureProvider for reactive UI

## See Also

- [Main Package README](../README.md)
- [API Documentation](https://pub.dev/documentation/flutter_cloud_sync/latest/)
- [Architecture Guide](../.docs/cloud/architecture.md)
- [Migration Guide](../.docs/cloud/migration-guide.md)
