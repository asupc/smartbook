/// Flutter Cloud Sync
///
/// A modular cloud sync framework for Flutter with pluggable backend providers.
///
/// ## Features
///
/// - 🔌 Pluggable architecture - Choose your cloud provider (Supabase, WebDAV, S3, etc.)
/// - 🔄 Auto sync - Automatic detection and synchronization of local/cloud changes
/// - 🎯 Business agnostic - Works with any data model through serialization interface
/// - 🔐 Authentication - Built-in authentication service abstraction
/// - 📦 Type-safe - Generic design with full type safety
/// - 🎭 State management - Designed for Riverpod integration
/// - 📝 Comprehensive logging - Hook into your existing logging framework
///
/// ## Quick Start
///
/// ```dart
/// import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
///
/// // 1. Define your data serializer
/// class MyDataSerializer implements DataSerializer<int> {
///   @override
///   Future<String> serialize(int ledgerId) async {
///     final data = await db.getData(ledgerId);
///     return jsonEncode(data);
///   }
///
///   @override
///   Future<int> deserialize(String data) async {
///     final json = jsonDecode(data);
///     return json['ledgerId'] as int;
///   }
///
///   @override
///   String fingerprint(String data) {
///     return sha256.convert(utf8.encode(data)).toString();
///   }
/// }
///
/// // 2. Initialize cloud provider
/// final provider = SupabaseProvider(); // From flutter_cloud_sync_supabase
/// await provider.initialize({
///   'url': 'https://your-project.supabase.co',
///   'anonKey': 'your-anon-key',
/// });
///
/// // 3. Create sync manager
/// final syncManager = CloudSyncManager<int>(
///   provider: provider,
///   serializer: MyDataSerializer(),
///   logger: CloudSyncLogger(onLog: (level, message) {
///     print('[$level] $message');
///   }),
/// );
///
/// // 4. Use it!
/// await syncManager.upload(ledgerId: 123, path: 'ledgers/123.json');
/// final status = await syncManager.getStatus(ledgerId: 123, path: 'ledgers/123.json');
/// ```
///
/// ## Available Providers
///
/// Install only the providers you need:
///
/// - `flutter_cloud_sync_supabase` - Supabase backend
/// - `flutter_cloud_sync_webdav` - WebDAV backend
/// - `flutter_cloud_sync_s3` - AWS S3 backend
///
library;

// Core interfaces
export 'src/core/auth_service.dart';
export 'src/core/cloud_provider.dart';
export 'src/core/data_serializer.dart';
export 'src/core/database_service.dart';
export 'src/core/exceptions.dart';
export 'src/core/realtime_service.dart';
export 'src/core/storage_service.dart';
export 'src/core/sync_status.dart';

// Configuration
export 'src/config/cloud_service_config.dart';
export 'src/config/cloud_service_store.dart';
export 'src/config/provider_factory.dart';
export 'src/providers/smartbook_cloud_provider.dart';

// Utilities
export 'src/utils/logger.dart';
export 'src/utils/path_helper.dart';
export 'src/utils/retry_helper.dart';

// Manager
export 'src/manager/cloud_sync_manager.dart';
export 'src/manager/database_sync_manager.dart';
