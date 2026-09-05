import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Policy for one raw-evidence source.
///
/// Local retention and server retention are independent. When server upload is
/// enabled while local retention is disabled, the client keeps a transient
/// queue row until upload succeeds; it is then cleared automatically.
class RawEvidenceSourcePolicy {
  static const int minRetentionDays = 0;
  static const int maxRetentionDays = 3650;

  final bool localEnabled;
  final int localRetentionDays;
  final bool serverEnabled;
  final int serverRetentionDays;

  const RawEvidenceSourcePolicy({
    this.localEnabled = false,
    this.localRetentionDays = 30,
    this.serverEnabled = false,
    this.serverRetentionDays = 30,
  });

  RawEvidenceSourcePolicy copyWith({
    bool? localEnabled,
    int? localRetentionDays,
    bool? serverEnabled,
    int? serverRetentionDays,
  }) {
    return RawEvidenceSourcePolicy(
      localEnabled: localEnabled ?? this.localEnabled,
      localRetentionDays:
          clampDays(localRetentionDays ?? this.localRetentionDays),
      serverEnabled: serverEnabled ?? this.serverEnabled,
      serverRetentionDays:
          clampDays(serverRetentionDays ?? this.serverRetentionDays),
    );
  }

  Map<String, dynamic> toJson() => {
        'localEnabled': localEnabled,
        'localRetentionDays': localRetentionDays,
        'serverEnabled': serverEnabled,
        'serverRetentionDays': serverRetentionDays,
      };

  factory RawEvidenceSourcePolicy.fromJson(Object? value) {
    if (value is! Map) return const RawEvidenceSourcePolicy();
    return RawEvidenceSourcePolicy(
      localEnabled: value['localEnabled'] == true,
      localRetentionDays: clampDays(value['localRetentionDays'], fallback: 30),
      serverEnabled: value['serverEnabled'] == true,
      serverRetentionDays:
          clampDays(value['serverRetentionDays'], fallback: 30),
    );
  }

  static int clampDays(Object? value, {int fallback = 30}) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return (parsed ?? fallback)
        .clamp(minRetentionDays, maxRetentionDays)
        .toInt();
  }
}

/// App-wide raw evidence policy with optional per-source overrides.
class RawEvidencePolicy {
  final RawEvidenceSourcePolicy defaultPolicy;
  final Map<String, RawEvidenceSourcePolicy> sourcePolicies;

  const RawEvidencePolicy({
    this.defaultPolicy = const RawEvidenceSourcePolicy(),
    this.sourcePolicies = const <String, RawEvidenceSourcePolicy>{},
  });

  /// Compatibility accessors for the first uploader implementation.
  bool get localEnabled => defaultPolicy.localEnabled;
  bool get serverEnabled => defaultPolicy.serverEnabled;
  int get retentionDays => defaultPolicy.serverEnabled
      ? defaultPolicy.serverRetentionDays
      : defaultPolicy.localRetentionDays;

  static const defaults = RawEvidencePolicy();

  RawEvidenceSourcePolicy forSource(String source) {
    return sourcePolicies[source.trim()] ?? defaultPolicy;
  }

  RawEvidencePolicy copyWith({
    RawEvidenceSourcePolicy? defaultPolicy,
    Map<String, RawEvidenceSourcePolicy>? sourcePolicies,
  }) {
    return RawEvidencePolicy(
      defaultPolicy: defaultPolicy ?? this.defaultPolicy,
      sourcePolicies: Map.unmodifiable(sourcePolicies ?? this.sourcePolicies),
    );
  }

  RawEvidencePolicy withSourcePolicy(
    String source,
    RawEvidenceSourcePolicy policy,
  ) {
    final key = source.trim();
    if (key.isEmpty) return this;
    return copyWith(sourcePolicies: {...sourcePolicies, key: policy});
  }

  Map<String, dynamic> toJson() => {
        'default': defaultPolicy.toJson(),
        'sources': {
          for (final entry in sourcePolicies.entries)
            entry.key: entry.value.toJson(),
        },
      };

  factory RawEvidencePolicy.fromJson(Object? value) {
    if (value is! Map) return RawEvidencePolicy.defaults;
    final rawSources = value['sources'];
    final sources = <String, RawEvidenceSourcePolicy>{};
    if (rawSources is Map) {
      for (final entry in rawSources.entries) {
        final key = '${entry.key}'.trim();
        if (key.isNotEmpty) {
          sources[key] = RawEvidenceSourcePolicy.fromJson(entry.value);
        }
      }
    }
    return RawEvidencePolicy(
      defaultPolicy: RawEvidenceSourcePolicy.fromJson(value['default']),
      sourcePolicies: Map.unmodifiable(sources),
    );
  }

  /// Computes the retention windows captured on an event row.
  RawEvidenceCapturePlan planFor(String source, DateTime capturedAt) {
    final sourcePolicy = forSource(source);
    final localUntil = sourcePolicy.localEnabled
        ? capturedAt.add(Duration(days: sourcePolicy.localRetentionDays))
        : null;
    final serverUntil = sourcePolicy.serverEnabled
        ? capturedAt.add(Duration(days: sourcePolicy.serverRetentionDays))
        : null;
    return RawEvidenceCapturePlan(
      localEnabled: sourcePolicy.localEnabled,
      serverEnabled: sourcePolicy.serverEnabled,
      localExpiresAt: localUntil,
      serverExpiresAt: serverUntil,
      uploadState: sourcePolicy.serverEnabled
          ? RawEvidenceUploadState.pending
          : RawEvidenceUploadState.notRequested,
    );
  }
}

class RawEvidenceCapturePlan {
  final bool localEnabled;
  final bool serverEnabled;
  final DateTime? localExpiresAt;
  final DateTime? serverExpiresAt;
  final String uploadState;

  const RawEvidenceCapturePlan({
    required this.localEnabled,
    required this.serverEnabled,
    required this.localExpiresAt,
    required this.serverExpiresAt,
    required this.uploadState,
  });

  bool get shouldStore {
    final now = DateTime.now();
    return (localEnabled && (localExpiresAt == null || localExpiresAt!.isAfter(now))) ||
        (serverEnabled && (serverExpiresAt == null || serverExpiresAt!.isAfter(now)));
  }

  /// Backward-compatible queue/GC window: the later of local and server
  /// expiry. New code should inspect the two independent fields instead.
  DateTime? get retentionUntil {
    if (localExpiresAt == null) return serverExpiresAt;
    if (serverExpiresAt == null) return localExpiresAt;
    return serverExpiresAt!.isAfter(localExpiresAt!)
        ? serverExpiresAt
        : localExpiresAt;
  }
}

/// SharedPreferences-backed policy service. It has no Riverpod/provider
/// dependency, so background/native capture code can use it directly.
class RawEvidencePolicyStore {
  static const storageKey = 'raw_evidence_policy_v1';

  // Legacy keys are read for one-way compatibility with the first prototype.
  static const localKey = 'raw_evidence_local_enabled';
  static const serverKey = 'raw_evidence_server_enabled';
  static const retentionKey = 'raw_evidence_retention_days';

  final SharedPreferences? _providedPreferences;
  RawEvidencePolicy? _cache;

  RawEvidencePolicyStore({SharedPreferences? preferences})
      : _providedPreferences = preferences;

  Future<SharedPreferences> _preferences() async {
    return _providedPreferences ?? await SharedPreferences.getInstance();
  }

  Future<RawEvidencePolicy> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await _preferences();
    final encoded = prefs.getString(storageKey);
    if (encoded != null && encoded.trim().isNotEmpty) {
      try {
        return _cache = RawEvidencePolicy.fromJson(jsonDecode(encoded));
      } catch (_) {
        // Fall through to defaults/legacy keys.
      }
    }
    final hasLegacy = prefs.containsKey(localKey) ||
        prefs.containsKey(serverKey) ||
        prefs.containsKey(retentionKey);
    if (hasLegacy) {
      final legacyDefault = RawEvidenceSourcePolicy(
        localEnabled: prefs.getBool(localKey) ?? false,
        localRetentionDays:
            RawEvidenceSourcePolicy.clampDays(prefs.getInt(retentionKey)),
        serverEnabled: prefs.getBool(serverKey) ?? false,
        serverRetentionDays:
            RawEvidenceSourcePolicy.clampDays(prefs.getInt(retentionKey)),
      );
      return _cache = RawEvidencePolicy(defaultPolicy: legacyDefault);
    }
    return _cache = RawEvidencePolicy.defaults;
  }

  Future<void> save(RawEvidencePolicy policy) async {
    final prefs = await _preferences();
    await prefs.setString(storageKey, jsonEncode(policy.toJson()));
    _cache = policy;
  }

  Future<RawEvidencePolicy> update(
    RawEvidencePolicy Function(RawEvidencePolicy current) transform,
  ) async {
    final next = transform(await load());
    await save(next);
    return next;
  }

  Future<RawEvidencePolicy> setDefault(RawEvidenceSourcePolicy policy) {
    return update((current) => current.copyWith(defaultPolicy: policy));
  }

  Future<RawEvidencePolicy> setSource(
    String source,
    RawEvidenceSourcePolicy policy,
  ) {
    return update((current) => current.withSourcePolicy(source, policy));
  }

  Future<void> reset() async {
    final prefs = await _preferences();
    await prefs.remove(storageKey);
    _cache = null;
  }

  /// Compatibility helper used by old capture/store code.
  static Future<bool> localCaptureEnabled() async {
    final policy = await RawEvidencePolicyStore().load();
    return policy.defaultPolicy.localEnabled ||
        policy.defaultPolicy.serverEnabled;
  }
}

/// Upload states are deliberately separate from AutoBookEvent.state.
abstract final class RawEvidenceUploadState {
  static const notRequested = 'not_requested';
  static const pending = 'pending';
  static const uploading = 'uploading';
  static const uploaded = 'uploaded';
  static const retry = 'retry';
  static const rejected = 'rejected';
  static const cleared = 'cleared';
  static const expired = 'expired';
}
