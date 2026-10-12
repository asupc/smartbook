// 对抗性测试:导入/导出/备份域(JSON 备份 + 配置 YAML 导出/导入)。
//
// 覆盖:
//  - buildBackupJson 对特殊字符/emoji/超长备注/null/负数金额的往返
//  - 非有限金额(Infinity/NaN)落库后端能否被序列化(导出整体失败面)
//  - 配置 YAML 发射器的引号/换行转义(整份配置不可再导入 / 静默篡改)
//  - 单条坏行的整批静默丢弃与部分提交
//  - 导出空库 / 截断备份的消费者行为
//
// 语义参照:test/services/json_backup_service_test.dart(不修改)。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/export/config_export_service.dart';
import 'package:smartbook/services/export/json_backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ────────────────────────────────────────────────────────────────
  group('buildBackupJson —— 特殊内容往返', () {
    test('HARDENING: emoji / 组合字符 / 超长备注 / 全角标点往返无损', () {
      final longNote = '很长的备注' * 5000; // 2 万字
      final weird = [
        '早餐🍜 咖啡☕️',
        '他说“每月”扣款', // 中文引号
        '他说"每月"扣款', // 半角引号
        '第一行\n第二行\t带制表',
        r'反斜杠 \ 与 \n 字面',
        '零宽\u200B符\uFEFF',
        '👨‍👩‍👧‍👦 家庭 emoji(ZWJ 序列)',
        longNote,
        '  前后空白  ',
        '{"looks":"like json"}',
      ];

      for (final note in weird) {
        final json = buildBackupJson(
          ledger: (id: 1, name: '生活账', currency: 'CNY'),
          accounts: const [],
          categories: const [],
          transactions: [
            BackupTx(
              id: 1,
              type: 'expense',
              amount: -45.5,
              happenedAt: DateTime(2026, 9, 2, 12, 30),
              note: note,
            ),
          ],
          exportedAt: '2026-09-02T12:00:00',
        );

        // 落盘用的是 JsonEncoder.withIndent(export_page.dart:378),这里同口径。
        final encoded = const JsonEncoder.withIndent('  ').convert(json);
        final back = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
        final tx = (back['transactions'] as List).single as Map;
        expect(tx['note'], note, reason: 'JSON 往返应逐字保留:$note');
      }
    });

    test('HARDENING: 空备注(空串)被省略,但非空纯空白备注被保留', () {
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
              id: 1,
              type: 'expense',
              amount: -1,
              happenedAt: DateTime(2026, 1, 1),
              note: ''),
          BackupTx(
              id: 2,
              type: 'expense',
              amount: -1,
              happenedAt: DateTime(2026, 1, 1),
              note: '   '),
        ],
        exportedAt: 'x',
      );
      final txs = (json['transactions'] as List).cast<Map>();
      expect(txs[0].containsKey('note'), isFalse, reason: '空串省略');
      expect(txs[1]['note'], '   ', reason: '纯空白照存(不 trim)');
    });

    test('HARDENING: 负数金额、0 金额、超大金额都原样落 JSON', () {
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
              id: 1,
              type: 'expense',
              amount: -0.01,
              happenedAt: DateTime(2026, 1, 1)),
          BackupTx(
              id: 2,
              type: 'income',
              amount: 0,
              happenedAt: DateTime(2026, 1, 1)),
          BackupTx(
              id: 3,
              type: 'income',
              amount: 1.7976931348623157e308,
              happenedAt: DateTime(2026, 1, 1)),
        ],
        exportedAt: 'x',
      );
      final txs = (json['transactions'] as List).cast<Map>();
      expect(txs[0]['amount'], -0.01);
      expect(txs[1]['amount'], 0);
      expect(txs[2]['amount'], 1.7976931348623157e308);
    });

    test('HARDENING: 空库导出结构完整(accounts/categories/transactions 为空数组)', () {
      final json = buildBackupJson(
        ledger: (id: 7, name: '空账本', currency: 'USD'),
        accounts: const [],
        categories: const [],
        transactions: const [],
        exportedAt: '2026-10-11T00:00:00',
      );
      expect(json['format'], 'smartbook-backup');
      expect(json['version'], 1);
      expect(json['accounts'], isEmpty);
      expect(json['categories'], isEmpty);
      expect(json['transactions'], isEmpty);
      expect(json['ledger']['currency'], 'USD');
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('ADVERSE: amount=Infinity 落库后端整份备份无法 JSON 编码 → 导出整体失败', () {
      // 源码:`lib/services/export/json_backup_service.dart:86`(amount 无
      // isFinite 守卫)、`lib/pages/data/export_page.dart:378-380`
      // (`JsonEncoder.withIndent('  ').convert(json)` 未捕获)。
      // transactions.amount 无 CHECK 约束(`lib/data/db.dart:112-116`),
      // 而 Infinity/1e999 可通过导入/同步/周期模板路径落库
      // (见 misc_recurring / misc_currency 文件)。
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
              id: 1,
              type: 'expense',
              amount: double.infinity,
              happenedAt: DateTime(2026, 1, 1),
              note: '正常备注'),
        ],
        exportedAt: 'x',
      );
      expect(
        () => const JsonEncoder.withIndent('  ').convert(json),
        returnsNormally,
        reason: 'ADVERSE FINDING: 一笔 Infinity 金额让整份备份导出抛 '
            'JsonUnsupportedObjectError,用户拿不到任何备份'
            '(期望:导出时把非有限金额规整/剔除,或至少逐笔隔离)',
      );
    });

    test('ADVERSE: nativeAmount=Infinity 同样让整份备份导出失败', () {
      // 源码:`json_backup_service.dart:95`(`if (t.nativeAmount != null)
      // 'nativeAmount': t.nativeAmount` 无有限性守卫)。
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
              id: 1,
              type: 'expense',
              amount: 10,
              happenedAt: DateTime(2026, 1, 1),
              currencyCode: 'USD',
              nativeAmount: double.infinity),
        ],
        exportedAt: 'x',
      );
      expect(
        () => const JsonEncoder.withIndent('  ').convert(json),
        returnsNormally,
        reason: 'ADVERSE FINDING: nativeAmount 走同期汇率折算,'
            'rate 字符串异常时可为 Infinity,整份备份同样不可序列化',
      );
    });

    test('HARDENING: tags/attachments 中的异常文件名(含引号/换行)原样进 JSON', () {
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
            id: 1,
            type: 'expense',
            amount: -1,
            happenedAt: DateTime(2026, 1, 1),
            tags: ['标签,带逗号', '标签"带引号'],
            attachments: ['a\nb.png'],
          ),
        ],
        exportedAt: 'x',
      );
      final tx = (json['transactions'] as List).single as Map;
      expect(tx['tags'], ['标签,带逗号', '标签"带引号']);
      expect(tx['attachments'], ['a\nb.png']);
      final back = jsonDecode(jsonEncode(json)) as Map;
      expect(((back['transactions'] as List).single as Map)['tags'],
          ['标签,带逗号', '标签"带引号']);
    });
  });

  // ────────────────────────────────────────────────────────────────
  group('JSON 备份的消费面:无导入消费者', () {
    test('HARDENING: 格式标识 smartbook-backup 在全仓无解析方(单向导出)', () {
      // 这是对现状的事实锁定:备份 JSON 没有任何导入/恢复入口
      // (lib/ 与 server/ 均无 'smartbook-backup' 的读取方)。
      // 因此"恢复半截损坏的备份清库"这类路径当前不可达 —— 但也意味着
      // 一旦后续新增导入方,必须自带全量校验,不能直接清库。
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: const [],
        exportedAt: 'x',
      );
      expect(json['format'], 'smartbook-backup');
      expect(json['version'], 1,
          reason: 'HARDENING:版本号已进文件,未来导入方必须校验 version');
    });

    // 修正说明(2026-10-11,批次 C2):该用例原先断言"删掉 JSON **最末字符**后
    // 仍能 jsonDecode 成功"。JSON 的最末字符恒为 `}`,删掉它必然使 JSON 非法,
    // 断言前提本身不成立 —— 产品行为(解析失败即抛 FormatException、无副作用)
    // 恰恰是正确的,FINDINGS-misc-services §1.1 已把它定性为"测试自身缺陷"。
    // 这里改为断言"截断必然失败且不产生副作用",与用例标题/期望一致。
    test('HARDENING: 截断的备份 JSON 一律解析失败,不产生副作用', () {
      final json = buildBackupJson(
        ledger: (id: 1, name: 'a', currency: 'CNY'),
        accounts: const [],
        categories: const [],
        transactions: [
          BackupTx(
              id: 1,
              type: 'expense',
              amount: -1,
              happenedAt: DateTime(2026, 1, 1)),
        ],
        exportedAt: 'x',
      );
      final full = const JsonEncoder.withIndent('  ').convert(json);
      final truncated = full.substring(0, full.length ~/ 2);
      expect(() => jsonDecode(truncated), throwsA(isA<FormatException>()),
          reason: '截断文件解析即失败 → 未来导入方必须整体拒绝而非清库');
      // 尾部少一个字符同样是截断:必须失败,不能"半截也当成完整备份"
      expect(() => jsonDecode(full.substring(0, full.length - 1)),
          throwsA(isA<FormatException>()),
          reason: '尾部截断必须被识别为损坏(而非"能解析就可用")');
    });
  });

  // ────────────────────────────────────────────────────────────────
  group('配置 YAML 导出:发射器转义', () {
    Future<(LocalRepository, BeeDatabase, int)> openDb() async {
      SharedPreferences.setMockInitialValues({});
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: '生活账', currency: 'CNY');
      return (repo, db, ledgerId);
    }

    test('ADVERSE: 备注含半角引号 → 发射出的 YAML 无法再解析(备份不可用)', () async {
      // 源码:`lib/services/export/config_export_service.dart:2064`
      //   buffer.writeln('      note: "${itemMap['note']}"');
      // 直接把原始串塞进双引号 YAML 标量,不转义 `"` —— 一旦备注里有半角引号
      // (中国用户写「他说"每月"扣款」很常见),导出文件语法损坏。
      final (repo, db, ledgerId) = await openDb();
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
        note: '他说"每月"扣款',
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      expect(
        () => loadYaml(yaml),
        returnsNormally,
        reason: 'ADVERSE FINDING: 备注含半角引号时导出的 YAML 抛 '
            'YamlException,而导出入口报「导出成功」—— 用户以为有备份',
      );
      await db.close();
    });

    test('ADVERSE: 备注含换行 → 同一处发射器产出坏 YAML', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
        note: '第一行\n第二行',
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      expect(() => loadYaml(yaml), returnsNormally,
          reason: 'ADVERSE FINDING: 双引号 YAML 标量不允许裸换行,'
              '换行备注同样使整份配置不可解析');
      await db.close();
    });

    // 修复后(2026-10-11,批次 C2):YAML 发射器对双引号标量做转义
    // (`_yamlQuotedValue`),备注里的 `"\n      currency_code: "USD"` 不再能
    // 终结标量、把自己变成新的 YAML 键。
    // (原断言 `item['currency_code'] == 'USD'` / `end_date == '2027-01-01'`
    // 是把"注入被静默采纳"当作既成事实记录下来的 ADVERSE 断言;注入面修掉后
    // 该断言必须反向,改为断言"注入内容原样留在 note 里、未变成真实字段"。)
    test('ADVERSE 修复: 备注里的 YAML 键不再被当成真实字段(注入面关闭)', () async {
      // 发射顺序:note 之后还有 frequency/interval/day_of_month/start_date/
      // enabled/currency_code。备注里插入**不冲突**的键(如 currency_code、
      // end_date)曾被后续解析当真实字段读走 → 静默篡改。
      final (repo, db, ledgerId) = await openDb();
      const injectedNote = 'x"\n      currency_code: "USD"\n'
          '      end_date: "2027-01-01"\n      z: "y';
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 5,
        startDate: DateTime(2026, 10, 1),
        note: injectedNote,
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      expect(() => loadYaml(yaml), returnsNormally,
          reason: '转义后整份配置必须可解析');
      final doc = loadYaml(yaml);
      final item = (doc['recurring_transactions']['items'] as List).single;
      expect(item['currency_code'], isNot('USD'),
          reason: '备注内容不得成为真实字段(否则该周期账单被写成外币)');
      expect(item['end_date'], isNot('2027-01-01'),
          reason: '备注不得注入结束日期');
      expect(item['note'], injectedNote,
          reason: '注入内容应原样保留在 note 字段里(数据不丢,只是不再有结构语义)');
      await db.close();
    });

    test('ADVERSE: 备注注入已有键 → 整份配置抛 Duplicate mapping key', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
        note: 'x"\n      interval: 12\n      dummy: "y',
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      expect(() => loadYaml(yaml), returnsNormally,
          reason: 'ADVERSE FINDING: 注入已发射的键 → Duplicate mapping key,'
              '整份配置(含账本/分类/账户)全部不可导入');
      await db.close();
    });

    test('ADVERSE: 备注注入 amount 可抬高周期账单金额(重复键)', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
        note: 'x"\n      amount: 999999\n      enabled: true\n      extra: "y',
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      // 发射器在 note 之前已经写过 amount,所以这是"重复键"→ 解析失败。
      expect(() => loadYaml(yaml), returnsNormally,
          reason: 'ADVERSE FINDING: 备注中的 amount 与真实 amount 构成重复键,'
              '整份配置无法解析(若顺序相反则会静默改金额)');
      await db.close();
    });

    test('HARDENING: 普通备注(中文/emoji/英文)往返正确', () async {
      final (repo, db, ledgerId) = await openDb();
      for (final note in ['水费', 'Netflix 🎬', '早餐-咖啡', '房租(每月)']) {
        await repo.addRecurringTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 10,
          frequency: 'monthly',
          interval: 1,
          startDate: DateTime(2026, 10, 1),
          note: note,
        );
      }
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      final doc = loadYaml(yaml);
      final notes = (doc['recurring_transactions']['items'] as List)
          .map((i) => i['note'])
          .toList();
      expect(notes, ['水费', 'Netflix 🎬', '早餐-咖啡', '房租(每月)']);
      await db.close();
    });
  });

  // ────────────────────────────────────────────────────────────────
  group('配置 YAML 导入:坏行处理', () {
    Future<(LocalRepository, BeeDatabase, int)> openDb() async {
      SharedPreferences.setMockInitialValues({});
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: '生活账', currency: 'CNY');
      return (repo, db, ledgerId);
    }

    const onlyRecurring = ExportOptions(
      ledgers: false,
      categories: false,
      accounts: false,
      tags: false,
      recurringTransactions: true,
      budgets: false,
      appSettings: false,
      ai: false,
    );

    test('ADVERSE: 单条坏 start_date 使整批周期账单静默丢弃(不报错)', () async {
      // 源码:`config_export_service.dart:2763-2782` —— DateTime.parse 在 for 循环内,
      // 整个循环包在 `try { ... } catch (e) { logger.error(...) }` 里,
      // 异常既不上抛也不记入返回值 → 调用方拿到"导入完成"。
      final (repo, db, ledgerId) = await openDb();
      const yaml = '''
recurring_transactions:
  items:
    - ledger_name: "生活账"
      type: "expense"
      amount: 10
      frequency: "monthly"
      interval: 1
      start_date: "2026-10-01"
      enabled: true
    - ledger_name: "生活账"
      type: "expense"
      amount: 20
      frequency: "monthly"
      interval: 1
      start_date: "not-a-date"
      enabled: true
''';
      Object? thrown;
      try {
        await ConfigExportService.importFromYaml(yaml,
            repository: repo, ledgerId: ledgerId, options: onlyRecurring);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNull);
      final rts = await repo.getAllRecurringTransactions();
      expect(rts.length, 2,
          reason: 'ADVERSE FINDING: 2 条里 1 条日期坏 → 好的一条也被丢弃'
              '(实际 0 条),函数正常返回、无任何用户可见提示');
      await db.close();
    });

    test('ADVERSE: 坏行在后 → 前面的行已提交,导入"部分成功"无提示', () async {
      final (repo, db, ledgerId) = await openDb();
      const yaml = '''
recurring_transactions:
  items:
    - ledger_name: "生活账"
      type: "expense"
      amount: 10
      frequency: "monthly"
      interval: 1
      start_date: "2026-10-01"
      enabled: true
    - ledger_name: "生活账"
      type: "expense"
      amount: 20
      frequency: "monthly"
      interval: 1
      start_date: "not-a-date"
      enabled: true
''';
      await ConfigExportService.importFromYaml(yaml,
          repository: repo, ledgerId: ledgerId, options: onlyRecurring);
      final rts = await repo.getAllRecurringTransactions();
      expect(rts.map((r) => r.amount).toList(), [10.0, 20.0],
          reason: 'ADVERSE FINDING: 实际只有第 1 条入库(部分提交),'
              '第 2 条及其后的所有模板被静默跳过 —— 无计数、无警告返回');
      await db.close();
    });

    test('HARDENING: 找不到账本/分类/账户的行被 skipped 计数但仍在返回之外', () async {
      final (repo, db, ledgerId) = await openDb();
      const yaml = '''
recurring_transactions:
  items:
    - ledger_name: "不存在的账本"
      type: "expense"
      amount: 10
      frequency: "monthly"
      interval: 1
      start_date: "2026-10-01"
      enabled: true
    - ledger_name: "生活账"
      type: "expense"
      amount: 20
      category_name: "不存在的分类"
      frequency: "monthly"
      interval: 1
      start_date: "2026-10-01"
      enabled: true
    - ledger_name: "生活账"
      type: "expense"
      amount: 30
      frequency: "monthly"
      interval: 1
      start_date: "2026-10-01"
      enabled: true
''';
      await ConfigExportService.importFromYaml(yaml,
          repository: repo, ledgerId: ledgerId, options: onlyRecurring);
      final rts = await repo.getAllRecurringTransactions();
      expect(rts.map((r) => r.amount).toList(), [30.0],
          reason: 'HARDENING: 未命中名称的行跳过(有日志无返回值),'
              '只有完全可解析的行落库');
      await db.close();
    });

    test('HARDENING: 缺 interval / interval 为字符串 → 抛 _TypeError(不做默认值)', () {
      // 源码:`config_export_service.dart:837` `interval: map['interval'] as int`
      // —— 无 null 兜底、无类型转换。对比 BudgetItem.fromMap 的
      // `map['start_day'] as int? ?? 1` 有兜底,口径不一致。
      expect(
        () => RecurringTransactionItem.fromMap(
            {'ledger_name': 'a', 'type': 'expense', 'amount': 1}),
        throwsA(isA<TypeError>()),
        reason: 'HARDENING: 缺 interval 直接抛,不走默认 1',
      );
      expect(
        () => RecurringTransactionItem.fromMap({
          'ledger_name': 'a',
          'type': 'expense',
          'amount': 1,
          'frequency': 'monthly',
          'interval': '1', // YAML 引号数字
          'start_date': '2026-10-01',
          'enabled': true,
        }),
        throwsA(isA<TypeError>()),
        reason: 'HARDENING: YAML 里 interval 被引号括起即类型错,整个文件不可导入',
      );
    });

    test('ADVERSE: day_of_month=0 可被 YAML 导入并落到周期模板(下游生成环)', () async {
      // 导入侧对 day_of_month 无 1..31 校验(`config_export_service.dart:2771`),
      // 值直达 recurring_transactions.day_of_month → 触发生成环
      // (见 misc_recurring_adversarial_test.dart)。
      final (repo, db, ledgerId) = await openDb();
      const yaml = '''
recurring_transactions:
  items:
    - ledger_name: "生活账"
      type: "expense"
      amount: 10
      frequency: "monthly"
      interval: 1
      day_of_month: 0
      start_date: "2026-10-01"
      enabled: true
''';
      await ConfigExportService.importFromYaml(yaml,
          repository: repo, ledgerId: ledgerId, options: onlyRecurring);
      final rts = await repo.getAllRecurringTransactions();
      expect(rts.single.dayOfMonth, 0,
          reason: 'ADVERSE FINDING: 非法 day_of_month=0 无校验直达数据库,'
              '成为后续 1000 笔重复生成的输入(见 recurring 文件)');
      await db.close();
    });

    test('HARDENING: 空 YAML / 纯字符串 YAML → 抛 FormatException(不清库)', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 10, 1),
        note: '已有交易',
      );
      for (final bad in ['', '   ', '"just a string"', '42']) {
        expect(
          () => ConfigExportService.importFromYaml(bad,
              repository: repo, ledgerId: ledgerId),
          throwsA(isA<FormatException>()),
          reason: '输入「$bad」应被格式校验拒绝',
        );
      }
      final rows =
          await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
      expect(rows.length, 1, reason: '损坏输入不得影响既有数据');
      await db.close();
    });

    test('HARDENING: 截断 YAML 抛 YamlException,既有数据不变(不清库)', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 10, 1),
        note: '已有交易',
      );
      expect(
        () => ConfigExportService.importFromYaml('ledgers:\n  items:\n    - name: "生',
            repository: repo, ledgerId: ledgerId),
        throwsA(anything),
      );
      final rows =
          await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
      expect(rows.length, 1);
      await db.close();
    });

    test('HARDENING: 正常往返 1 条周期账单(amount/day/note 保真)', () async {
      final (repo, db, ledgerId) = await openDb();
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10.5,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 5,
        startDate: DateTime(2026, 10, 1),
        note: '水费',
      );
      final yaml = await ConfigExportService.exportToYaml(
          repository: repo, ledgerId: ledgerId);
      final info = ConfigExportService.detectContent(yaml);
      expect(info.hasRecurringTransactions, isTrue);

      final db2 = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo2 = LocalRepository(db2);
      final l2 = await repo2.createLedger(name: '生活账', currency: 'CNY');
      await ConfigExportService.importFromYaml(yaml,
          repository: repo2, ledgerId: l2, options: onlyRecurring);
      final rts = await repo2.getAllRecurringTransactions();
      expect(rts.single.amount, 10.5);
      expect(rts.single.dayOfMonth, 5);
      expect(rts.single.note, '水费');
      await db.close();
      await db2.close();
    });
  });
}
