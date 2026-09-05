import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/services/import/parsers/alipay_parser.dart';
import 'package:smartbook/services/import/parsers/wechat_parser.dart';

void main() {
  test('支付宝新版字段映射和状态/退款归一', () {
    final parser = AlipayBillParser();
    final mapping = parser.mapColumns([
      '交易号',
      '交易创建时间',
      '金额（元）',
      '交易状态',
      '成功退款（元）',
      '收/支',
    ]);

    expect(mapping['external_id'], 0);
    expect(mapping['date'], 1);
    expect(mapping['status'], 3);
    expect(mapping['refund_amount'], 4);
    expect(parser.normalizeStatus('交易成功'), 'success');
    expect(parser.normalizeStatus('交易关闭'), 'closed');
    expect(parser.normalizeStatus('退款成功'), 'refund');
    expect(parser.normalizeRefundAmount('￥1,234.50'), 1234.5);
  });

  test('微信状态/退款字段归一且 provider 稳定', () {
    final parser = WechatBillParser();
    final mapping = parser.mapColumns([
      '交易时间',
      '交易单号',
      '当前状态',
      '退款金额',
    ]);

    expect(parser.providerKey, 'wechat');
    expect(mapping['date'], 0);
    expect(mapping['external_id'], 1);
    expect(mapping['status'], 2);
    expect(mapping['refund_amount'], 3);
    expect(parser.normalizeStatus('已完成'), 'success');
    expect(parser.normalizeStatus('待支付'), 'pending');
    expect(parser.normalizeStatus('交易失败'), 'failed');
    expect(parser.normalizeRefundAmount('12.30'), 12.3);
  });
}
