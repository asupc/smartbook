import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_extraction_context.dart';
import 'package:smartbook/ai/core/ai_extraction_engine.dart';
import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/ai/ai_bookkeeper.dart';
import 'package:smartbook/services/ai/bookkeeping_result.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

/// 跨渠道强判重(A1)+ 合并富化(A2)端到端:
/// 同一笔支付被多个事件来源(短信/通知/页面)先后上报,
/// 只落一笔交易,后到捕获的增量信息补进已有交易。
class _FakeEngine implements AiExtractionEngine {
  List<BillInfo> bills;
  _FakeEngine({this.bills = const []});

  @override
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async => AiExtractionOutcome(
      status: bills.isEmpty ? ExtractionStatus.noBill : ExtractionStatus.success,
      bills: bills,
    );

  @override
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async => bills;

  @override
  Future<List<ImageExtractOutcome>> extractFromImages(
    List<File> images,
    AiExtractionContext context, {
    String billGuard = '',
  }) async => [for (final _ in images) ImageExtractOutcome(bills: bills)];

  @override
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext ctx,
  ) async => const AudioExtractionResult();

  @override
  Future<String?> speechToText(File audio) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late BillCreationService persister;
  late AutoBookEventStore eventStore;
  late PendingCandidateStore candidateStore;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    persister = BillCreationService(repo);
    eventStore = AutoBookEventStore(db);
    candidateStore = PendingCandidateStore();
    ledgerId = await repo.createLedger(name: 'cross-channel');
    await repo.createCategory(name: '餐饮', kind: 'expense');
    await repo.createCategory(name: '其他', kind: 'expense');
    await repo.createAccount(ledgerId: ledgerId, name: '招商银行');
  });

  tearDown(() async {
    await db.close();
  });

  /// 用一个事件来源跑完整自动记账(coordinator claim → 识别 → 落库/判重)。
  Future<void> processFromSource({
    required AutoBookSource source,
    required String sourceValue,
    required BillInfo bill,
  }) async {
    final eventKey = 'test:${source.name}:${bill.amount}:${bill.time}';
    final coordinator = AutoBookCoordinator(db);
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: _FakeEngine(bills: [bill]),
      persister: persister,
      eventStore: eventStore,
    );
    await coordinator.execute<BookkeepingResult>(
      input: AutoBookInput(
        eventKey: eventKey,
        source: source,
        capturedAt: DateTime.now(),
        ledgerId: ledgerId,
      ),
      action: () => bookkeeper.fromText(
        text: 'x',
        ledgerId: ledgerId,
        billingTypes: const ['ai'],
        autoBookFlow: AutoBookFlow(
          store: candidateStore,
          eventKey: eventKey,
          eventStore: eventStore,
        ),
        source: sourceValue,
      ),
      updateFor: (value) => value.eventUpdate,
    );
  }

  test('sourceKeysForTransaction:booked/duplicate 父行与子项全部反查',
      () async {
    final time = DateTime(2026, 9, 10, 12, 3, 11);
    final txId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      happenedAt: time,
      note: '微信支付',
    );

    // 无事件关联 → 空集
    expect(await eventStore.sourceKeysForTransaction(txId), isEmpty);

    // 父行 booked 关联
    final e1 = await eventStore.ensure(AutoBookInput(
      eventKey: 'k1',
      source: AutoBookSource.sms,
      capturedAt: DateTime.now(),
      ledgerId: ledgerId,
    ));
    await eventStore.mark(
      AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: txId,
      ),
      eventId: e1.id,
    );
    expect(await eventStore.sourceKeysForTransaction(txId), {'sms'});

    // 另一渠道 duplicate 关联(duplicateOfTransactionId 列)
    final e2 = await eventStore.ensure(AutoBookInput(
      eventKey: 'k2',
      source: AutoBookSource.notification,
      capturedAt: DateTime.now(),
      ledgerId: ledgerId,
    ));
    await eventStore.mark(
      AutoBookEventUpdate(
        state: AutoBookState.duplicate,
        duplicateOfTransactionId: txId,
      ),
      eventId: e2.id,
    );
    expect(await eventStore.sourceKeysForTransaction(txId),
        {'sms', 'notification'});

    // manual/import/recurring 无来源键
    final e3 = await eventStore.ensure(AutoBookInput(
      eventKey: 'k3',
      source: AutoBookSource.manual,
      capturedAt: DateTime.now(),
      ledgerId: ledgerId,
    ));
    await eventStore.mark(
      AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: txId,
      ),
      eventId: e3.id,
    );
    // manual 不贡献来源键,集合不变
    expect(await eventStore.sourceKeysForTransaction(txId),
        {'sms', 'notification'});
  });

  test('sourceKey 口径:聚合与排除', () {
    expect(AutoBookSourceValue.sourceKey('sms'), 'sms');
    expect(AutoBookSourceValue.sourceKey('notification'), 'notification');
    expect(AutoBookSourceValue.sourceKey('screenText'), 'screen');
    expect(AutoBookSourceValue.sourceKey('screenshot'), 'image');
    expect(AutoBookSourceValue.sourceKey('sharedImage'), 'image');
    expect(AutoBookSourceValue.sourceKey('deepLinkText'), 'deeplink');
    expect(AutoBookSourceValue.sourceKey('deepLinkDirect'), 'deeplink');
    expect(AutoBookSourceValue.sourceKey('manual'), isNull);
    expect(AutoBookSourceValue.sourceKey('import'), isNull);
    expect(AutoBookSourceValue.sourceKey('recurring'), isNull);
    expect(AutoBookSourceValue.sourceKey('unknown-junk'), isNull);
    // _persistAll 注入的屏蔽词归一(AiBookkeeper source 参数)
    expect(AutoBookSourceValue.sourceKey('screen'), 'screen');
    expect(AutoBookSourceValue.sourceKey('text'), 'deeplink');
    expect(AutoBookSourceValue.sourceKey('image'), 'image');
    expect(AutoBookSourceValue.sourceKey('auto'), isNull);
  });

  test('4 渠道先后上报同一笔支付:只落 1 笔,富化补全商户/分类', () async {
    final time = DateTime(2026, 9, 10, 12, 3, 11);

    // 渠道 1:银行短信(先到)—— 金额+账户,无商户无分类,落库后是「其他」
    await processFromSource(
      source: AutoBookSource.sms,
      sourceValue: 'sms',
      bill: BillInfo(
        amount: -88,
        time: time,
        type: BillType.expense,
        account: '招商银行',
        currency: 'CNY',
        confidence: 0.95,
        confidenceProvided: true,
        timePrecision: BillTimePrecision.exact,
        settlementStatus: BillSettlementStatus.settled,
        eventKind: BillEventKind.purchase,
      ),
    );
    var txs = await repo.getTransactionsByLedgerInRange(
      ledgerId: ledgerId,
      start: time.subtract(const Duration(hours: 1)),
      end: time.add(const Duration(hours: 1)),
    );
    expect(txs, hasLength(1));
    final txId = txs.first.id;
    expect(txs.first.note, isNull); // 短信侧没有商户信息
    final cat1 = await repo.getCategoryById(txs.first.categoryId!);
    expect(cat1?.name, '其他'); // 兜底分类

    // 渠道 2:电商 App 通知(后到 20 秒,商户完全不同)
    await processFromSource(
      source: AutoBookSource.notification,
      sourceValue: 'notification',
      bill: BillInfo(
        amount: -88,
        time: time.add(const Duration(seconds: 20)),
        type: BillType.expense,
        merchant: '抖音商城',
        category: '餐饮',
        currency: 'CNY',
        confidence: 0.95,
        confidenceProvided: true,
        timePrecision: BillTimePrecision.exact,
        settlementStatus: BillSettlementStatus.settled,
        eventKind: BillEventKind.purchase,
      ),
    );
    txs = await repo.getTransactionsByLedgerInRange(
      ledgerId: ledgerId,
      start: time.subtract(const Duration(hours: 1)),
      end: time.add(const Duration(hours: 1)),
    );
    expect(txs, hasLength(1), reason: '跨渠道强判重应阻止第二笔落库');

    // A2 富化:商户补进备注、分类从「其他」换成「餐饮」、账户保留银行侧
    final merged = await repo.getTransactionById(txId);
    expect(merged!.note, '抖音商城');
    final cat2 = await repo.getCategoryById(merged.categoryId!);
    expect(cat2?.name, '餐饮');
    expect(merged.accountId, isNotNull); // 短信侧匹配的招商银行

    // 渠道 3:无障碍页面文本(再后到)与渠道 4:截图账单 —— 也不再落库
    await processFromSource(
      source: AutoBookSource.screenText,
      sourceValue: 'screen',
      bill: BillInfo(
        amount: -88,
        time: time.add(const Duration(seconds: 40)),
        type: BillType.expense,
        merchant: '抖音超级旗舰店',
        currency: 'CNY',
        confidence: 0.95,
        confidenceProvided: true,
        timePrecision: BillTimePrecision.exact,
        settlementStatus: BillSettlementStatus.settled,
        eventKind: BillEventKind.purchase,
      ),
    );
    txs = await repo.getTransactionsByLedgerInRange(
      ledgerId: ledgerId,
      start: time.subtract(const Duration(hours: 1)),
      end: time.add(const Duration(hours: 1)),
    );
    expect(txs, hasLength(1), reason: '第 3 渠道同样被强判重合并');
    // 已富化过的备注不被第 3 渠道覆盖(只补缺)
    final merged3 = await repo.getTransactionById(txId);
    expect(merged3!.note, '抖音商城');

    // 事件审计:先落库者 booked;后到渠道命中强判重(事件不再二次落交易)。
    // 终态可能是 duplicate(强合并直接终态)或 pending(判重分流进候选后
    // 整体事件终态),两种都不允许再产生新交易 —— 上面的 hasLength(1)
    // 已经验证了核心语义,这里只校验事件不再是 captured/processing。
    final states = <String>[];
    for (final e in await eventStore.listHistory(limit: 10)) {
      if (e.eventKey.startsWith('test:')) states.add(e.state);
    }
    expect(states, isNot(contains('captured')));
    expect(states, isNot(contains('processing')));
    expect(states.first, 'booked');
  });
}
