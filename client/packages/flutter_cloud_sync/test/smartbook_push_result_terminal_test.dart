/// 低-3 / 中-1 支撑(2026-10-11 三轮复查):SmartBookPushResult 终态拒绝面。
///
/// `terminalRejectionReasons` 必须与 `server/src/routers/sync/push.py` 的
/// 终态 reason **逐字**同步(ledger_deleted / membership_revoked /
/// unknown_ledger / sync_id_mismatch / entity_sync_id_too_long);
/// `terminalRejectionSamples` 是调用方(SyncEngine)丢弃 + 落错误行的依据。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

SmartBookPushResult _result({
  List<Map<String, dynamic>> conflict = const [],
  List<Map<String, dynamic>> failed = const [],
}) {
  return SmartBookPushResult(
    accepted: 0,
    rejected: conflict.length + failed.length,
    conflictCount: conflict.length,
    conflictSamples: conflict,
    failedCount: failed.length,
    failedSamples: failed,
    serverCursor: 0,
  );
}

void main() {
  test('terminalRejectionReasons 与 push.py 终态 reason 逐字一致', () {
    // 对照 server/src/routers/sync/push.py(:538/:570/:611/:657/:682)。
    expect(SmartBookPushResult.terminalRejectionReasons, {
      'membership_revoked',
      'unknown_ledger',
      'ledger_deleted',
      'sync_id_mismatch',
      'entity_sync_id_too_long',
    });
  });

  test('terminalRejectionSamples:failed_samples 里的终态 reason 被筛出',
      () {
    final r = _result(failed: [
      const {
        'reason': 'ledger_deleted',
        'ledgerId': 'L1',
        'entityType': 'transaction',
        'entitySyncId': 'tx-1',
      },
      const {
        'reason': 'apply_failed',
        'entityType': 'transaction',
        'entitySyncId': 'tx-2',
      },
    ]);
    final samples = r.terminalRejectionSamples;
    expect(samples, hasLength(1));
    expect(samples.single['reason'], 'ledger_deleted');
    expect(samples.single['entitySyncId'], 'tx-1');
  });

  test('terminalRejectionSamples:conflict_samples 里的终态 reason 也被筛出',
      () {
    final r = _result(conflict: [
      const {
        'reason': 'membership_revoked',
        'entityType': 'budget',
        'entitySyncId': 'bud-1',
      },
      const {
        'reason': 'lww_rejected_older_change',
        'entitySyncId': 'tx-3',
      },
      const {
        'reason': 'lww_tie_action_kept',
        'entitySyncId': 'tx-4',
      },
    ]);
    final samples = r.terminalRejectionSamples;
    expect(samples, hasLength(1));
    expect(samples.single['reason'], 'membership_revoked');
  });

  test('LWW / apply_failed 非终态 → rejectedEntitySyncIds 照旧(重试语义)',
      () {
    final r = _result(
      conflict: [
        const {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-3'}
      ],
      failed: [
        const {'reason': 'apply_failed', 'entitySyncId': 'tx-2'}
      ],
    );
    expect(r.terminalRejectionSamples, isEmpty);
    expect(r.rejectedEntitySyncIds, {'tx-3', 'tx-2'});
  });
}
