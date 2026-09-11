import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/services/automation/auto_book_policy.dart';

void main() {
  const policy = AutoBookPolicy();

  BillInfo bill({
    double amount = -30,
    BillType type = BillType.expense,
    BillEventKind? eventKind,
    BillSettlementStatus? status,
    bool confidenceProvided = true,
    bool timeInferred = false,
    BillTimePrecision timePrecision = BillTimePrecision.minute,
    String? account,
  }) {
    return BillInfo(
      amount: amount,
      type: type,
      time: DateTime(2026, 9, 4, 12),
      eventKind: eventKind,
      settlementStatus: status,
      confidenceProvided: confidenceProvided,
      timeInferred: timeInferred,
      timePrecision: timePrecision,
      account: account,
    );
  }

  test('账单汇总/余额提醒不创建消费', () {
    final result = policy.evaluate(
      bill: bill(eventKind: BillEventKind.statement),
      source: 'sms',
      evidenceText: '本期账单总额5000元，最低还款500元',
    );
    expect(result.action, AutoBookPolicyAction.ignore);
    expect(result.reason, 'statement_or_balance');
  });

  test('信用卡消费短信带「可用额度」尾注不再误判为汇总(2026-09-10)', () {
    // 真实信用卡消费短信标配尾注;旧口径把含「可用额度」的正文整条判
    // statement 静默丢弃,真实消费漏记。
    final result = policy.evaluate(
      bill: bill(
        eventKind: BillEventKind.purchase,
        status: BillSettlementStatus.settled,
      ),
      source: 'sms',
      evidenceText: '您尾号8888的信用卡于12:05消费100元,可用额度9000元',
    );
    expect(result.action, AutoBookPolicyAction.allow);
    expect(result.reason, 'settled_transaction');
  });

  test('纯额度提醒(弱汇总词且无动作词)仍判汇总', () {
    final result = policy.evaluate(
      bill: bill(eventKind: null),
      source: 'sms',
      evidenceText: '您尾号8888的信用卡可用额度9000元',
    );
    expect(result.action, AutoBookPolicyAction.ignore);
    expect(result.reason, 'statement_or_balance');
  });

  test('待付款/失败订单不创建消费', () {
    final result = policy.evaluate(
      bill: bill(eventKind: BillEventKind.pendingOrder),
      source: 'screen',
      evidenceText: '订单确认 待付款 ¥30.00',
    );
    expect(result.action, AutoBookPolicyAction.ignore);
  });

  test('已完成消费且字段完整允许入账', () {
    final result = policy.evaluate(
      bill: bill(
        eventKind: BillEventKind.purchase,
        status: BillSettlementStatus.settled,
      ),
      source: 'notification',
      evidenceText: '支付成功，消费30元',
    );
    expect(result.action, AutoBookPolicyAction.allow);
  });

  test('缺结算状态的自动事件进入待确认', () {
    final result = policy.evaluate(
      bill: bill(eventKind: BillEventKind.purchase),
      source: 'screen',
      evidenceText: '订单详情 金额30元',
    );
    expect(result.action, AutoBookPolicyAction.pending);
    expect(result.reason, 'settlement_unknown');
  });

  test('还款/转账缺账户进入待确认', () {
    final result = policy.evaluate(
      bill: bill(
        type: BillType.transfer,
        eventKind: BillEventKind.repayment,
        status: BillSettlementStatus.settled,
      ),
      source: 'sms',
      evidenceText: '还款成功500元',
    );
    expect(result.action, AutoBookPolicyAction.pending);
    expect(result.reason, 'transfer_account_missing');
  });

  test('主动路径不被自动硬闸门拦截', () {
    final result = policy.evaluate(
      bill: bill(eventKind: BillEventKind.statement),
      source: 'chat',
      evidenceText: '本期账单总额5000元',
      automatic: false,
    );
    expect(result.action, AutoBookPolicyAction.allow);
    expect(result.reason, 'user_initiated');
  });
}
