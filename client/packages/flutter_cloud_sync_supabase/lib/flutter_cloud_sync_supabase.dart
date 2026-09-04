/// Supabase provider for flutter_cloud_sync.
///
/// This library provides Supabase integration for the flutter_cloud_sync package,
/// enabling cloud synchronization using Supabase's storage and authentication services.
///
/// To use this library:
///
/// ```dart
/// import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
///
/// final provider = SupabaseProvider();
/// await provider.initialize({
///   'url': 'https://your-project.supabase.co',
///   'anonKey': 'your-anon-key',
///   'bucket': 'user-data', // optional, defaults to 'storage'
/// });
/// ```
library;

export 'src/supabase_provider.dart';
export 'src/supabase_auth_service.dart';
export 'src/supabase_storage_service.dart';
export 'src/supabase_database_service.dart';
export 'src/supabase_realtime_service.dart';
