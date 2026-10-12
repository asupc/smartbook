// 对抗性测试 — 类目 / 标签 / 账户 / 预算 / 维护孤儿域(SmartBook 客户端数据层)。
//
// 攻击面:层级循环与深度、父类目删除后悬空、标签重名/空/超长、标签关联清理、
// 账户初始余额与余额联动、隐藏账户、账户删除后悬挂引用、信用卡额度/账单日边界、
// 孤儿扫描器判定边界与幂等。
//
// 语义参照(只读):
//   lib/data/repositories/local/local_category_repository.dart
//   lib/data/repositories/local/local_tag_repository.dart
//   lib/data/repositories/local/local_account_repository.dart
//   lib/data/repositories/local/local_budget_repository.dart
//   lib/services/maintenance/orphan_scanner.dart + orphan_cleaner.dart
//   lib/data/category_node.dart
//   lib/utils/shared_ledger_picker_filter.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/category_node.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/data/repositories/exceptions.dart';
import 'package:smartbook/services/maintenance/orphan_cleaner.dart';
import 'package:smartbook/services/maintenance/orphan_record.dart';
import 'package:smartbook/services/maintenance/orphan_scanner.dart';

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
  // M. 类目层级
  // ══════════════════════════════════════════════════════════════════════

  group('M. 类目层级', () {
    test('M1 层级循环(A.parent=B, B.parent=A):两者从树里彻底消失,'
        '交易挂的类目不可达', () async {
      await seedLedger();
      final a = await repo.createCategory(name: 'CYC-A', kind: 'expense');
      final b = await repo.createCategory(name: 'CYC-B', kind: 'expense');
      // C3 修复:updateCategory 前做环检测(沿 parent 链走到根)。设置
      // A.parent=B 成功;再设 B.parent=A 会被 CategoryCycleException 拒绝,
      // 环不成立。原断言断言"两者都从树里消失",编码的是修复前缺陷。
      await repo.updateCategory(a, parentId: b);

      Object? cycleErr;
      try {
        await repo.updateCategory(b, parentId: a);
      } catch (e) {
        cycleErr = e;
      }
      expect(cycleErr, isA<CategoryCycleException>(),
          reason: 'C3 修复: B.parent=A 会形成环 → 被拒绝(${cycleErr.runtimeType})');

      final all = await repo.getAllCategories();
      final tree = CategoryHierarchy.buildHierarchy(all);
      final reachable = <int>{};
      void walk(List<CategoryNode> nodes) {
        for (final n in nodes) {
          reachable.add(n.category.id);
          walk(n.children.map((c) => CategoryNode(category: c)).toList());
        }
      }

      walk(tree);

      // C3 修复:环被拒 → 数据自洽:B(level 1)是根,A(level 2)在其 children 下,
      // 两者在树上都可达。原断言 expect(reachable, containsAll([a,b])) 在修复后
      // 依然成立,但原实现给出的 reachable 是空的(不可达)。
      expect(reachable, containsAll(<int>[b]),
          reason: 'C3 修复: 根分类 b 在树上可达(reachable=$reachable)');
      expect(reachable, containsAll(<int>[a]),
          reason: 'C3 修复: 子分类 a 挂在 b 下,同样可达');
      final tops = await repo.getTopLevelCategories('expense');
      expect(tops.map((c) => c.id), contains(b),
          reason: 'C3 修复: b 是根(level=1,parentId=null)');
      expect(tops.map((c) => c.id), isNot(contains(a)),
          reason: 'C3 修复: a 是子类(level=2)');
      final usable = await repo.getUsableCategories('expense');
      expect(usable.map((c) => c.id), contains(a),
          reason: 'C3 修复: 叶子分类 a 仍可用');
    });

    test('M2 深度 10 层:sub 创建硬编码 level=2,第 3 层以下 level 与深度脱钩',
        () async {
      await seedLedger();
      var p = await repo.createCategory(name: 'L0', kind: 'income');
      final chain = <int>[p];
      for (var i = 1; i <= 10; i++) {
        p = await repo.createSubCategory(parentId: p, name: 'L$i', kind: 'income');
        chain.add(p);
      }
      final all = await repo.getAllCategories();
      final levels = {
        for (final c in all.where((c) => chain.contains(c.id))) c.id: c.level
      };
      // HARDENING: createSubCategory 硬编码 level=2(local_category_repository
      // .dart:84),不校验父级本身是否 level=1 → 第 3 层起 level 全是 2,
      // 与"深度=2"的实际结构矛盾。数据可存,但 level 字段不再是深度的可信表示。
      expect(levels[chain[0]], 1, reason: 'HARDENING: 根 level=1');
      expect(levels[chain[2]], 2, reason: 'HARDENING: 第 3 层 level 仍被写成 2');
      expect(levels[chain[10]], 2, reason: 'HARDENING: 第 11 层 level 也是 2');

      // 树上只有根可见(子类只挂 level=1 的节点的 children)
      final tree = CategoryHierarchy.buildHierarchy(all);
      final root = tree.firstWhere((n) => n.category.id == chain[0]);
      // ADVERSE FINDING: buildHierarchy 的 children 查找用 `subCategories[cat.id]`
      // 只挂一层 → 第 2 层作为 L0 的 children 出现,但第 3..11 层全丢。
      // 用户在层级视图里只能看到两层,更深层类目"消失"(但数据在,统计仍在用)。
      expect(root.children.length, 1,
          reason: 'HARDENING: 树上只挂直接子级');
      final visible = <int>{};
      for (final n in tree) {
        visible.add(n.category.id);
        for (final c in n.children) {
          visible.add(c.id);
        }
      }
      expect(chain.where(visible.contains).length, 2,
          reason: 'ADVERSE FINDING: 11 层链在树上只有 ${chain.where(visible.contains).length} '
              '个可见(第 3 层起全部不可达);level=2 硬编码让层级语义崩坏');

      // 但 usable 会把"被当父的"排掉 → 只剩最深一个
      final usable = await repo.getUsableCategories('income');
      expect(usable.map((c) => c.id).toList(), [chain.last],
          reason: 'HARDENING: 11 层链只有最深一个被当叶子(getUsableCategories '
              '只看 parentId 是否被别人引用)');
    });

    test('M3 同名兄弟:createSubCategory 按 (name,kind) 全局查重,同名不同父也拒',
        () async {
      await seedLedger();
      final p1 = await repo.createCategory(name: 'P1', kind: 'expense');
      final p2 = await repo.createCategory(name: 'P2', kind: 'expense');
      await repo.createSubCategory(parentId: p1, name: '子', kind: 'expense');
      Object? err;
      try {
        // 另一个父下建同名子类
        await repo.createSubCategory(parentId: p2, name: '子', kind: 'expense');
      } catch (e) {
        err = e;
      }
      // ADVERSE FINDING: 查重条件是 `name == name AND kind == kind`
      // (local_category_repository.dart:70-79) —— **不含 parentId**。
      // 「餐饮/外卖」和「交通/外卖」这种跨父同名子类无法创建,而 UI 文案
      // (isCategoryNameDuplicate)也只给"分类名已存在"提示,用户无从得知是
      // 因为另一个父下已有。产品语义写的是"(name,kind) 联合唯一",属有意设计,
      // 但对抗验证显示它把层级命名空间压平了。
      expect(err, isNull,
          reason: 'ADVERSE FINDING: 跨父同名子类被拒(${err.runtimeType});'
              '查重不含 parentId → 层级命名空间被压平,「餐饮/外卖」与「交通/外卖」'
              '不能共存');
    });

    test('M4 删除父类目:子类目保留但 parentId 悬空(仅删一层)', () async {
      await seedLedger();
      final parent = await repo.createCategory(name: 'DP', kind: 'expense');
      final child = await repo.createSubCategory(
          parentId: parent, name: 'DC', kind: 'expense');
      final grandchild = await repo.createSubCategory(
          parentId: child, name: 'DGC', kind: 'expense');

      await repo.deleteCategory(parent);

      final childAfter = await repo.getCategoryById(child);
      final gcAfter = await repo.getCategoryById(grandchild);
      // C3 修复:deleteCategory 递归删除整棵子树(旧实现只删 `parent_id = id`
      // 一层,孙级残留且 parentId 悬空 → 树上不可见但交易仍计入统计)。
      // 原断言 expect(gcAfter, isNotNull) 编码的正是修复前缺陷。
      expect(childAfter, isNull, reason: 'HARDENING: 直接子类被级联删除');
      expect(gcAfter, isNull,
          reason: 'C3 修复: 孙级类目一并删除(递归整棵子树),不再残留悬挂行');

      // 树上自然也没有悬挂的孙类目
      final tree = CategoryHierarchy.buildHierarchy(await repo.getAllCategories());
      final visible = <int>{};
      for (final n in tree) {
        visible.add(n.category.id);
        for (final c in n.children) {
          visible.add(c.id);
        }
      }
      expect(visible.contains(grandchild), isFalse,
          reason: 'C3 修复: 已删类目不在树上(且后续无残留)');

      // 交易挂在孙级上时仍然算得进统计(挂 category_id),用户却看不到类目
      final stats = await repo.totalsByCategory(ledgerId: 1, type: 'expense',
          start: DateTime(2026, 1, 1), end: DateTime(2027, 1, 1));
      expect(stats, isEmpty, reason: 'HARDENING: 无交易 → 空');
    });

    test('M5 updateCategory 只改 parentId 不改 level:树结构立即自相矛盾', () async {
      await seedLedger();
      final a = await repo.createCategory(name: 'UA', kind: 'expense');
      final child = await repo.createCategory(name: 'UB', kind: 'expense');
      // 把 level=1 的分类改成某类的子类,但不传 level
      await repo.updateCategory(child, parentId: a);
      final after = await repo.getCategoryById(child);
      // ADVERSE FINDING: updateCategory(:94-112)对 parentId 与 level 是独立可选
      // 参数,不联动。parentId 设了但 level 仍为 1 → 既进 topLevel(level==1)
      // 又被挂进 a 的 children → 同一条数据在树里出现两次(或一次都不对)。
      expect(after!.level, 2,
          reason: 'ADVERSE FINDING: updateCategory(parentId: a) 后 level 仍为 '
              '${after.level};parentId 与 level 需调用方手工保持同步');
      final tree = CategoryHierarchy.buildHierarchy(await repo.getAllCategories());
      final occurrences = <int, int>{};
      void walk(List<CategoryNode> nodes, bool asChild) {
        for (final n in nodes) {
          occurrences[n.category.id] = (occurrences[n.category.id] ?? 0) + 1;
          walk(n.children.map((c) => CategoryNode(category: c)).toList(), true);
        }
      }

      walk(tree, false);
      expect(occurrences[child] ?? 0, lessThanOrEqualTo(1),
          reason: 'ADVERSE FINDING: level=1 + parentId 非空 → 树里出现 '
              '${occurrences[child]} 次(既作根又作子)');
    });

    test('M6 getUsableCategories:level=1 但 parentId 非空的行被当成叶子', () async {
      await seedLedger();
      final p = await repo.createCategory(name: 'UP', kind: 'expense');
      final weird = await repo.createCategory(
          name: 'UWEIRD', kind: 'expense', level: 1, parentId: p);
      final usable = await repo.getUsableCategories('expense');
      // HARDENING: getUsableCategories(category_node.dart:81-93)只看
      // "是否被别人当父" —— weird 没人认它当父 → 判定可用。
      // 而 getTopLevelCategories(level==1 AND parentId IS NULL)不含它,
      // getSubCategories(parentId=p AND level==2)也不含它 → 在记账选择器
      // (读 topLevel+subs)里不可见,但 AI 提示词(读 usable)里可见。
      expect(usable.map((c) => c.id), contains(weird),
          reason: 'HARDENING: level=1+parentId 非空的行被当叶子(两套可见性口径不一致)');
      final tops = await repo.getTopLevelCategories('expense');
      final subs = await repo.getSubCategories(p);
      expect(tops.map((c) => c.id), isNot(contains(weird)));
      expect(subs.map((c) => c.id), isNot(contains(weird)),
          reason: 'ADVERSE FINDING: 该分类在记账选择器两条路里都查不到,但 AI 记账能选中');
    });

    test('M7 migrateCategoryTransactions:合并同名子类时交易迁移但损失分类名', () async {
      await seedLedger();
      final from = await repo.createCategory(name: 'MGC-F', kind: 'expense');
      final to = await repo.createCategory(name: 'MGC-T', kind: 'expense');
      final fromSub = await repo.createSubCategory(
          parentId: from, name: '同级同名', kind: 'expense');
      // 第二个同名子类 repo 层拒绝(M3 的发现)→ 用原始 SQL 造出该状态,
      // 因为它在真实库中确实存在(云端 pull / 导入绕过本地查重)。
      await db.customStatement(
          "INSERT INTO categories (name, kind, parent_id, level, sync_id) "
          "VALUES ('同级同名', 'expense', $to, 2, 'RAW-DUP-SUB')");
      final toSub = (await repo.getSubCategories(to)).single;
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 10,
          categoryId: fromSub, happenedAt: DateTime(2026, 7, 1));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 20,
          categoryId: from, happenedAt: DateTime(2026, 7, 1));

      final res = await repo.migrateCategoryTransactions(
          fromCategoryId: from, toCategoryId: to);
      // HARDENING: 子类同名 → 交易改挂 toSub,源子类被删。交易没丢,
      // 但原来"from/同级同名"的归属信息丢失(只留 to/同级同名)。
      expect(res.migratedTransactions, 2,
          reason: 'HARDENING: from 的直连 1 笔 + 子类 1 笔 = 2 笔迁移');
      expect(await repo.getCategoryById(fromSub), isNull,
          reason: 'HARDENING: 同名子类被合并删除(信息丢失)');
      expect(await repo.getCategoryById(from), isNotNull,
          reason: '**注意**:migrateCategoryTransactions 不删 fromCategory 本身'
              '(只搬交易/子类),调用方需自行 deleteCategory');

      // 迁移到自身:canMigrate 会 false 但 migrateCategoryTransactions 不校验
      final self = await repo.getCategoryMigrationInfo(
          fromCategoryId: to, toCategoryId: to);
      expect(self.canMigrate, isFalse);
      final t2 = await repo.createCategory(name: 'SELF', kind: 'expense');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 5,
          categoryId: t2, happenedAt: DateTime(2026, 7, 2));
      final selfRes = await repo.migrateCategoryTransactions(
          fromCategoryId: t2, toCategoryId: t2);
      final selfCat = await repo.getCategoryById(t2);
      // ADVERSE FINDING: migrateCategoryTransactions 无 from==to 保护,
      // 自迁移时 level=1 分支会把自己的交易"迁移到自己"(无害)但子类会被
      // 移到**自己名下**(parentId=自身) → 自环。配合 M1 的环问题 → 不可达。
      expect(selfRes.migratedTransactions, 1);
      expect(selfRes.migratedSubCategories, 0);
      expect(selfCat, isNotNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // N. 标签
  // ══════════════════════════════════════════════════════════════════════

  group('N. 标签', () {
    test('N1 标签名空串 / 纯空格 / 超长:无校验全部可落库', () async {
      await seedLedger();
      final empty = await repo.createTag(name: '');
      final spaces = await repo.createTag(name: '   ');
      final huge = await repo.createTag(name: 'x' * 100000);
      final rows = await repo.getAllTags();
      // ADVERSE FINDING: createTag 只查重名(local_tag_repository.dart:32-40),
      // 对空串/空白/长度零校验,也无 trim。空名标签在 UI 上是"隐形的可点区域",
      // 且 getRecentlyUsedTags / watchTagsWithStats 都会把它列出来。
      expect(rows.where((t) => t.id == empty).first.name, '',
          reason: 'ADVERSE FINDING: 空串标签名可落库(UI 无法展示/无意义)');
      expect(rows.where((t) => t.id == spaces).first.name, '   ',
          reason: 'ADVERSE FINDING: 纯空格标签名可落库(未 trim)');
      expect(rows.where((t) => t.id == huge).first.name.length, 100000,
          reason: 'ADVERSE FINDING: 10 万字符标签名可落库(无长度上限)');
    });

    test('N2 标签重名:createTag 抛 DuplicateNameException,upsertTag 复用', () async {
      await seedLedger();
      final id = await repo.createTag(name: '重名');
      Object? err;
      try {
        await repo.createTag(name: '重名');
      } catch (e) {
        err = e;
      }
      expect(err, isA<DuplicateNameException>(),
          reason: 'HARDENING: createTag 严格查重');
      final u = await repo.upsertTag(name: '重名');
      expect(u, id, reason: 'HARDENING: upsertTag 复用已有 id');
      // C3 修复:updateTag 改名与新建同规则(对称查重)。
      final other = await repo.createTag(name: '另一个');
      Object? renameErr;
      try {
        await repo.updateTag(other, name: '重名');
      } catch (e) {
        renameErr = e;
      }
      final all = await repo.getAllTags();
      expect(renameErr, isA<DuplicateNameException>(),
          reason: 'C3 修复: updateTag 改成重名被拒(${renameErr.runtimeType}),'
              '与 createTag 校验对称');
      expect(all.where((t) => t.name == '重名').length, 1,
          reason: 'C3 修复: 无法再制造同名标签,getTagByName 保持可靠');
    });

    test('N3 删除标签清理交易关联:关联行删干净,但共享 override 表残留', () async {
      await seedLedger();
      final tag = await repo.createTag(name: 'DEL-T');
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, happenedAt: DateTime(2026, 7, 1), syncId: 'TT-1');
      await repo.updateTransactionTags(transactionId: txId, tagIds: [tag]);
      // 另加一条共享 override(同一交易 + 同一标签概念)
      await db.into(db.sharedLedgerTags).insert(SharedLedgerTagsCompanion.insert(
          ledgerSyncId: 'LS2',
          syncId: 'ST-DEL',
          name: 'shared-del',
          updatedAt: DateTime(2026, 7, 1)));
      await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
              transactionSyncId: 'TT-1',
              tagSyncId: 'ST-DEL',
              createdAt: DateTime(2026, 7, 1)));

      await repo.deleteTag(tag);

      final links = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      final overrides = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tag_overrides')
          .getSingle();
      expect(links.data['c'], 0, reason: 'HARDENING: transaction_tags 清理干净');
      // HARDENING: override 表按 (txSyncId, tagSyncId) 存,deleteTag 只清
      // transaction_tags(local_tag_repository.dart:87-95)→ override 行留着。
      // 这里"标签已删"的是本地标签,override 指向 Owner 标签,语义上不该清,
      // 所以不算缺陷 —— 但要让读者知道 override 不随本地删标签消失。
      expect(overrides.data['c'], 1,
          reason: 'HARDENING: override 行不随本地标签删除清理(语义正确:它指 Owner 标签)');
      final tagsAfter = await repo.getTagsForTransaction(txId);
      expect(tagsAfter.map((t) => t.name).toList(), ['shared-del'],
          reason: 'HARDENING: 本地关联清理干净(transaction_tags 无残留),'
              '仅剩 override 的共享标签(它指 Owner 标签,不该随本地删标签消失)');
    });

    test('N4 批量挂标签含重复 id:关联表无 UNIQUE → 双重计数', () async {
      await seedLedger();
      final tag = await repo.createTag(name: 'DUP-T');
      final id = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 100, happenedAt: DateTime(2026, 7, 1));
      // addTagToTransaction 有 select 防重(单条),所以这条路径安全
      await repo.addTagToTransaction(transactionId: id, tagId: tag);
      await repo.addTagToTransaction(transactionId: id, tagId: tag);
      await repo.addTagToTransaction(transactionId: id, tagId: tag);
      final one = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      expect(one.data['c'], 1,
          reason: 'HARDENING: addTagToTransaction 幂等(先 select 再 insert)');

      // 但 updateTransactionTags → addTagsToTransaction 内部也走 addTagToTransaction
      await repo.updateTransactionTags(transactionId: id, tagIds: [tag, tag, tag]);
      final two = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      expect(two.data['c'], 1,
          reason: 'HARDENING: updateTransactionTags 也幂等(逐条走 addTagToTransaction)');

      // 批量 relations 路径**不**查重(注释明说 "调用方需保证已去重")
      final bid = await repo.insertTransactionsBatchWithRelations(
          transactions: [
            TransactionsCompanion.insert(
                ledgerId: 1, type: 'expense', amount: 50,
                happenedAt: d.Value(DateTime(2026, 7, 2)))
          ],
          tagIdsByIndex: {
            0: [tag, tag],
          });
      final linkRows = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags WHERE transaction_id = ?',
              variables: [d.Variable.withInt(bid.first)])
          .getSingle();
      expect(linkRows.data['c'], 1,
          reason: 'ADVERSE FINDING: insertTransactionsBatchWithRelations 对重复 '
              'tagId 不去重(实际 ${linkRows.data['c']} 行),'
              'getTagStats 会把同一笔算两次金额');
    });

    test('N5 重复 tagId 导致的统计双计(getTagStats 按关联行 join)', () async {
      await seedLedger();
      final tag = await repo.createTag(name: 'DD-T');
      final ids = await repo.insertTransactionsBatchWithRelations(
          transactions: [
            TransactionsCompanion.insert(
                ledgerId: 1, type: 'expense', amount: 77,
                happenedAt: d.Value(DateTime(2026, 7, 2)))
          ],
          tagIdsByIndex: {
            0: [tag, tag],
          });
      expect(ids, hasLength(1));
      final stats = await repo.getTagStats(tag);
      final counts = await repo.getAllTagTransactionCounts();
      // ADVERSE FINDING: transaction_tags 无 UNIQUE(transaction_id, tag_id)
      // 约束(db.dart:272-276 只有 autoIncrement id)→ 重复关联行让
      // getTagStats 的 INNER JOIN 把同一笔交易匹配两次 → 金额翻倍。
      expect(stats.expense, 77.0,
          reason: 'ADVERSE FINDING: 重复标签关联使 getTagStats.expense = '
              '${stats.expense}(期望 77);count=${stats.count} '
              '(transaction_tags 缺 UNIQUE 约束, JOIN 放大)');
      expect(stats.count, 1,
          reason: 'ADVERSE FINDING: count 也被放大为 ${stats.count};'
              'getAllTagTransactionCounts 同样受影响(${counts[tag]})');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // O. 账户
  // ══════════════════════════════════════════════════════════════════════

  group('O. 账户', () {
    test('O1 initialBalance 与余额联动:直接改 initialBalance 立即平移余额',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'IB', initialBalance: 100);
      await repo.addTransaction(ledgerId: 1, type: 'income', amount: 50,
          accountId: acc, happenedAt: DateTime(2026, 7, 1));
      expect(await repo.getAccountBalance(acc), 150.0);
      await repo.updateAccount(acc, initialBalance: 200);
      expect(await repo.getAccountBalance(acc), 250.0,
          reason: 'HARDENING: 余额 = initialBalance + Σ交易(线性联动)');
      // updateAccountValuation 也写 initialBalance
      await repo.updateAccountValuation(acc, 1000);
      expect(await repo.getAccountBalance(acc), 1050.0,
          reason: 'HARDENING: updateAccountValuation 语义 = 重设 initialBalance');
    });

    test('O2 余额调整记录(AccountAdjustments)与 initialBalance 独立叠加',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'ADJ', initialBalance: 1000);
      await repo.addAccountAdjustment(
          ledgerId: 1, accountId: acc, amount: -300,
          balanceBefore: 1000, balanceAfter: 700);
      expect(await repo.getAccountBalance(acc), 700.0,
          reason: 'HARDENING: 调整记录带符号计入余额');
      // 调整记录不进收支统计
      final (inc, exp) = await repo.monthlyTotals(
          ledgerId: 1, month: DateTime(2026, 1, 1));
      expect(inc + exp, 0.0,
          reason: 'HARDENING: 调整记录不污染收支(与 v42 设计一致)');
      // 但账本余额(getLedgerStats)也不含调整 —— 与账户余额口径不同
      final ls = await repo.getLedgerStats(ledgerId: 1);
      expect(ls.balance, 0.0,
          reason: 'HARDENING: getLedgerStats 只看交易收支(不含账户 initialBalance '
              '也不含调整)');
      final bd = await repo.getNetWorthBreakdown();
      expect(bd.netWorth, 700.0,
          reason: 'HARDENING: 净值口径含 initialBalance + 调整');
    });

    test('O3 隐藏账户参与转账:余额正确,但选择器看不到(转账可继续用旧引用)',
        () async {
      await seedLedger();
      final a = await repo.createAccount(
          ledgerId: 1, name: 'HA', initialBalance: 1000);
      final b = await repo.createAccount(ledgerId: 1, name: 'HB');
      await repo.setAccountHidden(b, true);
      // 业务层允许对隐藏账户转账(repo 不校验隐藏)
      await repo.addTransaction(ledgerId: 1, type: 'transfer', amount: 200,
          accountId: a, toAccountId: b, happenedAt: DateTime(2026, 7, 5));
      final ba = await repo.getAccountBalance(a);
      final bb = await repo.getAccountBalance(b);
      // HARDENING: 隐藏只影响 picker(local/utils/shared_ledger_picker_filter
      // .dart:131-133 的 filterAccountsForLedger),不影响余额/净值。
      expect(ba, 800.0);
      expect(bb, 200.0, reason: 'HARDENING: 隐藏账户仍正常参与资金流');
      final net = await repo.getNetWorthBreakdown();
      expect(net.netWorth, 1000.0,
          reason: 'HARDENING: 隐藏账户计入净值(.docs/account-archive 契约)');
      // 通过 picker filter 确认隐藏生效
      final all = await repo.getAllAccounts();
      final filtered = all.where((x) => !x.hidden).toList();
      expect(filtered.map((x) => x.id), isNot(contains(b)),
          reason: 'HARDENING: picker 过滤隐藏账户');
    });

    test('O4 账户删除:交易的 accountId 悬挂,余额归 0 但净值/统计仍受影响',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'OA', initialBalance: 1000);
      final other = await repo.createAccount(ledgerId: 1, name: 'OB');
      final txId = await repo.addTransaction(ledgerId: 1, type: 'transfer',
          amount: 300, accountId: other, toAccountId: acc,
          happenedAt: DateTime(2026, 7, 5));

      await repo.deleteAccount(acc);

      final tx = await repo.getTransactionById(txId);
      // C3 修复:deleteAccount 级联清交易的 account_id / to_account_id 引用
      // (旧实现裸 DELETE 账户行,转账另一腿悬挂 → 只有用户主动跑孤儿扫描器
      // 才会置 null;净值凭空变化)。
      expect(tx!.toAccountId, isNull,
          reason: 'C3 修复: 删除账户后交易的悬挂引用(to 侧)被级联清空');
      expect(tx.accountId, other,
          reason: 'C3 修复: 存活账户(from 侧 OB)的引用不受影响');
      expect(await repo.getAccountBalance(acc), 0.0,
          reason: 'HARDENING: 已删账户余额读 0(account==null 早退)');
      // 净值:删除账户会连带销毁它的资产(O4 记录的既有语义 —— 删除账户
      // 即销毁资产,无提示)。C3 只保证引用与调整记录不悬挂,不改变该资产语义。
      final bd = await repo.getNetWorthBreakdown();
      expect(bd.netWorth, -300.0,
          reason: 'CR3/HARDENING: OB 余额 = 0 - 300 = -300(转出腿保留),'
              '账户 OA 的 1000+300 随删除消失 → 净值 -300;'
              '"删除账户即销毁资产"语义未变(仅悬挂引用被清)');
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      expect(report.dbOrphans.any((o) => o.type == OrphanType.txMissingAccount),
          isFalse,
          reason: 'C3 修复: 删除时已清引用 → 扫描器不再报 txMissingAccount');
    });

    test('O5 账户删除后余额调整记录悬挂(account_adjustments 不级联)',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'O5A', initialBalance: 500);
      await repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: 200);
      expect(await repo.getAccountBalance(acc), 700.0);

      await repo.deleteAccount(acc);

      final adj = await db
          .customSelect('SELECT COUNT(*) c FROM account_adjustments WHERE account_id = ?',
              variables: [d.Variable.withInt(acc)])
          .getSingle();
      // ADVERSE FINDING: account_adjustments 行残留(deleteAccount 不级联),
      // 且孤儿扫描器**没有**这个检查项(scanAll 的 10 个 DB 检查里没有
      // account_adjustment 类型)→ 永久无法发现/清理。
      expect(adj.data['c'], 0,
          reason: 'ADVERSE FINDING: 删除账户后 account_adjustments 残留 '
              '${adj.data['c']} 行;OrphanScanner/OrphanCleaner 均无对应检查项 → '
              '永久孤儿(既占空间也在重建账户时可能被误配)');
    });

    test('O6 信用卡:额度 0/负数、账单日 32/负数全部原样落库', () async {
      await seedLedger();
      final cc = await repo.createAccount(
          ledgerId: 1, name: 'CC', type: 'credit_card',
          creditLimit: 0, billingDay: 32, paymentDueDay: -1);
      final acc = await repo.getAccount(cc);
      // ADVERSE FINDING: createAccount/updateAccount 对信用卡元数据零校验
      // (schema 注释说 billingDay 1-28,但 DB 无 CHECK;
      //  UI 有 validator,repo 层没有 → import/同步/脚本写入可绕过)。
      expect(acc!.billingDay, 32,
          reason: 'ADVERSE FINDING: billingDay=32 可落库(UI 展示"每月32日出账")');
      expect(acc.paymentDueDay, -1,
          reason: 'ADVERSE FINDING: paymentDueDay=-1 可落库');
      expect(acc.creditLimit, 0.0);

      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 500,
          accountId: cc, happenedAt: DateTime(2026, 7, 5));
      final used = await repo.getCreditCardUsedAmount(cc);
      final bal = await repo.getAccountBalance(cc);
      expect(used, 500.0, reason: 'HARDENING: 已用额度 = -balance');
      expect(bal, -500.0);
      // 可用额度 = creditLimit - used 会是负(UI 需处理)
      expect(acc.creditLimit! - used, -500.0,
          reason: 'HARDENING: 额度 0 时"可用额度"为负(UI 必须自处理,repo 不管)');
    });

    test('O7 账户重名:createAccount 全局查重(跨账本),upsertAccount 复用',
        () async {
      await seedLedger(1);
      await seedLedger(2);
      final a = await repo.createAccount(ledgerId: 1, name: '同名');
      Object? err;
      try {
        await repo.createAccount(ledgerId: 2, name: '同名');
      } catch (e) {
        err = e;
      }
      expect(err, isA<DuplicateNameException>(),
          reason: 'HARDENING: accounts.name 全局唯一(注释明示"name 全局唯一")');
      final u = await repo.upsertAccount(name: '同名', ledgerId: 2);
      expect(u, a, reason: 'HARDENING: upsertAccount 复用跨账本的同名账户');
      // C3 修复:updateAccount 改名与 createAccount 同规则(对称查重)。
      final b = await repo.createAccount(ledgerId: 2, name: '另一个B');
      Object? renameErr;
      try {
        await repo.updateAccount(b, name: '同名');
      } catch (e) {
        renameErr = e;
      }
      final all = await repo.getAllAccounts();
      expect(renameErr, isA<DuplicateNameException>(),
          reason: 'C3 修复: updateAccount 改成重名被拒(${renameErr.runtimeType}),'
              '校验不再不对称');
      expect(all.where((x) => x.name == '同名').length, 1,
          reason: 'C3 修复: 无法再制造同名账户,转账选择器保持可区分');
    });

    test('O8 账户删除后 clearLedgerTransactions 不清调整记录:余额残留',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'O8A', initialBalance: 100);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 20,
          accountId: acc, happenedAt: DateTime(2026, 7, 5));
      await repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: 30);
      expect(await repo.getAccountBalance(acc), 110.0);

      final cleared = await repo.clearLedgerTransactions(1);

      final balAfter = await repo.getAccountBalance(acc);
      // C3 修复:clearLedgerTransactions 同时清 account_adjustments ——
      // 用户"清空账本交易"后余额回到 initialBalance(100)。
      // 原断言 expect(balAfter, 130.0) 编码的正是修复前缺陷(调整残留)。
      expect(cleared, 1);
      expect(balAfter, 100.0,
          reason: 'C3 修复: 清空交易+调整记录后余额 = initialBalance(100),'
              '不再带调整残留');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // P. 孤儿扫描 / 清理
  // ══════════════════════════════════════════════════════════════════════

  group('P. 孤儿扫描与清理', () {
    test('P1 扫描 → 清理 → 再扫描:幂等(A5/A6 只清引用不删交易)', () async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'P1A');
      final cat = await repo.createCategory(name: 'P1C', kind: 'expense');
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 5, accountId: acc, categoryId: cat,
          happenedAt: DateTime(2026, 7, 1));
      await repo.deleteAccount(acc);
      await repo.deleteCategory(cat);

      final scanner = OrphanScanner(db: db);
      final cleaner = OrphanCleaner(db: db);
      final r1 = await scanner.scanAll();
      // C3 修复:deleteAccount / deleteCategory 现在**在删除时**就清引用
      // (accountId / categoryId 置 null),不再依赖用户主动跑扫描器。
      // 原断言 expect(r1.dbOrphans.length, 2) 编码的是修复前缺陷(删除留悬挂)。
      expect(r1.dbOrphans, isEmpty,
          reason: 'C3 修复: 删除账户/分类时已级联清引用 → 无孤儿可扫');

      final r2 = await scanner.scanAll();
      expect(r2.dbOrphans, isEmpty, reason: 'HARDENING: 无残留');

      final tx = await repo.getTransactionById(txId);
      expect(tx, isNotNull, reason: 'HARDENING: 交易本体保留');
      expect(tx!.amount, 5.0, reason: 'HARDENING: 金额等用户数据不动');
      expect(tx.accountId, isNull);
      expect(tx.categoryId, isNull);
      // cleaner 仍可处理空集合(幂等)
      final res = await cleaner.clean(r1.dbOrphans);
      expect(res.successCount, 0);
      expect(res.failures, isEmpty);
    });

    test('P2 已推送(pushedAt 非空)的 local_change 缺实体不算孤儿', () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action, pushed_at) "
          "VALUES ('transaction', 1, 'GONE-PUSHED', 1, 'create', 1700000000)");
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      // HARDENING: scanLocalChangeMissingEntity 带 pushedAt IS NULL
      // (orphan_scanner.dart:496)→ 已推送的不报(它已经完成使命,留着只是历史)。
      expect(report.syncOrphans.where((o) => o.syncId == 'GONE-PUSHED'), isEmpty,
          reason: 'HARDENING: 已推送 change 不算孤儿(设计如此)');
    });

    test('P3 未推送 + action=delete 不算孤儿,但 action=create 缺实体算', () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action) "
          "VALUES ('transaction', 1, 'GONE-DEL', 1, 'delete'),"
          "       ('transaction', 2, 'GONE-CRE', 1, 'create')");
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      final ids = report.syncOrphans.map((o) => o.syncId).toList();
      expect(ids, contains('GONE-CRE'), reason: 'HARDENING: create 缺实体 = 孤儿');
      expect(ids, isNot(contains('GONE-DEL')),
          reason: 'HARDENING: delete 变更不算孤儿(语义就是实体该没了)');
    });

    test('P4 孤儿扫描器不检查的悬挂:account_adjustments / budgets 的类型'
        '「分类预算指向已删分类」只在一处检查', () async {
      await seedLedger();
      final scanner0 = OrphanScanner(db: db);
      // C3 修复:删除时级联 → 先手工造出**历史残留**形态(旧版本留下的
      // 悬挂行),再验证扫描器能覆盖这两类。
      final cat = await repo.createCategory(name: 'P4C', kind: 'expense');
      final bid = await repo.createBudget(
          ledgerId: 1, type: 'category', categoryId: cat, amount: 100);
      await db.customStatement('DELETE FROM categories WHERE id = $cat');
      final acc = await repo.createAccount(ledgerId: 1, name: 'P4A');
      final adjId = await repo.addAccountAdjustment(
          ledgerId: 1, accountId: acc, amount: 10);
      await db.customStatement('DELETE FROM accounts WHERE id = $acc');

      final report = await scanner0.scanAll();
      final types = report.dbOrphans.map((o) => o.type).toList();
      expect(types, contains(OrphanType.budgetMissingCategory),
          reason: 'HARDENING: budget→category 悬挂有检查');
      // C3 修复:新增 A12 检查项覆盖 account_adjustments —— 此前的永久孤儿
      // (既占空间,重建账户时可能被误配)现在能被检出并清理。
      expect(types, contains(OrphanType.adjustmentMissingAccount),
          reason: 'C3 修复: 悬挂的 balance adjustment 被扫描器检出'
              '(新增 OrphanType.adjustmentMissingAccount)');
      // 清理后不再残留
      final cleaner = OrphanCleaner(db: db);
      final res = await cleaner.clean(report.dbOrphans);
      expect(res.failures, isEmpty);
      final adjStill = await db
          .customSelect('SELECT COUNT(*) c FROM account_adjustments WHERE id = ?',
              variables: [d.Variable.withInt(adjId)])
          .getSingle();
      expect(adjStill.data['c'], 0,
          reason: 'C3 修复: 清理生效,调整记录不再永久残留');
    });

    test('P5 清理包含未知类型/缺 localId:单条失败不阻断其余', () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'P5C', kind: 'expense');
      await repo.deleteCategory(cat);
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, categoryId: cat, happenedAt: DateTime(2026, 7, 1));
      expect(txId, greaterThan(0));
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      final bad = OrphanRecord(
          type: OrphanType.fileOrphanAttachment,
          title: 'no-path',
          subtitle: 'filePath 缺失');
      final cleaner = OrphanCleaner(db: db);
      final res = await cleaner.clean([...report.dbOrphans, bad]);
      // HARDENING: 文件类失败进 failures,DB 类照常成功。
      expect(res.successCount, greaterThanOrEqualTo(1));
      expect(res.failures, hasLength(1));
      expect(res.failures.first.error, contains('filePath'));
    });

    test('P6 共享二级分类失父(SharedLedgerCategories 用 syncId 链)被正确检出',
        () async {
      await seedLedger();
      await db.into(db.sharedLedgerCategories).insert(
          SharedLedgerCategoriesCompanion.insert(
              ledgerSyncId: 'SLC',
              syncId: 'CHILD-1',
              name: '孤儿子类',
              kind: 'expense',
              level: const d.Value(2),
              parentSyncId: const d.Value('MISSING-PARENT'),
              updatedAt: DateTime(2026, 7, 1)));
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      expect(
          report.dbOrphans
              .where((o) => o.type == OrphanType.sharedCategoryMissingParent)
              .map((o) => o.syncId),
          contains('CHILD-1'));
      // 清理:删该 SharedLedgerCategories 行
      final cleaner = OrphanCleaner(db: db);
      final res = await cleaner.clean(report.dbOrphans);
      expect(res.failures, isEmpty);
      final left = await db
          .customSelect(
              "SELECT COUNT(*) c FROM shared_ledger_categories WHERE sync_id='CHILD-1'")
          .getSingle();
      expect(left.data['c'], 0, reason: 'HARDENING: A9 清理生效');
      final again = await scanner.scanAll();
      expect(again.dbOrphans, isEmpty, reason: 'HARDENING: 幂等');
    });

    test('P7 txTagOverrideMissingTx:交易已删但 override 残留', () async {
      await seedLedger();
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, happenedAt: DateTime(2026, 7, 1), syncId: 'OV-TX');
      await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
              transactionSyncId: 'OV-TX',
              tagSyncId: 'OV-TAG',
              createdAt: DateTime(2026, 7, 1)));
      // 直接删主表行(绕过 repo 的回收站,模拟同步/异常路径)
      await db.customStatement("DELETE FROM transactions WHERE id = $txId");
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      final hits = report.dbOrphans
          .where((o) => o.type == OrphanType.txTagOverrideMissingTx)
          .toList();
      expect(hits, hasLength(1), reason: 'HARDENING: A10 检出');
      expect(hits.single.syncId, 'OV-TX');
      expect(hits.single.extra?['tagSyncId'], 'OV-TAG',
          reason: 'HARDENING: extra 带 tagSyncId 供清理用');
      final cleaner = OrphanCleaner(db: db);
      final res = await cleaner.clean(report.dbOrphans);
      expect(res.failures, isEmpty);
      final left = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tag_overrides')
          .getSingle();
      expect(left.data['c'], 0);
    });

    test('P8 孤儿扫描器不检查「交易 sync_id 重复」/「悬挂 ledgerId」', () async {
      await seedLedger();
      // 交易挂在已删账本上
      await db.customStatement(
          "INSERT INTO transactions (ledger_id, type, amount, happened_at, sync_id) "
          "VALUES (999, 'expense', 10.0, 1783008000, 'ORPH-LEDGER')");
      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      final types = report.dbOrphans.map((o) => o.type).toSet();
      // C3 修复:scanAll 新增「交易悬挂 ledger_id」检查项,
      // 交易挂在已不存在的账本上现在能被发现并清理。原断言 expect(types, isEmpty)
      // 编码的是修复前缺陷(无 tx→ledger 检查)。
      expect(types, contains(OrphanType.txMissingLedger),
          reason: 'C3 修复: 交易挂着不存在的 ledger_id=999 被检出'
              '(新增 OrphanType.txMissingLedger)');
      final hits = report.dbOrphans
          .where((o) => o.type == OrphanType.txMissingLedger)
          .toList();
      expect(hits.single.syncId, 'ORPH-LEDGER');
      final cleaner = OrphanCleaner(db: db);
      final res = await cleaner.clean(report.dbOrphans);
      expect(res.failures, isEmpty);
      final left = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='ORPH-LEDGER'")
          .getSingle();
      expect(left.data['c'], 0,
          reason: 'C3 修复: 悬挂账本的交易被清理,不再永久驻留');
      expect(types, isNot(contains(OrphanType.budgetMissingLedger)),
          reason: 'HARDENING: 该构造下无 budget 悬挂');
    });

    test('P9 删除账本:无 changeTracker 时 budgets 残留(清理只在挂 tracker '
        '的分支里)', () async {
      await seedLedger();
      final bid = await repo.createBudget(ledgerId: 1, type: 'total', amount: 100);
      expect(await repo.getAllBudgets(1), hasLength(1));

      // 未挂 changeTracker 的 repo(导入/迁移/维护脚本等静默路径会这样用)
      await repo.deleteLedger(1);

      final left = await db
          .customSelect('SELECT COUNT(*) c FROM budgets WHERE id = ?',
              variables: [d.Variable.withInt(bid)])
          .getSingle();
      // C3 修复:无 changeTracker 的早退分支同样清 budgets/adjustments ——
      // 不再有悬挂孤儿。原断言 expect(left.data['c'], 0) 在修复后成立,
      // 但修复前该分支直接 return,残留 1 条预算。
      expect(left.data['c'], 0,
          reason: 'C3 修复: 无 changeTracker 时 deleteLedger 也清掉预算,无残留');

      final scanner = OrphanScanner(db: db);
      final report = await scanner.scanAll();
      expect(report.dbOrphans.any((o) => o.type == OrphanType.budgetMissingLedger),
          isFalse,
          reason: 'C3 修复: 已无 budget→ledger 悬挂(删除时清理生效)');
    });
  });
}
