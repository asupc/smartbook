# flutter_cloud_sync Usage Guide

Complete guide to integrating cloud sync into your Flutter application.

## Table of Contents

1. [Installation](#installation)
2. [Core Concepts](#core-concepts)
3. [Basic Setup](#basic-setup)
4. [Advanced Usage](#advanced-usage)
5. [Best Practices](#best-practices)
6. [Troubleshooting](#troubleshooting)

## Installation

### 1. Add Core Package

```yaml
dependencies:
  flutter_cloud_sync: ^0.1.0
```

### 2. Add Cloud Provider

Choose one or more cloud providers:

```yaml
dependencies:
  # For Supabase
  flutter_cloud_sync_supabase: ^0.1.0

  # For WebDAV
  flutter_cloud_sync_webdav: ^0.1.0

  # For AWS S3
  flutter_cloud_sync_s3: ^0.1.0
```

### 3. Install Dependencies

```bash
flutter pub get
```

## Core Concepts

### DataSerializer<T>

The `DataSerializer` interface is how you tell the sync manager how to convert your business data to/from strings for cloud storage.

**Key Methods:**
- `serialize(T data)` - Convert your data to a string (usually JSON)
- `deserialize(String data)` - Convert string back to your data
- `fingerprint(String data)` - Generate a hash for change detection

**Example:**
```dart
class TransactionSerializer implements DataSerializer<int> {
  final Database db;

  TransactionSerializer(this.db);

  @override
  Future<String> serialize(int ledgerId) async {
    final transactions = await db.getTransactionsByLedger(ledgerId);
    return jsonEncode({
      'ledgerId': ledgerId,
      'transactions': transactions.map((t) => t.toJson()).toList(),
      'exportedAt': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<int> deserialize(String data) async {
    final json = jsonDecode(data) as Map<String, dynamic>;

    // Import transactions to database
    final ledgerId = json['ledgerId'] as int;
    final transactionsJson = json['transactions'] as List;

    for (final txJson in transactionsJson) {
      await db.insertTransaction(Transaction.fromJson(txJson));
    }

    return ledgerId;
  }

  @override
  String fingerprint(String data) {
    final bytes = utf8.encode(data);
    return sha256.convert(bytes).toString();
  }
}
```

### CloudProvider

The `CloudProvider` abstracts different cloud services. Each provider implements:
- **Authentication** - Sign in, sign out, user management
- **Storage** - Upload, download, delete files
- **Configuration** - Service-specific settings

### SyncStatus

Represents the current sync state:

```dart
enum SyncState {
  notConfigured,     // Cloud service not set up
  notAuthenticated,  // User not signed in
  localOnly,         // No cloud backup
  synced,            // Everything matches
  outOfSync,         // Local and cloud differ
  uploading,         // Upload in progress
  downloading,       // Download in progress
  error,             // Something went wrong
  unknown,           // Cannot determine state
}
```

**Helper Properties:**
- `isSynced` - Is data synchronized?
- `needsSync` - Does data need syncing?
- `canSync` - Can sync operation be performed?
- `isLoading` - Is operation in progress?

## Basic Setup

### Step 1: Choose and Configure Provider

#### Supabase Example

```dart
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';

final provider = SupabaseProvider();
await provider.initialize({
  'url': 'https://your-project.supabase.co',
  'anonKey': 'your-anon-key',
  'bucket': 'user-data', // Optional, defaults to 'storage'
});
```

#### WebDAV Example

```dart
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';

final provider = WebDAVProvider();
await provider.initialize({
  'url': 'https://your-webdav-server.com',
  'username': 'your-username',
  'password': 'your-password',
  'remotePath': '/sync/', // Optional root path
});
```

### Step 2: Create Sync Manager

```dart
final syncManager = CloudSyncManager<int>(
  provider: provider,
  serializer: TransactionSerializer(database),
  logger: CloudSyncLogger(
    onLog: (level, message) {
      // Integrate with your logging framework
      debugPrint('[$level] $message');
    },
  ),
  cacheTTL: const Duration(seconds: 30), // Optional, default: 30s
);
```

### Step 3: Handle Authentication

```dart
// Sign in
try {
  final user = await provider.auth.signInWithEmail(
    email: 'user@example.com',
    password: 'password',
  );
  print('Signed in: ${user.email}');
} on CloudAuthException catch (e) {
  print('Auth failed: ${e.message}');
}

// Listen to auth state
provider.auth.authStateChanges.listen((user) {
  if (user != null) {
    print('User signed in: ${user.email}');
  } else {
    print('User signed out');
  }
});

// Sign out
await provider.auth.signOut();
```

### Step 4: Sync Data

```dart
// Upload local data to cloud
await syncManager.upload(
  data: ledgerId,
  path: 'ledgers/$ledgerId.json',
  metadata: {
    'version': '1.0',
    'app': 'SmartBook',
  },
);

// Check sync status
final status = await syncManager.getStatus(
  data: ledgerId,
  path: 'ledgers/$ledgerId.json',
);

if (status.needsSync) {
  print('Data out of sync! Uploading...');
  await syncManager.upload(
    data: ledgerId,
    path: 'ledgers/$ledgerId.json',
  );
}

// Download from cloud
final downloadedLedgerId = await syncManager.download(
  path: 'ledgers/$ledgerId.json',
);

// Delete from cloud
await syncManager.deleteRemote(
  path: 'ledgers/$ledgerId.json',
);
```

## Advanced Usage

### Riverpod Integration

```dart
// providers.dart

// Cloud provider
final cloudProviderProvider = Provider<CloudProvider>((ref) {
  final provider = SupabaseProvider();
  // Initialize in main() or use FutureProvider
  return provider;
});

// Auth state stream
final authStateProvider = StreamProvider<CloudUser?>((ref) {
  final provider = ref.watch(cloudProviderProvider);
  return provider.auth.authStateChanges;
});

// Sync manager
final syncManagerProvider = Provider<CloudSyncManager<int>>((ref) {
  return CloudSyncManager<int>(
    provider: ref.watch(cloudProviderProvider),
    serializer: TransactionSerializer(ref.watch(databaseProvider)),
    logger: CloudSyncLogger(onLog: (level, msg) {
      debugPrint('[$level] $msg');
    }),
  );
});

// Sync status for specific ledger
final ledgerSyncStatusProvider = FutureProvider.family<SyncStatus, int>(
  (ref, ledgerId) async {
    final manager = ref.watch(syncManagerProvider);
    return manager.getStatus(
      data: ledgerId,
      path: 'ledgers/$ledgerId.json',
    );
  },
);
```

**Usage in Widget:**

```dart
class SyncButton extends ConsumerWidget {
  final int ledgerId;

  const SyncButton({required this.ledgerId, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(ledgerSyncStatusProvider(ledgerId));

    return statusAsync.when(
      data: (status) {
        if (status.isSynced) {
          return const Icon(Icons.cloud_done, color: Colors.green);
        } else if (status.needsSync) {
          return IconButton(
            icon: const Icon(Icons.cloud_upload),
            onPressed: () async {
              final manager = ref.read(syncManagerProvider);
              await manager.upload(
                data: ledgerId,
                path: 'ledgers/$ledgerId.json',
              );
              ref.invalidate(ledgerSyncStatusProvider(ledgerId));
            },
          );
        } else {
          return Icon(Icons.cloud_off, color: Colors.grey);
        }
      },
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) => const Icon(Icons.error, color: Colors.red),
    );
  }
}
```

### Using RetryHelper

Wrap network operations with retry logic:

```dart
// Automatic retry on network errors
await RetryHelper.execute(
  () => syncManager.upload(data: ledgerId, path: path),
  config: RetryConfig.network, // Predefined config
  onRetry: (attempt, error) {
    print('Retry attempt $attempt after error: $error');
  },
);

// Custom retry configuration
await RetryHelper.execute(
  () => syncManager.download(path: path),
  config: RetryConfig(
    maxAttempts: 5,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 20),
    backoffMultiplier: 2.0,
    shouldRetry: (e) {
      // Only retry on storage exceptions
      return e is CloudStorageException;
    },
  ),
);

// Simplified API
await RetryHelper.executeSimple(
  () => syncManager.upload(data: ledgerId, path: path),
  maxAttempts: 3,
);
```

### Path Management

Organize cloud storage with `PathHelper`:

```dart
// Build user-specific paths
final userId = user.id;
final ledgerId = 123;
final path = PathHelper.userPath(userId, ['ledgers', '$ledgerId.json']);
// Result: 'users/abc123/ledgers/123.json'

// Join multiple segments
final path = PathHelper.join(['users', userId, 'backups', 'latest.json']);

// Extract filename
final filename = PathHelper.basename(path); // 'latest.json'

// Get directory
final dir = PathHelper.dirname(path); // 'users/abc123/backups'

// Get extension
final ext = PathHelper.extension(filename); // '.json'
```

## Best Practices

### 1. Error Handling

Always handle exceptions:

```dart
try {
  await syncManager.upload(data: ledgerId, path: path);
} on CloudNotAuthenticatedException {
  // Show login screen
  Navigator.push(context, MaterialPageRoute(builder: (_) => LoginPage()));
} on CloudStorageException catch (e) {
  // Show retry option
  showDialog(/* ... */);
} on CloudSyncException catch (e) {
  // Generic error handling
  print('Sync failed: ${e.message}');
}
```

### 2. Cache Management

```dart
// Force refresh when needed
final status = await syncManager.getStatus(
  data: ledgerId,
  path: path,
  forceRefresh: true, // Skip cache
);

// Clear cache after major operations
await syncManager.upload(data: ledgerId, path: path);
syncManager.clearCache(); // Optional, upload already clears cache
```

### 3. Conflict Resolution

```dart
final status = await syncManager.getStatus(data: localLedger, path: path);

if (status.state == SyncState.outOfSync) {
  // Show conflict resolution UI
  final choice = await showDialog<ConflictResolution>(/* ... */);

  switch (choice) {
    case ConflictResolution.useLocal:
      await syncManager.upload(data: localLedger, path: path);
      break;
    case ConflictResolution.useCloud:
      final cloudLedger = await syncManager.download(path: path);
      // Update local database
      break;
    case ConflictResolution.merge:
      final cloudLedger = await syncManager.download(path: path);
      final merged = await mergeData(localLedger, cloudLedger);
      await syncManager.upload(data: merged, path: path);
      break;
  }
}
```

### 4. Background Sync

```dart
// Periodic sync check
Timer.periodic(const Duration(minutes: 5), (_) async {
  final status = await syncManager.getStatus(
    data: ledgerId,
    path: path,
    forceRefresh: true,
  );

  if (status.needsSync) {
    await syncManager.upload(data: ledgerId, path: path);
  }
});
```

### 5. Offline Support

```dart
// Check connectivity before syncing
final hasConnection = await checkConnectivity();
if (!hasConnection) {
  print('Offline - sync will be queued');
  await queueSyncOperation(ledgerId);
  return;
}

await syncManager.upload(data: ledgerId, path: path);
```

## Troubleshooting

### Issue: "User not authenticated"

**Solution:** Ensure user is signed in before sync operations:

```dart
final user = await provider.auth.currentUser;
if (user == null) {
  await provider.auth.signInWithEmail(email: email, password: password);
}
```

### Issue: Upload fails with timeout

**Solution:** Use retry logic:

```dart
await RetryHelper.executeWithBackoff(
  () => syncManager.upload(data: ledgerId, path: path),
  maxAttempts: 5,
  maxDelay: Duration(seconds: 60),
);
```

### Issue: Fingerprints don't match

**Solution:** Ensure consistent serialization:

```dart
@override
String fingerprint(String data) {
  // Sort keys in JSON to ensure consistency
  final json = jsonDecode(data) as Map<String, dynamic>;
  final sortedJson = Map.fromEntries(
    json.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
  final normalized = jsonEncode(sortedJson);
  return sha256.convert(utf8.encode(normalized)).toString();
}
```

### Issue: Sync status always shows "unknown"

**Solution:** Ensure metadata includes fingerprint:

```dart
await provider.storage.upload(
  path: path,
  data: serializedData,
  metadata: {
    'fingerprint': fingerprint,  // Required!
    'uploadedAt': DateTime.now().toIso8601String(),
  },
);
```

## Next Steps

- Explore [API Documentation](https://pub.dev/documentation/flutter_cloud_sync/latest/)
- Read [Architecture Guide](../.docs/cloud/architecture.md)
- Check [Example Code](example/)
- Join discussions on [GitHub](https://github.com/TNT-Likely/BeeCount/discussions)
