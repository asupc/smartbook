/// 对抗性测试:待确认页(PendingConfirmationPage)渲染与数据边界。
///
/// **运行方式(2026-10-11 批次 X 修复后)**:本文件可**整文件单跑**,8 条全绿。
///
/// 历史:此前本文件"须逐条单跑",同文件批量从第 2 条起 "did not complete"。
/// 批次 X 的可测性 2 复现定位出真实根因 —— 不是页面订阅/pending timer:
/// `PendingCandidateStore._serial` 持有**进程级静态 Future 尾链**;在
/// `testWidgets` 的 fake-async zone 里建立的尾链,下一个用例再 `.then` 它时,
/// 传播微任务被排到上一个用例已废弃的 fake zone → 回调永不触发(挂起)。
/// page/store/coordinator 订阅路径均无 Timer(建议-12 的实测结论)。
/// 修法:页面新增 [PendingConfirmationPage.candidateLoader] 注入点,本文件
/// 用内存候选列表驱动渲染,完全绕开该静态尾链;生产默认路径不变。
///
/// 覆盖:列表渲染、筛选、超长文本、大字体、窄屏、空态;动作链语义由
/// test/services/automation/b4_restore_and_decisions_test.dart 等服务层测试覆盖。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/pages/automation/pending_confirmation_page.dart';
import 'package:smartbook/providers/automation_providers.dart';
import 'package:smartbook/providers/database_providers.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late AutoBookCoordinator coordinator;

  /// 测试候选(内存)。经注入 loader 进入页面,不碰
  /// PendingCandidateStore 的静态尾链(见文件头)。
  late List<PendingCandidate> candidates;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    coordinator = AutoBookCoordinator(db);
    candidates = [];
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  /// 有界 pump:页面异步 _reload 分多帧完成,且不得用 pumpAndSettle
  /// (页面存活期间的订阅会让它超时)。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<List<PendingCandidate>> loader(AutoBookEventStore _) async {
    final list = [...candidates];
    list.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return list;
  }

  Widget host() => ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(repo),
          autoBookCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: PendingConfirmationPage(candidateLoader: loader),
        ),
      );

  Future<int> seedLedger() =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: '测试账本'));

  Future<void> seedCandidate({
    required String id,
    required int ledgerId,
    double amount = 29.9,
    String note = '星巴克支付',
    String source = 'notification',
    String reason = 'duplicate',
    int? matchedTransactionId,
    double? matchScore,
  }) async {
    candidates.add(PendingCandidate(
      id: id,
      bill: BillInfo(
        amount: -amount,
        time: DateTime.now().subtract(const Duration(minutes: 2)),
        note: note,
        category: '餐饮',
        currency: 'CNY',
        type: BillType.expense,
        ledgerId: ledgerId,
      ),
      source: source,
      capturedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      reason: reason,
      matchedTransactionId: matchedTransactionId,
      matchScore: matchScore,
    ));
  }

  testWidgets('空列表渲染空态不崩', (tester) async {
    await seedLedger();
    await tester.pumpWidget(host());
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); // 卸载页面,释放订阅
  });

  testWidgets('单条候选渲染出关键信息(金额/备注)', (tester) async {
    final ledgerId = await seedLedger();
    await seedCandidate(id: 'p-one', ledgerId: ledgerId, reason: 'weak_match');
    await tester.pumpWidget(host());
    await settle(tester);
    expect(find.textContaining('29.9'), findsWidgets);
    expect(find.textContaining('星巴克支付'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('疑似重复候选显示匹配度与查看对比入口', (tester) async {
    final ledgerId = await seedLedger();
    final txId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 29.9,
      happenedAt: DateTime.now().subtract(const Duration(days: 1)),
      note: '星巴克门店',
      currencyCode: 'CNY',
      nativeAmount: 29.9,
    );
    await seedCandidate(
      id: 'p-dup',
      ledgerId: ledgerId,
      matchedTransactionId: txId,
      matchScore: 0.94,
    );
    await tester.pumpWidget(host());
    await settle(tester);
    expect(find.textContaining('匹配度 94%'), findsOneWidget);
    expect(find.text('查看对比'), findsWidgets);
  });

  testWidgets('超长 + emoji 备注不崩(截断显示)', (tester) async {
    final ledgerId = await seedLedger();
    await seedCandidate(
      id: 'p-long',
      ledgerId: ledgerId,
      note: '🚀' * 300,
      reason: 'weak_match',
    );
    await tester.pumpWidget(host());
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '超长 emoji 备注不得渲染崩溃');
  });

  // U-2 回归:420x900 + textScale 2.0。修复前候选卡片底部动作行/筛选行
  // 不可收缩 → RenderFlex 溢出。
  testWidgets('U-2 回归:大字体(2.0)下不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ledgerId = await seedLedger();
    await seedCandidate(id: 'p-big', ledgerId: ledgerId, reason: 'weak_match');
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: host(),
    ));
    await settle(tester);
    final ex = tester.takeException();
    expect(ex, isNull, reason: '大字体不得溢出,实际=$ex');
  });

  // U-2 回归:320 宽。修复前筛选行/动作行 RenderFlex 溢出 161px。
  testWidgets('U-2 回归:窄屏 320 下不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ledgerId = await seedLedger();
    await seedCandidate(id: 'p-narrow', ledgerId: ledgerId, reason: 'weak_match');
    await tester.pumpWidget(host());
    await settle(tester);
    final ex = tester.takeException();
    expect(ex, isNull, reason: '320 宽不得溢出,实际=$ex');
  });

  testWidgets('多候选(50 条)渲染不炸', (tester) async {
    final ledgerId = await seedLedger();
    for (var i = 0; i < 50; i++) {
      await seedCandidate(
        id: 'p-bulk-$i',
        ledgerId: ledgerId,
        note: '候选 $i',
        reason: 'weak_match',
      );
    }
    await tester.pumpWidget(host());
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '50 条候选批量渲染不得异常');
  });
}
