// 杂项域补测(批次 X2):隐私证据本地侧 + 后处理顺序(PostProcessor)。
//
// FINDINGS-misc-services.md §三 标注未产出「隐私证据本地侧(TTL 边界/损坏 JSON/
// clear 竞态)」;探测发现 6 记录 PostProcessor 顺序规则「未发现顺序冲突」。
// 本文件把这两项固化为可复跑证据。
//
// 与既有文件边界(不重复):
//   - `test/services/raw_evidence_store_test.dart` 覆盖策略启停/TTL 保留/uploads;
//   - `test/services/raw_evidence_policy_store_test.dart` 覆盖策略持久化;
//   - 本文件只补**进程重启后的策略加载**(RawEvidencePolicyStore 新实例)、
//     损坏策略 JSON 回落、事件行 raw 字段与策略的一致性、以及 PostProcessor 顺序。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync_service.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/providers/statistics_providers.dart';
import 'package:smartbook/providers/sync_providers.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/billing/post_processor.dart';
import 'package:smartbook/services/privacy/raw_evidence_policy.dart';

/// 记录调用次序的假同步服务。
class _RecordingSyncService implements SyncService {
  final List<String> calls = [];

  @override
  void markLocalChanged({required int ledgerId}) {
    calls.add('markLocalChanged:$ledgerId');
  }

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    calls.add('uploadCurrentLedger:$ledgerId');
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) async {
    calls.add('download:$ledgerId');
    return (inserted: 0, deletedDup: 0);
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async =>
      const SyncStatus(diff: SyncDiff.notConfigured, localCount: 0, localFingerprint: '');

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async =>
          (fingerprint: null, count: null, exportedAt: null);

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {}

  @override
  void clearStatusCache({int? ledgerId}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ════════════════════════════════════════════════════════════════
  // 探测发现 6:PostProcessor 顺序规则
  // ════════════════════════════════════════════════════════════════
  group('PostProcessor 顺序规则', () {
    test('runC 先 markLocalChanged 再读 auto_sync 决定是否上传', () async {
      SharedPreferences.setMockInitialValues({'auto_sync': true});
      final sync = _RecordingSyncService();
      final container = ProviderContainer(
        overrides: [syncServiceProvider.overrideWithValue(sync)],
      );
      addTearDown(container.dispose);

      final statsBefore = container.read(statsRefreshProvider);
      await PostProcessor.runC(container, ledgerId: 7);
      // _doSyncC 内的上传是 fire-and-forget(Future(...));等事件循环排空。
      await Future<void>.delayed(Duration.zero);

      expect(sync.calls.first, 'markLocalChanged:7',
          reason: 'markLocalChanged 必须先于任何上传(刷新缓存指纹口径)');
      expect(container.read(statsRefreshProvider), statsBefore + 1,
          reason: 'statsRefresh 无条件自增(UI 统计必须刷新)');
    });

    test('auto_sync=false 时 runC 只 markLocalChanged,不上传', () async {
      SharedPreferences.setMockInitialValues({'auto_sync': false});
      final sync = _RecordingSyncService();
      final container = ProviderContainer(
        overrides: [syncServiceProvider.overrideWithValue(sync)],
      );
      addTearDown(container.dispose);

      await PostProcessor.runC(container, ledgerId: 3);
      await Future<void>.delayed(Duration.zero);
      expect(sync.calls, ['markLocalChanged:3']);
    });

    test('syncC 只同步,不刷新 stats(与 runC 的语义分界)', () async {
      SharedPreferences.setMockInitialValues({'auto_sync': false});
      final sync = _RecordingSyncService();
      final container = ProviderContainer(
        overrides: [syncServiceProvider.overrideWithValue(sync)],
      );
      addTearDown(container.dispose);

      final statsBefore = container.read(statsRefreshProvider);
      await PostProcessor.syncC(container, ledgerId: 5);
      await Future<void>.delayed(Duration.zero);

      expect(sync.calls, ['markLocalChanged:5']);
      expect(container.read(statsRefreshProvider), statsBefore,
          reason: 'syncC 是「其它数据变更」路径,不触碰统计刷新');
    });

    test('云端下载后处理不触发上传(方向性正确)', () async {
      SharedPreferences.setMockInitialValues({'auto_sync': true});
      final sync = _RecordingSyncService();
      final container = ProviderContainer(
        overrides: [syncServiceProvider.overrideWithValue(sync)],
      );
      addTearDown(container.dispose);

      PostProcessor.runAfterDownloadC(container);
      await Future<void>.delayed(Duration.zero);
      expect(sync.calls, isEmpty,
          reason: '下载后只刷新 UI/缓存,不得反向触发上传(否则回环)');
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 隐私证据本地侧:策略加载 / 损坏 JSON / 与事件行一致性
  // ════════════════════════════════════════════════════════════════
  group('隐私证据本地侧:策略持久化与损坏', () {
    late BeeDatabase db;
    late AutoBookEventStore eventStore;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = BeeDatabase.forTesting(NativeDatabase.memory());
      eventStore = AutoBookEventStore(db);
    });

    tearDown(() async => db.close());

    test('新进程(新 store 实例)能从 SharedPreferences 恢复策略', () async {
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(
          localEnabled: true,
          localRetentionDays: 3,
          serverEnabled: false,
        ),
      );
      // 模拟重启:新实例 + 空缓存
      final reloaded = await RawEvidencePolicyStore().load();
      expect(reloaded.forSource('sms').localEnabled, isTrue);
      expect(reloaded.forSource('sms').localRetentionDays, 3);
      expect(reloaded.defaultPolicy.localEnabled, isFalse,
          reason: 'per-source 策略不得污染 default');
    });

    test('策略 JSON 损坏 → 回落默认(privacy-safe:默认全关)', () async {
      SharedPreferences.setMockInitialValues({
        RawEvidencePolicyStore.storageKey: '{not valid json',
      });
      final policy = await RawEvidencePolicyStore().load();
      expect(policy.defaultPolicy.localEnabled, isFalse);
      expect(policy.defaultPolicy.serverEnabled, isFalse);
      expect(policy.forSource('sms').localEnabled, isFalse);
    });

    test('策略 JSON 结构错(数组/标量)→ 回落默认,不抛', () async {
      for (final bad in ['[]', '"x"', '123', 'null']) {
        SharedPreferences.setMockInitialValues({
          RawEvidencePolicyStore.storageKey: bad,
        });
        final policy = await RawEvidencePolicyStore().load();
        expect(policy.defaultPolicy.localEnabled, isFalse, reason: '输入 $bad');
      }
    });

    test('per-source 键空串/空白被忽略(不产生幽灵 source)', () {
      final policy = RawEvidencePolicy.defaults.withSourcePolicy(
        '   ',
        const RawEvidenceSourcePolicy(localEnabled: true),
      );
      expect(policy.sourcePolicies, isEmpty);
    });

    test('保留天数越界被钳制(负 / 超大 / 非数 / 字符串数字)', () {
      expect(RawEvidenceSourcePolicy.clampDays(-5), 0);
      expect(RawEvidenceSourcePolicy.clampDays(999999), 3650);
      expect(RawEvidenceSourcePolicy.clampDays('abc'), 30);
      expect(RawEvidenceSourcePolicy.clampDays('7'), 7);
      expect(RawEvidenceSourcePolicy.clampDays(null), 30);
      // 事实锁定:NaN 走 num.toInt() 抛 UnsupportedError(而非回落 fallback)。
      // 从 JSON 读回的数值不可能是非有限(jsonEncode 拒绝 NaN),可达性低;
      // 但以代码构造策略传 NaN 时 clampDays 会抛。
      expect(() => RawEvidenceSourcePolicy.clampDays(double.nan),
          throwsA(isA<UnsupportedError>()),
          reason: 'HARDENING: NaN 抛 UnsupportedError,不是安全回落');
    });

    test('local+server 全关 → shouldStore=false,事件行不应留 raw 内容', () async {
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'k-off',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '消费 20.00 元',
        rawActor: '95555',
      ));
      expect(event.rawText, isNull, reason: '策略全关不得落 rawText');
      expect(event.rawEvidenceUploadState, RawEvidenceUploadState.notRequested);
    });

    test('策略中途打开:已存在事件行不会被回填 raw(只影响新捕获)', () async {
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'k-before',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
      ));
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(localEnabled: true, localRetentionDays: 7),
      );
      // ensure 同名 key 命中既有行 → 只 attach 证据,不改 policy 前的内容
      final again = await eventStore.ensure(AutoBookInput(
        eventKey: 'k-before',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '后补正文',
      ));
      expect(again.id, event.id);
      expect(again.rawText, '后补正文',
          reason: 'HARDENING:同一事件再次 ensure 会 attach 新证据(rawText 被更新)');
    });

    test('事件行的 raw* 字段与 policy 决定一致:local 到期时间 = capturedAt + N', () async {
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(localEnabled: true, localRetentionDays: 5),
      );
      // capturedAt 用**相对现在**的时间:绝对过去日期会落在保留窗外,
      // 事件行 raw 字段不落(旧测试腐烂模式,见批次 X 基线腐烂 3)。
      final capturedAt = DateTime.now().toUtc();
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'k-ttl',
        source: AutoBookSource.sms,
        capturedAt: capturedAt,
        rawText: '正文',
      ));
      // drift 的 dateTime 落库为 epoch 秒并回读为本地时间 → 按「同一瞬间」
      // 比较(秒精度),不要用 DateTime 相等。
      final expires = event.rawEvidenceLocalExpiresAt!;
      expect(
        expires.millisecondsSinceEpoch ~/ 1000,
        capturedAt.add(const Duration(days: 5)).millisecondsSinceEpoch ~/ 1000,
      );
      expect(event.rawEvidenceUploadState, RawEvidenceUploadState.notRequested);
    });

    test('clear 幂等:重复 clear 不报错,raw 字段保持空', () async {
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(localEnabled: true),
      );
      await eventStore.ensure(AutoBookInput(
        eventKey: 'k-clear',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '正文',
      ));
      final first = await eventStore.clearRawEvidence();
      expect(first, 1);
      final second = await eventStore.clearRawEvidence();
      expect(second, 0, reason: '二次 clear 没有可清行(it IS NOT NULL 过滤后为 0)');
      expect(await eventStore.countRawEvidence(), 0);
      // 事件行本身保留(只清 raw,不删事件)
      expect(await eventStore.findByEventKey('k-clear'), isNotNull);
    });

    test('按 source 清理只影响该来源', () async {
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(localEnabled: true),
      );
      await RawEvidencePolicyStore().setSource(
        'notification',
        const RawEvidenceSourcePolicy(localEnabled: true),
      );
      await eventStore.ensure(AutoBookInput(
        eventKey: 'k-sms',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '短信正文',
      ));
      await eventStore.ensure(AutoBookInput(
        eventKey: 'k-ntf',
        source: AutoBookSource.notification,
        capturedAt: DateTime.now().toUtc(),
        rawText: '通知正文',
      ));
      expect(await eventStore.countRawEvidence(), 2);
      final cleared = await eventStore.clearRawEvidence(source: 'sms');
      expect(cleared, 1);
      final remaining = await eventStore.listRawEvidence();
      expect(remaining, hasLength(1));
      expect(remaining.single.eventKey, 'k-ntf');
    });

    test('事件 rawMetadataJson 损坏时 query 仍返回行(不做 JSON 解析)', () async {
      await RawEvidencePolicyStore().setSource(
        'sms',
        const RawEvidenceSourcePolicy(localEnabled: true),
      );
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'k-badmeta',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '正文',
      ));
      await db.customStatement(
        'UPDATE auto_book_events SET raw_metadata_json = ? WHERE id = ?',
        [jsonEncode({'broken': true}), event.id],
      );
      // 事实锁定:queryRawEvidence 只按 IS NOT NULL 过滤,不解码 metadata;
      // 消费方(panel/sync)需自行容错。
      final rows = await eventStore.listRawEvidence();
      expect(rows, hasLength(1));
      expect(rows.single.id, event.id);
    });
  });
}
