# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Database Service**: New `SupabaseDatabaseService` implementing `CloudDatabaseService`
  - Direct database CRUD operations via Supabase REST API
  - Support for complex queries with filters
  - Batch insert operations
  - Automatic type conversion and error handling
- **Realtime Service**: New `SupabaseRealtimeService` implementing `CloudRealtimeService`
  - WebSocket-based real-time subscriptions
  - PostgreSQL CDC (Change Data Capture) support
  - Channel management with automatic cleanup
  - Filter-based subscriptions (eq, gt, lt, etc.)
- Exposed `databaseService`, `realtimeService`, and `client` in `SupabaseProvider`
- Initial release of flutter_cloud_sync_supabase
- Full Supabase authentication integration
  - Email/password sign up and sign in
  - Password reset email
  - Email verification resend
  - Auth state change stream
  - PKCE authentication flow
- Supabase Storage integration
  - Upload files with automatic user-path prefixing
  - Download files
  - Delete files
  - List files in directory
  - Check file existence
  - Get file metadata
- Custom metadata storage using optional database table
- User-specific path management (`users/{userId}/...`)
- Comprehensive error handling with typed exceptions
- Full documentation and setup guide
- 13 passing unit tests

## [0.1.0] - 2025-01-XX

### Added
- SupabaseProvider implementing CloudProvider interface
- SupabaseAuthService implementing CloudAuthService interface
- SupabaseStorageService implementing CloudStorageService interface
- Configuration validation
- README with setup instructions and usage examples

[Unreleased]: https://github.com/TNT-Likely/BeeCount/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TNT-Likely/BeeCount/releases/tag/flutter_cloud_sync_supabase-v0.1.0
