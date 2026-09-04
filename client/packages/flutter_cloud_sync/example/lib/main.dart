import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// Example: Implementing a cloud sync solution for a simple note-taking app
///
/// This example demonstrates:
/// 1. Implementing a custom DataSerializer
/// 2. Creating a mock CloudProvider
/// 3. Using CloudSyncManager to sync data
/// 4. Error handling and retry logic

void main() async {
  print('=== Flutter Cloud Sync Example ===\n');

  // Step 1: Create a serializer for your business data
  final serializer = NoteSerializer();

  // Step 2: Create and initialize a cloud provider
  final provider = MockCloudProvider();
  await provider.initialize({});

  // Step 3: Create a CloudSyncManager
  final syncManager = CloudSyncManager<Note>(
    provider: provider,
    serializer: serializer,
    logger: CloudSyncLogger(onLog: (level, message) {
      print('[$level] $message');
    }),
  );

  // Step 4: Authenticate (in mock provider, this is automatic)
  print('\n--- Authentication ---');
  final user = await provider.auth.currentUser;
  print('Current user: ${user?.email}\n');

  // Step 5: Create a note
  print('--- Creating a note ---');
  final note = Note(
    id: 1,
    title: 'My First Note',
    content: 'This is a test note for cloud sync.',
    createdAt: DateTime.now(),
  );
  print('Note created: ${note.title}\n');

  // Step 6: Upload note to cloud
  print('--- Uploading to cloud ---');
  final notePath = PathHelper.userPath(user!.id, ['notes', '${note.id}.json']);
  print('Upload path: $notePath');

  await syncManager.upload(
    data: note,
    path: notePath,
    metadata: {'app': 'notes_app', 'version': '1.0'},
  );
  print('Upload completed!\n');

  // Step 7: Check sync status
  print('--- Checking sync status ---');
  var status = await syncManager.getStatus(data: note, path: notePath);
  print('Sync state: ${status.state}');
  print('Is synced: ${status.isSynced}');
  print('Local fingerprint: ${status.localFingerprint}');
  print('Cloud fingerprint: ${status.cloudFingerprint}\n');

  // Step 8: Modify note locally
  print('--- Modifying note locally ---');
  final modifiedNote = note.copyWith(
    content: 'This note has been modified!',
  );
  print('Note modified: ${modifiedNote.content}\n');

  // Step 9: Check sync status again (should be out of sync)
  print('--- Checking sync status after modification ---');
  status = await syncManager.getStatus(
    data: modifiedNote,
    path: notePath,
    forceRefresh: true,
  );
  print('Sync state: ${status.state}');
  print('Needs sync: ${status.needsSync}\n');

  // Step 10: Sync the modified note
  print('--- Syncing modified note ---');
  await syncManager.upload(data: modifiedNote, path: notePath);
  print('Sync completed!\n');

  // Step 11: Download from cloud
  print('--- Downloading from cloud ---');
  final downloadedNote = await syncManager.download(path: notePath);
  print('Downloaded note: ${downloadedNote?.title}');
  print('Content: ${downloadedNote?.content}\n');

  // Step 12: Demonstrate retry logic
  print('--- Demonstrating retry logic ---');
  try {
    await RetryHelper.executeWithBackoff(
      () async {
        print('Attempting network operation...');
        // Simulate network operation
        await Future.delayed(const Duration(milliseconds: 100));
        return 'Success';
      },
      maxAttempts: 3,
      initialDelay: const Duration(milliseconds: 500),
    );
    print('Operation succeeded with retry logic\n');
  } catch (e) {
    print('Operation failed: $e\n');
  }

  // Step 13: Delete from cloud
  print('--- Deleting from cloud ---');
  await syncManager.deleteRemote(path: notePath);
  print('Deleted from cloud!\n');

  // Step 14: Verify deletion
  print('--- Verifying deletion ---');
  status = await syncManager.getStatus(
    data: modifiedNote,
    path: notePath,
    forceRefresh: true,
  );
  print('Sync state after deletion: ${status.state}');
  print('Is local only: ${status.state == SyncState.localOnly}\n');

  print('=== Example completed! ===');
}

/// Example Note model
class Note {
  final int id;
  final String title;
  final String content;
  final DateTime createdAt;

  const Note({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as int,
        title: json['title'] as String,
        content: json['content'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Note copyWith({
    int? id,
    String? title,
    String? content,
    DateTime? createdAt,
  }) =>
      Note(
        id: id ?? this.id,
        title: title ?? this.title,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
      );
}

/// Example DataSerializer implementation
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

/// Mock CloudProvider for demonstration
class MockCloudProvider implements CloudProvider {
  final _auth = MockAuthService();
  final _storage = MockStorageService();

  @override
  CloudAuthService get auth => _auth;

  @override
  CloudStorageService get storage => _storage;

  @override
  String get providerId => 'mock';

  @override
  String get providerName => 'Mock Provider';

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    // Auto-login for demo
    _auth._currentUser = const CloudUser(
      id: 'demo-user',
      email: 'demo@example.com',
    );
  }

  @override
  bool validateConfig(Map<String, dynamic> config) => true;

  @override
  Future<void> dispose() async {}
}

class MockAuthService implements CloudAuthService {
  CloudUser? _currentUser;

  @override
  Future<CloudUser?> get currentUser async => _currentUser;

  @override
  Stream<CloudUser?> get authStateChanges => Stream.value(_currentUser);

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async => _currentUser = null;

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}

  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

class MockStorageService implements CloudStorageService {
  final _storage = <String, _MockFile>{};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _storage[path] = _MockFile(data, metadata);
  }

  @override
  Future<String?> download({required String path}) async {
    return _storage[path]?.data;
  }

  @override
  Future<void> delete({required String path}) async {
    _storage.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return _storage.keys
        .where((key) => key.startsWith(path))
        .map((key) => CloudFile(
              name: PathHelper.basename(key),
              path: key,
              metadata: _storage[key]?.metadata,
            ))
        .toList();
  }

  @override
  Future<bool> exists({required String path}) async {
    return _storage.containsKey(path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    final file = _storage[path];
    if (file == null) return null;
    return CloudFile(
      name: PathHelper.basename(path),
      path: path,
      metadata: file.metadata,
    );
  }
}

class _MockFile {
  final String data;
  final Map<String, String>? metadata;

  _MockFile(this.data, this.metadata);
}
