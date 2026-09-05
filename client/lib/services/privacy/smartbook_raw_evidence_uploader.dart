import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../data/db.dart';
import 'raw_evidence_sync_service.dart';

/// A separate HTTP channel, never a ChangeTracker/pushChanges payload.
class SmartBookRawEvidenceUploader implements RawEvidenceUploader {
  final SmartBookCloudProvider cloud;
  final BeeDatabase db;

  SmartBookRawEvidenceUploader(this.cloud, this.db);

  @override
  Future<RawEvidenceUploadResult> upload(RawEvidenceEnvelope evidence) async {
    final payload = evidence.toJson()
      ..remove('local_event_id')
      ..remove('local_ledger_id');
    // Local integer ids are not server ledger ids. Unbound evidence remains
    // private to the uploading user even before the ledger has synced.
    if (evidence.ledgerId != null) {
      final ledger = await (db.select(db.ledgers)
            ..where((t) => t.id.equals(evidence.ledgerId!)))
          .getSingleOrNull();
      final externalId = ledger?.syncId;
      if (externalId != null && externalId.isNotEmpty) {
        payload['ledger_id'] = externalId;
      }
    }
    try {
      final saved = await cloud.upsertRawEvidence(payload: payload);
      return RawEvidenceUploadResult.accepted(remoteId: saved.id);
    } on CloudStorageException catch (error) {
      // The evidence transport exposes only a status code, never echoed input.
      if ([400, 410, 413, 422].contains(error.originalError)) {
        return const RawEvidenceUploadResult.rejected();
      }
      rethrow;
    }
  }
}
