/// 对抗性测试 1/4:AutoBookEventStore 生命周期(ensure / claim 租约 / mark /
/// TTL / cleanupExpired / backfill / listHistory / 子项聚合)。
///
/// 纪律:
/// - 确认缺陷 → 测试保持激活并失败,注释 `// ADVERSE FINDING: <标题>`;
/// - 可辩护但脆弱 → 断言当前行为并通过,注释 `// HARDENING: <说明>`;
/// - 时间一律相对 `DateTime.now()` 构造,禁止固定日期(防 TTL 腐烂)。
library;

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/privacy/raw_evidence_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late AutoBookEventStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  AutoBookInput input(
    String key, {
    AutoBookSource source = AutoBookSource.sms,
    DateTime? capturedAt,
    String? rawText,
    Map<String, dynamic>? rawMetadata,
    DateTime? expiresAt,
    int? ledgerId,
    String? sourceChannel,
  }) =>
      AutoBookInput(
        eventKey: key,
        source: source,
        capturedAt: capturedAt ?? DateTime.now(),
        rawText: rawText,
        rawMetadata: rawMetadata,
        expiresAt: expiresAt,
        ledgerId: ledgerId,
        sourceChannel: sourceChannel,
      );

  /// 直接把事件行的生命周期列改成任意值(测试构造老库 / 边界状态用)。
  Future<void> forceRow(
    int id, {
    String? state,
    DateTime? updatedAt,
    DateTime? nextRetryAt,
    DateTime? expiresAt,
    DateTime? rawEvidenceServerExpiresAt,
    String? rawEvidenceUploadState,
    bool? rawEvidenceServerEnabled,
  }) {
    return (db.update(db.autoBookEvents)..where((t) => t.id.equals(id)))
        .write(AutoBookEventsCompanion(
      state: state == null ? const d.Value.absent() : d.Value(state),
      updatedAt:
          updatedAt == null ? const d.Value.absent() : d.Value(updatedAt),
      nextRetryAt:
          nextRetryAt == null ? const d.Value.absent() : d.Value(nextRetryAt),
      expiresAt: expiresAt == null ? const d.Value.absent() : d.Value(expiresAt),
      rawEvidenceServerExpiresAt: rawEvidenceServerExpiresAt == null
          ? const d.Value.absent()
          : d.Value(rawEvidenceServerExpiresAt),
      rawEvidenceUploadState: rawEvidenceUploadState == null
          ? const d.Value.absent()
          : d.Value(rawEvidenceUploadState),
      rawEvidenceServerEnabled: rawEvidenceServerEnabled == null
          ? const d.Value.absent()
          : d.Value(rawEvidenceServerEnabled),
    ));
  }

  // ──────────────────────────────────────────────────────────────────
  group('claim 租约边界', () {
    test('HARDENING: processing 恰好 10 分钟前 → 可重抢;9分59秒 → 拒绝',
        () async {
      final key = 'claim:lease';
      final event = await store.ensure(input(key));

      await forceRow(
        event.id,
        state: 'processing',
        updatedAt: DateTime.now().subtract(const Duration(minutes: 9, seconds: 59)),
      );
      final refused = await store.claim(input(key));
      expect(refused.acquired, isFalse,
          reason: '租约未过期(9:59)不得重抢');
      expect((await store.findById(event.id))!.attemptCount, 0);

      await forceRow(
        event.id,
        state: 'processing',
        updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      final granted = await store.claim(input(key));
      // 断言当前行为:10 分钟(含)即到期。drift 以 epoch 秒存取,
      // updatedAt+lease <= now 时 isBefore 为 false → 放行。
      expect(granted.acquired, isTrue,
          reason: '租约恰好到期(10:00)应可重抢');
      expect((await store.findById(event.id))!.attemptCount, 1);
    });

    test('HARDENING: retry 的 nextRetryAt 为未来 → 拒绝;等于/早于 now → 放行',
        () async {
      final key = 'claim:retry-gate';
      final event = await store.ensure(input(key));

      await forceRow(
        event.id,
        state: 'retry',
        nextRetryAt: DateTime.now().add(const Duration(seconds: 2)),
      );
      expect((await store.claim(input(key))).acquired, isFalse,
          reason: '退避窗口内(isAfter 严格)不得放行');

      await forceRow(event.id, state: 'retry', nextRetryAt: DateTime.now());
      expect((await store.claim(input(key))).acquired, isTrue,
          reason: 'nextRetryAt == now 即到期(isAfter 严格大于)');

      await forceRow(event.id, state: 'retry');
      final row = await store.findById(event.id);
      expect(row!.nextRetryAt, isNull, reason: '前置断言:列已清空');
      expect((await store.claim(input(key))).acquired, isTrue,
          reason: 'HARDENING: retry 但 nextRetryAt 为空 = 无闸门,立即放行');
    });

    test('HARDENING: terminal 六态全部拒绝 claim', () async {
      const terminals = [
        AutoBookState.booked,
        AutoBookState.duplicate,
        AutoBookState.ignored,
        AutoBookState.pending,
        AutoBookState.failed,
        AutoBookState.expired,
      ];
      for (final state in terminals) {
        final key = 'claim:terminal:${state.value}';
        final event = await store.ensure(input(key));
        await store.mark(AutoBookEventUpdate(state: state), eventId: event.id);
        final claim = await store.claim(input(key));
        expect(claim.acquired, isFalse, reason: '${state.value} 是终态');
        expect((await store.findById(event.id))!.attemptCount, 0,
            reason: '拒绝时不得递增 attemptCount');
      }
    });

    // ADVERSE FINDING: claim 的「读状态 → 写 processing」不是原子操作,
    // 并发 claim 同一 eventKey 会双授予(彼此都拿到 acquired=true 且
    // attemptCount 只 +1)。源码注释声称 UNIQUE 约束兜住竞态,但 UNIQUE
    // 只兜住 ensure 的 INSERT 竞态,兜不住 claim 的 read-modify-write。
    test('ADVERSE: 并发 claim 同 eventKey 双授予(租约失效,同一事件可被执行两次)',
        () async {
      const key = 'claim:race';
      final results = await Future.wait([
        store.claim(input(key)),
        store.claim(input(key)),
      ]);
      final row = await store.findByEventKey(key);

      expect(results.where((r) => r.acquired).length, 1,
          reason: '同一事件的租约只能被一个调用方取得');
      expect(row!.attemptCount, 1,
          reason: '一次授予 = attemptCount 恰好 +1');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('ensure 键与证据', () {
    test('HARDENING: 纯空白 key 抛 ArgumentError', () async {
      for (final key in ['', '   ', '\t\n']) {
        await expectLater(
          store.ensure(input(key)),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('HARDENING: key 不做归一 —— \' x \' 与 \'x\' 是两个事件(含 ZWSP 通过判空)',
        () async {
      final trimmed = await store.ensure(input('x'));
      final padded = await store.ensure(input(' x '));
      expect(trimmed.id, isNot(padded.id),
          reason: 'ensure 只查 trim().isEmpty,不归一:调用方口径不一致会双事件');
      // U+200B(零宽空格)不是 Dart 的 whitespace → 视觉空 key 被接受
      final zwsp = await store.ensure(input('\u200b'));
      expect(zwsp.eventKey, '\u200b');
    });

    test('HARDENING: 超长 / Unicode key 可落库', () async {
      final long = await store.ensure(input('a' * 5000));
      expect(long.eventKey.length, 5000);
      final emoji = await store.ensure(input('emoji😀:v1'));
      expect(emoji.eventKey, 'emoji😀:v1');
    });

    test('HARDENING: 未传 expiresAt → capturedAt + 30d 兜底', () async {
      final captured = DateTime.now().subtract(const Duration(hours: 2));
      final event = await store.ensure(input('ensure:ttl', capturedAt: captured));
      expect(event.expiresAt, isNotNull,
          reason: 'A2:cleanupExpired 的 DELETE 必须有命中面');
      // drift 以 epoch 秒存取,capturedAt 的亚秒位落库即丢;差值允许 1s 误差
      expect(
        event.expiresAt!.difference(captured).inSeconds,
        inInclusiveRange(
          AutoBookInput.evidenceRetention.inSeconds - 1,
          AutoBookInput.evidenceRetention.inSeconds,
        ),
      );
    });

    test('HARDENING: 已存在时二次 ensure 不覆盖生命周期列与已有证据', () async {
      final first = await store.ensure(input('ensure:idempotent'));
      final second = await store.ensure(input(
        'ensure:idempotent',
        expiresAt: DateTime.now().add(const Duration(days: 7)),
        rawText: 'late evidence',
      ));
      expect(second.id, first.id);
      expect(second.expiresAt, first.expiresAt,
          reason: '二次 ensure 不得改写既有行的证据有效期');
      // 默认隐私策略不存证据 → late evidence 不落盘
      expect(second.rawText, isNull);
      expect(second.rawEvidenceUploadState, RawEvidenceUploadState.notRequested);
    });

    test('HARDENING: policy 开启后二次 ensure 可补附着证据;已附着不被覆盖',
        () async {
      SharedPreferences.setMockInitialValues({
        RawEvidencePolicyStore.storageKey: jsonEncode({
          'default': {
            'localEnabled': true,
            'localRetentionDays': 30,
            'serverEnabled': false,
            'serverRetentionDays': 30,
          },
        }),
      });
      final first = await store.ensure(input('evidence:attach'));
      expect(first.rawText, isNull, reason: '首次 ensure 无证据');

      final attached = await store.ensure(
          input('evidence:attach', rawText: 'first body'));
      expect(attached.rawText, 'first body');
      expect(attached.rawEvidenceUploadState, RawEvidenceUploadState.notRequested,
          reason: '只开本地 → 不进上传队列');

      final again = await store.ensure(
          input('evidence:attach', rawText: 'second body'));
      expect(again.rawText, 'first body',
          reason: '已有证据时二次 ensure 不改写(保留捕获现场)');
    });

    test('HARDENING: cleared / expired / uploaded 三个终态跳过证据附着', () async {
      SharedPreferences.setMockInitialValues({
        RawEvidencePolicyStore.storageKey: jsonEncode({
          'default': {
            'localEnabled': true,
            'localRetentionDays': 30,
            'serverEnabled': false,
            'serverRetentionDays': 30,
          },
        }),
      });
      for (final state in [
        RawEvidenceUploadState.cleared,
        RawEvidenceUploadState.expired,
        RawEvidenceUploadState.uploaded,
      ]) {
        final key = 'evidence:skip:$state';
        final event = await store.ensure(input(key, rawText: 'original'));
        await forceRow(event.id,
            rawEvidenceUploadState: state, rawEvidenceServerEnabled: true);
        // 先清空正文,模拟清理动作后的行;再 ensure 带新正文
        await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
            .write(const AutoBookEventsCompanion(
          rawText: d.Value(null),
        ));
        final after = await store.ensure(input(key, rawText: 'resurrect'));
        expect(after.rawText, isNull,
            reason: '$state 是证据链终态,禁止草稿/重试复活正文');
        expect(after.rawEvidenceUploadState, state);
      }
    });

    test('HARDENING: policy 在两次 ensure 之间变化时按「变化后」策略执行',
        () async {
      final event = await store.ensure(input('evidence:policy-shift'));
      expect(event.rawText, isNull, reason: '策略关 → 不存');
      SharedPreferences.setMockInitialValues({
        RawEvidencePolicyStore.storageKey: jsonEncode({
          'default': {
            'localEnabled': true,
            'localRetentionDays': 30,
            'serverEnabled': true,
            'serverRetentionDays': 30,
          },
        }),
      });
      final after = await store.ensure(
          input('evidence:policy-shift', rawText: 'now-allowed'));
      expect(after.rawText, 'now-allowed');
      expect(after.rawEvidenceUploadState, RawEvidenceUploadState.pending,
          reason: 'serverEnabled → 进上传队列');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('mark / markRetry 终态与退避', () {
    test('HARDENING: mark 不存在 eventId 静默 no-op', () async {
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: 987654,
      );
      expect(await store.findById(987654), isNull,
          reason: 'void API 无任何信号 —— 事件行被清掉后 mark 静默丢状态');
    });

    test('HARDENING: 终态(六态)清 draft,非终态(retry/captured)保留', () async {
      for (final state in [
        AutoBookState.booked,
        AutoBookState.duplicate,
        AutoBookState.ignored,
        AutoBookState.pending,
        AutoBookState.failed,
        AutoBookState.expired,
      ]) {
        final key = 'mark:draft:${state.value}';
        final event = await store.ensure(input(key));
        expect(
          await store.saveDraftByEventKey(
              key, const AutoBookDraftPayload(isImage: false, text: 'body')),
          isTrue,
        );
        await store.mark(AutoBookEventUpdate(state: state), eventId: event.id);
        expect((await store.findById(event.id))!.draftPayloadJson, isNull,
            reason: '${state.value} 是终态,草稿必须清(否则占 dueDrafts 名额)');
      }

      for (final state in [
        AutoBookState.retry,
        AutoBookState.captured,
        AutoBookState.processing,
      ]) {
        final key = 'mark:draft-keep:${state.value}';
        final event = await store.ensure(input(key));
        await store.saveDraftByEventKey(
            key, const AutoBookDraftPayload(isImage: false, text: 'body'));
        await store.mark(AutoBookEventUpdate(state: state), eventId: event.id);
        expect((await store.findById(event.id))!.draftPayloadJson, isNotNull,
            reason: '${state.value} 非终态,草稿留着等重试');
      }
    });

    test('HARDENING: markRetry 退避阶梯 30/120/480/1800/7200,第 5 次起固定 2h',
        () async {
      const expected = {1: 30, 2: 120, 3: 480, 4: 1800, 5: 7200, 7: 7200};
      for (final entry in expected.entries) {
        final key = 'retry:ladder:${entry.key}';
        final event = await store.ensure(input(key));
        final before = DateTime.now();
        await store.markRetry(
            eventId: event.id, attemptCount: entry.key, error: 'ai_retryable');
        final row = await store.findById(event.id);
        expect(row!.state, 'retry');
        final gap = row.nextRetryAt!.difference(before).inSeconds;
        expect(gap, inInclusiveRange(entry.value - 2, entry.value + 2),
            reason: '第 ${entry.key} 次应为 ${entry.value}s 档');
      }
      // clamp 下界:0 / 负数也按 30s(不越界不崩溃)
      final zero = await store.ensure(input('retry:ladder:0'));
      await store.markRetry(eventId: zero.id, attemptCount: 0, error: 'x');
      expect((await store.findById(zero.id))!.state, 'retry');
      final neg = await store.ensure(input('retry:ladder:negative'));
      await store.markRetry(eventId: neg.id, attemptCount: -3, error: 'x');
      expect((await store.findById(neg.id))!.state, 'retry');
    });

    test('HARDENING: attemptCount 恰好上限(8) → failed/retry_exhausted,清退避与草稿',
        () async {
      final event = await store.ensure(input('retry:exhausted'));
      await store.saveDraftByEventKey(
          'retry:exhausted',
          const AutoBookDraftPayload(isImage: false, text: 'body'));
      await store.markRetry(
          eventId: event.id, attemptCount: 8, error: 'ai_retryable');

      final row = await store.findById(event.id);
      expect(row!.state, 'failed');
      expect(row.reason, 'retry_exhausted');
      expect(row.nextRetryAt, isNull, reason: 'A1:退避闸门必须清,否则空转');
      expect(row.draftPayloadJson, isNull, reason: 'A1:草稿清,否则 dueDrafts 长期选中');
      expect(await store.dueDrafts(), isEmpty,
          reason: 'A1 契约:retry_exhausted 后 dueDrafts 不再选中该行');
      expect((await store.claim(input('retry:exhausted'))).acquired, isFalse,
          reason: 'failed 是终态,重放必须是空操作');
    });

    test('HARDENING: resetRetryGate 复活 failed → retry 且 attemptCount 归零',
        () async {
      final event = await store.ensure(input('retry:revive'));
      // 真实路径:claim 递增 attemptCount 到 8 后 markRetry 落 failed。
      // 这里直接写列,复现「已用尽」的行状态(markRetry 自身不写 attemptCount)。
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
          .write(const AutoBookEventsCompanion(attemptCount: d.Value(8)));
      await store.markRetry(eventId: event.id, attemptCount: 8, error: 'x');
      expect((await store.findById(event.id))!.attemptCount, 8);

      await store.resetRetryGate(event.id);
      final revived = await store.findById(event.id);
      expect(revived!.state, 'retry');
      expect(revived.attemptCount, 0, reason: 'A1:不归零 → 用户只买到一次尝试');
      expect(revived.nextRetryAt, isNull);

      final claim = await store.claim(input('retry:revive'));
      expect(claim.acquired, isTrue);
      expect(claim.event.attemptCount, 1);
    });

    test('HARDENING: error 截断 240(含边界 240/241)、多行取首行、空白归 null',
        () async {
      final event = await store.ensure(input('retry:redact'));

      await store.markRetry(eventId: event.id, attemptCount: 1, error: 'x' * 240);
      expect((await store.findById(event.id))!.lastError!.length, 240,
          reason: '恰好 240 不截断');

      await store.markRetry(eventId: event.id, attemptCount: 1, error: 'y' * 241);
      final long = (await store.findById(event.id))!.lastError!;
      expect(long.length, 241, reason: '241 截到 240 + 省略号');
      expect(long.endsWith('…'), isTrue);

      await store.markRetry(
          eventId: event.id,
          attemptCount: 1,
          error: 'first line\nsecond line\r\nthird');
      expect((await store.findById(event.id))!.lastError, 'first line');

      await store.markRetry(eventId: event.id, attemptCount: 1, error: '   ');
      expect((await store.findById(event.id))!.lastError, isNull);

      // HARDENING:截断按 UTF-16 code unit 处理,可切断代理对;
      // 落库(UTF-8)后变成 U+FFFD —— 仅可读性受损,无崩溃/无字段丢失。
      await store.markRetry(
          eventId: event.id,
          attemptCount: 1,
          error: '${'a' * 239}😀');
      final mangled = (await store.findById(event.id))!.lastError!;
      expect(mangled.length, 241);
      expect(mangled.codeUnits.contains(0xFFFD), isTrue,
          reason: '截断切坏代理对 → 替换字符');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('pending TTL', () {
    test('HARDENING: 未满 30 天不过期;超过 30 天(秒级)才过期;两轮幂等',
        () async {
      final fresh = await store.ensure(
          input('ttl:fresh', capturedAt: DateTime.now().subtract(const Duration(days: 29))));
      await store.mark(const AutoBookEventUpdate(state: AutoBookState.pending),
          eventId: fresh.id);
      final exact = await store.ensure(
          input('ttl:exact', capturedAt: DateTime.now().subtract(const Duration(days: 30))));
      await store.mark(const AutoBookEventUpdate(state: AutoBookState.pending),
          eventId: exact.id);
      final stale = await store.ensure(
          input('ttl:stale',
              capturedAt: DateTime.now().subtract(const Duration(days: 30, seconds: 2))));
      await store.mark(const AutoBookEventUpdate(state: AutoBookState.pending),
          eventId: stale.id);

      final expired = await store.expireStalePending();
      expect(expired, 1, reason: '只有严格早于 cutoff 的行过期(drift 比较按秒)');
      expect((await store.findById(fresh.id))!.state, 'pending');
      expect((await store.findById(exact.id))!.state, 'pending',
          reason: '恰好 30 天 == cutoff,不过期');
      final staleRow = (await store.findById(stale.id))!;
      expect(staleRow.state, 'expired');
      expect(staleRow.reason, 'pending_expired');
      expect(staleRow.expiresAt, isNull,
          reason: '清 expiresAt → 不被后续 DELETE 吃掉,历史页保留占位');

      expect(await store.expireStalePending(), 0, reason: '第二轮幂等');
    });

    test('HARDENING: expireStalePending 一并清 draft 与 nextRetryAt', () async {
      final event = await store.ensure(input('ttl:fields',
          capturedAt: DateTime.now().subtract(const Duration(days: 31))));
      await store.saveDraftByEventKey(
          'ttl:fields', const AutoBookDraftPayload(isImage: false, text: 'x'));
      await store.mark(
        AutoBookEventUpdate(
            state: AutoBookState.pending, nextRetryAt: DateTime.now()),
        eventId: event.id,
      );
      await store.expireStalePending();
      final row = (await store.findById(event.id))!;
      expect(row.state, 'expired');
      expect(row.draftPayloadJson, isNull);
      expect(row.nextRetryAt, isNull);
    });

    test('HARDENING: 已 expiresAt 置空的占位行不被二次处理', () async {
      final event = await store.ensure(input('ttl:placeholder',
          capturedAt: DateTime.now().subtract(const Duration(days: 40))));
      await store.mark(const AutoBookEventUpdate(state: AutoBookState.pending),
          eventId: event.id);
      expect(await store.expireStalePending(), 1);
      final placeholder = (await store.findById(event.id))!;
      expect(placeholder.expiresAt, isNull);

      await store.cleanupExpired();
      expect(await store.findById(event.id), isNotNull,
          reason: '占位行必须活下来(历史页可见「为什么停下」)');
      expect(await store.expireStalePending(), 0);
      expect(await store.backfillMissingExpiresAt(), 0,
          reason: 'state=expired 的占位行禁止被回填 expiresAt');
    });

    // ADVERSE FINDING: cleanupExpired 会把 30 天前的 pending 事件物理删除
    // (只要它的 expiresAt 还没被 expireStalePending 清空)。C8 承诺
    // 「pending 超 30 天转 expired 终态,历史页保留为什么停下」,但
    // cleanupExpired 的两个生产调用点(Coordinator.initialize、
    // AutoBillingService.retryDueDrafts)都先于 expireStalePending 运行,
    // 谁先跑决定记录是「占位」还是「消失」。
    test('ADVERSE: 30 天前的 pending 事件被 cleanupExpired 物理删除,丢失过期占位',
        () async {
      final event = await store.ensure(input('ttl:deleted-by-cleanup',
          capturedAt: DateTime.now().subtract(const Duration(days: 31))));
      await store.mark(const AutoBookEventUpdate(state: AutoBookState.pending),
          eventId: event.id);

      await store.cleanupExpired();

      final row = await store.findById(event.id);
      expect(row, isNotNull,
          reason: '过期 pending 应转 expired 占位(历史页可见 pending_expired),'
              '而不是被 DELETE 抹掉');
      expect(row?.state, 'expired');
    });

    test('HARDENING: 同轮 cleanupExpired 先转占位再删除 —— 转占位的行当轮不被删',
        () async {
      // 构造「曾有证据、证据留存期已过」的行:两个留存窗口都置为过去,
      // expiresAt 也置为过去(expiresAt < now 才有 DELETE 命中面)。
      final event = await store.ensure(input('cleanup:placeholder'));
      final past = DateTime.now().subtract(const Duration(days: 5));
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
          .write(AutoBookEventsCompanion(
        rawText: const d.Value('evidence body'),
        rawEvidenceLocalEnabled: const d.Value(true),
        rawEvidenceServerEnabled: const d.Value(true),
        rawEvidenceLocalExpiresAt: d.Value(past),
        rawEvidenceServerExpiresAt: d.Value(past),
        rawEvidenceRetentionUntil: d.Value(past),
        rawEvidenceUploadState: const d.Value(RawEvidenceUploadState.pending),
        expiresAt: d.Value(past),
      ));

      final cleared = await store.cleanupExpiredRawEvidence();
      expect(cleared, 1, reason: '两个窗口都过期 → 清证据');

      await store.cleanupExpired();
      final row = await store.findById(event.id);
      expect(row, isNotNull, reason: '占位行不得被同轮 DELETE 吃掉');
      expect(row!.state, 'expired');
      expect(row.reason, 'expired_evidence_cleared');
      expect(row.expiresAt, isNull);
      expect(row.rawText, isNull);

      // 第二轮幂等
      await store.cleanupExpired();
      expect((await store.findById(event.id))!.state, 'expired');
    });

    test('HARDENING: cleanupExpired 对无证据行按 expiresAt 精确边界删除', () async {
      final event = await store.ensure(input('cleanup:exact'));
      // expiresAt == now(秒级相等)→ 不删
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
          .write(AutoBookEventsCompanion(
        expiresAt: d.Value(DateTime.now()),
      ));
      await store.cleanupExpired();
      expect(await store.findById(event.id), isNotNull,
          reason: 'isSmallerThanValue 严格小于,相等不删');

      // expiresAt 秒级早于 now → 删(永不超期的行不该存在,这是清理出口)
      await forceRow(event.id,
          expiresAt: DateTime.now().subtract(const Duration(seconds: 3)));
      await store.cleanupExpired();
      expect(await store.findById(event.id), isNull);
    });

    test('HARDENING: backfillMissingExpiresAt 幂等,只补 NULL 且跳过 expired 占位',
        () async {
      final event = await store.ensure(input('backfill:one'));
      await forceRow(event.id, expiresAt: DateTime.now());
      final nulled = await (db.update(db.autoBookEvents)
            ..where((t) => t.id.equals(event.id)))
          .write(const AutoBookEventsCompanion(expiresAt: d.Value(null)));
      expect(nulled, 1, reason: '前置:列已置 NULL');

      expect(await store.backfillMissingExpiresAt(), 1);
      expect(await store.backfillMissingExpiresAt(), 0, reason: '第二轮幂等');
      final row = (await store.findById(event.id))!;
      expect(row.expiresAt, row.capturedAt.add(AutoBookInput.evidenceRetention));

      // expired 占位行:NULL 也不补
      final placeholder = await store.ensure(input('backfill:placeholder'));
      await forceRow(placeholder.id, state: 'expired', expiresAt: DateTime.now());
      await (db.update(db.autoBookEvents)
            ..where((t) => t.id.equals(placeholder.id)))
          .write(const AutoBookEventsCompanion(expiresAt: d.Value(null)));
      expect(await store.backfillMissingExpiresAt(), 0);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('listHistory / listPending / limit clamp', () {
    // ADVERSE FINDING: listHistory 先 orderBy+limit 取最近 N 行,再在 Dart
    // 里按 state/source 过滤 —— 过滤结果被截断窗口吃掉。库里有 2 条 booked
    // 时 listHistory(state:'booked', limit:2) 返回 0 条(它们不在最近 3 条
    // pending 窗口里)。历史页筛选/每日汇总都吃这个亏。
    test('ADVERSE: listHistory 先 limit 后过滤 → 匹配的旧记录被截断窗口吃掉',
        () async {
      for (var i = 0; i < 3; i++) {
        final e = await store.ensure(input('history:pending:$i'));
        await store.mark(
            const AutoBookEventUpdate(state: AutoBookState.pending),
            eventId: e.id);
      }
      for (var i = 0; i < 2; i++) {
        final e = await store.ensure(input('history:booked:$i'));
        await store.mark(
          AutoBookEventUpdate(
              state: AutoBookState.booked, transactionId: 900 + i),
          eventId: e.id,
        );
        await forceRow(e.id,
            updatedAt: DateTime.now().subtract(const Duration(days: 2)));
      }

      final all = await store.listHistory();
      expect(all, hasLength(5));

      final booked = await store.listHistory(state: 'booked', limit: 2);
      expect(booked, hasLength(2),
          reason: '库里确有 2 条 booked,limit=2 应返回它们;'
              '实际 0 条(limit 在过滤前截断了最近 2 条 pending)');
      expect(booked.every((e) => e.state == 'booked'), isTrue);
    });

    test('ADVERSE: listHistory 的 source 过滤同样被 limit 窗口截断', () async {
      for (var i = 0; i < 2; i++) {
        final e = await store.ensure(input('history:notify:$i',
            source: AutoBookSource.notification));
        await store.mark(
          const AutoBookEventUpdate(state: AutoBookState.booked),
          eventId: e.id,
        );
        await forceRow(e.id,
            updatedAt: DateTime.now().subtract(const Duration(days: 3)));
      }
      for (var i = 0; i < 4; i++) {
        final e = await store.ensure(input('history:sms:$i'));
        await store.mark(
          const AutoBookEventUpdate(state: AutoBookState.ignored),
          eventId: e.id,
        );
      }
      final notify = await store.listHistory(source: 'notification', limit: 4);
      expect(notify, hasLength(2),
          reason: 'source 过滤必须基于全量再截断;'
              '实际 0 条(2 条 notification 已被 4 条 sms 挤出窗口)');
    });

    test('HARDENING: limit clamp 语义(0/负数 → 1,超上限 → 上限)', () async {
      for (var i = 0; i < 3; i++) {
        final e = await store.ensure(input('clamp:$i'));
        await store.mark(
            const AutoBookEventUpdate(state: AutoBookState.pending),
            eventId: e.id);
      }
      expect((await store.listPending(limit: 0)).length, 1,
          reason: 'clamp(1,500):0 → 1');
      expect((await store.listPending(limit: -7)).length, 1);
      expect((await store.listPending(limit: 99999)).length, 3);
      expect((await store.listHistory(limit: 0)).length, 1);
      expect((await store.listHistory(limit: -1)).length, 1);
      expect((await store.listDrafts(limit: 0)).length, 0);
      expect((await store.dueDrafts(limit: 0)).length, 0);
      expect((await store.listIgnoredItems(limit: 0)).length, 0);
    });

    test('HARDENING: listHistory 默认按 updatedAt desc 排序', () async {
      final older = await store.ensure(input('order:older'));
      final newer = await store.ensure(input('order:newer'));
      await forceRow(older.id,
          updatedAt: DateTime.now().subtract(const Duration(hours: 1)));
      await forceRow(newer.id, updatedAt: DateTime.now());
      final rows = await store.listHistory();
      expect(rows.first.id, newer.id);
      expect(rows.last.id, older.id);
    });

    test('HARDENING: listDrafts/dueDrafts 的 failed 分支基本不可达(死过滤)',
        () async {
      final event = await store.ensure(input('drafts:failed'));
      await store.saveDraftByEventKey(
          'drafts:failed', const AutoBookDraftPayload(isImage: false, text: 'x'));
      await store.mark(
        const AutoBookEventUpdate(
            state: AutoBookState.failed, reason: 'ai_permanent_failure'),
        eventId: event.id,
      );
      expect(await store.saveDraftByEventKey(
              'drafts:failed', const AutoBookDraftPayload(isImage: false, text: 'y')),
          isFalse,
          reason: 'failed 终态拒绝草稿');
      expect(await store.dueDrafts(), isEmpty);
      expect(await store.listDrafts(), isEmpty,
          reason: 'state 过滤含 failed,但 mark() 清草稿 + saveDraft 拒终态 → 恒空');

      final retryable = await store.ensure(input('drafts:retry'));
      await store.saveDraftByEventKey(
          'drafts:retry', const AutoBookDraftPayload(isImage: false, text: 'z'));
      await store.mark(
          const AutoBookEventUpdate(state: AutoBookState.retry),
          eventId: retryable.id);
      expect(await store.dueDrafts(), hasLength(1),
          reason: 'retry + nextRetryAt 空 → 立即可重放');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('子项写入与聚合', () {
    test('HARDENING: upsertItem 同 (eventId,itemIndex) 幂等覆盖,不产生残影',
        () async {
      final event = await store.ensure(input('item:upsert'));
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'pending',
        amount: -30,
        semanticKey: 'k1',
        bill: {'a': 1},
      );
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'booked',
        amount: -31,
        semanticKey: 'k2',
        transactionId: 7,
        bill: {'a': 2},
      );
      final items = await store.itemsForEvent(event.id);
      expect(items, hasLength(1));
      expect(items.single.semanticKey, 'k2');
      expect(items.single.transactionId, 7);
      expect(items.single.amount, -31);
    });

    test('HARDENING: itemIndex 负数 / int32 极大值可落库且各自独立', () async {
      final event = await store.ensure(input('item:index-range'));
      await store.upsertItem(
          eventId: event.id, itemIndex: -1, state: 'pending', bill: {'a': 1});
      await store.upsertItem(
          eventId: event.id,
          itemIndex: 2147483647,
          state: 'pending',
          bill: {'b': 2});
      expect(
        (await store.itemsForEvent(event.id)).map((i) => i.itemIndex).toList(),
        [-1, 2147483647],
        reason: '参数无校验 —— 调用方传错索引不会报错,只会造出游离子项',
      );
    });

    test('HARDENING: itemsForEvents 分块(>400)合并结果与逐事件一致', () async {
      final a = await store.ensure(input('item:batch:a'));
      final b = await store.ensure(input('item:batch:b'));
      await store.upsertItem(eventId: a.id, itemIndex: 0, state: 'pending');
      await store.upsertItem(eventId: a.id, itemIndex: 1, state: 'pending');
      await store.upsertItem(eventId: b.id, itemIndex: 0, state: 'pending');

      final ids = [
        ...List.generate(401, (i) => 100000 + i),
        a.id,
        b.id,
      ];
      final grouped = await store.itemsForEvents(ids);
      expect(grouped[a.id], hasLength(2));
      expect(grouped[b.id], hasLength(1));
      expect(grouped.keys.toSet(), {a.id, b.id});
    });

    test('HARDENING: resolvePendingItem 对非 pending 子项 changed==0 且父事件不动',
        () async {
      final event = await store.ensure(input('item:resolve-non-pending'));
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'booked',
        transactionId: 5,
        amount: -30,
        bill: {'amount': -30},
      );
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 5),
        eventId: event.id,
      );
      await store.resolvePendingItem(
        eventId: event.id,
        itemIndex: 0,
        state: AutoBookState.ignored,
        reason: 'late_click',
      );
      final row = (await store.findById(event.id))!;
      expect(row.state, 'booked');
      expect(row.transactionId, 5);
      expect((await store.itemsForEvent(event.id)).single.state, 'booked');
      // HARDENING:void 返回值 —— 调用方无法区分「已处理」与「被并发抢先」,
      // 与 reopenItem 的 bool 期望状态检查不对称。
    });

    test('HARDENING: resolvePendingItem 拒绝非终态目标态', () async {
      final event = await store.ensure(input('item:resolve-bad-state'));
      await store.upsertItem(
          eventId: event.id, itemIndex: 0, state: 'pending', bill: {'a': 1});
      await expectLater(
        store.resolvePendingItem(
            eventId: event.id,
            itemIndex: 0,
            state: AutoBookState.pending),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        store.resolvePendingItem(
            eventId: event.id,
            itemIndex: 0,
            state: AutoBookState.retry),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('HARDENING: 父事件聚合优先级 pending > booked > duplicate > ignored',
        () async {
      // (a) 剩余 pending 压过 booked
      final a = await store.ensure(input('agg:a'));
      await store.upsertItem(eventId: a.id, itemIndex: 0, state: 'pending');
      await store.upsertItem(eventId: a.id, itemIndex: 1, state: 'pending');
      await store.resolvePendingItem(
          eventId: a.id,
          itemIndex: 0,
          state: AutoBookState.booked,
          transactionId: 11);
      expect((await store.findById(a.id))!.state, 'pending');
      await store.resolvePendingItem(
          eventId: a.id, itemIndex: 1, state: AutoBookState.ignored);
      final closedA = (await store.findById(a.id))!;
      expect(closedA.state, 'booked', reason: 'booked 压过 ignored');
      expect(closedA.transactionId, 11);

      // (b) duplicate 压过 ignored
      final b = await store.ensure(input('agg:b'));
      await store.upsertItem(eventId: b.id, itemIndex: 0, state: 'pending');
      await store.upsertItem(eventId: b.id, itemIndex: 1, state: 'pending');
      await store.resolvePendingItem(
          eventId: b.id,
          itemIndex: 0,
          state: AutoBookState.duplicate,
          transactionId: 9);
      await store.resolvePendingItem(
          eventId: b.id, itemIndex: 1, state: AutoBookState.ignored);
      final closedB = (await store.findById(b.id))!;
      expect(closedB.state, 'duplicate');
      expect(closedB.duplicateOfTransactionId, 9);

      // (c) 全 ignored → ignored
      final c = await store.ensure(input('agg:c'));
      await store.upsertItem(eventId: c.id, itemIndex: 0, state: 'pending');
      await store.resolvePendingItem(
          eventId: c.id, itemIndex: 0, state: AutoBookState.ignored);
      expect((await store.findById(c.id))!.state, 'ignored');

      // (d) booked 子项 transactionId 为 null → 父 transactionId 落 null
      final e = await store.ensure(input('agg:d'));
      await store.upsertItem(eventId: e.id, itemIndex: 0, state: 'pending');
      await store.resolvePendingItem(
          eventId: e.id, itemIndex: 0, state: AutoBookState.booked);
      final closedE = (await store.findById(e.id))!;
      expect(closedE.state, 'booked');
      expect(closedE.transactionId, isNull);
    });

    // ADVERSE FINDING: resolvePendingItem 的 `duplicateOfTransactionId: ...
    // : null` 分支本意是「父事件不再是 duplicate 时清掉该列」,但 mark() 把
    // null 语义定义为 d.Value.absent()(不改),于是父事件从 duplicate 退回
    // pending 后仍背着旧的 duplicateOfTransactionId。该列是
    // sourceKeysForTransaction 的反查来源,残留会让已撤销的判重关系继续
    // 贡献「该交易被哪个渠道记录过」的跨渠道证据。
    test('ADVERSE: 父事件从 duplicate 回退后残留 stale duplicateOfTransactionId',
        () async {
      final event = await store.ensure(input('agg:stale-dup'));
      await store.upsertItem(
          eventId: event.id, itemIndex: 0, state: 'pending', bill: {'a': 1});
      await store.upsertItem(
          eventId: event.id, itemIndex: 1, state: 'pending', bill: {'b': 2});
      await store.resolvePendingItem(
          eventId: event.id,
          itemIndex: 0,
          state: AutoBookState.duplicate,
          transactionId: 9);
      await store.resolvePendingItem(
          eventId: event.id, itemIndex: 1, state: AutoBookState.ignored);
      var row = (await store.findById(event.id))!;
      expect(row.state, 'duplicate');
      expect(row.duplicateOfTransactionId, 9, reason: '前置:判重关系已建立');

      // 用户恢复被忽略的子项 → 父事件回到 pending(判重关系已被撤销)
      expect(await store.reopenItem(eventId: event.id, itemIndex: 1), isTrue);
      row = (await store.findById(event.id))!;
      expect(row.state, 'pending');

      expect(row.duplicateOfTransactionId, isNull,
          reason: '父事件已不是 duplicate,旧的 duplicateOfTransactionId '
              '必须被清;实际保留 9 → 反查源集合继续污染');
    });

    test('HARDENING: reopenItem 仅 ignored → pending;父事件从 booked 回 pending',
        () async {
      final event = await store.ensure(input('reopen:basic'));
      await store.upsertItem(
          eventId: event.id, itemIndex: 0, state: 'pending', bill: {'a': 1});
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 1,
        state: 'ignored',
        reason: 'user_rejected',
        bill: {'b': 2},
      );
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 5),
        eventId: event.id,
      );

      expect(await store.reopenItem(eventId: event.id, itemIndex: 1), isTrue);
      final row = (await store.findById(event.id))!;
      expect(row.state, 'pending', reason: '重新出现候选 → 父事件回 pending');
      expect((await store.itemsForEvent(event.id))
              .firstWhere((i) => i.itemIndex == 1)
              .state,
          'pending');

      // 只能 ignored → pending:booked / pending / duplicate 均拒绝
      expect(await store.reopenItem(eventId: event.id, itemIndex: 0), isFalse);
      expect(await store.reopenItem(eventId: event.id, itemIndex: 1), isFalse);
      expect(await store.reopenItem(eventId: event.id, itemIndex: 99), isFalse);
    });

    test('HARDENING: listIgnoredItems 只返回带 billJson 的已忽略子项', () async {
      final withBill = await store.ensure(input('ignored:with-bill'));
      await store.upsertItem(
        eventId: withBill.id,
        itemIndex: 0,
        state: 'ignored',
        bill: {'amount': -30},
      );
      final withoutBill = await store.ensure(input('ignored:no-bill'));
      await store.upsertItem(
          eventId: withoutBill.id, itemIndex: 0, state: 'ignored');
      final booked = await store.ensure(input('ignored:booked'));
      await store.upsertItem(
        eventId: booked.id,
        itemIndex: 0,
        state: 'booked',
        bill: {'amount': -30},
      );

      final rows = await store.listIgnoredItems();
      expect(rows, hasLength(1));
      expect(rows.single.item.eventId, withBill.id);
      expect(rows.single.event.id, withBill.id);
    });
  });
}
