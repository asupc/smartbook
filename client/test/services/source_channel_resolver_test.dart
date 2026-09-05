import 'package:smartbook/services/data/source_channel_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 来源渠道解析(M4)测试:短信短号/名称、通知包名 → 渠道名,文案前缀。
void main() {
  group('channelForSmsSender', () {
    test('银行短号 → 银行渠道', () {
      expect(SourceChannelResolver.channelForSmsSender('95555'), '招商银行');
      expect(
          SourceChannelResolver.channelForSmsSender('95588 欢迎您的来电'),
          '中国工商银行');
      expect(SourceChannelResolver.channelForSmsSender('[xx95599xx]'),
          '中国农业银行');
    });

    test('支付平台名称 → 渠道', () {
      expect(SourceChannelResolver.channelForSmsSender('支付宝'), '支付宝');
      expect(SourceChannelResolver.channelForSmsSender('微信支付'), '微信');
      expect(SourceChannelResolver.channelForSmsSender('财付通'), '微信');
      expect(SourceChannelResolver.channelForSmsSender('银联商务'), '云闪付');
    });

    test('银行名称(含中文后缀)→ 渠道', () {
      expect(SourceChannelResolver.channelForSmsSender('招商银行客户服务'), '招商银行');
      expect(
          SourceChannelResolver.channelForSmsSender('中国农业银行通知'), '中国农业银行');
    });

    test('运营商 → 渠道', () {
      expect(SourceChannelResolver.channelForSmsSender('10086'), '中国移动');
      expect(SourceChannelResolver.channelForSmsSender('中国联通'), '中国联通');
    });

    test('未知号 → null', () {
      expect(
          SourceChannelResolver.channelForSmsSender('99999999999'), isNull);
      expect(SourceChannelResolver.channelForSmsSender(''), isNull);
    });
  });

  group('channelForPackage', () {
    test('支付 App 包名 → 渠道', () {
      expect(
          SourceChannelResolver.channelForPackage(
              'com.eg.android.AlipayGphone'),
          '支付宝');
      expect(SourceChannelResolver.channelForPackage('com.tencent.mm'),
          '微信');
      // 服务号包名前缀含 tencent.mm,专门规则在前(顺序敏感)
      expect(
          SourceChannelResolver.channelForPackage('com.tencent.mm.biz'),
          '微信');
      expect(SourceChannelResolver.channelForPackage('com.unionpay.union'),
          '云闪付');
    });

    test('银行 App 包名 → 渠道', () {
      expect(SourceChannelResolver.channelForPackage('com.icbc.imepay'),
          '中国工商银行');
      expect(SourceChannelResolver.channelForPackage('android.bankabc'),
          '中国农业银行');
      expect(SourceChannelResolver.channelForPackage('cmb.pb.member'),
          '招商银行');
    });

    test('核验后的银行包名(2026-09)→ 渠道', () {
      // chinamworld 两家:bocmbci 在前,避免与 main 串道
      expect(SourceChannelResolver.channelForPackage('com.chinamworld.main'),
          '中国建设银行');
      expect(
          SourceChannelResolver.channelForPackage('com.chinamworld.bocmbci'),
          '中国银行');
      expect(
          SourceChannelResolver.channelForPackage('com.yitong.mbank.psbc'),
          '中国邮政储蓄银行');
      expect(SourceChannelResolver.channelForPackage('cn.com.cmbc.newmbank'),
          '中国民生银行');
      expect(SourceChannelResolver.channelForPackage('com.ecitic.bank.mobile'),
          '中信银行');
      expect(
          SourceChannelResolver.channelForPackage('cn.com.spdb.mobilebank.per'),
          '浦发银行');
      expect(SourceChannelResolver.channelForPackage('com.cib.cibmb'),
          '兴业银行');
      expect(SourceChannelResolver.channelForPackage('com.cgbchina.xpt'),
          '广发银行');
      expect(SourceChannelResolver.channelForPackage('com.hxb.mobile.client'),
          '华夏银行');
      expect(
          SourceChannelResolver.channelForPackage('com.pingan.paces.ccms'),
          '中国平安银行');
      expect(SourceChannelResolver.channelForPackage('com.webank.wemoney'),
          '微众银行');
      expect(
          SourceChannelResolver.channelForPackage('com.mybank.android.phone'),
          '网商银行');
      // 已证伪的旧包名不再命中(防止回退)
      expect(
          SourceChannelResolver.channelForPackage('com.chinabank.mobilebank'),
          isNull);
      expect(SourceChannelResolver.channelForPackage('cn.pay.youjian'), isNull);
    });

    test('屏幕文本监听包名(抖音/京东)→ 渠道', () {
      expect(SourceChannelResolver.channelForPackage('com.ss.android.ugc.aweme'),
          '抖音');
      // 极速版包名含主包名,渠道一致(专门规则在前)
      expect(
          SourceChannelResolver.channelForPackage('com.ss.android.ugc.aweme.lite'),
          '抖音');
      expect(SourceChannelResolver.channelForPackage('com.jingdong.app.mall'),
          '京东');
    });

    test('未知包名 → null', () {
      expect(SourceChannelResolver.channelForPackage('com.fake.app'),
          isNull);
    });
  });

  group('withSourcePrefix', () {
    test('有渠道 → 加【来源】前缀', () {
      expect(
        SourceChannelResolver.withSourcePrefix('招商银行', '您尾号1234卡消费20'),
        '【来源:招商银行】\n您尾号1234卡消费20',
      );
    });

    test('无渠道 → 原样返回', () {
      expect(SourceChannelResolver.withSourcePrefix(null, 'hello'), 'hello');
    });
  });
}
