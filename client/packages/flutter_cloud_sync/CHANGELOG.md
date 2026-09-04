# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Database Service**: New `CloudDatabaseService` abstract interface for direct database operations
  - CRUD operations (insert, update, delete, query)
  - Flexible query filtering with `QueryFilter` class
  - Batch operations support
  - Sorting and pagination
- **Realtime Service**: New `CloudRealtimeService` abstract interface for WebSocket-based subscriptions
  - Channel-based subscriptions
  - PostgreSQL change detection (INSERT, UPDATE, DELETE)
  - Real-time data synchronization
  - Automatic reconnection support
- **Database Sync Manager**: New `DatabaseSyncManager` for managing database synchronization
  - Real-time bidirectional sync
  - Conflict resolution strategies
  - Initial sync support
  - Connection state management
- Initial release of flutter_cloud_sync
- Core abstractions: `CloudProvider`, `CloudAuthService`, `CloudStorageService`
- Generic `DataSerializer<T>` interface for business data serialization
- `CloudSyncManager<T>` for orchestrating sync operations
  - Upload/download with fingerprint-based change detection
  - Automatic cache management with configurable TTL
  - Status checking with `SyncState` enum
- Comprehensive exception hierarchy
- `SyncStatus` and `SyncState` for sync state tracking
- `CloudSyncLogger` for logging integration
- Utility classes:
  - `PathHelper` - Cloud storage path management
  - `RetryHelper` - Automatic retry with exponential backoff
  - `RetryConfig` - Predefined retry strategies (network, aggressive, conservative)
- Complete API documentation with dartdoc comments
- Full example application demonstrating all features
- Comprehensive usage guide
- 59 passing unit tests with >95% code coverage

## [0.1.0] - 2025-01-XX

### Added
- Core package structure
- Abstract interfaces for cloud providers
- Pluggable architecture design
- Type-safe generic implementation
- Documentation and examples

[Unreleased]: https://github.com/TNT-Likely/BeeCount/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TNT-Likely/BeeCount/releases/tag/flutter_cloud_sync-v0.1.0
