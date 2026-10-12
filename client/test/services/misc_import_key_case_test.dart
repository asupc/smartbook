// 杂项域补测(批次 X2):导入幂等键大小写一致性(确证缺陷,本批已修)。
//
// FINDINGS-misc-services.md §二.2:导入幂等键 `_keyHash(external)` 未小写化,
// 同一订单号换大小写(`ABC123` vs `abc123`)重复导入 → 产生两笔交易;
// 而 `findTransactionByExternalId` 是归一化查询(大小写不敏感)→ 两侧口径不一致。
//
// 与既有文件边界:`test/services/data_import_idempotency_test.dart` 覆盖同大小写
// 完全重复的幂等;本文件专攻**大小写/空白归一化**这一缺口。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ImportTransaction order(String externalId) => ImportTransaction(
        type: 'expense',
        amount: 30,
        happenedAt: DateTime(2026, 9, 3, 12),
        note: '咖啡',
        provider: 'alipay',
        externalId: externalId,
        status: '交易成功',
      );

  group('importEventKey 归一化', () {
    test('同一 externalId 大小写不同 → 幂等键必须相同', () {
      final upper = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('ABC123'),
      );
      final lower = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('abc123'),
      );
      expect(lower, upper,
          reason: 'ADVERSE FINDING(已修):_keyHash 未小写化 → 同订单号换大小写'
              '得到不同幂等键,重复导入会落第二笔');
    });

    test('前后空白差异同样归一(与查询侧 trim 口径一致)', () {
      final a = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('ORDER-9'),
      );
      final b = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('  ORDER-9  '),
      );
      expect(a, b);
    });

    test('不同 ledger / 不同 provider 仍是不同键(归一化不放宽身份维度)', () {
      final base = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('A1'),
      );
      expect(
        DataImportService.importEventKey(
            ledgerId: 2, provider: 'alipay', transaction: order('A1')),
        isNot(base),
      );
      expect(
        DataImportService.importEventKey(
            ledgerId: 1, provider: 'wechat', transaction: order('A1')),
        isNot(base),
      );
    });

    test('provider 大小写/空白归一(既有行为,防回归)', () {
      final a = DataImportService.importEventKey(
        ledgerId: 1,
        provider: 'Alipay',
        transaction: order('A1'),
      );
      final b = DataImportService.importEventKey(
        ledgerId: 1,
        provider: '  alipay ',
        transaction: order('A1'),
      );
      expect(a, b);
    });
  });

  group('端到端:大小写变体重复导入不落第二笔', () {
    late BeeDatabase db;
    late LocalRepository repo;
    late DataImportService service;
    late AutoBookEventStore eventStore;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = BeeDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      service = DataImportService();
      eventStore = AutoBookEventStore(db);
      await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')",
      );
    });

    tearDown(() async => db.close());

    Future<ImportResult> import(ImportTransaction tx) =>
        service.importTransactions(
          repo,
          1,
          [tx],
          accountNameToId: {},
          categoryCache: {},
          tagNameToId: {},
          eventStore: eventStore,
        );

    test('先 ABC123 再 abc123 → 只落一笔,第二笔判重复', () async {
      final first = await import(order('ABC123'));
      final second = await import(order('abc123'));

      expect(first.inserted, 1);
      expect(second.inserted, 0,
          reason: 'ADVERSE FINDING(已修):大小写变体曾被当作新行再次入库');
      expect(second.duplicated, 1);
      expect(await (db.select(db.transactions)).get(), hasLength(1));
      expect(await (db.select(db.autoBookEvents)).get(), hasLength(1));
    });

    test('前后空白变体 (A1 vs "  a1 ") 同样判重复', () async {
      expect((await import(order('A1'))).inserted, 1);
      final second = await import(order('  a1 '));
      expect(second.inserted, 0);
      expect(second.duplicated, 1);
    });

    test('预览口径与导入口径一致:大小写变体在 preview 即判 duplicate', () async {
      expect((await import(order('MixCase-7'))).inserted, 1);
      final preview = await service.previewTransactions(
        repo,
        1,
        [order('mixcase-7')],
        eventStore: eventStore,
      );
      expect(preview.newCount, 0);
      expect(preview.duplicateCount, 1,
          reason: 'ADVERSE FINDING(已修):preview 曾用未小写化的键,'
              '预览显示"新增"但导入又因事件键命中而跳过 —— 口径分裂');
    });

    test('真正的不同订单号仍各自入库(归一化不误合并)', () async {
      expect((await import(order('ABC123'))).inserted, 1);
      expect((await import(order('ABC124'))).inserted, 1);
      expect(await (db.select(db.transactions)).get(), hasLength(2));
    });

    test('升级兼容:旧版本(未归一)已落库的行,重导同单号判重复', () async {
      // 模拟旧版本写入的事件行:事件键用**未小写化**的 externalId。
      // 现实场景:升级后用户重导**同一个文件** → externalId 大小写与旧次一致
      // ('ABC123'),此时探测旧键命中 → 判重复,不多落一笔。
      final legacyKey = DataImportService.legacyImportEventKey(
        ledgerId: 1,
        provider: 'alipay',
        transaction: order('ABC123'),
      );
      expect(legacyKey, isNotNull, reason: '含大写 → 旧键与规范键不同');
      expect(
        legacyKey,
        isNot(DataImportService.importEventKey(
            ledgerId: 1, provider: 'alipay', transaction: order('ABC123'))),
        reason: '旧键必须与归一后的新键不同,否则该用例是空断言',
      );
      await eventStore.ensure(AutoBookInput(
        eventKey: legacyKey!,
        source: AutoBookSource.import,
        captureIntent: AutoBookCaptureIntent.importData,
        ledgerId: 1,
        capturedAt: DateTime.now(),
      ));

      final res = await import(order('ABC123'));
      expect(res.inserted, 0,
          reason: '升级兼容:旧键命中应判重复,否则老用户重导同一文件多一笔');
      expect(res.duplicated, 1);
      expect(await (db.select(db.transactions)).get(), isEmpty);
    });

    test('升级兼容的边界:旧行大小写与本次导入不一致时不可还原(事实锁定)', () async {
      // 旧行以 'ABC123' 落键,本次导入却写成 'abc123' → 旧键 hash('ABC123')
      // 无法从入参还原(入参只剩小写)。这是**有意的取舍**:大小写不携带语义,
      // 且同一文件重导大小写不变;跨大小写重导会多一笔,由语义判重兜底。
      final legacyKey = DataImportService.legacyImportEventKey(
          ledgerId: 1, provider: 'alipay', transaction: order('ABC123'))!;
      await eventStore.ensure(AutoBookInput(
        eventKey: legacyKey,
        source: AutoBookSource.import,
        captureIntent: AutoBookCaptureIntent.importData,
        ledgerId: 1,
        capturedAt: DateTime.now(),
      ));

      final res = await import(order('abc123'));
      expect(res.inserted, 1,
          reason: 'HARDENING:入参全小写 → 无法还原旧键,视为新行(已知边界)');
      expect(await (db.select(db.transactions)).get(), hasLength(1));
    });

    test('legacyImportEventKey:全小写/无 externalId 时不产生额外探测', () {
      expect(
        DataImportService.legacyImportEventKey(
            ledgerId: 1, provider: 'alipay', transaction: order('abc123')),
        isNull,
        reason: '全小写 → 旧键与规范键相同,无需探测',
      );
      expect(
        DataImportService.legacyImportEventKey(
            ledgerId: 1,
            provider: 'alipay',
            transaction: ImportTransaction(
                type: 'expense',
                amount: 1,
                happenedAt: DateTime(2026, 1, 1))),
        isNull,
        reason: '无 externalId → 走 row-hash 分支,无旧键概念',
      );
    });
  });
}
