import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 短信指纹测试(M1 短信自动记账)。
///
/// 指纹算法必须与 native SmsReceiver(sha256(sender|body) 取前 8 字节 hex)
/// 完全同口径 —— 两层去重共用同一指纹,偏移会导致重复入账。
void main() {
  group('AutoBillingService.smsFingerprint', () {
    test('相同发送者+内容 → 相同指纹', () {
      final a = AutoBillingService.smsFingerprint('95555', '您的尾号1234账户消费100元');
      final b = AutoBillingService.smsFingerprint('95555', '您的尾号1234账户消费100元');
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('不同内容(即使发送者相同)→ 不同指纹', () {
      final a = AutoBillingService.smsFingerprint('95555', '尾号1234消费100元');
      final b = AutoBillingService.smsFingerprint('95555', '尾号1234消费200元');
      expect(a, isNot(b));
    });

    test('不同发送者(内容相同)→ 不同指纹', () {
      final a = AutoBillingService.smsFingerprint('95555', '尾号1234消费100元');
      final b = AutoBillingService.smsFingerprint('招商银行', '尾号1234消费100元');
      expect(a, isNot(b));
    });

    test('中文多字节内容稳定(UTF-8)', () {
      final a = AutoBillingService.smsFingerprint('招商银行', '您尾号8888的储蓄卡于14:32消费人民币¥1,234.56元');
      final b = AutoBillingService.smsFingerprint('招商银行', '您尾号8888的储蓄卡于14:32消费人民币¥1,234.56元');
      expect(a, b);
    });

    test('指纹只含 hex 字符', () {
      final fp = AutoBillingService.smsFingerprint('95588', '转账入账500元');
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(fp), isTrue);
    });
  });

  group('AutoBillingService.billFingerprint(2026-09-10 按小时粒度)', () {
    test('同日同小时同账单 → 相同指纹(重复进详情页仍去重)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 14, 3),
      );
      final b = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 14, 58),
      );
      expect(a, b);
    });

    test('同日不同小时的两笔同款 → 不同指纹(真实第二笔不再被吞)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 9, 5),
      );
      final b = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 15, 2),
      );
      expect(a, isNot(b));
    });
  });
}
