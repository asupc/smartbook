import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/widgets/biz/transaction_list.dart';

typedef _TxRow = ({
  Transaction t,
  Category? category,
  Account? account,
  Account? toAccount,
});

void main() {
  testWidgets('相同交易列表引用的无关 rebuild 不重复派生扁平列表', (tester) async {
    final key = GlobalKey<TransactionListState>();
    final transactions = <_TxRow>[];

    Widget app({required bool hideAmounts, required List<_TxRow> rows}) {
      return ProviderScope(
        child: MaterialApp(
          home: TransactionList(
            key: key,
            transactions: rows,
            hideAmounts: hideAmounts,
            emptyWidget: const SizedBox.shrink(),
          ),
        ),
      );
    }

    await tester.pumpWidget(app(hideAmounts: false, rows: transactions));
    await tester.pump();
    final firstBuildCount = key.currentState!.debugFlatItemsBuildCount;
    expect(firstBuildCount, 1);

    // 仅切换金额隐藏状态：父组件会 rebuild，但交易 snapshot 引用没变。
    await tester.pumpWidget(app(hideAmounts: true, rows: transactions));
    await tester.pump();
    expect(key.currentState!.debugFlatItemsBuildCount, firstBuildCount);

    // Drift 发出新的 List 引用时才应重新分组。
    await tester.pumpWidget(app(hideAmounts: true, rows: <_TxRow>[]));
    await tester.pump();
    expect(key.currentState!.debugFlatItemsBuildCount, firstBuildCount + 1);
  });
}
