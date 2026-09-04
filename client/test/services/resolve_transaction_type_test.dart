import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 交易类型识别(M4 还款)测试:显式 type 优先;分类含转账/还款 → transfer。
void main() {
  test('显式 type 优先', () {
    expect(
        resolveTransactionType(type: BillType.expense, category: '还款'),
        'expense');
    expect(
        resolveTransactionType(type: BillType.transfer, category: '餐饮'),
        'transfer');
  });

  test('分类含「转账/transfer」→ transfer', () {
    expect(resolveTransactionType(category: '转账'), 'transfer');
    expect(resolveTransactionType(category: '转账-银行卡'), 'transfer');
    expect(resolveTransactionType(category: 'transfer'), 'transfer');
    expect(resolveTransactionType(category: '转帐'), 'transfer');
  });

  test('分类含「还款/还信用卡/repayment」→ transfer(§6.1 不进消费)', () {
    expect(resolveTransactionType(category: '还款'), 'transfer');
    expect(resolveTransactionType(category: '信用卡还款'), 'transfer');
    expect(resolveTransactionType(category: '房贷还款'), 'transfer');
    expect(resolveTransactionType(category: 'repayment'), 'transfer');
  });

  test('普通消费/收入分类 → 原类型', () {
    expect(resolveTransactionType(category: '餐饮'), 'expense');
    expect(resolveTransactionType(category: '工资'), 'expense'); // 无 type 保守支出
  });

  test('空分类 → expense', () {
    expect(resolveTransactionType(category: ''), 'expense');
    expect(resolveTransactionType(category: null), 'expense');
  });
}
