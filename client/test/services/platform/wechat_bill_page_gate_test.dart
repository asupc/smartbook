import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/services/platform/screen_text_monitor_service.dart';

/// B6(2026-09-15,fix plan 附录 B6):微信退款详情页系统性漏记 —— drain 侧
/// 微信账单页双特征门的状态值词表不认「退款成功」,退款详情页被整页 ACK
/// 丢弃。本测试锁定新词表口径(与 native ScreenTextWatcher.isWechatBillPage
/// 同步维护)。
void main() {
  group('ScreenTextMonitorService.isWechatBillPageText', () {
    test('支出账单详情(当前状态 支付成功)放行', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '账单详情\n当前状态 支付成功\n-529.00\n创建时间 2026-09-05 20:28:42',
        ),
        isTrue,
      );
    });

    test('收款账单详情(支付状态 已存入零钱)放行', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '转账详情\n支付状态 已存入零钱\n+8.00',
        ),
        isTrue,
      );
    });

    test('B6:退款详情页(当前状态 退款成功)放行 —— 旧词表不认,系统性漏记', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '退款详情\n当前状态 退款成功\n¥8.00\n退款方式 零钱\n创建时间 2026-09-15 09:30',
        ),
        isTrue,
      );
    });

    test('B6:退款详情页旧版字段(支付状态 已退款)放行', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '退款详情\n支付状态 已退款\n¥8.00',
        ),
        isTrue,
      );
    });

    test('聊天列表预览(有金额无状态字段行)仍拦截', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '微信支付\n已支付¥8.00\n好友消息\n今晚吃火锅吗',
        ),
        isFalse,
      );
    });

    test('有状态字段但无已结算状态值仍拦截(防退回旧口径)', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
          'com.tencent.mm',
          '当前状态 转账中\n¥8.00',
        ),
        isFalse,
      );
    });

    test('非微信包名不受约束', () {
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
            'com.eg.android.AlipayGphone', '任意文本'),
        isTrue,
      );
      expect(
        ScreenTextMonitorService.isWechatBillPageText(
            'com.ss.android.ugc.aweme', '任意文本'),
        isTrue,
      );
    });
  });
}
