// 杂项域补测(批次 X2):配置 YAML 换行/制表往返(探测发现 1)。
//
// FINDINGS-misc-services.md §二.1:探测实测「双引号标量内的换行在解析时折叠为
// 空格(`第一行\n第二行` → 回读 `第一行 第二行`)」,既有测试把该用例标为 ADVERSE
// 但断言只是「可解析」(通过),未捕捉这一**静默内容损坏**。
//
// 现状(2026-10-11 批次 C2 后):`_yamlQuotedValue` 已对 `"`/`\`/换行/制表/回车
// 做转义,往返无损。本文件把「无损」固化为回归护栏 —— 一旦发射器退回裸插值,
// 该组立即变红。
//
// 与 `test/adversarial/misc_json_backup_adversarial_test.dart` 的边界:
// 后者锁「可解析/不可注入」;本文件锁**内容保真**(往返逐字相等)。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/export/config_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<(BeeDatabase, LocalRepository, int)> openDb() async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledgerId = await repo.createLedger(name: '生活账', currency: 'CNY');
    return (db, repo, ledgerId);
  }

  /// 导出 → 新库导入 → 回读 note。
  Future<List<String?>> roundtripNotes(List<String> notes) async {
    final (db, repo, ledgerId) = await openDb();
    try {
      for (final note in notes) {
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
      final yaml =
          await ConfigExportService.exportToYaml(repository: repo, ledgerId: ledgerId);

      final (db2, repo2, ledgerId2) = await openDb();
      try {
        await ConfigExportService.importFromYaml(yaml,
            repository: repo2, ledgerId: ledgerId2, options: onlyRecurring);
        final rts = await repo2.getAllRecurringTransactions();
        return rts.map((r) => r.note).toList();
      } finally {
        await db2.close();
      }
    } finally {
      await db.close();
    }
  }

  group('配置 YAML:换行/制表/回车往返保真', () {
    test('换行备注逐字往返(旧探测:折叠为空格)', () async {
      final out = await roundtripNotes(['第一行\n第二行']);
      expect(out, ['第一行\n第二行'],
          reason: '换行必须保真 —— 曾被 YAML 折叠为空格,静默改写用户备注');
    });

    test('制表与回车同样保真', () async {
      final out = await roundtripNotes(['a\tb', 'x\ry']);
      expect(out, ['a\tb', 'x\ry']);
    });

    test('混合:换行+引号+emoji 全保真', () async {
      const tricky = '他说"每月"\n扣款 不是换行 🎬\t结束';
      final out = await roundtripNotes([tricky]);
      expect(out, [tricky]);
    });

    // ────────────────────────────────────────────────────────────
    // 新发现(X2 探测):**字面反斜杠**未被转义。
    // `_yamlQuotedValue` 的 `case 0x5C` 只写回**一个** `\`(YAML 双引号标量
    // 里它是转义引导符,必须写成 `\\`),于是备注里的字面 `\n`(反斜杠+n)
    // 会被解析成真换行 —— 与探测发现 1(换行折叠)同族的**静默内容损坏**。
    // 归属:`lib/services/export/config_export_service.dart`(C2 批次文件,
    // 不在本批编辑白名单)→ 本批只固化证据并交接。
    // 期望修法:`case 0x5C: buf.write('\\\\');`
    // ────────────────────────────────────────────────────────────
    test('ADVERSE: 字面反斜杠未被转义 → `\\n` 被解析成真换行', () async {
      final out = await roundtripNotes([r'扣款\n 不是换行']);
      expect(out, [r'扣款\n 不是换行'],
          reason: 'ADVERSE FINDING(未修,交接 C2):字面反斜杠未转义为 \\\\,'
              '`\\n` 经 YAML 解析变真换行 —— 用户备注被静默改写');
    });

    test('多条记录各自保真(转义不串行)', () async {
      final out = await roundtripNotes(['单行', '两\n行', '制\t表']);
      expect(out, ['单行', '两\n行', '制\t表']);
    });

    test('导出的 YAML 含转义序列而非裸换行(发射器形态锁定)', () async {
      final (db, repo, ledgerId) = await openDb();
      try {
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
        expect(yaml.contains(r'\n'), isTrue,
            reason: '双引号标量内的换行应转义为 \\n(而非物理换行)');
        // 解析后 note 单值不含物理换行外的额外键
        final doc = loadYaml(yaml);
        final item =
            (doc['recurring_transactions']['items'] as List).single;
        expect(item['note'], '第一行\n第二行');
      } finally {
        await db.close();
      }
    });

    test('控制字符 (NUL/ESC) 被转义为 \\xNN,不产出裸控制字节', () async {
      final (db, repo, ledgerId) = await openDb();
      try {
        await repo.addRecurringTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 10,
          frequency: 'monthly',
          interval: 1,
          startDate: DateTime(2026, 10, 1),
          note: 'a\u0001b\u001bc',
        );
        final yaml = await ConfigExportService.exportToYaml(
            repository: repo, ledgerId: ledgerId);
        expect(yaml.contains(r'\x01'), isTrue);
        expect(yaml.contains(r'\x1b'), isTrue);
        expect(() => loadYaml(yaml), returnsNormally);
        final doc = loadYaml(yaml);
        final item =
            (doc['recurring_transactions']['items'] as List).single;
        expect(item['note'], 'a\u0001b\u001bc',
            reason: 'YAML \\xNN 转义应还原原控制字符');
      } finally {
        await db.close();
      }
    });
  });
}
