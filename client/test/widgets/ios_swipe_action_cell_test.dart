import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/widgets/ui/ios_swipe_action_cell.dart';

void main() {
  testWidgets('左滑一个按钮宽度后吸附显示删除按钮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: Center(
          child: IosSwipeActionCell(
            onDelete: _unusedDelete,
            child: SizedBox(width: 320, height: 64, child: Text('交易明细')),
          ),
        ),
      ),
    ));

    await tester.drag(find.text('交易明细'), const Offset(-80, 0));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(InkWell)).width, 80);
  });

  testWidgets('左滑最多露出按钮宽度，点击按钮直接删除', (tester) async {
    var deleteCount = 0;

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: IosSwipeActionCell(
            onDelete: () async {
              deleteCount++;
            },
            child: const SizedBox(
              width: 320,
              height: 64,
              child: Text('交易明细'),
            ),
          ),
        ),
      ),
    ));

    await tester.drag(find.text('交易明细'), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(deleteCount, 0);
    expect(tester.getSize(find.byType(InkWell)).width, 80);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(deleteCount, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });
}

Future<void> _unusedDelete() async {}
