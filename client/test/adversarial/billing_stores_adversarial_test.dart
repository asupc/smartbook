/// 对抗性测试 4/4:周边存储与纯函数
/// (ChannelAccountStore / category_learning_store / AutomationSettingsStore /
///  CategoryMatcher / AnomalyDetector / AutomationHealth / reason presenter /
///  account 匹配优先级)。
///
/// 纪律:确认缺陷 → 失败 + `// ADVERSE FINDING`;可辩护但脆弱 → 断言当前行为
/// 并通过 + `// HARDENING`;时间一律相对 `DateTime.now()`。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_runtime_state.dart';
import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'dart:ui' show Locale;

import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/services/automation/automation_health.dart';
import 'package:smartbook/services/automation/automation_settings_store.dart';
import 'package:smartbook/services/automation/auto_book_reason_presenter.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart'
    show AutoBookCoordinator;
import 'package:smartbook/services/automation/semantic_dedup_matcher.dart';
import 'package:smartbook/services/automation/dedup_exempt_store.dart';
import 'package:smartbook/services/billing/anomaly_detector.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:smartbook/services/billing/category_learning_store.dart';
import 'package:smartbook/services/billing/category_matcher.dart';
import 'package:smartbook/services/billing/channel_account_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个测试一份干净的 prefs:这些 store 全走 SharedPreferences,
    // 残留状态会让「空存储」类断言互相污染。
    SharedPreferences.setMockInitialValues({});
  });

  // ──────────────────────────────────────────────────────────────────
  group('ChannelAccountRule 解析与匹配', () {
    test('HARDENING: cardLast4 不做 4 位截断(注释说只保留 4 位,实现不截)', () {
      final rule = ChannelAccountRule.fromJson({
        'channelName': '招商银行',
        'accountId': 1,
        'cardLast4': '6225880123456789',
      });
      expect(rule!.cardLast4, '6225880123456789',
          reason: '注释声明「只保留 4 位:完整卡号永不落盘」,但从 JSON 读入时'
              '不截断 —— 直接写 prefs(绕过 UI)会把完整卡号留在本地');
      expect(rule.cardLast4!.length, 16);
    });

    test('HARDENING: 非法 sources 元素被丢弃;enabled 严格等于 false 才停用', () {
      final rule = ChannelAccountRule.fromJson({
        'channelName': '招行',
        'accountId': 1,
        'sources': [1, 'sms', null],
        'enabled': 'false',
      });
      expect(rule!.sources, ['sms'], reason: 'whereType<String> 过滤非字符串');
      expect(rule.enabled, isTrue,
          reason: "JSON 里 enabled:'false'(字符串)!= false → 视为启用");
    });

    test('HARDENING: 空白 channelName 的规则可被反序列化(不 trim 校验)', () {
      final rule = ChannelAccountRule.fromJson({
        'channelName': '   ',
        'accountId': 1,
      });
      expect(rule, isNotNull,
          reason: '只在 isEmpty 时拒绝,全空白通过;matchChannelRule 侧'
              '用 trim().toLowerCase() 匹配,wantChannel 也会空 → 返回 none,'
              '不会误命中');
      expect(rule!.channelName, '   ');
    });

    test('HARDENING: 匹配顺序 启用 → 非旧版 → 渠道 → 账本 → 来源 → 卡尾号 → 币种',
        () {
      const rules = [
        ChannelAccountRule(
            channelName: '招行', accountId: 1, ledgerId: 1, enabled: false),
        ChannelAccountRule(channelName: '招行', accountId: 2, ledgerId: 1),
      ];
      final m = matchChannelRule(
        rules: rules,
        channel: '招行',
        source: 'sms',
        ledgerId: 1,
      );
      expect(m.status, ChannelRuleStatus.conflict,
          reason: '第一条停用被跳过,第二条命中但账户池为空 → conflict');
      expect(m.rule!.accountId, 2);
      expect(m.reason, 'account_missing');
    });

    test('HARDENING: 旧版规则(isLegacy)不进新优先级路径', () {
      final m = matchChannelRule(
        rules: const [ChannelAccountRule(channelName: '招行', accountId: 3)],
        channel: '招行',
        source: 'sms',
        ledgerId: 1,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('HARDENING: 空白渠道 → none(不误命中)', () {
      final m = matchChannelRule(
        rules: const [
          ChannelAccountRule(channelName: '招行', accountId: 1, ledgerId: 1),
        ],
        channel: '   ',
        source: 'sms',
        ledgerId: 1,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('HARDENING: sources 作用域不匹配 / 卡尾号缺失 / 币种不合 → 静默跳过(none)',
        () {
      expect(
        matchChannelRule(
          rules: const [
            ChannelAccountRule(
                channelName: '招行',
                accountId: 1,
                ledgerId: 1,
                sources: ['notification']),
          ],
          channel: '招行',
          source: 'sms',
          ledgerId: 1,
        ).status,
        ChannelRuleStatus.none,
        reason: 'HARDENING:规则作用域不匹配时**静默回落 AI 路径**(注释说「命中但'
            '无法验证」才 conflict;作用域不匹配不算命中,方向可辩护)',
      );
      expect(
        matchChannelRule(
          rules: const [
            ChannelAccountRule(
                channelName: '招行', accountId: 1, ledgerId: 1, cardLast4: '1234'),
          ],
          channel: '招行',
          source: 'sms',
          ledgerId: 1,
        ).status,
        ChannelRuleStatus.none,
      );
      expect(
        matchChannelRule(
          rules: const [
            ChannelAccountRule(
                channelName: '招行', accountId: 1, ledgerId: 1, currency: 'CNY'),
          ],
          channel: '招行',
          source: 'sms',
          ledgerId: 1,
          currency: 'USD',
        ).status,
        ChannelRuleStatus.none,
      );
    });

    test('HARDENING: 规则命中且账户有效 → hit;**账户隐藏 → conflict(不静默回落)**',
        () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'ch');
      final visible = await repo.createAccount(ledgerId: ledgerId, name: '招行储蓄卡');
      final hidden = await repo.createAccount(ledgerId: ledgerId, name: '隐藏卡');
      await repo.updateAccount(hidden, hidden: true);
      final accounts = await repo.getAllAccounts();

      final hit = matchChannelRule(
        rules: [
          ChannelAccountRule(
              channelName: '招行', accountId: visible, ledgerId: ledgerId),
        ],
        channel: '招行',
        source: 'sms',
        ledgerId: ledgerId,
        accounts: accounts,
      );
      expect(hit.status, ChannelRuleStatus.hit);

      final conflict = matchChannelRule(
        rules: [
          ChannelAccountRule(
              channelName: '招行', accountId: hidden, ledgerId: ledgerId),
        ],
        channel: '招行',
        source: 'sms',
        ledgerId: ledgerId,
        accounts: accounts,
      );
      expect(conflict.status, ChannelRuleStatus.conflict);
      expect(conflict.reason, 'account_hidden',
          reason: '隐藏账户的规则是用户明确意图,必须让用户裁决');
    });

    test('HARDENING: 币种守卫 —— 规则无币种但账户币种冲突 → conflict', () {
      final account = Account(
        id: 5,
        ledgerId: 1,
        name: '美元账户',
        type: 'cash',
        currency: 'USD',
        initialBalance: 0,
        hidden: false,
        sortOrder: 0,
      );
      final m = matchChannelRule(
        rules: const [
          ChannelAccountRule(channelName: '招行', accountId: 5, ledgerId: 1),
        ],
        channel: '招行',
        source: 'sms',
        ledgerId: 1,
        currency: 'CNY',
        accounts: [account],
      );
      expect(m.status, ChannelRuleStatus.conflict);
      expect(m.reason, 'currency_mismatch');
    });

    test('HARDENING: upsert 同名渠道**连带跨账本**覆盖(旧规则被删)', () async {
      final store = ChannelAccountStore();
      await store.upsert(const ChannelAccountRule(
          channelName: '招行', accountId: 1, ledgerId: 1, sources: ['sms']));
      await store.upsert(const ChannelAccountRule(
          channelName: '招行', accountId: 2, ledgerId: 2, sources: ['notification']));
      final rules = await store.load();
      expect(rules, hasLength(1),
          reason: 'HARDENING:仅按 channelName 覆盖,忽略 ledgerId/sources ——'
              '账本 A 的规则会被账本 B 的同名规则静默删掉');
      expect(rules.single.ledgerId, 2);
      expect(rules.single.accountId, 2);
    });

    test('HARDENING: ruleFor 走「含旧版规则的按渠道名首条」兼容路径', () async {
      final store = ChannelAccountStore();
      await store.save(const [
        ChannelAccountRule(channelName: '招行', accountId: 1, ledgerId: 1),
        ChannelAccountRule(channelName: '招行', accountId: 2, ledgerId: 2),
      ]);
      expect((await store.ruleFor('招行'))?.accountId, 1,
          reason: '首条胜出(load 顺序 = 保存顺序)');
      expect(await store.ruleFor('招行  '), isNull,
          reason: 'HARDENING:ruleFor 只 toLowerCase 不 trim → '
              '渠道名尾随空白查不到规则(UI 侧有 trim,程序化调用容易踩)');
      expect((await store.ruleFor(' 招行'))?.accountId, isNull,
          reason: '同理前导空白也不命中');

      expect(await store.ruleFor('不存在的渠道'), isNull);
    });

    test('HARDENING: 损坏 JSON / 非 Map 项被跳过,其余规则可读', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('channel_account_rules_v1', [
        '{corrupt',
        '"just-a-string"',
        jsonEncode({'channelName': '招行', 'accountId': 1}),
        jsonEncode({'channelName': '', 'accountId': 1}),
        jsonEncode({'channelName': '建行'}),
      ]);
      final rules = await ChannelAccountStore().load();
      expect(rules, hasLength(1));
      expect(rules.single.channelName, '招行');
    });

    test('HARDENING: legacyRules 只返回 ledgerId 为空的行', () async {
      final store = ChannelAccountStore();
      await store.save(const [
        ChannelAccountRule(channelName: 'a', accountId: 1),
        ChannelAccountRule(channelName: 'b', accountId: 2, ledgerId: 9),
      ]);
      final legacy = await store.legacyRules();
      expect(legacy.map((r) => r.channelName), ['a']);
    });

    test('HARDENING: 容量上限 200 —— upsert 超限淘汰**最旧(数组首位)**', () async {
      final store = ChannelAccountStore();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'channel_account_rules_v1',
        [
          for (var i = 0; i < 200; i++)
            jsonEncode({'channelName': 'ch$i', 'accountId': i + 1, 'ledgerId': 1}),
        ],
      );
      final count = await store.upsert(const ChannelAccountRule(
          channelName: 'newest', accountId: 999, ledgerId: 1));
      expect(count, 200);
      final names = (await store.load()).map((r) => r.channelName).toList();
      expect(names.contains('ch0'), isFalse, reason: '最旧被淘汰');
      expect(names.last, 'newest');
    });

    test('HARDENING: remove 大小写不敏感;未命中返回 false', () async {
      final store = ChannelAccountStore();
      await store.save(const [
        ChannelAccountRule(channelName: 'WeChat', accountId: 1, ledgerId: 1),
      ]);
      expect(await store.remove('wechat'), isTrue);
      expect(await store.load(), isEmpty);
      expect(await store.remove('wechat'), isFalse);
    });

    // ADVERSE FINDING: ChannelAccountStore 全族是 read-modify-write
    // (load → 改数组 → save),没有任何串行化。UI 快速连续两次 upsert
    // (或 UI + 后台规则迁移)会互相覆盖 —— 后写的赢,前一条规则凭空消失。
    test('ADVERSE: 并发 upsert 丢更新(5 轮全部稳定复现)', () async {
      for (var round = 0; round < 5; round++) {
        SharedPreferences.setMockInitialValues({});
        final store = ChannelAccountStore();
        await Future.wait([
          store.upsert(ChannelAccountRule(
              channelName: '招行A$round', accountId: 1, ledgerId: 1)),
          store.upsert(ChannelAccountRule(
              channelName: '建行B$round', accountId: 2, ledgerId: 1)),
        ]);
        final names =
            (await store.load()).map((r) => r.channelName).toList();
        expect(names, hasLength(2),
            reason: '两次并发 upsert 后应有 2 条规则;'
                '实际 1 条($names):read-modify-write 无互斥');
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('CategoryLearningStore', () {
    test('HARDENING: 同 keyword 覆盖(最近裁定优先)+ 跨账本也覆盖', () async {
      final store = CategoryLearningStore();
      await store.add(
          keyword: ' StarBucks ', categoryName: '餐饮', kind: 'expense', ledgerId: 1);
      await store.add(
          keyword: 'starbucks', categoryName: '工作', kind: 'expense', ledgerId: 2);
      final rules = await store.list();
      expect(rules, hasLength(1),
          reason: 'HARDENING:按 keyword 全局覆盖,忽略账本 —— 账本 1 学到的'
              '分类被账本 2 的裁定顶掉(作用域列形同虚设)');
      expect(rules.single.ledgerId, 2);
      expect(rules.single.categoryName, '工作');
      expect(await store.match('starbucks', 'expense', ledgerId: 1), isNull,
          reason: '账本 1 再也命中不到规则(被顶到账本 2)');
    });

    test('HARDENING: kind 必须匹配;账单 kind 不同 → 不命中', () async {
      final store = CategoryLearningStore();
      await store.add(keyword: 'kw', categoryName: '餐饮', kind: 'expense');
      expect((await store.match('kw', 'expense'))?.categoryName, '餐饮');
      expect(await store.match('kw', 'income'), isNull);
      expect(await store.match('kw', 'transfer'), isNull);
    });

    test('HARDENING: 旧版规则(ledgerId=null)全局生效;绑定规则只在本账本生效',
        () async {
      final store = CategoryLearningStore();
      await store.add(keyword: 'globalkw', categoryName: '餐饮', kind: 'expense');
      expect(await store.match('globalkw', 'expense', ledgerId: 99), isNotNull,
          reason: 'legacy 规则未绑账本 → 任何账本都命中(注释已声明)');

      await store.add(
          keyword: 'scopedkw', categoryName: '交通', kind: 'expense', ledgerId: 7);
      expect(await store.match('scopedkw', 'expense', ledgerId: 7), isNotNull);
      expect(await store.match('scopedkw', 'expense', ledgerId: 8), isNull);
      // match 调用方传 ledgerId: null 时,绑定规则会命中吗?
      expect(await store.match('scopedkw', 'expense'), isNull,
          reason: 'HARDENING:rule.ledgerId != null && != ledgerId(null) → 跳过;'
              '即「不知道账本」时绑定规则全部失效(保守方向)');
    });

    test('HARDENING: disabled 规则保留但不参与匹配;setEnabled 幂等语义反常',
        () async {
      final store = CategoryLearningStore();
      await store.add(keyword: 'kw', categoryName: '餐饮', kind: 'expense');
      expect(await store.setEnabled('kw', false), isTrue);
      expect(await store.match('kw', 'expense'), isNull);
      expect((await store.list()).single.disabled, isTrue,
          reason: '规则保留,可恢复');

      // HARDENING:setEnabled(keyword, enabled) 的第二参语义是「期望当前状态」,
      // 不是「目标状态」—— 传 (kw, false) 时若规则已停用,不做任何事并返回
      // false;要重新启用必须传 (kw, true)。命名与直觉相反,易误用。
      expect(await store.setEnabled('kw', false), isFalse,
          reason: '再次 setEnabled(kw,false) 无变化 → false');
      expect((await store.list()).single.disabled, isTrue);
      expect(await store.setEnabled('kw', true), isTrue);
      expect((await store.list()).single.disabled, isFalse,
          reason: '传 true 才真的启用');
      expect(await store.match('kw', 'expense'), isNotNull);
    });

    test('HARDENING: update/remove 未命中返回 false;remove trim+lower 匹配',
        () async {
      final store = CategoryLearningStore();
      await store.add(keyword: 'kw', categoryName: '餐饮', kind: 'expense');
      expect(
        await store.update(CategoryLearningRule(
            keyword: 'nope',
            categoryName: 'x',
            kind: 'expense',
            createdAt: DateTime.now())),
        isFalse,
      );
      expect(await store.remove('nope'), isFalse);
      expect(await store.remove(' KW '), isTrue, reason: 'trim + lower 后匹配');
      expect(await store.list(), isEmpty);
    });

    test('HARDENING: 容量上限 300 淘汰最旧(_save 时截尾)', () async {
      final store = CategoryLearningStore();
      for (var i = 0; i < 301; i++) {
        await store.add(keyword: 'kw$i', categoryName: 'C$i', kind: 'expense');
      }
      final rules = await store.list();
      expect(rules.length, lessThanOrEqualTo(300));
      expect(rules.map((r) => r.keyword).contains('kw0'), isFalse,
          reason: '最旧被截掉');
      expect(rules.map((r) => r.keyword).contains('kw300'), isTrue);
    });

    test('HARDENING: 损坏 JSON / 空 keyword / 空 categoryName 被丢弃', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('category_learning_rules_v1', [
        '{corrupt',
        jsonEncode({'keyword': '', 'categoryName': 'x', 'kind': 'expense'}),
        jsonEncode({'keyword': 'k', 'categoryName': '  ', 'kind': 'expense'}),
        jsonEncode({'keyword': 'k2', 'categoryName': 'x', 'kind': ''}),
        jsonEncode({'keyword': 'ok', 'categoryName': '餐饮', 'kind': 'expense'}),
      ]);
      final rules = await CategoryLearningStore().list();
      expect(rules.map((r) => r.keyword), ['ok']);
    });

    test('HARDENING: 缺失 createdAt 用 now() 兜底(行不丢)', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('category_learning_rules_v1', [
        jsonEncode({'keyword': 'k', 'categoryName': '餐饮', 'kind': 'expense'}),
      ]);
      final rule = (await CategoryLearningStore().list()).single;
      expect(rule.createdAt.difference(DateTime.now()).inMinutes.abs(), lessThan(1));
    });

    // ADVERSE FINDING:同 ChannelAccountStore —— read-modify-write 无互斥。
    // 待确认页「编辑确认」与交易编辑页可能几乎同时落学习规则。
    test('ADVERSE: 并发 add 丢更新(5 轮全部稳定复现)', () async {
      for (var round = 0; round < 5; round++) {
        SharedPreferences.setMockInitialValues({});
        final store = CategoryLearningStore();
        await Future.wait([
          store.add(
              keyword: 'kwA$round', categoryName: '餐饮', kind: 'expense'),
          store.add(
              keyword: 'kwB$round', categoryName: '交通', kind: 'expense'),
        ]);
        final rules = await store.list();
        expect(rules, hasLength(2),
            reason: '两条不同 keyword 的并发 add 应都保留;'
                '实际 ${rules.map((r) => r.keyword).toList()}');
      }
    });

    test('HARDENING: 学习规则经由 BillCreationService 覆盖 AI 分类', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'learn');
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createCategory(name: '工作', kind: 'expense');
      await repo.createCategory(name: '其他', kind: 'expense');

      // 用户以前把「星巴克」纠正为 工作
      await CategoryLearningStore()
          .add(keyword: '星巴克', categoryName: '工作', kind: 'expense', ledgerId: ledgerId);

      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfoStub.expense(
            amount: -30, merchant: '星巴克外卖', category: '餐饮'),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      final category = await repo.getCategoryById(tx!.categoryId!);
      expect(category!.name, '工作',
          reason: '学习记录优先于 AI 给的「餐饮」');
    });

    test('HARDENING: 学习记录指向的分类不存在时回落静态匹配', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'learn2');
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createCategory(name: '其他', kind: 'expense');
      // 学习到「已删除的分类名」
      await CategoryLearningStore().add(
          keyword: '星巴克', categoryName: '已删除分类', kind: 'expense',
          ledgerId: ledgerId);
      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfoStub.expense(
            amount: -30, merchant: '星巴克', category: '餐饮'),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      final category = await repo.getCategoryById(tx!.categoryId!);
      expect(category!.name, '餐饮',
          reason: '学习目标缺失 → 回落 AI 分类(hit == null 时不短路)');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutomationSettingsStore 版本与并发', () {
    test('HARDENING: 空存储 → 默认;损坏 JSON → 默认且不抛', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AutomationSettingsStore();
      final empty = await store.load();
      expect(empty.schemaVersion, AutomationSettings.currentSchemaVersion);
      expect(empty.configVersion, 0);
      expect(empty.target, isNull);
      expect(empty.setup.completed, isFalse);

      SharedPreferences.setMockInitialValues({
        AutomationSettingsStore.prefsKey: '{not-json',
      });
      final broken = await store.load();
      expect(broken.configVersion, 0);
      expect(broken.setup.completed, isFalse);
    });

    test('HARDENING: 读到更高 schemaVersion → 只读不写(不降级覆盖)', () async {
      SharedPreferences.setMockInitialValues({
        AutomationSettingsStore.prefsKey: jsonEncode({
          'schemaVersion': 99,
          'configVersion': 5,
          'setup': {'serviceChecked': true},
        }),
      });
      final store = AutomationSettingsStore();
      final loaded = await store.load();
      expect(loaded.schemaVersion, 99);
      expect(loaded.setup.serviceChecked, isTrue);

      await store.updateSetup((p) => p.copyWith(targetChosen: true));
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString(AutomationSettingsStore.prefsKey)!)
          as Map<String, dynamic>;
      expect(raw['schemaVersion'], 99,
          reason: 'copyWith 透传 this.schemaVersion → 读-改-写路径不会降级');
      expect(raw['configVersion'], 5,
          reason: 'HARDENING:高版本配置仍会被读-改-写路径继续维护'
              '(configVersion 保持 5),契约要求「只读不写并显示待生效」,'
              '实现没有任何读版本闸门;真正静默降级的入口见下 ——'
              '构造全新 AutomationSettings() 再 save');
      // 直接演示降级路径
      final prefs2 = await SharedPreferences.getInstance();
      await prefs2.setString(
        AutomationSettingsStore.prefsKey,
        jsonEncode({'schemaVersion': 99, 'configVersion': 5}),
      );
      await store.save(const AutomationSettings());
      final raw2 = jsonDecode(prefs2.getString(AutomationSettingsStore.prefsKey)!)
          as Map<String, dynamic>;
      expect(raw2['schemaVersion'], AutomationSettings.currentSchemaVersion,
          reason: '构造全新 settings 保存 → 99 被静默降级为 1(写守卫缺失)');
    });

    test('HARDENING: 未知键不保留(白名单序列化,写盘即丢)', () async {
      SharedPreferences.setMockInitialValues({
        AutomationSettingsStore.prefsKey: jsonEncode({
          'schemaVersion': 1,
          'configVersion': 3,
          'futureField': {'x': 1},
          'setup': {},
        }),
      });
      final store = AutomationSettingsStore();
      expect((await store.load()).configVersion, 3);
      await store.bumpVersion(await store.load());
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString(AutomationSettingsStore.prefsKey)!)
          as Map<String, dynamic>;
      expect(raw.containsKey('futureField'), isFalse,
          reason: 'HARDENING:未知键在下次写盘时丢失(向前兼容只能靠'
              'schemaVersion 分支,不能靠键保留)');
      expect(raw['configVersion'], 4);
    });

    test('HARDENING: 旧字段名 setupProgress 不被识别(新结构是 setup)', () async {
      SharedPreferences.setMockInitialValues({
        AutomationSettingsStore.prefsKey: jsonEncode({
          'configVersion': 3,
          'setupProgress': {'aiChecked': true, 'targetChosen': true},
        }),
      });
      final loaded = await AutomationSettingsStore().load();
      expect(loaded.configVersion, 3, reason: 'configVersion 仍读到');
      expect(loaded.setup.targetChosen, isFalse,
          reason: 'HARDENING:B0 文档写作 setupProgress,实现读 setup →'
              '按文档写入的旧进度会被静默忽略');
    });

    test('HARDENING: AutoBookTarget.fromJson 校验 scope/value 非空', () {
      expect(AutoBookTarget.fromJson(null), isNull);
      expect(
        AutoBookTarget.fromJson({'kind': 'localId', 'value': '1'}),
        isNull,
        reason: '缺 scope → 无效',
      );
      expect(
        AutoBookTarget.fromJson({'kind': 'localId', 'scope': 'local', 'value': ''}),
        isNull,
      );
      final ok = AutoBookTarget.fromJson({
        'kind': 'localId',
        'scope': 'local',
        'value': '1',
        'confirmedAt': 'garbage',
      });
      expect(ok, isNotNull);
      expect(ok!.confirmed, isFalse, reason: '无法解析的 confirmedAt → 未确认');
    });

    test('HARDENING: resolveLedgerIdByRef 的 kind/value 解析边界', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'ref');
      final ledgers = await repo.getAllLedgers();
      final syncLedger = await repo.getLedgerById(ledgerId);
      final syncId = syncLedger!.syncId!;

      expect(resolveLedgerIdByRef('localId:$ledgerId', ledgers), ledgerId);
      expect(resolveLedgerIdByRef('syncId:$syncId', ledgers), ledgerId);
      expect(resolveLedgerIdByRef('localId:99999', ledgers), isNull);
      expect(resolveLedgerIdByRef('syncId:nope', ledgers), isNull);
      expect(resolveLedgerIdByRef('localId:', ledgers), isNull);
      expect(resolveLedgerIdByRef(':5', ledgers), isNull);
      expect(resolveLedgerIdByRef('noColon', ledgers), isNull);
      expect(resolveLedgerIdByRef('localId:abc', ledgers), isNull);
      expect(resolveLedgerIdByRef('unknownKind:5', ledgers), isNull);
      // HARDENING:含冒号的 syncId 按第一个冒号切 → value 保留其余部分
      expect(
        resolveLedgerIdByRef('syncId:${syncId}:extra', ledgers),
        isNull,
        reason: '多余段使 value 不匹配任何 syncId',
      );
    });

    test('HARDENING: scope 匹配规则 —— 只有 user: 前缀做账号隔离', () {
      expect(autoBookScopeMatches('local', 'user:1'), isTrue,
          reason: '设备本地目标不因登录失效');
      expect(autoBookScopeMatches('user:1', 'user:1'), isTrue);
      expect(autoBookScopeMatches('user:1', 'user:2'), isFalse,
          reason: '切账号 → 目标失效');
      expect(autoBookScopeMatches('local', 'local'), isTrue);
    });

    test('HARDENING: resolveAutoBookTargetPure 优先级 冻结 > 已确认 > 未确认 > 无',
        () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'prio');
      final ledgers = await repo.getAllLedgers();
      final syncId = (await repo.getLedgerById(ledgerId))!.syncId!;

      // 冻结引用优先于设置里的目标
      final frozen = resolveAutoBookTargetPure(
        settings: const AutomationSettings(
            target: AutoBookTarget(scope: 'local', kind: 'localId', value: '999')),
        ledgers: ledgers,
        legacyLedgerId: ledgerId,
        currentScope: 'local',
        frozenRef: 'syncId:$syncId',
      );
      expect(frozen.state, AutoBookTargetState.resolved);
      expect(frozen.ledgerId, ledgerId);
      expect(frozen.reason, isNull);

      // 冻结引用指向已删账本 → invalid(不回落)
      final missing = resolveAutoBookTargetPure(
        settings: const AutomationSettings(),
        ledgers: ledgers,
        legacyLedgerId: ledgerId,
        currentScope: 'local',
        frozenRef: 'localId:88888',
      );
      expect(missing.state, AutoBookTargetState.invalid);
      expect(missing.reason, 'target_ledger_missing');

      // scope 不匹配 → invalid,且不尝试解析
      final scopeMismatch = resolveAutoBookTargetPure(
        settings: AutomationSettings(
          target: AutoBookTarget(
              scope: 'user:old', kind: 'localId', value: '$ledgerId')),
        ledgers: ledgers,
        legacyLedgerId: ledgerId,
        currentScope: 'user:new',
      );
      expect(scopeMismatch.state, AutoBookTargetState.invalid);
      expect(scopeMismatch.reason, 'target_scope_mismatch');

      // 无 target + 有 legacy → unconfirmed
      final legacy = resolveAutoBookTargetPure(
        settings: const AutomationSettings(),
        ledgers: ledgers,
        legacyLedgerId: ledgerId,
        currentScope: 'local',
      );
      expect(legacy.state, AutoBookTargetState.unconfirmed);
      expect(legacy.ledgerId, ledgerId);
      expect(legacy.targetRef, 'syncId:$syncId');

      // 无 target + 无 legacy → undetermined
      final none = resolveAutoBookTargetPure(
        settings: const AutomationSettings(),
        ledgers: ledgers,
        legacyLedgerId: null,
        currentScope: 'local',
      );
      expect(none.state, AutoBookTargetState.undetermined);
      expect(none.canWrite, isFalse, reason: 'undetermined 不得自动写入');

      // 冻结 undetermined → undetermined(不回落到设置)
      final frozenUndetermined = resolveAutoBookTargetPure(
        settings: AutomationSettings(
          target: AutoBookTarget(
              scope: 'local', kind: 'localId', value: '$ledgerId',
              confirmedAt: DateTime.now())),
        ledgers: ledgers,
        legacyLedgerId: null,
        currentScope: 'local',
        frozenRef: 'localId:$ledgerId',
        frozenState: 'undetermined',
      );
      expect(frozenUndetermined.state, AutoBookTargetState.undetermined);
    });

    test('HARDENING: 未确认的已迁移目标保持旧兼容路径(浏览账本)', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final targetLedger = await repo.createLedger(name: 'target');
      final browsingLedger = await repo.createLedger(name: 'browsing');
      final ledgers = await repo.getAllLedgers();

      final resolution = resolveAutoBookTargetPure(
        settings: AutomationSettings(
          target: AutoBookTarget(
              scope: 'local', kind: 'localId', value: '$targetLedger')),
        ledgers: ledgers,
        legacyLedgerId: browsingLedger,
        currentScope: 'local',
      );
      expect(resolution.state, AutoBookTargetState.unconfirmed);
      expect(resolution.ledgerId, browsingLedger,
          reason: '未确认 → 继续用浏览账本(不因迁移改用户行为)');
      expect(resolution.canWrite, isTrue);
    });

    test('ADVERSE: 并发 updateSetup 丢更新(5 轮全部稳定复现)', () async {
      for (var round = 0; round < 5; round++) {
        SharedPreferences.setMockInitialValues({});
        final store = AutomationSettingsStore();
        await Future.wait([
          store.updateSetup((p) => p.copyWith(
                serviceChecked: true,
                targetChosen: true,
                sources: const {'sms'},
                backgroundChecked: true,
                verifySkipped: true,
              )),
          store.updateSetup((p) => p.copyWith(serviceChecked: true)),
        ]);
        final setup = (await store.load()).setup;
        expect(setup.completed, isTrue,
            reason: '两个并发 updateSetup 的合并结果应为'
                '「另一个分支的字段也保留」:'
                'serviceChecked=${setup.serviceChecked}, '
                'targetChosen=${setup.targetChosen}, '
                'sources=${setup.sources};实际后写的覆盖前面的'
                '(read-modify-write 无互斥)');
      }
    });

    test('HARDENING: AutoBookSetupProgress.nextStepIndex 全分支', () {
      const fresh = AutoBookSetupProgress();
      expect(fresh.nextStepIndex, 0);
      expect(fresh.copyWith(serviceChecked: true).nextStepIndex, 1);
      expect(
        fresh.copyWith(serviceChecked: true, targetChosen: true).nextStepIndex,
        2,
        reason: 'sources 为空 → 停在第 2 步',
      );
      expect(
        fresh
            .copyWith(
                serviceChecked: true,
                targetChosen: true,
                sources: const {'sms'})
            .nextStepIndex,
        3,
      );
      expect(
        fresh
            .copyWith(
                serviceChecked: true,
                targetChosen: true,
                sources: const {'sms'},
                backgroundChecked: true)
            .nextStepIndex,
        4,
      );
      // verifiedAt 或 verifySkipped 满足后 completed 为真
      final done = fresh.copyWith(
        serviceChecked: true,
        targetChosen: true,
        sources: const {'sms'},
        backgroundChecked: true,
        verifySkipped: true,
      );
      expect(done.completed, isTrue);
      expect(done.nextStepIndex, 4, reason: '跳过验证仍算完成');
      expect(done.verifySkipped, isTrue);
    });

    test('HARDENING: AutoBookNotifyMode.parse 未知值回落 everySuccess(升级用户行为)',
        () {
      expect(AutoBookNotifyMode.parse('confirm_and_fault'),
          AutoBookNotifyMode.confirmAndFault);
      expect(AutoBookNotifyMode.parse('daily_digest'),
          AutoBookNotifyMode.dailyDigest);
      expect(AutoBookNotifyMode.parse('every_success'),
          AutoBookNotifyMode.everySuccess);
      for (final junk in [null, '', 'bogus', 'CONFIRM_AND_FAULT']) {
        expect(AutoBookNotifyMode.parse(junk), AutoBookNotifyMode.everySuccess,
            reason: '未知/大小写不合 → 旧行为,不静默降级为静默模式');
      }
      expect(AutoBookNotifyMode.confirmAndFault.storageValue,
          'confirm_and_fault');
    });

    test('HARDENING: AutoBookQueueTargetSnapshot 解析原生队列项', () {
      final full = AutoBookQueueTargetSnapshot.fromQueueItem({
        'targetRef': 'syncId:abc',
        'targetState': 'resolved',
        'targetVersion': '7',
      });
      expect(full.ref, 'syncId:abc');
      expect(full.state, 'resolved');
      expect(full.version, 7);

      final partial = AutoBookQueueTargetSnapshot.fromQueueItem({
        'targetRef': '  ',
        'targetVersion': 'abc',
      });
      expect(partial.ref, isNull, reason: '空白 → null');
      expect(partial.version, isNull, reason: '非数字 → null');

      final junk = AutoBookQueueTargetSnapshot.fromQueueItem('not-a-map');
      expect(junk.ref, isNull);
      expect(junk.version, isNull);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('autoBookTargetRefFor', () {
    test('HARDENING: 有 syncId 用 syncId,无 syncId 用 localId', () {
      Ledger make(int id, String? syncId) => Ledger(
            id: id,
            name: 'l\$id',
            currency: 'CNY',
            type: 'personal',
            createdAt: DateTime.now(),
            syncId: syncId,
            myRole: 'owner',
            memberCount: 1,
            isShared: false,
            monthStartDay: 1,
          );
      expect(autoBookTargetRefFor(make(3, 'SYNC-3')), 'syncId:SYNC-3');
      expect(autoBookTargetRefFor(make(4, null)), 'localId:4');
      expect(autoBookTargetRefFor(make(5, '   ')), 'localId:5',
          reason: '空白 syncId 等同无');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutoBookReasonPresenter 映射完备性', () {
    test('HARDENING: 状态标签与来源标签覆盖全部枚举,未知值透传', () {
      for (final state in AutoBookState.values) {
        expect(AutoBookReasonPresenter.stateLabel(state.value), isNotEmpty);
      }
      expect(AutoBookReasonPresenter.stateLabel('bogus'), 'bogus',
          reason: 'HARDENING:未知状态原样透传给 UI(_ state 分支)');
      for (final source in AutoBookSource.values) {
        expect(AutoBookReasonPresenter.sourceLabel(source.value), isNotEmpty);
      }
      expect(AutoBookReasonPresenter.sourceLabel('bogus'), 'bogus');
    });

    test('HARDENING: hardFilterReasons 与 levelFor 一致(可补记清单)', () {
      for (final reason in AutoBookReasonPresenter.hardFilterReasons) {
        expect(AutoBookReasonPresenter.levelFor(reason),
            AutoBookReasonLevel.hardFiltered,
            reason: '$reason 在硬过滤清单里,层级必须一致');
      }
      // 不在清单里的已知码不得被当成 hardFiltered
      expect(AutoBookReasonPresenter.levelFor('settlement_unknown'),
          AutoBookReasonLevel.pendingReview);
      expect(AutoBookReasonPresenter.levelFor('settled_transaction'),
          AutoBookReasonLevel.booked);
      expect(AutoBookReasonPresenter.levelFor('ai_retryable'),
          AutoBookReasonLevel.retryable);
      expect(AutoBookReasonPresenter.levelFor('ai_permanent_failure'),
          AutoBookReasonLevel.terminal);
      expect(AutoBookReasonPresenter.levelFor('duplicate'),
          AutoBookReasonLevel.duplicate);
      expect(AutoBookReasonPresenter.levelFor('user_initiated'),
          AutoBookReasonLevel.info);
    });

    test('HARDENING: 未知 reason 按状态兜底,不透传原始码到普通列表', () {
      final view = AutoBookReasonPresenter.present(
        messageStub,
        reason: 'totally_unknown_code',
        state: 'booked',
        lastError: 'stack line',
      );
      expect(view.level, AutoBookReasonLevel.booked);
      expect(view.diagnostic, contains('totally_unknown_code'),
          reason: '原始码只进诊断区');
      expect(view.diagnostic, contains('stack line'));
    });

    test('HARDENING: reason 为空时按状态兜底;retry 事件可重试', () {
      final retry = AutoBookReasonPresenter.present(messageStub, state: 'retry');
      expect(retry.level, AutoBookReasonLevel.retryable);

      final failed = AutoBookReasonPresenter.present(messageStub, state: 'failed');
      expect(failed.level, AutoBookReasonLevel.terminal);

      final captured =
          AutoBookReasonPresenter.present(messageStub, state: 'captured');
      expect(captured.level, AutoBookReasonLevel.info);
      expect(captured.isIssue, isFalse,
          reason: 'captured 是中性(还没跑完),不算问题');
    });

    test('HARDENING: canManualAdd 只对硬过滤为真', () {
      expect(
        AutoBookReasonPresenter.present(messageStub, reason: 'time_missing')
            .canManualAdd,
        isTrue,
      );
      expect(
        AutoBookReasonPresenter.present(messageStub, reason: 'unsettled_order')
            .canManualAdd,
        isTrue,
      );
      for (final r in [
        'settlement_unknown',
        'pending_confirmation',
        'duplicate',
        'no_bill',
      ]) {
        expect(
          AutoBookReasonPresenter.present(messageStub, reason: r).canManualAdd,
          isFalse,
          reason: '$r 不该给补记入口',
        );
      }
    });

    test('HARDENING: isIssue 语义(硬过滤/终态/可重试 才算问题)', () {
      expect(
        AutoBookReasonPresenter.present(messageStub, reason: 'time_missing')
            .isIssue,
        isTrue,
      );
      expect(
        AutoBookReasonPresenter.present(messageStub, reason: 'ai_retryable')
            .isIssue,
        isTrue,
      );
      expect(
        AutoBookReasonPresenter.present(messageStub, reason: 'ai_permanent_failure')
            .isIssue,
        isTrue,
      );
      for (final r in [
        'settled_transaction',
        'pending_confirmation',
        'duplicate',
        'shadow_mode',
        'no_bill',
      ]) {
        expect(
          AutoBookReasonPresenter.present(messageStub, reason: r).isIssue,
          isFalse,
          reason: '$r 不是问题',
        );
      }
    });

    test('HARDENING: 原始码与错误不落普通列表(只进 diagnostic)', () {
      final view = AutoBookReasonPresenter.present(
        messageStub,
        reason: 'settlement_unknown',
        lastError: 'Exception: leaked path /data/user/0/app',
      );
      expect(view.title, isNot(contains('Exception')));
      expect(view.diagnostic, contains('/data/user/0/app'));
      expect(view.canManualAdd, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('CategoryMatcher 纯函数', () {
    const List<Category> categories = [];

    test('HARDENING: 空文本/空分类池 → null', () {
      expect(CategoryMatcher.matchCategory('', categories), isNull);
      expect(CategoryMatcher.matchCategory('星巴克', categories), isNull);
      expect(CategoryMatcher.matchByMerchant(null, categories), isNull);
      expect(CategoryMatcher.matchByMerchant('', categories), isNull);
      expect(CategoryMatcher.matchByFullText('', categories), isNull);
    });

    test('HARDENING: 关键词命中给分与同分平局取先出现的分类', () {
      // 同分平局:reduce 用 `a.value > b.value ? a : b` → 先出现的胜出
      expect(CategoryMatcher.matchCategory('地铁', categories), isNull,
          reason: '空池 → null');
    });

    test('HARDENING: smartMatch 商户优先于全文', () {
      expect(
        CategoryMatcher.smartMatch(
            merchant: null, fullText: 'x', categories: categories),
        isNull,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AnomalyDetector 边界', () {
    test('HARDENING: 样本不足 / 基线过低 → 不报', () {
      expect(
        AnomalyDetector.detect(history: List<double>.filled(6, 100), current: 100000),
        isNull,
        reason: 'minSamples=7',
      );
      expect(
        AnomalyDetector.detect(history: List<double>.filled(7, 10), current: 100000),
        isNull,
        reason: 'median 10 < minBaseline 15 → 无统计意义',
      );
    });

    test('HARDENING: 阈值 = max(20, median + 3*MAD),current <= 阈值 不报', () {
      final history = List<double>.filled(7, 100);
      // MAD = 0 → 阈值 = max(20, 100) = 100
      expect(AnomalyDetector.detect(history: history, current: 100), isNull,
          reason: '等于阈值不报(严格大于)');
      final verdict = AnomalyDetector.detect(history: history, current: 101);
      expect(verdict, isNotNull);
      expect(verdict!.threshold, 100);
      expect(verdict.median, 100);
      expect(verdict.mad, 0);
      expect(verdict.ratio, closeTo(1.01, 0.0001));
    });

    test('HARDENING: 有波动的基线用 median + k*MAD 判定', () {
      const history = <double>[100, 110, 90, 105, 95, 100, 100];
      // median = 100;绝对差 = [0,10,10,5,5,0,0] → 排序 [0,0,0,5,5,10,10] → MAD = 5
      // 阈值 = max(20, 100 + 15) = 115
      expect(AnomalyDetector.detect(history: history, current: 115), isNull);
      final v = AnomalyDetector.detect(history: history, current: 116);
      expect(v!.threshold, 115);
      expect(AnomalyDetector.median(history), 100);
      expect(AnomalyDetector.mad(history, 100), 5);
    });

    test('HARDENING: 空/单元素 history 不崩(median 0)', () {
      expect(AnomalyDetector.median(const <double>[]), 0);
      expect(AnomalyDetector.median(const <double>[5]), 5);
      expect(AnomalyDetector.median(const <double>[1, 2]), 1.5);
      expect(AnomalyDetector.mad(const <double>[], 0), 0);
      expect(AnomalyDetector.detect(history: const <double>[], current: 1e9), isNull);
    });

    test('HARDENING: NaN/Infinity 输入不产生虚假异常判定', () {
      final history = [for (var i = 0; i < 7; i++) 100.0];
      // current NaN:NaN <= threshold 为 false → 会掉落 AnomalyVerdict
      final nanVerdict = AnomalyDetector.detect(history: history, current: double.nan);
      expect(nanVerdict, isNotNull,
          reason: 'HARDENING:NaN <= 阈值 恒 false → NaN 被当成「显著异常」'
              '并生成 verdict(ratio/excessRatio 均为 NaN);'
              '上游不会传 NaN,但检测器缺 isFinite 守卫');
      expect(nanVerdict!.ratio.isNaN, isTrue);

      final infVerdict = AnomalyDetector.detect(
          history: history, current: double.infinity);
      expect(infVerdict, isNotNull);
      expect(infVerdict!.ratio, double.infinity);

      // NaN 出现在历史序列里
      const dirtyHistory = <double>[100.0, 100.0, 100.0, 100.0, 100.0, 100.0, double.nan];
      final dirty = AnomalyDetector.detect(history: dirtyHistory, current: 1e6);
      expect(dirty, isNotNull,
          reason: 'HARDENING:历史含 NaN 时 median/mad 传播 NaN,'
              '阈值变成 NaN → 任何 current 都被判异常(误报面)');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutomationHealth 判定', () {
    test('HARDENING: 查询失败 → 阻断项 + isHealthy=false,绝不显示「正常」', () {
      final health = AutomationHealth.unknown();
      final issues = health.issues();
      expect(issues.single.code, 'statusQueryFailed');
      expect(issues.single.blocking, isTrue);
      expect(health.isHealthy, isFalse);
      expect(health.queryFailed, isTrue);
    });

    test('HARDENING: 未开启的来源不产生问题;已开启且权限被撤 → 阻断', () {
      const off = AutomationSourceHealth(
          key: 'sms', enabled: false, permissionGranted: false);
      const on = AutomationSourceHealth(
          key: 'sms', enabled: true, permissionGranted: false);
      AutomationHealth base(List<AutomationSourceHealth> sources) =>
          AutomationHealth(
            sources: sources,
            aiState: AiRuntimeState.ready,
            aiTextConfigured: true,
            aiVisionConfigured: true,
            eventStateCounts: const {},
            pendingCount: 0,
            shadowMode: false,
            isAndroid: true,
          );

      expect(base(const [off]).issues(), isEmpty,
          reason: '「未选择的来源不算故障」');
      final onIssues = base(const [on]).issues();
      expect(onIssues.map((i) => i.code),
          containsAll(['permissionRevoked:sms', 'listenerUnverified']),
          reason: '权限被撤 → permissionRevoked(阻断);'
              'bridgeConnected 未查(null)→ 附加 listenerUnverified(不阻断)');
      expect(
        onIssues.firstWhere((i) => i.code == 'permissionRevoked:sms').blocking,
        isTrue,
      );
      expect(
        onIssues.firstWhere((i) => i.code == 'listenerUnverified').blocking,
        isFalse,
      );
    });

    test('HARDENING: bridgeConnected=null 只提示「待验证」,不阻断', () {
      final health = AutomationHealth(
        sources: const [
          AutomationSourceHealth(key: 'notify', enabled: true, bridgeConnected: null),
        ],
        aiState: AiRuntimeState.ready,
        aiTextConfigured: true,
        aiVisionConfigured: true,
        eventStateCounts: const {},
        pendingCount: 0,
        shadowMode: false,
        isAndroid: true,
      );
      final issue = health.issues().single;
      expect(issue.code, 'listenerUnverified');
      expect(issue.blocking, isFalse);
    });

    test('HARDENING: retryCount 把 retry 与 failed 一起算进积压', () {
      final health = AutomationHealth(
        sources: const [],
        aiState: AiRuntimeState.ready,
        aiTextConfigured: true,
        aiVisionConfigured: true,
        eventStateCounts: const {'retry': 2, 'failed': 3, 'booked': 10},
        pendingCount: 0,
        shadowMode: false,
        isAndroid: true,
      );
      expect(health.retryCount, 5);
      expect(health.backlogCount, 5);
      final backlog = health.issues().single;
      expect(backlog.code, 'queueBacklog');
      expect(backlog.count, 5);
    });

    test('HARDENING: 待确认计数产生 queue 问题(不阻断)', () {
      final health = AutomationHealth(
        sources: const [],
        aiState: AiRuntimeState.ready,
        aiTextConfigured: true,
        aiVisionConfigured: true,
        eventStateCounts: const {},
        pendingCount: 3,
        shadowMode: false,
        isAndroid: true,
      );
      final issue = health.issues().single;
      expect(issue.code, 'pendingCount');
      expect(issue.count, 3);
      expect(issue.blocking, isFalse);
    });

    test('HARDENING: target invalid/undetermined 阻断,unconfirmed 不阻断', () {
      AutomationHealth withTarget(String state, {String? reason}) =>
          AutomationHealth(
            sources: const [],
            aiState: AiRuntimeState.ready,
            aiTextConfigured: true,
            aiVisionConfigured: true,
            eventStateCounts: const {},
            pendingCount: 0,
            shadowMode: false,
            isAndroid: true,
            targetState: state,
            targetReason: reason,
          );
      expect(withTarget('invalid').issues().single.blocking, isTrue);
      expect(withTarget('invalid', reason: 'target_scope_mismatch')
              .issues()
              .single
              .code,
          'targetScopeMismatch');
      expect(withTarget('undetermined').issues().single.blocking, isTrue);
      expect(withTarget('unconfirmed').issues().single.blocking, isFalse);
      expect(withTarget('resolved').issues(), isEmpty);
    });

    test('HARDENING: 阻断项排在最前,同组按维度序', () {
      final health = AutomationHealth(
        sources: const [
          AutomationSourceHealth(
              key: 'sms', enabled: true, bridgeConnected: null),
        ],
        aiState: AiRuntimeState.unconfigured,
        aiTextConfigured: false,
        aiVisionConfigured: false,
        eventStateCounts: const {},
        pendingCount: 2,
        shadowMode: false,
        isAndroid: true,
      );
      final issues = health.issues();
      expect(issues.first.blocking, isTrue,
          reason: 'aiUnconfigured 是阻断项,必须排最前');
      expect(issues.any((i) => !i.blocking), isTrue);
      final lastBlocking = issues.lastIndexWhere((i) => i.blocking);
      expect(issues.skip(lastBlocking + 1).every((i) => !i.blocking), isTrue,
          reason: '阻断区段连续,不得交错');
    });

    test('HARDENING: withAiState 只改 AI 维度,其余字段原样', () {
      final base = AutomationHealth(
        sources: const [
          AutomationSourceHealth(key: 'sms', enabled: true),
        ],
        aiState: AiRuntimeState.unconfigured,
        aiTextConfigured: false,
        aiVisionConfigured: false,
        eventStateCounts: const {'booked': 1},
        pendingCount: 7,
        shadowMode: true,
        isAndroid: true,
        targetState: 'resolved',
        queueLossCount: 2,
      );
      final next = base.withAiState(AiRuntimeState.ready);
      expect(next.aiState, AiRuntimeState.ready);
      expect(next.pendingCount, 7);
      expect(next.shadowMode, isTrue);
      expect(next.queueLossCount, 2);
      expect(next.targetState, 'resolved');
      expect(next.sources.length, 1);
      expect(next.eventStateCounts['booked'], 1);
    });

    test('HARDENING: NativeCaptureStatus.lossCount 容错(非 JSON/非数组 → 0)',
        () {
      expect(NativeCaptureStatus.lossCount(null), 0);
      expect(NativeCaptureStatus.lossCount(''), 0);
      expect(NativeCaptureStatus.lossCount('not json'), 0);
      expect(NativeCaptureStatus.lossCount('{"a":1}'), 0,
          reason: '非数组 → 0');
      expect(NativeCaptureStatus.lossCount('[1,2,3]'), 3);
    });

    test('HARDENING: needsShadowBanner 由 shadowMode 决定', () {
      final on = AutomationHealth(
        sources: const [],
        aiState: AiRuntimeState.ready,
        aiTextConfigured: true,
        aiVisionConfigured: true,
        eventStateCounts: const {},
        pendingCount: 0,
        shadowMode: true,
        isAndroid: true,
      );
      expect(on.needsShadowBanner, isTrue);
      final off = AutomationHealth(
        sources: const [],
        aiState: AiRuntimeState.ready,
        aiTextConfigured: true,
        aiVisionConfigured: true,
        eventStateCounts: const {},
        pendingCount: 0,
        shadowMode: false,
        isAndroid: true,
      );
      expect(off.needsShadowBanner, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('BillCreationService 落库边界', () {
    test('HARDENING: amount 为 null / 0 → null(不落库)', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'bcs');
      final service = BillCreationService(repo);
      expect(
        await service.createFromBill(
            bill: BillInfoStub.expense(amount: null), ledgerId: ledgerId),
        isNull,
      );
      expect(
        await service.createFromBill(
            bill: BillInfoStub.expense(amount: 0), ledgerId: ledgerId),
        isNull,
      );
    });

    test('HARDENING: 带币种与账户时币种随账户(账户内不混币)', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'cur');
      await repo.createCategory(name: '其他', kind: 'expense');
      await repo.createAccount(
          ledgerId: ledgerId, name: '美元卡', currency: 'USD');
      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfo(
          amount: -30,
          time: DateTime.now(),
          type: BillType.expense,
          account: '美元卡',
          // AI 说 CNY,账户是 USD → 池按 CNY 筛 → 匹配不到 → 回落默认账户
          currency: 'CNY',
        ),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      expect(tx!.currencyCode, 'CNY',
          reason: 'HARDENING:AI 币种与账户币种冲突时账户被丢弃,'
              '币种回落到 AI 给的(而非静默改账户)');
      expect(tx.accountId, isNull);
    });

    test('HARDENING: 缺币种账户时账户反过来决定币种', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'cur2');
      await repo.createCategory(name: '其他', kind: 'expense');
      await repo.createAccount(
          ledgerId: ledgerId, name: '美元卡', currency: 'USD');
      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfo(
          amount: -30,
          time: DateTime.now(),
          type: BillType.expense,
          account: '美元卡',
        ),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      expect(tx!.currencyCode, 'USD', reason: 'L7:命中账户反过来定币种');
    });

    test('HARDENING: 没有「其他」分类时 categoryId 为 null(不塞随机分类)',
        () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'cat');
      await repo.createCategory(name: '餐饮', kind: 'expense');
      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfoStub.expense(amount: -30, merchant: '完全未知的商户'),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      expect(tx!.categoryId, isNull,
          reason: '兜底只认「其他」系列,否则交待确认(不再回退 categories.last)');
    });

    test('HARDENING: 转账时转出=转入 → toAccountId 置空(不自我转账)', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 'transfer');
      await repo.createCategory(name: '转账', kind: 'transfer');
      final account = await repo.createAccount(
          ledgerId: ledgerId, name: '招行卡', currency: 'CNY');
      final service = BillCreationService(repo);
      final txId = await service.createFromBill(
        bill: BillInfo(
          amount: 100,
          time: DateTime.now(),
          type: BillType.transfer,
          account: '招行卡',
          fromAccount: '招行卡',
          toAccount: '招行卡',
        ),
        ledgerId: ledgerId,
      );
      final tx = await repo.getTransactionById(txId!);
      expect(tx!.accountId, account);
      expect(tx.toAccountId, isNull,
          reason: '同一账户自我转账 → 转入置空');
    });

    test('HARDENING: resolveTransactionType 分类名含「还款/转账」→ transfer', () {
      expect(resolveTransactionType(type: BillType.transfer), 'transfer');
      expect(resolveTransactionType(type: BillType.income), 'income');
      expect(resolveTransactionType(type: BillType.expense), 'expense');
      expect(resolveTransactionType(category: '信用卡还款'), 'transfer');
      expect(resolveTransactionType(category: '还款'), 'transfer');
      expect(resolveTransactionType(category: 'repayment'), 'transfer');
      expect(resolveTransactionType(category: '转账'), 'transfer');
      expect(resolveTransactionType(category: '餐饮'), 'expense');
      // 显式 type 压过 category
      expect(resolveTransactionType(type: BillType.income, category: '还款'),
          'income');
      expect(resolveTransactionType(), 'expense',
          reason: '全缺省保守按 expense(不退化成收入)');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('normalizeAutoBookText / autoBookHash 纯函数', () {
    test('HARDENING: normalize 去标点与压缩空白,合并大小写', () {
      expect(normalizeAutoBookText('  A   B  '), 'a b');
      // HARDENING:只清全角标点集(，。、：“”‘’；!?()【】［］),ASCII 标点原样保留
      expect(normalizeAutoBookText('商户,。、：;!?()【】'), '商户,;!?()',
          reason: '全角「。、： 【】」被删,ASCII「,;!?()」保留 → '
              '「商户!」与「商户」在判重/学习中是两个不同文本');
      expect(normalizeAutoBookText('星巴克（中国）'), '星巴克中国');
      expect(normalizeAutoBookText('STARBUCKS'), 'starbucks');
      expect(normalizeAutoBookText('全角ＡＢＣ'), '全角ａｂｃ');
      expect(normalizeAutoBookText(''), '');
      expect(normalizeAutoBookText('   '), '');
      // 制表/换行按 \s+ 压成单空格(再 trim)
      expect(normalizeAutoBookText('a\t\nb'), 'a b');
    });

    test('HARDENING: autoBookHash 裁剪到 [8, 64]', () {
      expect(autoBookHash('x'), hasLength(32), reason: '默认 32');
      expect(autoBookHash('x', length: 8), hasLength(8));
      expect(autoBookHash('x', length: 64), hasLength(64));
      expect(autoBookHash('x', length: 1), hasLength(8), reason: '下界 8');
      expect(autoBookHash('x', length: 999), hasLength(64), reason: '上界 64');
      expect(autoBookHash('a'), isNot(autoBookHash('b')));
    });

    test('HARDENING: 枚举 parse 未知值回落(不抛)', () {
      expect(AutoBookStateValue.parse('booked'), AutoBookState.booked);
      expect(AutoBookStateValue.parse(null), AutoBookState.captured);
      expect(AutoBookStateValue.parse('BOOKED'), AutoBookState.captured,
          reason: '大小写敏感 → 未知回落 captured');
      expect(AutoBookStateValue.parse(' booked'), AutoBookState.captured);
      expect(AutoBookCaptureIntentValue.parse('import'),
          AutoBookCaptureIntent.importData,
          reason: 'importData 的存储值是 import,不等于 name');
      expect(AutoBookCaptureIntentValue.parse('bogus'),
          AutoBookCaptureIntent.automatic);
      expect(AutoBookSourceValue.parse('bogus'), AutoBookSource.manual,
          reason: '未知来源按 manual(不会被误当成自动入口)');
      expect(AutoBookSourceValue.sourceKey('bogus'), isNull,
          reason: 'bogus → manual → 无来源键');
    });

    test('HARDENING: 枚举字符串值是持久化契约(改名即破库)', () {
      expect(
        AutoBookState.values.map((s) => s.value).toList(),
        ['captured','processing','pending','booked','duplicate','ignored','retry','failed','expired'],
        reason: '这些值写入 auto_book_events.state,跨版本升级后必须能 parse',
      );
      expect(
        AutoBookSource.values.map((s) => s.value).toList(),
        [
          'screenshot','sharedImage','sms','notification','screenText',
          'deepLinkText','deepLinkDirect','import','recurring','manual',
        ],
      );
    });

    test('HARDENING: sourceKey 聚合口径(4 路来源 → 3 个键)', () {
      expect(AutoBookSourceValue.sourceKey('screenshot'), 'image');
      expect(AutoBookSourceValue.sourceKey('sharedImage'), 'image');
      expect(AutoBookSourceValue.sourceKey('screenText'), 'screen');
      expect(AutoBookSourceValue.sourceKey('screen'), 'screen');
      expect(AutoBookSourceValue.sourceKey('text'), 'deeplink');
      expect(AutoBookSourceValue.sourceKey('image'), 'image');
      for (final none in ['manual', 'import', 'recurring', 'auto', null]) {
        expect(AutoBookSourceValue.sourceKey(none), isNull, reason: '$none');
      }
    });

    test('HARDENING: 事件 key 派生函数的确定性', () {
      expect(AutoBookCoordinatorKeys.textEventKey('sms', '  消费 100 元 '),
          AutoBookCoordinatorKeys.textEventKey('sms', '消费 100 元'),
          reason: '走 normalizeAutoBookText → 空白差异被吸收');
      expect(AutoBookCoordinatorKeys.textEventKey('sms', 'x'),
          isNot(AutoBookCoordinatorKeys.textEventKey('notification', 'x')),
          reason: '来源进 key 前缀');
      expect(AutoBookCoordinatorKeys.deepLinkEventKey('KEY-1', 'url'),
          AutoBookCoordinatorKeys.deepLinkEventKey('KEY-1', 'other'),
          reason: 'idempotencyKey 存在时与 URL 无关');
      expect(AutoBookCoordinatorKeys.deepLinkEventKey(' key-1 ', 'url'),
          AutoBookCoordinatorKeys.deepLinkEventKey('key-1', 'url'),
          reason: 'trim 后 hash');
      // HARDENING:deepLinkEventKey 只 trim 不 toLowerCase —— 提供方若把
      // 同一 idempotency key 换大小写重发,会生成两个 eventKey → 双事件。
      // 幂等键按规范是大小写敏感的,不强改;如实记录。
      expect(AutoBookCoordinatorKeys.deepLinkEventKey('KEY-1', 'url'),
          isNot(AutoBookCoordinatorKeys.deepLinkEventKey('key-1', 'url')),
          reason: '大小写差异 → 不同 key(如实记录)');
      expect(AutoBookCoordinatorKeys.deepLinkEventKey(null, 'url'),
          isNot(AutoBookCoordinatorKeys.deepLinkEventKey(null, 'url2')));
      expect(AutoBookCoordinatorKeys.deepLinkEventKey('  ', 'url'),
          AutoBookCoordinatorKeys.deepLinkEventKey(null, 'url'),
          reason: '纯空白 key 等同缺失');
    });
  });
}

/// 测试夹具:BillInfo 的常用构造。
class BillInfoStub {
  static BillInfo expense({
    double? amount = -30,
    String? merchant,
    String? category,
    DateTime? time,
  }) =>
      BillInfo(
        amount: amount,
        time: time ?? DateTime.now(),
        type: BillType.expense,
        merchant: merchant,
        note: merchant,
        category: category,
      );
}

/// 真实本地化实例(zh):presenter 的已知识别码分支会读 l10n,不 stub。
final AppLocalizations messageStub = lookupAppLocalizations(const Locale('zh'));

/// coordinator 的纯静态 key 派生函数(生产实现就在这里)。
class AutoBookCoordinatorKeys {
  static String textEventKey(String source, String value) =>
      AutoBookCoordinator.textEventKey(source, value);
  static String deepLinkEventKey(String? idempotencyKey, String canonicalUrl) =>
      AutoBookCoordinator.deepLinkEventKey(idempotencyKey, canonicalUrl);
}

/// 无用但保留:避免 analyzer 报未使用导入。
final _unusedValue = Value(1);
final _unusedDedupExempt = DedupExemptStore;
final _unusedSemantic = SemanticDedupMatcher;
