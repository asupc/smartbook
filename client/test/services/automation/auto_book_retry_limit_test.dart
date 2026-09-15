/// P1-A1 / P1-A2 回归(design-flaw-fix-plan 2026-09-15):
/// - A1:`markRetry` 重试上限(8 次)—— 用尽落 `failed` + `retry_exhausted`,
///   不再无限 2h 重试;手动重试(`resetRetryGate`)复活时 attemptCount 归零。
/// - A1:证据消失(`BookkeepingResult.evidenceMissing`)→ `expired` 终态,
///   不进退避阶梯(截图文件等待超时路径)。
/// - A2:`ensure` 未传 expiresAt 时按 capturedAt+30d 兜底;存量 NULL 行
///   一次性回填(占位行豁免);回填后 `cleanupExpired` 物理删除生效。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/ai/bookkeeping_result.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart'
    show BookkeepingResultEvent;
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late AutoBookEventStore store;
  late AutoBookCoordinator coordinator;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
    coordinator = AutoBookCoordinator(db);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  // 整秒 DateTime:drift 默认按秒级 unix 时间戳存取,亚秒部分会丢失,
  // 断言「capturedAt+30d 精确相等」需要整秒输入。
  final capturedAt = DateTime.utc(2026, 9, 1, 12);

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: capturedAt,
      );

  group('A1: markRetry 重试上限', () {
    test('attemptCount 在上限内 → retry + 阶梯退避(第 7 次仍是 2h 档)', () async {
      final event = await store.ensure(input('sms:a1:ladder'));

      await store.markRetry(
          eventId: event.id, attemptCount: 7, error: 'ai_retryable');

      final row = await store.findById(event.id);
      expect(row!.state, 'retry');
      expect(row.reason, isNull);
      final gap = row.nextRetryAt!.difference(DateTime.now()).inSeconds;
      expect(gap, inInclusiveRange(7000, 7200),
          reason: '第 7 次仍按 2h 退避,尚未用尽');
    });

    test('attemptCount 达上限 → failed/retry_exhausted 终态,清退避与草稿',
        () async {
      final event = await store.ensure(input('sms:a1:exhausted'));
      // 先挂一份离线草稿:终态化时必须一并清掉,否则 dueDrafts 会长期选中
      // failed 行占住 limit,挤掉新草稿(重放又因终态被 claim 拒绝,空转)。
      expect(
          await store.saveDraftByEventKey(
              'sms:a1:exhausted',
              const AutoBookDraftPayload(
                  isImage: false, text: '草稿正文')),
          isTrue);

      await store.markRetry(
          eventId: event.id, attemptCount: 8, error: 'ai_retryable');

      final row = await store.findById(event.id);
      expect(row!.state, 'failed');
      expect(row.reason, 'retry_exhausted');
      expect(row.nextRetryAt, isNull);
      expect(row.draftPayloadJson, isNull);
      expect(row.lastError, 'ai_retryable');
    });

    test('coordinator 全链路:连续可重试失败在第 8 次后停在 failed;手动重试复活',
        () async {
      Future<AutoBookExecution<BookkeepingResult>> runOnce() {
        return coordinator.execute<BookkeepingResult>(
          input: input('sms:a1:loop'),
          action: () async => const BookkeepingResult(retryable: true),
          updateFor: (result) => result.eventUpdate,
        );
      }

      // 7 次:每次都落 retry(带退避),用 resetRetryGate 清闸门模拟退避到期。
      for (var i = 0; i < 7; i++) {
        final execution = await runOnce();
        expect(execution.state, AutoBookState.retry,
            reason: '第 ${i + 1} 次尝试应仍是 retry');
        await store.resetRetryGate(execution.eventId);
      }

      // 第 8 次:用尽 → failed 终态。
      final exhausted = await runOnce();
      expect(exhausted.state, AutoBookState.failed);
      // 执行结果反映真实终态(A1:coordinator 回读)—— 监听层据此 ACK 原生
      // 队列,而不是拿着 retry 不 ACK、等下轮 drain 补。
      expect(exhausted.terminal, isTrue);
      final row = await store.findById(exhausted.eventId);
      expect(row!.state, 'failed');
      expect(row.reason, 'retry_exhausted');
      expect(row.attemptCount, 8);

      // 终态后自动路径不再执行(claim 拒绝)。
      final ninth = await runOnce();
      expect(ninth.skipped, isTrue);
      expect(ninth.state, AutoBookState.failed);

      // 手动重试复活:failed → retry 且 attemptCount 归零(复活后第一次
      // 可重试失败不会立刻再次用尽,用户买到完整的新退避阶梯)。
      await store.resetRetryGate(exhausted.eventId);
      final revived = await store.findById(exhausted.eventId);
      expect(revived!.state, 'retry');
      expect(revived.attemptCount, 0);

      final manual = await coordinator.execute<BookkeepingResult>(
        input: input('sms:a1:loop'),
        action: () async => const BookkeepingResult(transactionIds: [42]),
        updateFor: (result) => result.eventUpdate,
      );
      expect(manual.state, AutoBookState.booked);
      expect((await store.findById(manual.eventId))!.attemptCount, 1);
    });
  });

  group('A1: 证据消失 → expired(截图文件等待超时路径)', () {
    test('evidenceMissing 结果映射为 expired 终态 + 原因码,不进 retry', () {
      const result = BookkeepingResult(evidenceMissing: true);
      final update = result.eventUpdate;

      expect(update.state, AutoBookState.expired);
      expect(update.reason, 'evidence_missing');
      // 不是 retry:coordinator 的 M1-3 分流不会把它送进 markRetry 退避。
      expect(update.state, isNot(AutoBookState.retry));
      // expired 属于终态集合:原生队列据此 ACK,不再每轮 drain 白等 3s。
      expect(
        AutoBookExecution<BookkeepingResult>(
          skipped: false,
          value: null,
          state: update.state,
          eventId: 1,
        ).terminal,
        isTrue,
      );
    });
  });

  group('A2: 证据有效期 expiresAt', () {
    test('ensure 未传 expiresAt → 按 capturedAt+30d 兜底落列', () async {
      final event = await store.ensure(input('sms:a2:default'));
      final row = await store.findById(event.id);
      // drift 默认按秒级 unix 时间戳存取(读回为本地时区 DateTime),精确
      // 相等断言用 epoch毫秒 比较,整秒 fixture 下无损。
      expect(row!.expiresAt!.millisecondsSinceEpoch,
          capturedAt.add(const Duration(days: 30)).millisecondsSinceEpoch);
    });

    test('显式 expiresAt 优先于兜底默认', () async {
      final custom = capturedAt.add(const Duration(days: 7));
      final event = await store.ensure(AutoBookInput(
        eventKey: 'sms:a2:custom',
        source: AutoBookSource.sms,
        capturedAt: capturedAt,
        expiresAt: custom,
      ));
      expect((await store.findById(event.id))!.expiresAt!.millisecondsSinceEpoch,
          custom.millisecondsSinceEpoch);
    });

    test('backfillMissingExpiresAt:回填存量 NULL 行,占位行豁免,幂等', () async {
      // 直接插行模拟「历史版本从不写 expiresAt」的存量数据(绕过 ensure 的
      // 兜底默认)。
      final legacyId = await db.into(db.autoBookEvents).insert(
            AutoBookEventsCompanion.insert(
              eventKey: 'legacy:null-expires',
              source: 'sms',
              capturedAt: capturedAt,
            ),
          );
      final placeholderId = await db.into(db.autoBookEvents).insert(
            AutoBookEventsCompanion.insert(
              eventKey: 'legacy:expired-placeholder',
              source: 'sms',
              capturedAt: capturedAt,
              state: const d.Value('expired'),
            ),
          );

      final backfilled = await store.backfillMissingExpiresAt();
      expect(backfilled, 1, reason: '只回填 NULL 且非 expired 占位的行');

      expect(
        (await store.findById(legacyId))!.expiresAt!.millisecondsSinceEpoch,
        capturedAt.add(const Duration(days: 30)).millisecondsSinceEpoch,
      );
      expect((await store.findById(placeholderId))!.expiresAt, isNull,
          reason: '占位行的 expiresAt 是被 cleanupExpired 有意置空的,不回填');

      expect(await store.backfillMissingExpiresAt(), 0, reason: '幂等:二次调用无行可补');
    });

    test('cleanupExpired:回填后的过期存量行被物理删除(A2 主出口)', () async {
      final old = await db.into(db.autoBookEvents).insert(
            AutoBookEventsCompanion.insert(
              eventKey: 'legacy:older-than-30d',
              source: 'sms',
              capturedAt:
                  DateTime.now().toUtc().subtract(const Duration(days: 40)),
            ),
          );
      // fresh 用动态时刻(而非固定 fixture),保证「+30d 永远在未来」,
      // 测试不会随日历推进而翻转。
      final fresh = await store.ensure(AutoBookInput(
        eventKey: 'sms:a2:fresh',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
      ));

      await store.cleanupExpired();

      expect(await store.findById(old), isNull,
          reason: '存量行被回填 capturedAt+30d(已过期)后,DELETE 终于命中');
      expect(await store.findById(fresh.id), isNotNull,
          reason: '未过期的新事件不受影响');
    });
  });
}
