/// 对抗性测试 2/4:自动记账状态机与协调器
/// (Coordinator claim/retry 语义、AutoBookPolicy 硬闸门、离线草稿重放、
///  PendingCandidateStore 候选队列、父事件聚合与确认页投影)。
///
/// 纪律:确认缺陷 → 失败 + `// ADVERSE FINDING`;可辩护但脆弱 → 断言当前行为
/// 并通过 + `// HARDENING`;时间一律相对 `DateTime.now()`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/automation/auto_book_policy.dart';
import 'package:smartbook/services/automation/dedup_exempt_store.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late AutoBookEventStore store;
  late AutoBookCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
    coordinator = AutoBookCoordinator(db);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key, {int? ledgerId}) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
        ledgerId: ledgerId,
      );

  // ──────────────────────────────────────────────────────────────────
  group('Coordinator 执行语义', () {
    test('HARDENING: 同 eventKey 串行 —— 第二个调用必须看到第一个的终态',
        () async {
      final order = <String>[];
      final first = coordinator.execute<String>(
        input: input('coord:serial'),
        action: () async {
          order.add('first-start');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          order.add('first-end');
          return 'a';
        },
        updateFor: (_) => const AutoBookEventUpdate(state: AutoBookState.booked),
      );
      final second = coordinator.execute<String>(
        input: input('coord:serial'),
        action: () async {
          order.add('second-start');
          return 'b';
        },
        updateFor: (_) => const AutoBookEventUpdate(state: AutoBookState.booked),
      );
      final results = await Future.wait([first, second]);
      expect(order, ['first-start', 'first-end'],
          reason: '同 key 第二个动作不得并发执行(终态跳过)');
      expect(results[0].skipped, isFalse);
      expect(results[1].skipped, isTrue);
      expect(results[1].state, AutoBookState.booked);
      expect(results[1].existingTransactionId, isNull,
          reason: 'booked 但无 transactionId → 反查信号也为空');
    });

    test('HARDENING: retry(retryable)结果统一走 markRetry 阶梯,不落裸 retry',
        () async {
      final started = DateTime.now();
      final execution = await coordinator.execute<String>(
        input: input('coord:retry-ladder'),
        action: () async => 'retry-me',
        updateFor: (_) => const AutoBookEventUpdate(
            state: AutoBookState.retry, reason: 'ai_retryable'),
      );
      expect(execution.state, AutoBookState.retry);
      final row = await store.findByEventKey('coord:retry-ladder');
      expect(row!.nextRetryAt, isNotNull,
          reason: 'M1-3:业务返回的 retry 必须补退避闸门,否则忙循环');
      final gap = row.nextRetryAt!.difference(started).inSeconds;
      expect(gap, inInclusiveRange(28, 32), reason: '首次退避 30s');
    });

    test('HARDENING: 退避用尽时执行结果回读真实终态 failed(不返回虚假 retry)',
        () async {
      // 先让 attemptCount 到 7(claim 会 +1 → 8 → 用尽)
      final event = await store.ensure(input('coord:exhaust'));
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
          .write(const AutoBookEventsCompanion(attemptCount: d.Value(7)));

      final execution = await coordinator.execute<String>(
        input: input('coord:exhaust'),
        action: () async => 'retry-me',
        updateFor: (_) => const AutoBookEventUpdate(
            state: AutoBookState.retry, reason: 'ai_retryable'),
      );
      expect(execution.state, AutoBookState.failed,
          reason: 'A1:attemptCount 8 → failed 终态,监听层据此 ACK 队列项');
      final row = await store.findByEventKey('coord:exhaust');
      expect(row!.reason, 'retry_exhausted');
      expect(row.nextRetryAt, isNull);
    });

    test('HARDENING: 业务异常 → 先 markRetry 再把异常抛给调用方', () async {
      await expectLater(
        coordinator.execute<String>(
          input: input('coord:throws'),
          action: () async => throw StateError('boom'),
          updateFor: (_) => const AutoBookEventUpdate(
              state: AutoBookState.booked),
        ),
        throwsA(isA<StateError>()),
      );
      final row = await store.findByEventKey('coord:throws');
      expect(row!.state, 'retry', reason: '异常必须留下可重试痕迹');
      expect(row.lastError, contains('boom'));
      expect(row.nextRetryAt, isNotNull);
    });

    test('HARDENING: dispose 后 execute 抛 StateError,不静默吞事件', () async {
      coordinator.dispose();
      await expectLater(
        coordinator.execute<String>(
          input: input('coord:disposed'),
          action: () async => 'x',
          updateFor: (_) => const AutoBookEventUpdate(
              state: AutoBookState.booked),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('HARDENING: 显式 nextRetryAt 的 retry 结果走 mark(),尊重给定闸门',
        () async {
      final gate = DateTime.now().add(const Duration(hours: 3));
      final execution = await coordinator.execute<String>(
        input: input('coord:explicit-gate'),
        action: () async => 'x',
        updateFor: (_) => AutoBookEventUpdate(
            state: AutoBookState.retry, nextRetryAt: gate),
      );
      expect(execution.state, AutoBookState.retry);
      final row = await store.findByEventKey('coord:explicit-gate');
      // drift 秒级存储:比较到秒
      expect(
        row!.nextRetryAt!.difference(gate).inSeconds.abs() <= 1,
        isTrue,
        reason: '显式闸门不得被阶梯覆盖',
      );
      // 闸门内 claim 拒绝
      expect((await store.claim(input('coord:explicit-gate'))).acquired, isFalse);
    });

    test('HARDENING: 有界并发 —— 不同 key 可并行,max=1 时严格串行', () async {
      coordinator.setMaxConcurrency(1);
      expect(coordinator.currentMaxConcurrency, 1);
      var concurrent = 0;
      var peak = 0;
      Future<void> run(String key) async {
        await coordinator.execute<String>(
          input: input(key),
          action: () async {
            concurrent++;
            peak = concurrent > peak ? concurrent : peak;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            concurrent--;
            return 'x';
          },
          updateFor: (_) =>
              const AutoBookEventUpdate(state: AutoBookState.booked),
        );
      }

      await Future.wait([run('coord:c1'), run('coord:c2'), run('coord:c3')]);
      expect(peak, 1, reason: 'max=1 时三个不同 key 也必须串行');
    });

    test('HARDENING: 并发池满时等待者 FIFO 唤醒,不丢任务', () async {
      coordinator.setMaxConcurrency(1);
      final finished = <int>[];
      Future<void> run(int i) => coordinator
          .execute<String>(
            input: input('coord:fifo:$i'),
            action: () async {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return 'x';
            },
            updateFor: (_) =>
                const AutoBookEventUpdate(state: AutoBookState.booked),
          )
          .then((_) => finished.add(i));
      final futures = [run(0), run(1), run(2), run(3)];
      await Future.wait(futures);
      expect(finished, [0, 1, 2, 3]);
    });

    // ADVERSE FINDING(与 event store 同源,但走 Coordinator 的真实入口):
    // coordinator 声称「同一 eventKey 仍在各自的串行尾链上排队,幂等 claim / 租约
    // 语义与『同一事件绝不双执行』不变」——但两个**不同 Coordinator 实例**
    // (例如 drain 与手动重试各持一个;或进程重启后的新实例)对同一 eventKey
    // 并发 execute 时,claim 的 read-modify-write 仍会双授予,业务动作执行两次。
    test('ADVERSE: 两个 Coordinator 实例并发 execute 同 eventKey → 业务双执行',
        () async {
      final other = AutoBookCoordinator(db);
      var runs = 0;
      Future<void> run(AutoBookCoordinator c) async {
        await c.execute<String>(
          input: input('coord:dual-instance'),
          action: () async {
            runs++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return 'x';
          },
          updateFor: (_) =>
              const AutoBookEventUpdate(state: AutoBookState.booked),
        );
      }

      await Future.wait([run(coordinator), run(other)]);
      other.dispose();
      expect(runs, 1,
          reason: '「同一事件绝不双执行」是租约契约的核心;'
              '实际两次都执行 → 双记账风险');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutoBookPolicy 硬闸门', () {
    const policy = AutoBookPolicy();

    BillInfo bill({
      double? amount = -30,
      DateTime? time,
      BillEventKind? kind,
      BillSettlementStatus? status = BillSettlementStatus.settled,
      BillTimePrecision? precision,
      bool confidenceProvided = true,
      bool timeInferred = false,
      BillType? type = BillType.expense,
      String? fromAccount,
      String? toAccount,
      String? account,
    }) =>
        BillInfo(
          amount: amount,
          time: time ?? DateTime.now(),
          type: type,
          eventKind: kind,
          settlementStatus: status,
          timePrecision: precision ?? BillTimePrecision.exact,
          confidenceProvided: confidenceProvided,
          timeInferred: timeInferred,
          fromAccount: fromAccount,
          toAccount: toAccount,
          account: account,
        );

    test('HARDENING: 时间缺失 / 推测时间 / 秒级不可信精度 → 全部丢弃', () async {
      expect(
        policy
            .evaluate(bill: BillInfo(amount: -30, type: BillType.expense),
                source: 'sms')
            .reason,
        'time_missing',
      );
      expect(
        policy
            .evaluate(
                bill: bill(timeInferred: true, precision: BillTimePrecision.inferred),
                source: 'sms')
            .reason,
        'time_inferred',
      );
      // 枚举各弱精度:闸门顺序为 settlement → confidence → precision,
      // 因此这里保持 settled + confidenceProvided
      for (final p in [
        BillTimePrecision.unknown,
        BillTimePrecision.inferred,
        BillTimePrecision.date,
      ]) {
        final decision = policy.evaluate(bill: bill(precision: p), source: 'sms');
        expect(decision.action, AutoBookPolicyAction.pending);
        expect(decision.reason, 'time_precision_weak');
      }
      // HARDENING:闸门有固定优先级 —— 同时缺结算状态与弱精度时先报
      // settlement_unknown;两个都属于「进待确认」的保守方向,文案不精确。
      expect(
        policy
            .evaluate(
              bill: BillInfo(
                amount: -30,
                time: DateTime.now(),
                type: BillType.expense,
                eventKind: BillEventKind.purchase,
                timePrecision: BillTimePrecision.date,
              ),
              source: 'sms',
            )
            .reason,
        'settlement_unknown',
      );
    });

    test('HARDENING: 汇总/余额提醒/未结算单 一票否决(ignore,不进待确认)',
        () async {
      for (final st in [
        BillSettlementStatus.pending,
        BillSettlementStatus.failed,
        BillSettlementStatus.cancelled,
        BillSettlementStatus.reversed,
      ]) {
        final decision = policy.evaluate(bill: bill(status: st), source: 'sms');
        expect(decision.action, AutoBookPolicyAction.ignore);
        expect(decision.reason, 'unsettled_order');
      }
      expect(
        policy
            .evaluate(bill: bill(kind: BillEventKind.statement), source: 'sms')
            .reason,
        'statement_or_balance',
      );
      expect(
        policy
            .evaluate(
                bill: bill(status: BillSettlementStatus.summary), source: 'sms')
            .reason,
        'statement_or_balance',
      );
    });

    test('HARDENING: 转账类缺账户 → pending(不静默记成支出)', () async {
      for (final kind in [
        BillEventKind.transfer,
        BillEventKind.repayment,
        BillEventKind.recharge,
      ]) {
        final decision = policy.evaluate(bill: bill(kind: kind), source: 'sms');
        expect(decision.action, AutoBookPolicyAction.pending);
        expect(decision.reason, 'transfer_account_missing');
      }
      final withAccount =
          policy.evaluate(bill: bill(kind: BillEventKind.transfer, account: '招行'), source: 'sms');
      expect(withAccount.isAllowed, isTrue);
    });

    test('HARDENING: 缺 confidence / 未知 eventKind → pending', () async {
      final noConf = policy.evaluate(
          bill: bill(confidenceProvided: false), source: 'sms');
      expect(noConf.action, AutoBookPolicyAction.pending);
      expect(noConf.reason, 'confidence_missing');

      final unknown =
          policy.evaluate(bill: bill(kind: BillEventKind.unknown), source: 'sms');
      expect(unknown.action, AutoBookPolicyAction.pending);
      expect(unknown.reason, 'event_kind_unknown');
    });

    test('HARDENING: 弱汇总词不吞真实消费(「可用额度」尾注)', () async {
      final decision = policy.evaluate(
        bill: bill(status: BillSettlementStatus.settled),
        source: 'sms',
        evidenceText: '您尾号1234账户于1月5日消费100元,可用额度900元',
      );
      expect(decision.isAllowed, isTrue,
          reason: '2026-09-10 修复:settled 词优先,不整条判汇总');
      expect(decision.reason, 'settled_transaction');
    });

    test('HARDENING: normalizeForPersistence 按 eventKind 反推方向与绝对值',
        () async {
      final refund = policy.normalizeForPersistence(
        bill: BillInfo(
          amount: -88,
          time: DateTime.now(),
          type: BillType.expense,
          eventKind: BillEventKind.refund,
        ),
      );
      expect(refund.type, BillType.income, reason: '退款改收入方向');
      expect(refund.amount, 88, reason: 'abs 规范化');

      final repayment = policy.normalizeForPersistence(
        bill: BillInfo(
          amount: -500,
          time: DateTime.now(),
          type: BillType.expense,
          eventKind: BillEventKind.repayment,
        ),
      );
      expect(repayment.type, BillType.transfer);

      final fee = policy.normalizeForPersistence(
        bill: BillInfo(
          amount: 5,
          time: DateTime.now(),
          type: BillType.income,
          eventKind: BillEventKind.fee,
        ),
      );
      expect(fee.type, BillType.expense);
      expect(fee.amount, 5);
    });

    test('HARDENING: 主动路径(automatic=false)不受任何闸门约束', () async {
      final decision = policy.evaluate(
        bill: BillInfo(amount: null, type: BillType.expense),
        source: 'manual',
        automatic: false,
      );
      expect(decision.isAllowed, isTrue);
      expect(decision.reason, 'user_initiated');
    });

    // ADVERSE FINDING: AutoBookPolicy 只做 `amount.abs() <= 0` 与
    // `amount.abs() <= 0` 判空,没有 isFinite 守卫。NaN 的比较恒为 false,
    // 于是 NaN 金额绕过 invalid_amount 闸门被判 allow;Infinity 同理。
    // 上游 JsonResponseParser 同样不做 isFinite 过滤,JSON 里的 1e999 /
    // "Infinity" / "NaN" 会一路走到落库。
    test('ADVERSE: NaN / Infinity 金额绕过 invalid_amount 闸门被判 allow',
        () async {
      final nanDecision = policy.evaluate(
        bill: bill(amount: double.nan),
        source: 'sms',
      );
      expect(nanDecision.action, AutoBookPolicyAction.ignore,
          reason: 'NaN 不是有效金额,必须按 invalid_amount 丢弃;'
              '实际 allow(settled_transaction)');

      final infDecision = policy.evaluate(
        bill: bill(amount: double.infinity),
        source: 'sms',
      );
      expect(infDecision.action, AutoBookPolicyAction.ignore,
          reason: 'Infinity 同样不是有效金额');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('离线草稿重放契约', () {
    test('HARDENING: saveDraftByEventKey 对不存在 / 终态事件返回 false', () async {
      expect(
        await store.saveDraftByEventKey(
            'draft:missing', const AutoBookDraftPayload(isImage: false, text: 'x')),
        isFalse,
      );
      for (final state in [
        AutoBookState.booked,
        AutoBookState.duplicate,
        AutoBookState.ignored,
        AutoBookState.pending,
        AutoBookState.failed,
        AutoBookState.expired,
      ]) {
        final key = 'draft:terminal:${state.value}';
        final event = await store.ensure(input(key));
        await store.mark(AutoBookEventUpdate(state: state), eventId: event.id);
        expect(
          await store.saveDraftByEventKey(
              key, const AutoBookDraftPayload(isImage: false, text: 'x')),
          isFalse,
          reason: '${state.value} 终态不得被草稿复活',
        );
      }
    });

    test('HARDENING: 草稿 JSON 往返(版本 / 可选字段)', () async {
      const payload = AutoBookDraftPayload(
        isImage: true,
        imagePath: '/tmp/a.png',
        title: 't',
        actor: '95555',
      );
      final json = jsonDecode(jsonEncode(payload.toJson())) as Map;
      final restored = AutoBookDraftPayload.fromJson(json)!;
      expect(restored.isImage, isTrue);
      expect(restored.imagePath, '/tmp/a.png');
      expect(restored.title, 't');
      expect(restored.actor, '95555');
      expect(restored.version, AutoBookDraftPayload.currentVersion);
      expect(restored.previewLabel, 'image');

      // 损坏 / 非 Map 输入
      expect(AutoBookDraftPayload.fromJson('junk'), isNull);
      expect(AutoBookDraftPayload.fromJson(null), isNull);
      // isImage 非 bool → false
      final tolerant = AutoBookDraftPayload.fromJson(
          {'isImage': 'yes', 'text': null})!;
      expect(tolerant.isImage, isFalse);
      // HARDENING:fromJson 用 `as String?` / `as num?` 强转,畸形字段直接抛
      // TypeError 而不是返回 null。调用侧(retryDueDrafts / retryDraft)多数
      // 包了 try/catch,但一旦写入畸形 JSON,该草稿只能整条跳过并 clearDraft
      // —— 用户在「离线草稿」列表里看到的条目无法重放。
      expect(
        () => AutoBookDraftPayload.fromJson({'isImage': false, 'text': 42}),
        throwsA(isA<TypeError>()),
      );
      expect(
        () => AutoBookDraftPayload.fromJson({'isImage': false, 'version': 'x'}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('PendingCandidateStore 候选队列', () {
    late PendingCandidateStore candidates;

    setUp(() {
      candidates = PendingCandidateStore();
    });

    PendingCandidate candidate({
      required String id,
      DateTime? capturedAt,
      String? eventKey,
      int? itemIndex,
      double amount = -30,
    }) =>
        PendingCandidate(
          id: id,
          bill: BillInfo(
            amount: amount,
            time: DateTime.now(),
            type: BillType.expense,
            ledgerId: 1,
          ),
          capturedAt: capturedAt ?? DateTime.now(),
          source: 'sms',
          eventKey: eventKey,
          eventItemIndex: itemIndex,
        );

    test('HARDENING: 同 id 幂等;remove 支持按 (eventKey,itemIndex) 连带清理',
        () async {
      final first = await candidates.add(candidate(id: 'c1', eventKey: 'k', itemIndex: 0));
      final dup = await candidates.add(candidate(id: 'c1', eventKey: 'k', itemIndex: 0));
      expect(first, isTrue);
      expect(dup, isFalse, reason: '同 id 幂等跳过');
      expect(await candidates.count(), 1);

      // 按子项身份清理(即使候选 id 不同)
      await candidates.add(candidate(id: 'c2', eventKey: 'k', itemIndex: 0));
      await candidates.add(candidate(id: 'c3', eventKey: 'k', itemIndex: 1));
      expect(await candidates.count(), 3);
      final removed =
          await candidates.remove('nonexistent', eventKey: 'k', eventItemIndex: 0);
      expect(removed, isTrue, reason: '按 (eventKey,itemIndex) 应命中 2 条');
      expect(await candidates.count(), 1);
    });

    test('HARDENING: remove 缺少 eventItemIndex 时不做身份清理(防空删)', () async {
      await candidates.add(candidate(id: 'c1', eventKey: 'k', itemIndex: 0));
      expect(await candidates.remove('other', eventKey: 'k'), isFalse,
          reason: '只有 eventKey 不得误删同事件其它子项');
      expect(await candidates.count(), 1);
      // HARDENING:注释说「不把旧候选缺失的索引当作 0」,但显式传 0 是合法身份
      expect(await candidates.remove('other', eventKey: 'k', eventItemIndex: 0),
          isTrue);
    });

    test('HARDENING: legacy 候选 30 天 TTL 在读写路径都过滤', () async {
      await candidates.add(PendingCandidate(
        id: 'stale',
        bill: BillInfo(
            amount: -30, time: DateTime.now(), type: BillType.expense, ledgerId: 1),
        capturedAt: DateTime.now().subtract(const Duration(days: 31)),
      ));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_candidates_v1'), hasLength(1),
          reason: '首次写入时 TTL 未生效(写入的是刚 add 的那条)');

      await candidates.add(candidate(id: 'fresh'));
      expect(await candidates.count(), 1, reason: 'TTL 在 _loadUnlocked 里过滤');
      // HARDENING:下一次落盘会顺手把过期记录物理清掉(_saveUnlocked 写的是
      // 过滤后的列表)——「只在读路径过滤」的注释与实现不完全一致,
      // 但方向正确(过期候选终将被清),不构成缺陷。
      expect(prefs.getStringList('pending_candidates_v1'), hasLength(1));
      final stored = prefs.getStringList('pending_candidates_v1')!.single;
      expect(stored.contains('"stale"'), isFalse,
          reason: '过期记录已在下次 add 的落盘中被清掉');
    });

    test('HARDENING: cap 100 淘汰最旧并置「已归档」提示', () async {
      final base = DateTime.now();
      for (var i = 0; i < 101; i++) {
        await candidates.add(candidate(
          id: 'cap:$i',
          capturedAt: base.add(Duration(seconds: i)),
        ));
      }
      expect(await candidates.count(), 100);
      final kept = await candidates.load();
      expect(kept.any((c) => c.id == 'cap:0'), isFalse, reason: '最旧被淘汰');
      expect(kept.any((c) => c.id == 'cap:100'), isTrue);
      expect(await candidates.hasArchivedHint(), isTrue);
      await candidates.clearArchivedHint();
      expect(await candidates.hasArchivedHint(), isFalse);
    });

    test('HARDENING: loadForReview 合并 event store 投影与 legacy 候选', () async {
      final event = await store.ensure(input('review:e1', ledgerId: 1));
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'pending',
        amount: -30,
        semanticKey: 'sem:1',
        reason: 'lowConfidence',
        bill: {
          'candidate_id': 'evt-cand-1',
          'bill': {
            'amount': -30,
            'time': DateTime.now().toIso8601String(),
            'type': 'expense',
            'ledgerId': 1,
          },
          'candidate_reason': 'duplicate',
          'billing_types': ['ai'],
        },
      );
      await store.mark(
        const AutoBookEventUpdate(
            state: AutoBookState.pending, reason: 'pending_confirmation'),
        eventId: event.id,
      );
      // legacy 副本:candidate id 相同,eventItemIndex 缺失
      await candidates.add(PendingCandidate(
        id: 'evt-cand-1',
        bill: BillInfo(
            amount: -30, time: DateTime.now(), type: BillType.expense, ledgerId: 1),
        capturedAt: DateTime.now(),
        source: 'legacy',
        eventKey: event.eventKey,
      ));
      // 纯 legacy 候选(无 eventKey)
      await candidates.add(candidate(id: 'legacy-only'));

      final review = await candidates.loadForReview(store);
      expect(review.map((c) => c.id).toSet(), {'evt-cand-1', 'legacy-only'});
      final projected = review.firstWhere((c) => c.id == 'evt-cand-1');
      expect(projected.eventItemIndex, 0, reason: '以 event store 投影为准');
      expect(projected.semanticKey, 'sem:1');
      expect(projected.reason, 'lowConfidence',
          reason: 'item.reason 优先于 payload candidate_reason');
    });

    test('HARDENING: loadForReview 跳过证据不足的行(amount/time 缺失)', () async {
      final event = await store.ensure(input('review:incomplete', ledgerId: 1));
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'pending',
        bill: {'candidate_id': 'bad', 'bill': {'amount': null}},
      );
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.pending),
        eventId: event.id,
      );
      expect(await candidates.loadForReview(store), isEmpty,
          reason: 'bill.amount 缺失的候选无入账材料,不展示假按钮');
    });

    test('HARDENING: loadForReview 触发 pending TTL 过期(30 天未确认等同放弃)',
        () async {
      final event = await store.ensure(AutoBookInput(
        eventKey: 'review:ttl',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().subtract(const Duration(days: 31)),
        ledgerId: 1,
      ));
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'pending',
        bill: {
          'candidate_id': 'old',
          'bill': {
            'amount': -30,
            'time': DateTime.now().toIso8601String(),
            'type': 'expense',
            'ledgerId': 1,
          },
        },
      );
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.pending),
        eventId: event.id,
      );
      expect(await candidates.loadForReview(store), isEmpty);
      expect((await store.findById(event.id))!.state, 'expired',
          reason: 'loadForReview 自带 TTL 过期');
    });

    test('HARDENING: PendingDecisionCoordinator 同键串行,异常不断链', () async {
      PendingDecisionCoordinator.resetForTest();
      final order = <String>[];
      final key = 'pending:e:0';
      final f1 = PendingDecisionCoordinator.run<String>(key, () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('a');
        return 'a';
      });
      final f2 = PendingDecisionCoordinator.run<String>(key, () async {
        order.add('b');
        throw StateError('boom');
      });
      final f3 = PendingDecisionCoordinator.run<String>(key, () async {
        order.add('c');
        return 'c';
      });
      expect(await f1, 'a');
      await expectLater(f2, throwsA(isA<StateError>()));
      expect(await f3, 'c', reason: '前一个失败不阻断后续队列');
      expect(order, ['a', 'b', 'c']);

      // 不同键互不阻塞
      final slow = PendingDecisionCoordinator.run<void>('key-x', () async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      final fastDone = <bool>[];
      final fast = PendingDecisionCoordinator.run<void>(
          'key-y', () async => fastDone.add(true));
      await fast;
      expect(fastDone, [true]);
      await slow;
      PendingDecisionCoordinator.resetForTest();
    });

    test('HARDENING: keyFor 口径稳定(同候选跨页一致)', () {
      final withIndex = candidate(id: 'a', eventKey: 'k', itemIndex: 3);
      final withoutIndex = candidate(id: 'a', eventKey: 'k');
      expect(PendingDecisionCoordinator.keyFor(withIndex), 'pending:k:3');
      expect(PendingDecisionCoordinator.keyFor(withoutIndex), 'pending:k:0',
          reason: '缺失索引按 0 —— 与 remove 的「不当 0」口径相反,'
              '但互斥键取粗粒度是安全方向');
      final legacy = candidate(id: 'legacy-id');
      expect(PendingDecisionCoordinator.keyFor(legacy), 'pending:legacy-id:0');
    });

    test('HARDENING: PendingCandidate JSON 往返保留判重证据字段', () async {
      final c = PendingCandidate(
        id: 'json-1',
        bill: BillInfo(
          amount: -88,
          time: DateTime.now(),
          type: BillType.expense,
          ledgerId: 7,
          merchant: '抖音商城',
        ),
        billingTypes: const ['ai', 'sms'],
        source: 'notification',
        capturedAt: DateTime.now(),
        reason: 'duplicate',
        eventKey: 'k',
        eventItemIndex: 1,
        semanticKey: 'sem',
        matchedTransactionId: 42,
        matchScore: 0.93,
      );
      final restored = PendingCandidate.fromJson(
          jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>)!;
      expect(restored.matchedTransactionId, 42);
      expect(restored.matchScore, 0.93);
      expect(restored.billingTypes, ['ai', 'sms']);
      expect(restored.eventItemIndex, 1);
      expect(restored.bill.merchant, '抖音商城');
      // 损坏输入
      expect(PendingCandidate.fromJson({'bill': 'not-a-map'}), isNull);
      expect(PendingCandidate.fromJson({}), isNull);
    });

    test('HARDENING: candidateId 由 bill JSON 派生且稳定(同内容同 id)', () {
      final a = BillInfo(
          amount: -30, time: DateTime.now(), type: BillType.expense, ledgerId: 1);
      final b = BillInfo(
          amount: -30,
          time: a.time,
          type: BillType.expense,
          ledgerId: 1);
      expect(PendingCandidate.candidateId(a), PendingCandidate.candidateId(b));
      final c = a.copyWith(amount: -31);
      expect(PendingCandidate.candidateId(a), isNot(PendingCandidate.candidateId(c)));
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutoBookRule 分流硬闸门', () {
    test('HARDENING: 同账本同类型金额全等且 <=1min → 疑似重复', () {
      final t = DateTime.now();
      final base = BillInfo(
          amount: -30, time: t, type: BillType.expense, ledgerId: 1);
      expect(
        AutoBookRule.looksLikeDuplicate(base, [
          BillInfo(
              amount: -30,
              time: t.add(const Duration(seconds: 59)),
              type: BillType.expense,
              ledgerId: 1),
        ]),
        isTrue,
      );
      expect(
        AutoBookRule.looksLikeDuplicate(base, [
          BillInfo(
              amount: -30,
              time: t.add(const Duration(seconds: 61)),
              type: BillType.expense,
              ledgerId: 1),
        ]),
        isFalse,
      );
      // 差 0.01 元不判重(无容差)
      expect(
        AutoBookRule.looksLikeDuplicate(base, [
          BillInfo(
              amount: -30.01,
              time: t,
              type: BillType.expense,
              ledgerId: 1),
        ]),
        isFalse,
      );
      // 跨账本 / 异类型不判重
      expect(
        AutoBookRule.looksLikeDuplicate(base, [
          BillInfo(amount: -30, time: t, type: BillType.expense, ledgerId: 2),
        ]),
        isFalse,
      );
      expect(
        AutoBookRule.looksLikeDuplicate(base, [
          BillInfo(amount: -30, time: t, type: BillType.income, ledgerId: 1),
        ]),
        isFalse,
      );
    });

    test('HARDENING: 时间双方都缺失时按 diff=0 判重(保守方向可辩护)', () {
      final a = BillInfo(amount: -30, type: BillType.expense, ledgerId: 1);
      final b = BillInfo(amount: -30, type: BillType.expense, ledgerId: 1);
      expect(AutoBookRule.looksLikeDuplicate(a, [b]), isTrue,
          reason: '两条都无时间 → Duration.zero → 判重进待确认(宁可多问)');
    });

    // ADVERSE FINDING: requiresConfirmation 的低置信分支只看
    // confidence < 0.9,不看 confidenceProvided。BillInfo 的默认 confidence
    // 是 1.0(旧模型缺省=高置信),但 NaN 会让 `nan < 0.9` 恒为 false 而
    // 绕过;**更重要的是** confidence=0.95 这类「模型自报高置信」被直接放行,
    // 而注释明确承认「模型返回的 confidence 并不可靠」。
    test('HARDENING: NaN confidence 不算低置信(比较恒 false)', () {
      final nanConfidence = BillInfo(
        amount: -30,
        time: DateTime.now(),
        type: BillType.expense,
        confidence: double.nan,
        ledgerId: 1,
      );
      expect(AutoBookRule.isLowConfidence(nanConfidence), isFalse,
          reason: 'NaN < 0.9 == false → NaN 置信度被判高置信,直接放行');
      expect(
        AutoBookRule.requiresConfirmation(
            bill: nanConfidence, recentBills: const [], pendingBills: const []),
        isFalse,
      );
    });

    test('HARDENING: reasonKeyFor 优先级 疑似重复 > 低置信 > null', () {
      final lowConf = BillInfo(
          amount: -30, confidence: 0.5, time: DateTime.now(), ledgerId: 1);
      expect(AutoBookRule.reasonKeyFor(bill: lowConf, duplicate: true),
          'duplicate');
      expect(AutoBookRule.reasonKeyFor(bill: lowConf, duplicate: false),
          'lowConfidence');
      final highConf = BillInfo(
          amount: -30, confidence: 1.0, time: DateTime.now(), ledgerId: 1);
      expect(AutoBookRule.reasonKeyFor(bill: highConf, duplicate: false), isNull);
    });

    test('HARDENING: 豁免规则同时作用于硬闸门(用户裁定「仍记一笔」不复发)',
        () async {
      final t = DateTime.now();
      final base = BillInfo(
        amount: -30,
        time: t,
        type: BillType.expense,
        ledgerId: 1,
        merchant: '星巴克',
      );
      final other = BillInfo(
        amount: -30,
        time: t,
        type: BillType.expense,
        ledgerId: 1,
        merchant: '星巴克',
      );
      expect(AutoBookRule.hardGateMatches(base, other), isTrue);
      final exempted = AutoBookRule.hardGateMatches(
        base,
        other,
        exemptRules: [
          DedupExemptRule(
              keyword: '星巴克', amount: 30, createdAt: DateTime.now()),
        ],
      );
      expect(exempted, isFalse, reason: '命中豁免后不得再判重');
    });
  });
}
