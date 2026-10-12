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
import 'package:smartbook/services/automation/auto_book_event.dart';
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

  testWidgets('后台升级合并后,打开的确认页自动移除原候选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ledgerId = await repo.createLedger(name: '测试账本');
    final happenedAt = DateTime.now();
    final bill = BillInfo(
      amount: -8.1,
      note: '地铁免密扣款',
      time: happenedAt,
      type: BillType.expense,
      ledgerId: ledgerId,
    );
    final event = await coordinator.store.ensure(AutoBookInput(
      eventKey: 'pending-page-auto-upgrade',
      source: AutoBookSource.notification,
      capturedAt: happenedAt,
      ledgerId: ledgerId,
    ));
    await coordinator.store.upsertItem(
      eventId: event.id,
      itemIndex: 0,
      amount: bill.amount,
      state: 'pending',
      reason: 'duplicate',
      bill: bill.toJson(),
    );
    await coordinator.store.mark(
      const AutoBookEventUpdate(state: AutoBookState.pending),
      eventId: event.id,
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('地铁免密扣款'), findsOneWidget);

    final txId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 8.1,
      happenedAt: happenedAt,
      note: '地铁乘车',
    );
    await coordinator.store.resolvePendingItem(
      eventId: event.id,
      itemIndex: 0,
      state: AutoBookState.duplicate,
      transactionId: txId,
      reason: 'cluster_merged',
    );
    await tester.pumpAndSettle();

    expect(find.text('地铁免密扣款'), findsNothing);
    expect(await PendingCandidateStore().loadForReview(coordinator.store),
        isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
