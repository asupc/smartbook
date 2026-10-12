// 杂项域补测(批次 X2):存储损坏 / 存储容量收敛 / 种子幂等 / 匹配器未接线。
//
// 覆盖 FINDINGS-misc-services.md §三 标注「未产出」的子域中的:
//   - 存储损坏(store 的 JSON 损坏/容量/迁移形态)
//   - 匹配器(种子/容量/未接线模块)
//   - 探测发现 3(seedDatabase 非幂等)、4(store 容量不收敛)、5(AnomalyDetector 未接线)
//
// 与既有文件的边界(不重复):
//   - `test/adversarial/billing_stores_adversarial.dart` 已覆盖 4 store 的损坏 JSON、
//     并发丢更新、单点裁剪;本文件只补**探测阶段实测但未编码**的容量不收敛与
//     seed 幂等,以及模块级事实锁定(接线状态)。
//   - `test/services/data/seed_categories_unique_test.dart` 只覆盖**单次** seed
//     的 (name,kind) 无重复;本文件覆盖**二次** seed 的幂等。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/services/billing/anomaly_detector.dart';
import 'package:smartbook/services/billing/channel_account_store.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';
import 'package:smartbook/services/data/seed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // ────────────────────────────────────────────────────────────────
  // 探测发现 3:seedDatabase 非幂等(确证缺陷,本批已修)
  // ────────────────────────────────────────────────────────────────
  group('seedDatabase 幂等性', () {
    Future<(BeeDatabase, AppLocalizations)> open() async {
      SharedPreferences.setMockInitialValues({});
      final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      return (db, l10n);
    }

    test('二次调用 seedDatabase(一级分类)不产生任何重复行', () async {
      // 修复前(探测实测):二次调用 → 分类 59 → 119 条(含重复)、账本 2 条。
      // 可达路径:欢迎页重入 / ensureSeed 被调两次。
      final (db, l10n) = await open();
      try {
        await SeedService.seedDatabase(db, l10n);
        final ledgers1 = await db.select(db.ledgers).get();
        final cats1 = await db.select(db.categories).get();

        await SeedService.seedDatabase(db, l10n);
        final ledgers2 = await db.select(db.ledgers).get();
        final cats2 = await db.select(db.categories).get();

        expect(ledgers2.length, ledgers1.length,
            reason: 'ADVERSE FINDING(已修):二次 seed 不该再建一个默认账本');
        expect(cats2.length, cats1.length,
            reason: 'ADVERSE FINDING(已修):二次 seed 不该重复插入分类');
        // 分类 (name,kind) 仍无重复 —— 修复必须真去重而不是只改计数。
        final seen = <String>{};
        final dups = <String>[];
        for (final c in cats2) {
          if (!seen.add('${c.name}|${c.kind}')) dups.add('${c.name}|${c.kind}');
        }
        expect(dups, isEmpty, reason: '二次 seed 后不得出现 (name,kind) 重复: $dups');
      } finally {
        await db.close();
      }
    });

    test('二次调用 seedDatabase(二级分类)同样幂等,且 syncId 不产生第二套', () async {
      final (db, l10n) = await open();
      try {
        await SeedService.seedDatabase(db, l10n,
            useHierarchicalCategories: true);
        final first = await db.select(db.categories).get();
        final firstSyncIds = first.map((c) => c.syncId).toList();

        await SeedService.seedDatabase(db, l10n,
            useHierarchicalCategories: true);
        final second = await db.select(db.categories).get();

        expect(second.length, first.length);
        final ids = second.map((c) => c.syncId).toList();
        expect(ids.toSet().length, ids.length,
            reason: '确定性 syncId 在二次 seed 后仍应唯一(不产生第二套)');
        expect(ids.toSet(), firstSyncIds.toSet());
      } finally {
        await db.close();
      }
    });

    test('skipCategories 二次调用也不重复;转账虚拟分类唯一', () async {
      final (db, l10n) = await open();
      try {
        await SeedService.seedDatabase(db, l10n,
            skipCategories: true, createDefaultLedger: false);
        await SeedService.seedDatabase(db, l10n,
            skipCategories: true, createDefaultLedger: false);
        final transfers = await (db.select(db.categories)
              ..where((t) => t.kind.equals('transfer')))
            .get();
        expect(transfers, hasLength(1), reason: 'transfer 虚拟分类只能有一条');
        final ledgers = await db.select(db.ledgers).get();
        expect(ledgers, isEmpty, reason: 'createDefaultLedger=false 不建账本');
      } finally {
        await db.close();
      }
    });
  });

  // ────────────────────────────────────────────────────────────────
  // 探测发现 4:store 容量不收敛(确证;save() 无上限,本文件只做事实锁定)
  // ────────────────────────────────────────────────────────────────
  group('ChannelAccountStore 容量不收敛', () {
    test('save() 绕过上限:超 200 条整表可持久化(ADVERSE 事实锁定)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ChannelAccountStore();
      final over = List.generate(
        ChannelAccountStore.maxRules + 20,
        (i) => ChannelAccountRule(channelName: 'ch$i', accountId: i + 1),
      );
      await store.save(over);

      final loaded = await store.load();
      expect(loaded.length, greaterThan(ChannelAccountStore.maxRules),
          reason: 'ADVERSE FINDING(未修,仅补测):save() 是公共入口且无容量守卫,'
              '只有 upsert 的单点裁剪 —— 一次 save 超限列表即可长期滞留;'
              'load() 每次全量反序列化,规则匹配线性扫描');
      // 事实锁定:超限状态不会被后续 upsert 一次性收敛(只淘汰 1 条/次)。
      final n = await store
          .upsert(ChannelAccountRule(channelName: 'new', accountId: 999));
      expect(n, greaterThan(ChannelAccountStore.maxRules),
          reason: '一次 upsert 只淘汰最旧 1 条,超限状态不收敛');
      // 清理,避免影响同进程后续测试。
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('channel_account_rules_v1');
    });
  });

  PendingCandidate candidate(String id) => PendingCandidate(
        id: id,
        bill: BillInfo(note: 'n-$id', amount: 1, ledgerId: 1),
        capturedAt: DateTime.now(),
      );

  group('PendingCandidateStore 容量', () {
    test('add 超 100 条时淘汰最旧并置「已归档」提示', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PendingCandidateStore();
      for (var i = 0; i < PendingCandidateStore.maxCandidates + 5; i++) {
        await store.add(candidate('c$i'));
      }
      final list = await store.load();
      expect(list.length, PendingCandidateStore.maxCandidates);
      expect(list.first.id, 'c5', reason: '最旧 5 条被淘汰');
      expect(await store.hasArchivedHint(), isTrue,
          reason: '触 cap 必须置位提示(P1-3),不能静默归档');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_candidates_v1');
      await store.clearArchivedHint();
    });

    test('save() 同样无上限守卫(ADVERSE 事实锁定)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PendingCandidateStore();
      final over = List.generate(
        PendingCandidateStore.maxCandidates + 10,
        (i) => candidate('x$i'),
      );
      await store.save(over);
      final list = await store.load();
      expect(list.length, greaterThan(PendingCandidateStore.maxCandidates),
          reason: 'ADVERSE FINDING(未修,仅补测):save() 无裁剪,'
              'load 只做 30 天 TTL 过滤,超限列表长期驻留');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_candidates_v1');
    });
  });

  // ────────────────────────────────────────────────────────────────
  // 探测发现 5:AnomalyDetector 未接线(事实锁定 + 边界行为)
  // ────────────────────────────────────────────────────────────────
  group('AnomalyDetector 接线状态', () {
    test('非有限 current 不被拒绝,ratio 可为 Infinity(未接线模块边界)', () {
      final verdict = AnomalyDetector.detect(
        history: List.filled(10, 100.0),
        current: double.infinity,
      );
      expect(verdict, isNotNull,
          reason: 'ADVERSE FINDING(未修,仅补测):detect 不拒绝非有限 current');
      expect(verdict!.ratio.isFinite, isFalse,
          reason: 'ratio = Infinity / 100 = Infinity —— 若模块将来接线到提醒,'
              '文案/阈值比较必须先做 isFinite 守卫');
      expect(verdict.threshold.isFinite, isTrue);
      expect(verdict.excessRatio.isFinite, isFalse);
    });

    test('NaN current 同样不在入口被拒(回到 verdict 而非 null)', () {
      final verdict = AnomalyDetector.detect(
        history: List.filled(10, 100.0),
        current: double.nan,
      );
      // 实现顺序:`if (current <= threshold) return null`;NaN 的比较恒 false
      // → 落到 verdict 构造,ratio/excessRatio 全 NaN。若未来接线,必须先守卫。
      expect(verdict, isNotNull,
          reason: 'ADVERSE FINDING(未修,仅补测):NaN 绕过 <= 阈值早退,'
              '产出 ratio=NaN 的 verdict');
      expect(verdict!.ratio.isNaN, isTrue);
      expect(verdict.excessRatio.isNaN, isTrue);
    });

    test('历史含非有限值时阈值变 NaN → 退化为「永远报异常」', () {
      // 实测:median=Infinity、mad=NaN、max(20, NaN)=NaN(Dart 语义),
      // `current <= NaN` 恒 false → 直接越过早退返回 verdict。
      final med = AnomalyDetector.median(
          [100.0, 100.0, double.infinity, double.infinity]);
      expect(med.isFinite, isFalse,
          reason: 'ADVERSE FINDING(未修,仅补测):median 对 Infinity 无守卫');

      final polluted = AnomalyDetector.detect(
        history: [100.0, 100.0, double.infinity, double.infinity],
        current: 1e9,
        minSamples: 3,
      );
      expect(polluted, isNotNull,
          reason: 'threshold=NaN 使 `<=` 恒 false → 任何 current 都被判异常');
      expect(polluted!.threshold.isNaN, isTrue);
      // ratio = current / Infinity = 0(有限但语义错误);excessRatio 全 NaN。
      expect(polluted.ratio, 0.0);
      expect(polluted.excessRatio.isNaN, isTrue);
      // 即便 current 很小也被判异常 —— 接线前必须过滤非有限历史值。
      final tiny = AnomalyDetector.detect(
        history: [100.0, 100.0, double.infinity, double.infinity],
        current: 1.0,
        minSamples: 3,
      );
      expect(tiny, isNotNull,
          reason: '污染基线下连 current=1 都被判异常(全量误报)');
    });
  });

  // ────────────────────────────────────────────────────────────────
  // 存储损坏:损坏 JSON / 迁移 / 未知形态
  // ────────────────────────────────────────────────────────────────
  group('存储损坏与形态容错', () {
    test('规则语料全坏(非 JSON / 错误类型)→ 空列表且不抛', () async {
      SharedPreferences.setMockInitialValues({
        'channel_account_rules_v1': ['not json', '{"channelName": 5}', '{}'],
      });
      final rules = await ChannelAccountStore().load();
      expect(rules, isEmpty, reason: '三条全坏 → 空列表(不抛)');
    });

    test('规则 JSON 混入顶层数组/字符串 → 跳过坏行而不污染其余行', () async {
      SharedPreferences.setMockInitialValues({
        'channel_account_rules_v1': [
          jsonEncode({'channelName': '支付宝', 'accountId': 1}),
          jsonEncode([1, 2, 3]),
          '"just a string"',
        ],
      });
      final rules = await ChannelAccountStore().load();
      expect(rules, hasLength(1));
      expect(rules.single.channelName, '支付宝');
    });

    test('pending_candidates 混入坏行 → 只丢弃坏行', () async {
      SharedPreferences.setMockInitialValues({
        'pending_candidates_v1': [
          '[]',
          '"x"',
          jsonEncode({
            'id': 'ok',
            'bill': BillInfo(note: 'n', amount: 1, ledgerId: 1).toJson(),
            'source': 'sms',
            'capturedAt': DateTime.now().toIso8601String(),
          }),
        ],
      });
      final list = await PendingCandidateStore().load();
      expect(list, hasLength(1));
      expect(list.single.id, 'ok');
    });

    test('候选缺 bill 字段 → 该行被整体丢弃(不产出半残候选)', () async {
      SharedPreferences.setMockInitialValues({
        'pending_candidates_v1': [
          jsonEncode({
            'id': 'no-bill',
            'source': 'sms',
            'capturedAt': DateTime.now().toIso8601String(),
          }),
        ],
      });
      final list = await PendingCandidateStore().load();
      expect(list, isEmpty);
    });
  });
}
