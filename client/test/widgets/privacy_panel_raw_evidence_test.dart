import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/pages/data/privacy_panel_page.dart';
import 'package:smartbook/providers/automation_providers.dart';
import 'package:smartbook/providers/database_providers.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/privacy/raw_evidence_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repository;
  late AutoBookCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repository = LocalRepository(db);
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
        repositoryProvider.overrideWithValue(repository),
        autoBookCoordinatorProvider.overrideWithValue(coordinator),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: PrivacyPanelPage(),
      ),
    );
  }

  testWidgets('privacy panel shows raw policy and saved evidence',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 5000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await RawEvidencePolicyStore().save(
      RawEvidencePolicy.defaults.withSourcePolicy(
        AutoBookSource.sms.value,
        const RawEvidenceSourcePolicy(
          localEnabled: true,
          localRetentionDays: 30,
          serverEnabled: false,
          serverRetentionDays: 30,
        ),
      ),
    );
    await coordinator.store.ensure(
      AutoBookInput(
        eventKey: 'sms:privacy-widget',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
        rawActor: '95555',
        rawText: '消费 20.00 元',
      ),
    );

    await tester.pumpWidget(host());
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('原始证据保留策略').evaluate().isNotEmpty) break;
    }

    expect(find.text('原始证据保留策略'), findsOneWidget);
    expect(find.text('其他来源默认策略'), findsOneWidget);
    expect(find.text('短信'), findsWidgets);
    expect(find.text('已保存 1 条'), findsOneWidget);
    expect(find.textContaining('消费 20.00 元'), findsOneWidget);
    expect(find.text('允许保存到服务端'), findsNWidgets(7));

    final enabledSwitch = find.byWidgetPredicate(
      (widget) => widget is Switch && widget.value,
    );
    expect(enabledSwitch, findsOneWidget);
    await tester.tap(enabledSwitch);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final changedPolicy = await RawEvidencePolicyStore().load();
    expect(changedPolicy.forSource(AutoBookSource.sms.value).localEnabled,
        isFalse);

    await tester.tap(find.textContaining('消费 20.00 元'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('来源主体: 95555'), findsOneWidget);
    expect(find.textContaining('正文:\n消费 20.00 元'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
