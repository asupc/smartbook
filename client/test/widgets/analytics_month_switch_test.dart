import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/pages/main/analytics_page.dart';
import 'package:smartbook/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);

    // 创建账本与账户
    await repo.createLedger(name: '默认账本');
    await repo.createAccount(
      ledgerId: 1,
      name: '账户A',
      type: 'general',
      currency: 'CNY',
    );
    await repo.createAccount(
      ledgerId: 1,
      name: '账户B',
      type: 'general',
      currency: 'CNY',
    );
  });

  tearDown(() async => db.close());

  testWidgets('AnalyticsPage: 切换月份后商户Top和账户分布跟着更新', (tester) async {
    // 2026-07 记录
    await repo.addTransaction(
      ledgerId: 1,
      type: 'expense',
      amount: 700.0,
      note: '七月商户',
      accountId: 1,
      happenedAt: DateTime(2026, 7, 15),
    );

    // 2026-08 记录
    await repo.addTransaction(
      ledgerId: 1,
      type: 'expense',
      amount: 800.0,
      note: '八月商户',
      accountId: 2,
      happenedAt: DateTime(2026, 8, 15),
    );

    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerIdProvider.overrideWith((ref) => 1),
      ],
    );
    addTearDown(container.dispose);

    // 初始设为 8 月
    container.read(selectedMonthProvider.notifier).state =
        DateTime(2026, 8, 1);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AnalyticsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 此时应显示 8 月的商户与账户
    expect(find.text('八月商户'), findsOneWidget);
    expect(find.text('¥800.00'), findsWidgets);
    expect(find.text('七月商户'), findsNothing);

    // 切换到 7 月
    container.read(selectedMonthProvider.notifier).state =
        DateTime(2026, 7, 1);
    await tester.pumpAndSettle();

    // 此时应更新为 7 月的商户与账户
    expect(find.text('七月商户'), findsOneWidget);
    expect(find.text('¥700.00'), findsWidgets);
    expect(find.text('八月商户'), findsNothing);

    // 等待日志防抖定时器执行完毕
    await tester.pump(const Duration(seconds: 3));
  });
}
