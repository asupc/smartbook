import 'package:meta/meta.dart';

/// Sync state enumeration
enum SyncState {
  /// Cloud service not configured
  notConfigured,

  /// User not authenticated
  notAuthenticated,

  /// Only local data exists, no cloud backup
  localOnly,

  /// Data is synchronized (local and cloud match)
  synced,

  /// Data is out of sync (local and cloud differ)
  outOfSync,

  /// Upload in progress
  uploading,

  /// Download in progress
  downloading,

  /// Error occurred
  error,

  /// Unknown state
  unknown,
}

/// Sync direction when data is out of sync
enum SyncDirection {
  /// Local data is newer than cloud
  localNewer,

  /// Cloud data is newer than local
  cloudNewer,

  /// Cannot determine which is newer
  unknown,
}

/// Sync status information
@immutable
class SyncStatus {
  /// Current sync state
  final SyncState state;

  /// Local data fingerprint (optional)
  final String? localFingerprint;

  /// Cloud data fingerprint (optional)
  final String? cloudFingerprint;

  /// Last sync timestamp (optional)
  final DateTime? lastSyncedAt;

  /// Local data updated timestamp (optional)
  final DateTime? localUpdatedAt;

  /// Cloud data updated timestamp (optional)
  final DateTime? cloudUpdatedAt;

  /// Sync direction when out of sync (optional)
  final SyncDirection? direction;

  /// Local data count (optional)
  final int? localCount;

  /// Cloud data count (optional)
  final int? cloudCount;

  /// Status message or error description (optional)
  final String? message;

  /// Progress percentage (0.0 - 1.0, optional)
  final double? progress;

  const SyncStatus({
    required this.state,
    this.localFingerprint,
    this.cloudFingerprint,
    this.lastSyncedAt,
    this.localUpdatedAt,
    this.cloudUpdatedAt,
    this.direction,
    this.localCount,
    this.cloudCount,
    this.message,
    this.progress,
  });

  /// Whether data is synchronized
  bool get isSynced => state == SyncState.synced;

  /// Whether sync is needed
  bool get needsSync =>
      state == SyncState.outOfSync || state == SyncState.localOnly;

  /// Whether sync is possible
  bool get canSync =>
      state != SyncState.notConfigured &&
      state != SyncState.notAuthenticated &&
      state != SyncState.uploading &&
      state != SyncState.downloading;

  /// Whether an operation is in progress
  bool get isLoading =>
      state == SyncState.uploading || state == SyncState.downloading;

  /// Whether local data is newer than cloud
  bool get isLocalNewer => direction == SyncDirection.localNewer;

  /// Whether cloud data is newer than local
  bool get isCloudNewer => direction == SyncDirection.cloudNewer;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStatus &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          localFingerprint == other.localFingerprint &&
          cloudFingerprint == other.cloudFingerprint;

  @override
  int get hashCode =>
      state.hashCode ^ localFingerprint.hashCode ^ cloudFingerprint.hashCode;

  @override
  String toString() => 'SyncStatus(state: $state, message: $message)';

  /// Create a copy with modified fields
  SyncStatus copyWith({
    SyncState? state,
    String? localFingerprint,
    String? cloudFingerprint,
    DateTime? lastSyncedAt,
    DateTime? localUpdatedAt,
    DateTime? cloudUpdatedAt,
    SyncDirection? direction,
    int? localCount,
    int? cloudCount,
    String? message,
    double? progress,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      localFingerprint: localFingerprint ?? this.localFingerprint,
      cloudFingerprint: cloudFingerprint ?? this.cloudFingerprint,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      localUpdatedAt: localUpdatedAt ?? this.localUpdatedAt,
      cloudUpdatedAt: cloudUpdatedAt ?? this.cloudUpdatedAt,
      direction: direction ?? this.direction,
      localCount: localCount ?? this.localCount,
      cloudCount: cloudCount ?? this.cloudCount,
      message: message ?? this.message,
      progress: progress ?? this.progress,
    );
  }
}
