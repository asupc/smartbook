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
import 'package:smartbook/services/billing/pending_candidate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late AutoBookCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    coordinator = AutoBookCoordinator(db);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  Widget host() {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repo),
        autoBookCoordinatorProvider.overrideWithValue(coordinator),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: PendingConfirmationPage(),
      ),
    );
  }

  testWidgets('疑似重复候选显示已有交易摘要并可打开并排对比', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: '测试账本'),
        );
    final categoryId = await repo.createCategory(
      name: '餐饮',
      kind: 'expense',
    );
    final accountId = await repo.createAccount(
      ledgerId: ledgerId,
      name: '微信钱包',
      type: 'wechat',
      currency: 'CNY',
    );
    final happenedAt = DateTime(2026, 9, 5, 10, 18);
    final transactionId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 29.9,
      categoryId: categoryId,
      accountId: accountId,
      happenedAt: happenedAt,
      note: '星巴克门店',
      currencyCode: 'CNY',
      nativeAmount: 29.9,
    );

    await PendingCandidateStore().add(
      PendingCandidate(
        id: 'pending-compare',
        bill: BillInfo(
          amount: -29.9,
          time: happenedAt.add(const Duration(minutes: 2)),
          note: '星巴克支付',
          category: '餐饮',
          account: '微信钱包',
          currency: 'CNY',
          type: BillType.expense,
          ledgerId: ledgerId,
        ),
        source: 'notification',
        capturedAt: happenedAt.add(const Duration(minutes: 2)),
        reason: 'duplicate',
        matchedTransactionId: transactionId,
        matchScore: 0.94,
      ),
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      find.text('相似已有交易 #$transactionId'),
      findsOneWidget,
    );
    expect(find.text('星巴克门店'), findsOneWidget);
    expect(find.textContaining('CNY 29.90'), findsOneWidget);
    expect(find.text('匹配度 94%'), findsOneWidget);

    await tester.tap(find.text('查看对比'));
    await tester.pumpAndSettle();

    expect(find.text('待确认候选'), findsOneWidget);
    expect(find.text('已有交易'), findsOneWidget);
    expect(find.text('星巴克支付'), findsWidgets);
    expect(find.text('星巴克门店'), findsWidgets);
    expect(find.text('微信钱包'), findsWidgets);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
