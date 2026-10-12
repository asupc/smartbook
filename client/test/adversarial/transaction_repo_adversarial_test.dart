// 对抗性测试 — 交易仓库域(SmartBook 客户端数据层)。
//
// 目标:找出真实缺陷(约束违反、软删/复活漏洞、边界数值、悬挂引用、
// 口径不一致)。发现缺陷时测试保持激活并失败,注释标 `// ADVERSE FINDING:`。
// 行为可辩护但脆弱 → 断言当前行为并通过,注释标 `// HARDENING:`。
//
// 只读语义参照:lib/data/repositories/local/local_transaction_repository.dart
//             lib/data/repositories/local/local_repository.dart
//             lib/data/db.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/data/repositories/transaction_repository.dart'
    show BatchAttachmentData, TransactionPageCursor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });
  tearDown(() async => db.close());

  Future<void> seedLedger([int id = 1, String currency = 'CNY']) {
    return db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES ($id, 'L$id', '$currency')");
  }

  // ══════════════════════════════════════════════════════════════════════
  // A. syncId 约束
  // ══════════════════════════════════════════════════════════════════════

  group('A. syncId 约束', () {
    test('A1 transactions.sync_id 无 UNIQUE 约束:同 syncId 可插入两行,'
        'getTransactionBySyncId 抛 Bad state 并静默丢失删除', () async {
      await seedLedger();
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: 'DUP-1');
      // C3 修复:第二行同 (ledger_id, syncId) 被 v45 的
      // UNIQUE(ledger_id, sync_id) 拒绝(SqliteException),不再是静默落库。
      // 此处断言"被拒绝"—— 原断言 expect(c, 2) 编码的正是修复前的缺陷。
      Object? dupErr;
      try {
        await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: 2,
            happenedAt: DateTime(2026, 7, 2), syncId: 'DUP-1');
      } catch (e) {
        dupErr = e;
      }
      final rows = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='DUP-1'")
          .getSingle();
      expect(dupErr, isNotNull,
          reason: 'C3 修复:同账本同 syncId 第二行被唯一约束拒绝(${dupErr.runtimeType})');
      expect(rows.data['c'], 1, reason: 'C3 修复:syncId 在账本内唯一,不再有重复行');

      // 单行读:唯一索引保证了单行;即便历史脏库残留重复行,limit(1) 也不再抛
      Object? readErr;
      try {
        await repo.getTransactionBySyncId('DUP-1');
      } catch (e) {
        readErr = e;
      }
      // C3 修复: getTransactionBySyncId 改 limit(1)(确定性取最早一行),
      // 不再在多行时抛 StateError。产品源码: local_transaction_repository.dart
      // (原 getSingleOrNull 无去重)。
      expect(readErr, isNull,
          reason: 'C3 修复: limit(1) 后按 syncId 的单行读稳定返回一行,不再抛 '
              '"Bad state: Too many elements"');

      // 删除路径:同样不再抛错,且删除生效
      Object? delErr;
      try {
        await repo.deleteTransactionBySyncId('DUP-1');
      } catch (e) {
        delErr = e;
      }
      final after = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='DUP-1'")
          .getSingle();
      expect(delErr, isNull, reason: 'C3 修复: deleteTransactionBySyncId 不再抛错');
      expect(after.data['c'], 0,
          reason: 'C3 修复: 按 syncId 的删除真正落库(进入回收站)');
    });

    test('A2 空串 syncId 被当作正常标识写入:两行同为空串,'
        'updateTransactionBySyncId("") 一写全改', () async {
      await seedLedger();
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: '');
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 7, 2), syncId: '');
      // addTransaction 只在 syncId == null 时补 UUID(dart:446 `syncId ?? _uuid.v4()`),
      // 空串被原样接受。v45 的 UNIQUE(ledger_id, sync_id) 是**部分索引**
      // (`WHERE sync_id <> ''`),故空串仍允许多行 —— 这是刻意的:空串是 caller
      // 契约外的输入(HARDENING),不纳入唯一域以免把存量脏数据判为冲突。
      final rows = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id = ''")
          .getSingle();
      expect(rows.data['c'], 2,
          reason: '空串 syncId 不被 UUID 兜底替换(仅 null 才替换)');

      // 批量 UPDATE 命中两行:一次"更新一笔"变成改写全部空 syncId 交易。
      await repo.updateTransactionBySyncId(
          syncId: '', type: 'income', amount: 99,
          happenedAt: DateTime(2026, 7, 3));
      final all = await db.select(db.transactions).get();
      final changed = all.where((t) => t.amount == 99).length;
      // HARDENING: 空串是 caller 契约外的输入;repo 不做校验。当前行为是
      // 一次写改多行,数据不损坏(仅被覆盖),故不断言为缺陷,只钉住行为。
      expect(changed, 2,
          reason: 'HARDENING: updateTransactionBySyncId 对空串 syncId 是 N 行 UPDATE;'
              '调用方必须自行保证 syncId 非空/唯一');
      // C3 修复:读路径 limit(1) → 空串多行时返回最早一行,不再抛 Bad state
      Object? readErr;
      try {
        await repo.getTransactionBySyncId('');
      } catch (e) {
        readErr = e;
      }
      expect(readErr, isNull,
          reason: 'C3 修复: 空串 + 多行 → limit(1) 稳定返回一行(A1 同根因已修)');
    });

    test('A3 syncId 超长(1MB)与非法字符:无长度/格式校验但可落库', () async {
      await seedLedger();
      final huge = 'x' * 1000000; // 1MB
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: huge);
      final t = await repo.getTransactionBySyncId(huge);
      // HARDENING: TEXT 无长度限制,syncId 长度只影响同步 payload 体积。
      expect(t, isNotNull, reason: 'HARDENING: syncId 无长度校验(1MB 可落库)');

      // 含 NUL / 换行的 syncId
      final weird = 'a\u0000b\nc';
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 7, 2), syncId: weird);
      // SQLite TEXT 可存任意字节,但 sqlite3 驱动按 C 字符串处理可能截断。
      final w = await repo.getTransactionBySyncId(weird);
      final wTrunc = await repo.getTransactionBySyncId('a');
      // HARDENING: 无校验;此处只记录真实落库形态,不断言成败。
      expect(w != null || wTrunc != null, isTrue,
          reason: 'HARDENING: syncId 无字符白名单校验');
    });

    test('A4 同 syncId 不同账本:getTransactionBySyncId 跨账本泄漏', () async {
      await seedLedger(1);
      await seedLedger(2);
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: 'CROSS');
      await repo.addTransaction(
          ledgerId: 2, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 7, 1), syncId: 'CROSS');
      Object? err;
      try {
        await repo.getTransactionBySyncId('CROSS');
      } catch (e) {
        err = e;
      }
      // ADVERSE FINDING: 跨账本重复 syncId 无任何隔离,读路径直接崩。
      expect(err, isNull,
          reason: 'ADVERSE FINDING: syncId 全表唯一性缺失,跨账本同 syncId → '
              'getTransactionBySyncId 抛 Bad state');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // B. 回收站 / 软删 / 复活
  // ══════════════════════════════════════════════════════════════════════

  group('B. 回收站软删/复活', () {
    test('B1 删除交易后 attachments 行残留(未级联),恢复后标签永久丢失', () async {
      await seedLedger();
      final tagId = await repo.createTag(name: 'T-trash');
      final txId = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10, happenedAt: DateTime(2026, 7, 1));
      await repo.updateTransactionTags(transactionId: txId, tagIds: [tagId]);
      await repo.createAttachment(transactionId: txId, fileName: 'a.jpg');

      await repo.deleteTransaction(txId);

      final attLeft = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_attachments')
          .getSingle();
      final tagLeft = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      // ADVERSE FINDING: 删除只清 transaction_tags(:645-647),附件行留着 →
      // 成孤儿,又不进回收站 payload(只有 payloadJson 存交易行字段)。清理
      // _deleteAttachmentsForTransaction 是私有方法且在 v43 路径上不再被调用。
      expect(attLeft.data['c'], 0,
          reason: 'ADVERSE FINDING: deleteTransaction 后 transaction_attachments '
              '残留 ${attLeft.data['c']} 行(悬挂引用,需孤儿扫描器才能清)');
      expect(tagLeft.data['c'], 0, reason: '标签关联被正确清理');

      final tomb = (await repo.listDeletedTransactions()).first;
      final newId = await repo.restoreDeletedTransaction(tomb.id);
      final tagsAfter = await repo.getTagsForTransaction(newId!);
      final attsAfter = await repo.getAttachmentsByTransaction(newId);
      // ADVERSE FINDING: 恢复不还原标签/附件关联 —— payload(:_archiveToTrash)
      // 只序列化交易行字段,不含 tagIds/attachments。
      expect(tagsAfter.length, 1,
          reason: 'ADVERSE FINDING: 回收站恢复后标签丢失(0 个),payload 不含标签关联');
      expect(attsAfter.length, 1,
          reason: 'ADVERSE FINDING: 回收站恢复后附件关联丢失(0 个);'
              '而附件行又残留在新交易 id 之外 → 双向悬挂');
    });

    test('B2 批量删除(deleteTransactionsBatchBySyncIds)既不入回收站也不登记 change',
        () async {
      await seedLedger();
      final txId = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'BATCH-DEL');
      await repo.createAttachment(transactionId: txId, fileName: 'b.jpg');

      final n = await repo.deleteTransactionsBatchBySyncIds(['BATCH-DEL']);
      final trash = await repo.listDeletedTransactions();

      // ADVERSE FINDING: 同一仓库两条删除路径语义不一致 —— 单条 delete 进回收站
      // (v43 承诺"30 天内可恢复"),批量 delete 是硬删连附件行一起清。
      // 产品源码: local_transaction_repository.dart:1960-1986。
      expect(trash.length, 1,
          reason: 'ADVERSE FINDING: deleteTransactionsBatchBySyncIds 硬删(n=$n),'
              '不进回收站,与 deleteTransaction 的 30 天可恢复承诺不一致');
    });

    test('B3 trash → restore → trash 三轮:墓碑被复用,不产生重复', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'LOOP');
      var cur = id;
      for (var round = 0; round < 3; round++) {
        await repo.deleteTransaction(cur);
        final trash = await repo.listDeletedTransactions();
        expect(trash.length, 1, reason: '每轮恰好一条墓碑(_archiveToTrash 幂等)');
        cur = (await repo.restoreDeletedTransaction(trash.first.id))!;
        final live = await db
            .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='LOOP'")
            .getSingle();
        // HARDENING: 恢复写回主表时沿用旧 syncId,墓碑删除 → 状态自洽。
        expect(live.data['c'], 1, reason: 'HARDENING: 主表恰好一行');
      }
      await repo.deleteTransaction(cur);
      final fin = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='LOOP'")
          .getSingle();
      expect(fin.data['c'], 0);
      expect((await repo.listDeletedTransactions()).length, 1,
          reason: 'HARDENING: 三轮循环后墓碑数不膨胀');
    });

    test('B4 deletedAt = epoch 0:被当作 30 天前清理(误删)但列表仍可读', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'EPOCH');
      await repo.deleteTransaction(id);
      await db.customStatement(
          "UPDATE deleted_transactions SET deleted_at = 0 WHERE sync_id = 'EPOCH'");
      final tomb = (await repo.listDeletedTransactions()).first;
      // HARDENING: epoch 0 读回是本地时区 1970-01-01(isUtc=false)——
      // drift 用本地时间解析 unix 秒,UTC 边界在非 UTC 时区会偏一天,
      // 但清理比较同样走同一时区,不产生误判。
      expect(tomb.deletedAt.year, lessThan(2000));
      final removed = await repo.cleanupDeletedTransactions(days: 30);
      expect(removed, 1,
          reason: 'HARDENING: deletedAt=epoch0 必然过期 → 被清理(符合语义)');
    });

    test('B5 cleanup 边界:恰好 30 天前(isSmallerOrEqual)会被提前清掉', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'EXACT30');
      await repo.deleteTransaction(id);
      final exactly = DateTime.now().subtract(const Duration(days: 30));
      await db.customStatement(
          'UPDATE deleted_transactions SET deleted_at = ? WHERE sync_id = ?',
          [exactly.millisecondsSinceEpoch ~/ 1000, 'EXACT30']);
      final removed = await repo.cleanupDeletedTransactions(days: 30);
      // HARDENING: 实现用 isSmallerOrEqualValue(≤ cutoff),所以"正好 30 天"当天
      // 就被清。UI 承诺「30 天内可恢复」在此边界少一天,属可辩护但脆弱。
      expect(removed, 1,
          reason: 'HARDENING: 边界日被清理(≤ 而非 <,承诺窗口实际 < 30 天)');
    });

    test('B6 墓碑 payloadJson 非法 JSON:restore 返回 null 且墓碑保留', () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO deleted_transactions (sync_id, ledger_id, amount, tx_type, happened_at, payload_json) "
          "VALUES ('BADJ', 1, 1.0, 'expense', 0, 'not-json')");
      final tomb = (await repo.listDeletedTransactions()).first;
      final nid = await repo.restoreDeletedTransaction(tomb.id);
      // HARDENING: 非法 JSON 走 catch(_) → return null,墓碑不删(不丢数据)。
      expect(nid, isNull);
      expect((await repo.listDeletedTransactions()).length, 1);
    });

    test('B7 payload 合法 JSON 但缺 ledgerId:restore 抛 TypeError 且墓碑保留',
        () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO deleted_transactions (sync_id, ledger_id, amount, tx_type, happened_at, payload_json) "
          "VALUES ('BADP', 1, 1.0, 'expense', 0, '${jsonEncode({'type': 'expense', 'amount': 1})}')");
      final tomb = (await repo.listDeletedTransactions()).first;
      Object? err;
      try {
        await repo.restoreDeletedTransaction(tomb.id);
      } catch (e) {
        err = e;
      }
      // ADVERSE FINDING: payload 结构损坏时抛 _TypeError 而不是返回 null —
      // 注释声称"找不到/已过期返回 null",实际非 JSON 解析类错误直接冒泡;
      // 更糟的是墓碑仍在(对比 B6 的 catch)。
      expect(err, isNull,
          reason: 'ADVERSE FINDING: restoreDeletedTransaction 解析合法 JSON 但缺 '
              'ledgerId 时抛 ${err.runtimeType}(未纳入 try/catch,与 B6 分支不一致)');
    });

    test('B8 远端 pull 复活 + 本地 restore 叠加 → 主表重复 syncId,后续操作全断',
        () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'RES-SYNC');
      await repo.deleteTransaction(id); // 本地回收站(远端不知道)

      // 模拟下一次 pull:远端仍认为实体存在,按同 syncId upsert 回主表。
      await repo.insertTransactionCompanion(
        TransactionsCompanion.insert(
            ledgerId: 1, type: 'expense', amount: 10,
            happenedAt: d.Value(DateTime(2026, 7, 1)),
            syncId: const d.Value('RES-SYNC')),
        recordChanges: false,
      );
      final live1 = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='RES-SYNC'")
          .getSingle();
      expect(live1.data['c'], 1);

      // 用户点「恢复」:payload 携带同一 syncId 写回主表 → 两行同 syncId。
      final tomb = (await repo.listDeletedTransactions()).first;
      final newId = await repo.restoreDeletedTransaction(tomb.id);
      final live2 = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='RES-SYNC'")
          .getSingle();

      // ADVERSE FINDING: restoreDeletedTransaction 不检查主表是否已有同 syncId
      // (_archiveToTrash 只在写墓碑时查重,恢复方向没有防护)。
      // 产品源码: local_transaction_repository.dart:706-751。
      expect(live2.data['c'], 1,
          reason: 'ADVERSE FINDING: 远端复活 + 本地恢复 → 同 syncId 两行'
              '(实际 ${live2.data['c']} 行, newId=$newId);此后 '
              'getTransactionBySyncId / deleteTransactionBySyncId 全部抛 Bad state');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // B'. 批量删除的跨账本判定(跨审缺陷 1c)
  //
  // 判据是「**单个 syncId** 命中多个账本」,不是「批次里出现了多个账本」:
  // UNIQUE(ledger_id, sync_id) 下两个不同 syncId 各属一个账本是完全正常的
  // 批次,旧判定会整批 StateError 且一行不删(合法批次被误拒)。
  // ══════════════════════════════════════════════════════════════════════

  group("B'. 批量删除跨账本判定", () {
    test('B9 不同 syncId 分属不同账本:正常删除(旧实现整批误拒)', () async {
      await seedLedger(1);
      await seedLedger(2);
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: 'TX-A');
      await repo.addTransaction(
          ledgerId: 2, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 7, 1), syncId: 'TX-B');

      Object? err;
      int? n;
      try {
        n = await repo.deleteTransactionsBatchBySyncIds(['TX-A', 'TX-B']);
      } catch (e) {
        err = e;
      }
      expect(err, isNull,
          reason: '1c: 两个**不同** syncId 各属一个账本是合法批次,不得整批拒绝');
      expect(n, 2, reason: '1c: 两行都删除');
      final left = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      expect(left.data['c'], 0, reason: '1c: 主表两行都清掉');
    });

    test('B10 单个 syncId 跨两个账本:fail-closed,一行不删', () async {
      await seedLedger(1);
      await seedLedger(2);
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 1), syncId: 'SAME');
      await repo.addTransaction(
          ledgerId: 2, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 7, 1), syncId: 'SAME');

      Object? err;
      try {
        await repo.deleteTransactionsBatchBySyncIds(['SAME']);
      } catch (e) {
        err = e;
      }
      expect(err, isA<StateError>(),
          reason: '1c: 单个 syncId 跨账本无法判定该删哪一笔 → 显式拒绝');
      final left = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
          .getSingle();
      expect(left.data['c'], 2, reason: '1c: 报错时一行都不删(不做部分删除)');

      // 混合批次:同一批次里既有跨账本 syncId 又有合法 syncId —— 整批拒绝
      // (fail-closed,不能只删"看起来安全"的那些:调用方拿到异常后应重试)。
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 3,
          happenedAt: DateTime(2026, 7, 1), syncId: 'TX-OK');
      Object? mixedErr;
      try {
        await repo.deleteTransactionsBatchBySyncIds(['SAME', 'TX-OK']);
      } catch (e) {
        mixedErr = e;
      }
      expect(mixedErr, isA<StateError>(),
          reason: '1c: 批次含跨账本 syncId → 整批拒绝(不静默部分删除)');
      final okLeft = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='TX-OK'")
          .getSingle();
      expect(okLeft.data['c'], 1,
          reason: '1c: 整批拒绝时合法行也不删(调用方修复后重试)');

      // 单条入口共用同一判定:syncId 跨账本 → StateError,一行不删。
      Object? singleErr;
      try {
        await repo.deleteTransactionBySyncId('SAME');
      } catch (e) {
        singleErr = e;
      }
      expect(singleErr, isA<StateError>(),
          reason: '1c: deleteTransactionBySyncId 与批量入口共用判定,语义一致');
      final still = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
          .getSingle();
      expect(still.data['c'], 2, reason: '1c: 单条入口同样一行不删');

      // 单条入口的常态路径不受影响:单账本 syncId 正常删除(进回收站)。
      Object? okErr;
      try {
        await repo.deleteTransactionBySyncId('TX-OK');
      } catch (e) {
        okErr = e;
      }
      expect(okErr, isNull, reason: '1c: 单账本 syncId 正常删除');
      final okGone = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='TX-OK'")
          .getSingle();
      expect(okGone.data['c'], 0, reason: '1c: 删除落库');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // C. 更新语义(丢字段)
  // ══════════════════════════════════════════════════════════════════════

  group('C. 更新语义', () {
    test('C1 updateTransaction 未传 categoryId/note 会被清空(默认值陷井)',
        () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'WC', kind: 'expense');
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10, categoryId: cat,
          happenedAt: DateTime(2026, 7, 1), note: 'keep me');

      // 只改金额,不传 category/note(可选参数默认 null)
      await repo.updateTransaction(
          id: id, type: 'expense', amount: 11, happenedAt: DateTime(2026, 7, 1));
      final t = await repo.getTransactionById(id);

      // ADVERSE FINDING: categoryId / note 无条件写 d.Value(null)(:589-590),
      // 而 happenedAt/accountId 走 absent 保护。同一方法内两种 null 语义并存,
      // 调用方(如 search_page 批量改备注)必须回填所有字段才不丢数据。
      // 产品源码: local_transaction_repository.dart:585-612。
      expect(t!.categoryId, cat,
          reason: 'ADVERSE FINDING: updateTransaction 未传 categoryId 时清空分类'
              '(期望保留 $cat,实际 ${t.categoryId});note 同理(${t.note})');
      expect(t.note, 'keep me',
          reason: 'ADVERSE FINDING: updateTransaction 未传 note 时清空备注');
    });

    test('C2 updateTransactionFields 只改 toAccountId:from 账户不受影响', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          accountId: 5, happenedAt: DateTime(2026, 7, 1));
      await repo.updateTransactionFields(id: id, toAccountId: 7);
      final t = await repo.getTransactionById(id);
      // HARDENING: accountId 未传 → Value.absent,from 账户保留。
      expect(t!.accountId, 5);
      expect(t.toAccountId, 7);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // D. 金额边界
  // ══════════════════════════════════════════════════════════════════════

  group('D. 金额边界', () {
    test('D1 2^53/NaN/Infinity:NaN 被 SQLite 拒为 NOT NULL,Infinity 静默落库'
        '并污染全部聚合', () async {
      await seedLedger();
      // NaN → sqlite 驱动把 NaN 当 NULL → NOT NULL 约束拒绝(意外但安全)
      Object? nanErr;
      try {
        await repo.addTransaction(ledgerId: 1, type: 'expense',
            amount: double.nan, happenedAt: DateTime(2026, 7, 1));
      } catch (e) {
        nanErr = e;
      }
      expect(nanErr, isNotNull, reason: 'HARDENING: NaN 被 NOT NULL 拦下(非产品校验)');

      // C3 修复:addTransaction 落库前校验 isFinite。Infinity 被拒绝,
      // 账本聚合不再被污染。原断言 expect(exp.isFinite, isTrue) 编码的是修复前
      // 的缺陷(Infinity 静默落库)。
      Object? infErr;
      try {
        await repo.addTransaction(ledgerId: 1, type: 'expense',
            amount: double.infinity, happenedAt: DateTime(2026, 7, 2));
      } catch (e) {
        infErr = e;
      }
      expect(infErr, isNotNull,
          reason: 'C3 修复: amount=Infinity 被 addTransaction 拒绝'
              '(${infErr.runtimeType}),不再静默落库污染聚合');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          happenedAt: DateTime(2026, 7, 3));
      final (_, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      expect(exp.isFinite, isTrue,
          reason: 'C3 修复: 月支出保持有限值($exp),整账本统计可用');
      expect(exp, 100.0, reason: 'C3 修复: 只有合法的一笔 100 计入');
    });

    test('D2 0.001 精度 × 100 笔:和漂移 ~1e-14(展示层可容忍)', () async {
      await seedLedger();
      for (var i = 0; i < 100; i++) {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 0.001,
            happenedAt: DateTime(2026, 7, 1));
      }
      final (_, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      // HARDENING: REAL 列 + SQLite SUM,漂移在 1e-13 量级(金额 2 位小数场景无感)。
      expect((exp - 0.1).abs(), lessThan(1e-9),
          reason: 'HARDENING: 0.001×100 累计漂移 ${exp - 0.1}');
    });

    test('D3 负数金额:支出为负会抵消其它支出,转账为负会反转资金流', () async {
      await seedLedger();
      final a = await repo.createAccount(ledgerId: 1, name: 'NGA', initialBalance: 1000);
      final b = await repo.createAccount(ledgerId: 1, name: 'NGB');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          happenedAt: DateTime(2026, 7, 1));
      // C3 修复(待确认产品决策):负数金额对方向性类型(expense/income/
      // transfer)在 addTransaction 处**拒绝** —— 方向由 type 表达,负金额会
      // 抵消其它支出、反转转账资金流。原断言 expect(exp, 200.0) 编码的正是
      // 修复前的缺陷(负金额落库并抵消)。
      Object? negErr;
      try {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: -100,
            happenedAt: DateTime(2026, 7, 2));
      } catch (e) {
        negErr = e;
      }
      expect(negErr, isNotNull,
          reason: 'C3 修复: expense 负金额被拒绝(${negErr.runtimeType})');
      final (inc, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      expect(exp, 100.0,
          reason: 'C3 修复: 月支出 = 100(负数被拒,不再互相抵消)');
      expect(inc, 0.0);

      // 转账为负:同样被拒,资金流不再反转
      Object? negTrErr;
      try {
        await repo.addTransaction(ledgerId: 1, type: 'transfer', amount: -100,
            accountId: a, toAccountId: b, happenedAt: DateTime(2026, 7, 4));
      } catch (e) {
        negTrErr = e;
      }
      expect(negTrErr, isNotNull,
          reason: 'C3 修复: transfer 负金额被拒绝(${negTrErr.runtimeType})');
      final balA = await repo.getAccountBalance(a);
      final balB = await repo.getAccountBalance(b);
      expect(balA, 1000.0,
          reason: 'C3 修复: 负转账未落库,转出账户余额不变');
      expect(balB, 0.0, reason: 'C3 修复: 转入账户余额不变(资金流未反转)');
    });

    test('D4 分页 limit <= 0 与超大 limit', () async {
      await seedLedger();
      for (var i = 0; i < 5; i++) {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: i.toDouble(),
            happenedAt: DateTime(2026, 7, 1, 0, 0, i));
      }
      final zero = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 0);
      final neg = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: -5);
      // HARDENING: limit 被 clamp(1,400)(:1023),所以 0/-5 都退化成 1 条。
      expect(zero.items.length, 1, reason: 'HARDENING: limit=0 → clamp 到 1');
      expect(neg.items.length, 1, reason: 'HARDENING: limit<0 → clamp 到 1');
      final huge = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 100000);
      expect(huge.items.length, 5);

      // C3 修复:列表入口的 limit 统一为「<= 0 → 空」(fail-closed)。
      // 旧行为把 -1 下推成 SQLite 的 "无上限",静默物化整账本 —— 原断言
      // expect(recentNeg.length, 5) 编码的正是该缺陷。
      final recentNeg = await repo.getRecentTransactions(1, limit: -1);
      final recentZero = await repo.getRecentTransactions(1, limit: 0);
      final recentBig = await repo.getRecentTransactions(1, limit: 100000);
      expect(recentNeg.length, 0,
          reason: 'C3 修复: getRecentTransactions(limit:-1) → 空(不再当无上限全量)');
      expect(recentZero.length, 0);
      expect(recentBig.length, 5);
    });

    test('D5 越界 offset / limit:负数偏移等价 0、LIMIT -1 等价无上限,'
        '同一仓库内三套 limit 语义并存', () async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'D5A');
      for (var i = 0; i < 3; i++) {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: i.toDouble(),
            accountId: acc, happenedAt: DateTime(2026, 7, 1, 0, 0, i));
      }
      final negOffset = await repo.getAccountTransactions(acc, offset: -10);
      final bigOffset = await repo.getAccountTransactions(acc, offset: 99999);
      final negLimit = await repo.getAccountTransactions(acc, limit: -1);
      final zeroLimit = await repo.getAccountTransactions(acc, limit: 0);
      // HARDENING: SQLite 把 OFFSET -N 当 0(返回全部)、LIMIT -1 当无上限、
      // LIMIT 0 返空。getAccountTransactions 原样下推(:720-733),不做 clamp,
      // 与 getTransactionPageWithCategory 的 clamp(1,400) 是两套约定。
      expect(negOffset.length, 3, reason: 'HARDENING: OFFSET -10 等价 0');
      expect(bigOffset.length, 0, reason: 'HARDENING: 越界 offset 返回空(非异常)');
      expect(negLimit.length, 3,
          reason: 'HARDENING: LIMIT -1 = 无上限(静默全量),调用方传负值不会报错只会拖慢');
      expect(zeroLimit.length, 0, reason: 'HARDENING: LIMIT 0 返空');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // E. 日期 / 时区 / 月起始日
  // ══════════════════════════════════════════════════════════════════════

  group('E. 日期与时区', () {
    test('E1 日历月视图(getDailyTotalsByMonth/getTransactionDatesByMonth)'
        '在 UTC+8 下恒返回空 —— 日期格式化缺 unixepoch/localtime 修饰', () async {
      await seedLedger();
      // 相对基准:取"现在"(不依赖固定日期,避免时区/系统时钟差异造成 flake)
      final now = DateTime.now();
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: now);

      final daily = await repo.getDailyTotalsByMonth(
          ledgerId: 1, month: DateTime(now.year, now.month, 1));
      final dates = await repo.getTransactionDatesByMonth(
          ledgerId: 1, month: DateTime(now.year, now.month, 1));
      // 同一个月的列表入口能查到这笔
      final list = await repo.getTransactionsByDate(ledgerId: 1, date: now);

      // ADVERSE FINDING: getDailyTotalsByMonth 的 SQL 是
      //   strftime('%Y-%m-%d', happened_at, 'unixepoch', 'localtime')
      // (local_transaction_repository.dart:1420),
      // getTransactionDatesByMonth 是 DATE(happened_at)(:1858)。
      // drift 存的是 UTC unix 秒;DATE() 不做 unixepoch 解释 → NULL;
      // 'localtime' 在本环境 SQLite 3.51 返回 NULL(见探测 Q1)。
      // 结果:日历页所有日期都没有圆点、每天点进去 0 笔(但点某天列表有数据)。
      expect(daily, isNotEmpty,
          reason: 'ADVERSE FINDING: getDailyTotalsByMonth 返回空 map(日期格式化为 NULL),'
              '日历月视图当月总览恒为空');
      expect(dates, isNotEmpty,
          reason: 'ADVERSE FINDING: getTransactionDatesByMonth 返回空列表'
              '(DATE(happened_at) 缺 unixepoch 解释),日历无"有交易"标记;'
              '同月 getTransactionsByDate 却有 ${list.length} 笔 → 同页口径自相矛盾');
    });

    test('E2 UTC 存储 vs 本地展示:同一天的两笔在月窗口边界一致', () async {
      await seedLedger();
      final now = DateTime.now();
      final morning = DateTime(now.year, now.month, now.day, 0, 30);
      final night = DateTime(now.year, now.month, now.day, 23, 30);
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10, happenedAt: morning);
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 20, happenedAt: night);
      final (_, exp) = await repo.totalsInRange(
          ledgerId: 1,
          start: DateTime(now.year, now.month, now.day),
          end: DateTime(now.year, now.month, now.day + 1));
      // HARDENING: drift 对 naive(local)DateTime 存本地 epoch 秒,
      // 因此 [本地日起点, 次日起点) 窗口能完整覆盖当天 00:00–23:59:59。
      expect(exp, 30.0, reason: 'HARDENING: 本地上/下午两笔都在当天窗口内');
      final byDay = await repo.totalsByDay(
          ledgerId: 1, type: 'expense',
          start: DateTime(now.year, now.month, now.day),
          end: DateTime(now.year, now.month, now.day + 1));
      expect(byDay.length, 1);
      expect(byDay.first.total, 30.0,
          reason: 'HARDENING: totalsByDay 用 TZ 偏移手工还原本地日,结果正确');
    });

    test('E3 月窗口边界:月末 23:59:59 与 +1s', () async {
      await seedLedger();
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 50,
          happenedAt: DateTime(2026, 7, 31, 23, 59, 59));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 90,
          happenedAt: DateTime(2026, 8, 1, 0, 0, 0));
      final (_, jul) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      final (_, aug) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 8, 1));
      // HARDENING: 半开区间 [start, end),月末 23:59:59 归 7 月,+1s 归 8 月。
      expect(jul, 50.0);
      expect(aug, 90.0);
    });

    test('E4 2 月窗口(28 天)与 monthStartDay=28 跨 2 月', () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, month_start_day) VALUES (1, 'L', 'CNY', 28)");
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          happenedAt: DateTime(2026, 2, 28));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 2, 27, 23, 59, 59));
      final (_, feb) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 2, 1));
      final (_, jan) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 1, 1));
      // HARDENING: 窗口 [2/28, 3/28) / [1/28, 2/28) —— 2 月 28 天场景正确处理。
      expect(feb, 100.0, reason: 'HARDENING: 2/28 归 2 月周期');
      expect(jan, 1.0, reason: 'HARDENING: 2/27 归 1 月周期');
    });

    test('E5 monthStartDay 越界值:DB 无 CHECK,统计层 clamp 到 [1,28] 但账本列留脏值',
        () async {
      // 直接写脏值(模拟同步/导入绕过 updateLedger 的 clamp)
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, month_start_day) VALUES (1, 'L', 'CNY', 31)");
      final l = await repo.getLedgerById(1);
      expect(l!.monthStartDay, 31,
          reason: 'HARDENING: ledgers.month_start_day 无 CHECK 约束(0/31/负 均可存)');

      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 7,
          happenedAt: DateTime(2026, 3, 30));
      final (_, mar) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 3, 30));
      // HARDENING: 统计层 _monthStartDayOf clamp(1,28) → 3/30 落在 [3/28, 4/28)。
      // 但 UI 显示的"起始日 = 31"与统计实际用的 28 不一致(账本设置页展示脏值)。
      expect(mar, 7.0, reason: 'HARDENING: 统计按 clamp 后 28 计算');

      // updateLedger 有 clamp,path 不一致
      await repo.updateLedger(id: 1, monthStartDay: 40);
      expect((await repo.getLedgerById(1))!.monthStartDay, 28,
          reason: 'HARDENING: 写路径 clamp 到 28,读路径 clamp,但 DB 列可被旁路写脏');

      // monthStartDay = 0 / 负 → clamp 到 1
      await db.customStatement('UPDATE ledgers SET month_start_day = 0 WHERE id = 1');
      final (_, z) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 3, 15));
      expect(z, 7.0, reason: 'HARDENING: msd=0 → clamp 1(自然月)');
    });

    test('E6 monthStartDay 跨月查询:月起始日 28 时,2 月窗口用 28 而非 29/31',
        () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, month_start_day) VALUES (1, 'L', 'CNY', 28)");
      // 2026-03-01 属于 [2/28, 3/28) 周期
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 5,
          happenedAt: DateTime(2026, 3, 1));
      final (_, feb) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 2, 1));
      final (_, mar) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 3, 1));
      // HARDENING: periodForLabel(2026,2,28) = [2/28, 3/28) → 3/1 属 2 月周期。
      expect(feb, 5.0, reason: 'HARDENING: 3/1 落在 2 月周期(28 起始)');
      expect(mar, 0.0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // F. 批量写入
  // ══════════════════════════════════════════════════════════════════════

  group('F. 批量写入', () {
    test('F1 批量 400/999/1000 条均可插入(无变量上限截断)', () async {
      await seedLedger();
      var total = 0;
      for (final n in [400, 999, 1000]) {
        final items = [
          for (var i = 0; i < n; i++)
            TransactionsCompanion.insert(
                ledgerId: 1, type: 'expense', amount: i.toDouble(),
                happenedAt: d.Value(DateTime(2026, 7, 1)))
        ];
        total += await repo.insertTransactionsBatch(items);
      }
      expect(total, 2399);
      final cnt = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      expect(cnt.data['c'], 2399, reason: '2399 行全落库,无静默截断');
    });

    test('F2 批量含重复 syncId:静默插入重复行,破坏 syncId 身份', () async {
      await seedLedger();
      await repo.insertTransactionsBatch([
        TransactionsCompanion.insert(
            ledgerId: 1, type: 'expense', amount: 1,
            happenedAt: d.Value(DateTime(2026, 7, 1)),
            syncId: const d.Value('SAME')),
        TransactionsCompanion.insert(
            ledgerId: 1, type: 'expense', amount: 2,
            happenedAt: d.Value(DateTime(2026, 7, 2)),
            syncId: const d.Value('SAME')),
      ]);
      final rows = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
          .getSingle();
      // ADVERSE FINDING: 批量路径完全不做 syncId 去重/冲突检测,直接 insertAll;
      // import(500/批)场景下重复 syncId 会安静地产生重复账目。
      // 产品源码: local_transaction_repository.dart:467-476。
      expect(rows.data['c'], 1,
          reason: 'ADVERSE FINDING: 批量插入同 syncId 两行均落库(${rows.data['c']} 行),'
              '紧接着 insertTransactionsBatchWithRelations 的 idBySyncId 映射会'
              '把两笔的标签都挂到最后一行(见 F3)');
    });

    test('F3 批量 + 关联:重复 syncId 导致两笔的标签/附件合并到最后一行', () async {
      await seedLedger();
      final tag1 = await repo.createTag(name: 'g1');
      final tag2 = await repo.createTag(name: 'g2');
      final ids = await repo.insertTransactionsBatchWithRelations(
        transactions: [
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: 1,
              happenedAt: d.Value(DateTime(2026, 7, 1)),
              syncId: const d.Value('DUP-BATCH')),
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: 2,
              happenedAt: d.Value(DateTime(2026, 7, 2)),
              syncId: const d.Value('DUP-BATCH')),
        ],
        tagIdsByIndex: {
          0: [tag1],
          1: [tag2],
        },
        attachmentsByIndex: {
          0: [BatchAttachmentData(fileName: 'f0.jpg')],
          1: [BatchAttachmentData(fileName: 'f1.jpg')],
        },
      );
      final all = await (db.select(db.transactions)
            ..orderBy([(t) => d.OrderingTerm(expression: t.id)]))
          .get();
      final tagsById = <int, List<String>>{};
      for (final t in all) {
        tagsById[t.id] =
            (await repo.getTagsForTransaction(t.id)).map((x) => x.name).toList();
      }
      final attCounts = <int, int>{};
      for (final t in all) {
        attCounts[t.id] = (await repo.getAttachmentsByTransaction(t.id)).length;
      }
      // ADVERSE FINDING: 反查映射 `idBySyncId[syncIds[i]]!` 用 syncId 做键
      // (local_transaction_repository.dart:500-508),重复 syncId 时后一行覆盖前
      // 一行 → 标签/附件全挂到同一行,另一行丢失关联。
      expect(ids, hasLength(2));
      expect(tagsById.values.every((v) => v.length == 1), isTrue,
          reason: 'ADVERSE FINDING: 重复 syncId 关联错挂 → $tagsById(期望各 1 个标签)');
      expect(attCounts.values.every((v) => v == 1), isTrue,
          reason: 'ADVERSE FINDING: 附件分布 $attCounts(期望各 1)');
    });

    test('F4 批量部分失败:整体原子回滚(drift transaction 包裹有效)', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.insertTransactionsBatch([
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: 1,
              happenedAt: d.Value(DateTime(2026, 7, 1))),
          // 非法行:type 缺失
          const TransactionsCompanion(ledgerId: d.Value(1), amount: d.Value(2.0)),
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: 3,
              happenedAt: d.Value(DateTime(2026, 7, 1))),
        ]);
      } catch (e) {
        err = e;
      }
      final rows = await db.select(db.transactions).get();
      // HARDENING: db.transaction 包裹 → 前两行也回滚,0 残留。
      expect(err, isNotNull);
      expect(rows.length, 0, reason: 'HARDENING: 批量失败整体回滚,无半提交');
    });

    test('F5 批量显式重复主键:整体回滚(不静默吞行)', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.insertTransactionsBatch([
          TransactionsCompanion.insert(
              id: const d.Value(500), ledgerId: 1, type: 'expense', amount: 1,
              happenedAt: d.Value(DateTime(2026, 7, 1))),
          TransactionsCompanion.insert(
              id: const d.Value(500), ledgerId: 1, type: 'expense', amount: 2,
              happenedAt: d.Value(DateTime(2026, 7, 2))),
        ]);
      } catch (e) {
        err = e;
      }
      final rows = await db.select(db.transactions).get();
      // HARDENING: 主键冲突抛 SqliteException 并整批回滚(0 行)。
      expect(err, isNotNull);
      expect(rows.length, 0, reason: 'HARDENING: 主键冲突整批回滚');
    });

    test('F6 500 条批量 + 标签/附件关联:分块正确(400 边界)', () async {
      await seedLedger();
      final tags = <int>[];
      for (var i = 0; i < 5; i++) {
        tags.add(await repo.createTag(name: 'BG$i'));
      }
      final txs = [
        for (var i = 0; i < 500; i++)
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: i.toDouble(),
              happenedAt: d.Value(DateTime(2026, 7, 1)),
              syncId: d.Value('BG-$i')),
      ];
      final ids = await repo.insertTransactionsBatchWithRelations(
        transactions: txs,
        tagIdsByIndex: {for (var i = 0; i < 500; i++) i: [tags[i % 5]]},
        attachmentsByIndex: {
          for (var i = 0; i < 500; i++)
            i: [BatchAttachmentData(fileName: 'f$i.jpg')],
        },
      );
      expect(ids.toSet().length, 500, reason: '500 个 id 全不同');
      final tagLinks = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      final atts = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_attachments')
          .getSingle();
      expect(tagLinks.data['c'], 500);
      expect(atts.data['c'], 500);
      // 反向批量读也走 400 分块(不溢出变量上限)
      final tagsByTx = await repo.getTagsForTransactions(ids);
      expect(tagsByTx.length, 500,
          reason: 'HARDENING: getTagsForTransactions 按 400 分块,500 条 ok');
    });

    test('F7 getTransactionsByIds / getAccountsByIds / getAttachmentsForTransactions '
        '未分块:>32766 个 id 抛 "too many SQL variables"', () async {
      await seedLedger();
      // 同仓库内分块策略不一致:getTagsForTransactions /
      // getAttachmentCountsForTransactions 走 chunkIds(400),而这几个直接 isIn。
      // 实测边界(本环境 SQLite 3.51,SQLITE_MAX_VARIABLE_NUMBER=32766):
      //   32766 个 id → 通过;32767 个 id → 抛错(见报告阈值表)。
      final many = List<int>.generate(40000, (i) => i + 1);
      Object? e1, e2, e3;
      try {
        await repo.getTransactionsByIds(many);
      } catch (e) {
        e1 = e;
      }
      try {
        await repo.getAccountsByIds(many);
      } catch (e) {
        e2 = e;
      }
      try {
        await repo.getAttachmentsForTransactions(many);
      } catch (e) {
        e3 = e;
      }
      Object? ok;
      try {
        await repo.getTagsForTransactions(many);
      } catch (e) {
        ok = e;
      }
      // ADVERSE FINDING: 同仓库内分块策略不一致 —— 有 chunk 的入口在 40000 个 id
      // 下正常,没 chunk 的直接抛 SqliteException。
      // 真实可达路径:export_page.dart:135/310 用**本次导出的全部交易 id**
      // 调 getAttachmentsForTransactions;sync_diff_service.dart:111 用账号 id
      // 全集调 getAccountsByIds;ai_bookkeeper.dart:1382 调 getTransactionsByIds。
      // 长期用户导出全部账目(>3.2 万笔)即命中。
      // 产品源码: local_transaction_repository.dart:832-836、
      //           local_account_repository.dart:692-697、
      //           local_attachment_repository.dart:222-233(均无 chunk)。
      expect(e1, isNull,
          reason: 'ADVERSE FINDING: getTransactionsByIds(40000) 抛 '
              '${e1.runtimeType}(too many SQL variables);'
              '同族 getTagsForTransactions 因有 400 分块而正常');
      expect(e2, isNull,
          reason: 'ADVERSE FINDING: getAccountsByIds 同样未分块'
              '(${e2.runtimeType}),调用方 sync_diff_service 用账号 id 全集');
      expect(e3, isNull,
          reason: 'ADVERSE FINDING: getAttachmentsForTransactions 同样未分块'
              '(${e3.runtimeType}),调用方 export_page 用导出范围的全部交易 id');
      expect(ok, isNull, reason: '对照:getTagsForTransactions 已分块,正常');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // G. 搜索 / 分页
  // ══════════════════════════════════════════════════════════════════════

  group('G. 搜索与分页', () {
    test('G1 同 happenedAt 大量行:keyset 翻页稳定且不漏不重', () async {
      await seedLedger();
      final same = DateTime(2026, 7, 10, 12);
      for (var i = 0; i < 10; i++) {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: i.toDouble(),
            happenedAt: same);
      }
      final seen = <int>[];
      var page = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 3);
      seen.addAll(page.items.map((e) => e.t.id));
      var guard = 0;
      while (page.hasOlder && guard++ < 10) {
        page = await repo.getTransactionPageWithCategory(
            ledgerId: 1, limit: 3, before: page.lastCursor);
        seen.addAll(page.items.map((e) => e.t.id));
      }
      // HARDENING: keyset (happened_at DESC, id DESC) 双键 → 同时间戳跨页不漏不重。
      expect(seen.length, 10);
      expect(seen.toSet().length, 10, reason: 'HARDENING: 无重复');

      // 两次查询顺序一致(确定性排序)
      final p1 = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 4);
      final p2 = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 4);
      expect(p1.items.map((e) => e.t.id).toList(),
          p2.items.map((e) => e.t.id).toList(),
          reason: 'HARDENING: 排序确定(id 作 tie-breaker)');
    });

    test('G2 同时间戳行的排序契约缺失:getTransactionsByLedger 等入口无 id '
        'tie-breaker,tie 顺序是实现产物', () async {
      await seedLedger();
      final same = DateTime(2026, 7, 10, 12);
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        ids.add(await repo.addTransaction(ledgerId: 1, type: 'expense',
            amount: i.toDouble(), happenedAt: same));
      }
      ids.sort();

      // (a) 分页入口有双键排序,同时间戳按 id DESC —— 契约明确。
      final page = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 10);
      expect(page.items.map((e) => e.t.id).toList(), ids.reversed.toList(),
          reason: 'HARDENING: getTransactionPageWithCategory 双键 (happened_at DESC, '
              'id DESC),同时间戳顺序确定');

      // (b) 但列表入口只按 happened_at DESC 排序:
      //     watchRecentTransactions(:29-37)、getRecentTransactions(:1291-1303)、
      //     getTransactionsByLedger(:1234-1242)、
      //     getFirst/LastTransactionByLedger(:1350-1372)、
      //     watchAccountTransactions(account_repo:674-682) 全部缺 id tie-breaker。
      final listed = await repo.getTransactionsByLedger(1);
      final listedIds = listed.map((t) => t.id).toList();
      // ADVERSE FINDING: 实测 tie 顺序是 id 升序,与分页入口的 id 降序**相反**。
      // SQLite 对 ORDER BY 相等键不保证顺序,换索引/换查询计划/换版本都可能翻转。
      // 消费方只要用 .first/.last 或"两次查询结果一致"的假设就会出错
      // (已核实产品首页走的是分页入口的游标,故当前未爆;但契约层面无保护)。
      expect(listedIds, ids.reversed.toList(),
          reason: 'ADVERSE FINDING: getTransactionsByLedger 同时间戳返回 id 升序 '
              '$listedIds,与同类分页入口的 id 降序相反 → 排序无契约、不可依赖;'
              '任何 .first/.last 或跨入口顺序比较都可能翻转');
    });

    test('G3 searchTransactions 金额子串命中已按注释放弃(退化行为)', () async {
      await seedLedger();
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 123.45,
          happenedAt: DateTime(2026, 7, 1));
      final byAmount = await repo.searchTransactions(ledgerId: 1, searchText: '123');
      final byFull = await repo.searchTransactions(ledgerId: 1, searchText: '123.45');
      // HARDENING: SQL 只匹配 note/category.name(CAST 后任意位置子串无法用 LIKE
      // 表达),Dart 兜底又反过来收窄 → 纯金额串搜索永远 0 结果。注释已明示该
      // 降级,不算缺陷,但对用户是「搜不到」的体验缺口。
      expect(byAmount.length, 0,
          reason: 'HARDENING: 金额子串搜索无匹配(注释承认的降级)');
      expect(byFull.length, 0);
      // 备注命中正常
      final id = await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 7, 2), note: 'coffee 123');
      final byNote = await repo.searchTransactions(ledgerId: 1, searchText: '123');
      expect(byNote.map((e) => e.t.id), contains(id),
          reason: 'HARDENING: 备注含关键字可搜到');
    });

    test('G4 searchTransactions limit<0 抛 RangeError(未捕获),limit=0 静默返空',
        () async {
      await seedLedger();
      for (var i = 0; i < 4; i++) {
        await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 1,
            happenedAt: DateTime(2026, 7, 1), note: 'kw');
      }
      final zero =
          await repo.searchTransactions(ledgerId: 1, searchText: 'kw', limit: 0);
      expect(zero.length, 0, reason: 'HARDENING: limit=0 → SQL LIMIT 0 → 空(静默)');

      Object? err;
      List<dynamic>? negResult;
      try {
        negResult =
            await repo.searchTransactions(ledgerId: 1, searchText: 'kw', limit: -1);
      } catch (e) {
        err = e;
      }
      // ADVERSE FINDING: searchTransactions 未校验 limit;负数时
      // `limit * 2` = -2 被 SQLite 当无上限,随后 Dart 侧
      // `hydrated.take(limit)` 对负 count 抛 RangeError(未捕获,直接冒泡到 UI)。
      // 产品源码: local_transaction_repository.dart:949(limit*2)、:971(take)。
      expect(err, isNull,
          reason: 'ADVERSE FINDING: searchTransactions(limit:-1) 抛 '
              '${err.runtimeType}: "takeCount: Invalid value ... -1";'
              '对比 getTransactionPageWithCategory 有 clamp(1,400),本入口零校验'
              '${negResult == null ? '' : '(实际返回 ${negResult.length} 行)'}');
    });
  });
}