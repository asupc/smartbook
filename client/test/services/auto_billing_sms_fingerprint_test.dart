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

  group('AutoBillingService.billFingerprint(2026-09-10 按小时粒度;C2 加方向)', () {
    test('同日同小时同账单 → 相同指纹(重复进详情页仍去重)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 14, 3),
        type: 'expense',
      );
      final b = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 14, 58),
        type: 'expense',
      );
      expect(a, b);
    });

    test('同日不同小时的两笔同款 → 不同指纹(真实第二笔不再被吞)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 9, 5),
        type: 'expense',
      );
      final b = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -19.9,
        note: '瑞幸咖啡',
        time: DateTime(2026, 9, 10, 15, 2),
        type: 'expense',
      );
      expect(a, isNot(b));
    });

    test('C2:同渠道同金额的支付与退款 → 不同指纹(旧口径 abs 相同会吞退款)', () {
      final pay = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88.0,
        note: '京东平台商户',
        time: DateTime(2026, 9, 15, 10, 0),
        type: 'expense',
      );
      final refund = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: 88.0,
        note: '京东平台商户',
        time: DateTime(2026, 9, 15, 10, 0),
        type: 'income',
      );
      expect(pay, isNot(refund),
          reason: 'C2:指纹加入 type(收支方向),退款不再被 already_processed 跳过');
    });

    test('C2:方向一致时金额 abs 相等 → 相同指纹(归一保留)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88.0,
        note: '京东平台商户',
        time: DateTime(2026, 9, 15, 10, 0),
        type: 'expense',
      );
      final b = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: 88.0,
        note: '京东平台商户',
        time: DateTime(2026, 9, 15, 10, 0),
        type: 'expense',
      );
      expect(a, b, reason: '金额 abs 归一保持,方向由 type 区分');
    });

    test('type 缺省与显式空串同口径(向后兼容)', () {
      final a = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -1.0,
        note: null,
        time: null,
        type: null,
      );
      final b = AutoBillingService.billFingerprint(
        channel: '支付宝',
        amount: -1.0,
        note: '',
        time: null,
        type: '',
      );
      expect(a, b);
    });
  });

  group('AutoBillingService.notifyFingerprint(C6 与 native 同口径)', () {
    test('同身份(notificationKey/id/postTime)→ 相同指纹', () {
      final a = AutoBillingService.notifyFingerprint(
        'com.tencent.mm',
        '微信支付',
        '已支付¥8.00',
        notificationKey: 'pkg|id|tag',
        notificationId: 42,
        postTime: 1757900000000,
      );
      final b = AutoBillingService.notifyFingerprint(
        'com.tencent.mm',
        '微信支付',
        '已支付¥8.00',
        notificationKey: 'pkg|id|tag',
        notificationId: 42,
        postTime: 1757900000000,
      );
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('C6:同通知被更新(postTime 变化)→ 不同指纹(与 native 口径一致)', () {
      final a = AutoBillingService.notifyFingerprint(
        'com.tencent.mm',
        '微信支付',
        '已支付¥8.00',
        notificationKey: 'pkg|id|tag',
        notificationId: 42,
        postTime: 1757900000000,
      );
      final b = AutoBillingService.notifyFingerprint(
        'com.tencent.mm',
        '微信支付',
        '已支付¥8.00',
        notificationKey: 'pkg|id|tag',
        notificationId: 42,
        postTime: 1757900005000,
      );
      expect(a, isNot(b),
          reason: 'C6:native 指纹含 postTime,Dart 侧旧口径(pkg|title|body)不含');
    });

    test('缺身份字段 → 退回内容指纹(旧队列兼容)', () {
      final a = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00');
      final b = AutoBillingService.notifyFingerprint(
        'com.tencent.mm',
        '微信支付',
        '已支付¥8.00',
        notificationKey: '',
        notificationId: 0,
        postTime: 0,
      );
      expect(a, b);
    });
  });
}
