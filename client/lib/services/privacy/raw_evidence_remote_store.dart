import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// Deliberately has no write/reparse method: viewers cannot trigger bookkeeping.
abstract interface class RawEvidenceRemoteStore {
  Future<SmartBookCloudRawEvidenceList> list({String? source, int offset = 0});
  Future<SmartBookCloudRawEvidence> get(String id);
  Future<void> delete(String id);
  Future<int> cleanup({String? source, DateTime? before});
}

class SmartBookRawEvidenceRemoteStore implements RawEvidenceRemoteStore {
  final SmartBookCloudProvider cloud;
  SmartBookRawEvidenceRemoteStore(this.cloud);

  @override
  Future<SmartBookCloudRawEvidenceList> list(
          {String? source, int offset = 0}) =>
      cloud.listRawEvidence(source: source, offset: offset, limit: 30);
  @override
  Future<SmartBookCloudRawEvidence> get(String id) =>
      cloud.getRawEvidence(evidenceId: id);
  @override
  Future<void> delete(String id) => cloud.deleteRawEvidence(evidenceId: id);
  @override
  Future<int> cleanup({String? source, DateTime? before}) =>
      cloud.cleanupRawEvidence(source: source, before: before);
}
