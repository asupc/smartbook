import 'dart:convert';

import '../../data/db.dart' as schema;
import '../automation/auto_book_event_store.dart';
import 'raw_evidence_policy.dart';

class RawEvidenceEnvelope {
  final int eventId;
  final String eventKey;
  final String source;
  final int? ledgerId;
  final String? sourceChannel;
  final String? externalId;
  final String? rawTitle;
  final String? rawText;
  final String? rawActor;
  final Map<String, dynamic>? rawMetadata;
  final DateTime capturedAt;
  final DateTime? sourceOccurredAt;
  final DateTime? serverExpiresAt;
  final String? contentHash;

  const RawEvidenceEnvelope({
    required this.eventId,
    required this.eventKey,
    required this.source,
    required this.capturedAt,
    this.ledgerId,
    this.sourceChannel,
    this.externalId,
    this.rawTitle,
    this.rawText,
    this.rawActor,
    this.rawMetadata,
    this.sourceOccurredAt,
    this.serverExpiresAt,
    this.contentHash,
  });

  factory RawEvidenceEnvelope.fromEvent(schema.AutoBookEvent event) {
    Map<String, dynamic>? metadata;
    final encoded = event.rawMetadataJson;
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          metadata = decoded.map((key, value) => MapEntry('$key', value));
        }
      } catch (_) {
        // Keep the rest of the evidence uploadable if legacy metadata is bad.
      }
    }
    return RawEvidenceEnvelope(
      eventId: event.id,
      eventKey: event.eventKey,
      source: event.source,
      ledgerId: event.ledgerId,
      sourceChannel: event.sourceChannel,
      externalId: event.externalId,
      rawTitle: event.rawTitle,
      rawText: event.rawText,
      rawActor: event.rawActor,
      rawMetadata: metadata,
      capturedAt: event.capturedAt,
      sourceOccurredAt: event.sourceOccurredAt,
      serverExpiresAt:
          event.rawEvidenceServerExpiresAt ?? event.rawEvidenceRetentionUntil,
      contentHash: event.contentHash,
    );
  }

  /// Canonical transport shape. This is intentionally separate from normal
  /// transaction sync and never becomes a sync_changes payload.
  Map<String, dynamic> toJson() => {
        'local_event_id': eventId,
        'event_key': eventKey,
        'source': source,
        if (ledgerId != null) 'local_ledger_id': ledgerId,
        if (sourceChannel != null) 'source_channel': sourceChannel,
        if (externalId != null) 'external_id': externalId,
        if (rawTitle != null) 'title': rawTitle,
        if (rawText != null) 'body': rawText,
        if (rawActor != null) 'actor': rawActor,
        'metadata': rawMetadata ?? const <String, dynamic>{},
        'captured_at': capturedAt.toUtc().toIso8601String(),
        if (sourceOccurredAt != null)
          'occurred_at': sourceOccurredAt!.toUtc().toIso8601String(),
        if (serverExpiresAt != null)
          'expires_at': serverExpiresAt!.toUtc().toIso8601String(),
        if (contentHash != null) 'content_hash': contentHash,
      };
}

class RawEvidenceUploadResult {
  final bool accepted;
  final String? remoteId;

  const RawEvidenceUploadResult({required this.accepted, this.remoteId});

  const RawEvidenceUploadResult.accepted({String? remoteId})
      : this(accepted: true, remoteId: remoteId);

  const RawEvidenceUploadResult.rejected() : this(accepted: false);
}

/// Backend adapter. Keeping this interface independent of HTTP lets local
/// capture and retention be tested without requiring a configured cloud.
abstract interface class RawEvidenceUploader {
  Future<RawEvidenceUploadResult> upload(RawEvidenceEnvelope evidence);
}

class RawEvidenceSyncService {
  final AutoBookEventStore store;
  RawEvidenceUploader? uploader;
  Future<void>? _running;

  RawEvidenceSyncService(this.store, {this.uploader});

  /// Serializes host-triggered runs so two normal sync callbacks cannot upload
  /// the same event concurrently.
  Future<void> syncPending({int limit = 50}) {
    return _running ??= _syncPending(limit).whenComplete(() => _running = null);
  }

  Future<void> _syncPending(int limit) async {
    await store.cleanupExpiredRawEvidence();
    await uploadPending(limit: limit);
    await store.cleanupExpiredRawEvidence();
  }

  Future<int> uploadPending({int limit = 50}) async {
    final currentUploader = uploader;
    if (currentUploader == null) return 0;
    final events = await store.listRawEvidence(
      uploadableOnly: true,
      limit: limit,
    );
    var uploaded = 0;
    for (final event in events) {
      if (!identical(currentUploader, uploader)) break;
      if (await uploadEvent(event.id, currentUploader: currentUploader)) {
        uploaded++;
      }
    }
    return uploaded;
  }

  Future<bool> uploadEvent(
    int eventId, {
    RawEvidenceUploader? currentUploader,
  }) async {
    final target = currentUploader ?? uploader;
    if (target == null) return false;
    final event = await store.findById(eventId);
    if (event == null ||
        !event.rawEvidenceServerEnabled ||
        event.rawEvidenceUploadedAt != null ||
        [
          RawEvidenceUploadState.cleared,
          RawEvidenceUploadState.expired,
          RawEvidenceUploadState.rejected
        ].contains(event.rawEvidenceUploadState) ||
        (event.rawEvidenceNextRetryAt?.isAfter(DateTime.now()) ?? false) ||
        (event.rawEvidenceServerExpiresAt != null &&
            !event.rawEvidenceServerExpiresAt!.isAfter(DateTime.now())) ||
        (event.rawText == null &&
            event.rawTitle == null &&
            event.rawActor == null &&
            event.rawMetadataJson == null)) {
      return false;
    }

    await store.markRawEvidenceUploading(eventId);
    try {
      final result = await target.upload(RawEvidenceEnvelope.fromEvent(event));
      if (result.accepted) {
        await store.markRawEvidenceUploadSucceeded(eventId);
        return true;
      }
      await store.markRawEvidenceUploadFailed(
        eventId,
        'uploader_rejected',
        state: RawEvidenceUploadState.rejected,
      );
      return false;
    } catch (error) {
      await store.markRawEvidenceUploadFailed(eventId, 'upload_failed');
      return false;
    }
  }
}
