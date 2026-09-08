// M5-4C：TransactionList 窗口化 loader 参数契约测试。
//
// 验证 hasOlder/hasNewer 时顶部/底部渲染 loader 项、滚动到底部会触发
// onLoadOlder、新记录横幅在 unseenNewCount>0 时渲染并可点击回最新。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/providers/database_providers.dart';
import 'package:smartbook/widgets/biz/transaction_list.dart';

typedef _TxRow = ({
  Transaction t,
  Category? category,
  Account? account,
  Account? toAccount,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  _TxRow row(int id) => (
        t: Transaction(
          id: id,
          ledgerId: 1,
          type: 'expense',
          amount: 10.0,
          categoryId: null,
          accountId: null,
          toAccountId: null,
          happenedAt: DateTime(2026, 7, 15),
          recordedAt: null,
          note: null,
          syncId: 's$id',
          excludeFromStats: false,
          excludeFromBudget: false,
        ),
        category: null,
        account: null,
        toAccount: null,
      );

  Widget app(Widget child) => ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  testWidgets('hasOlder=true 时底部渲染 loader,滚动到底触发 onLoadOlder', (tester) async {
    var loaded = false;

    await tester.pumpWidget(app(SizedBox(
      height: 600,
      child: TransactionList(
        transactions: List.generate(30, (i) => row(i)),
        hideAmounts: false,
        hasOlder: true,
        onLoadOlder: () => loaded = true,
        emptyWidget: const SizedBox.shrink(),
      ),
    )));
    await tester.pump();

    await tester.fling(
        find.byType(TransactionList), const Offset(0, -2500), 3000);
    await tester.pumpAndSettle();

    expect(loaded, isTrue);
  });

  testWidgets('unseenNewCount>0 时渲染「有新记录」横幅,点击回最新', (tester) async {
    var returned = false;

    await tester.pumpWidget(app(TransactionList(
      transactions: List.generate(5, (i) => row(i)),
      hideAmounts: false,
      unseenNewCount: 3,
      onReturnToLatest: () => returned = true,
      emptyWidget: const SizedBox.shrink(),
    )));
    await tester.pump();

    expect(find.textContaining('新记录'), findsOneWidget);
    await tester.tap(find.textContaining('新记录'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
  });

  testWidgets('unseenNewCount=0 时不渲染横幅', (tester) async {
    await tester.pumpWidget(app(TransactionList(
      transactions: List.generate(5, (i) => row(i)),
      hideAmounts: false,
      unseenNewCount: 0,
      emptyWidget: const SizedBox.shrink(),
    )));
    await tester.pump();
    expect(find.textContaining('新记录'), findsNothing);
  });
}
