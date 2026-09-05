/// 来源渠道解析(M4-A):短信 sender / 通知 pkg → 中文渠道名。
///
/// 与 native 白名单镜像(见 android/.../SmsReceiver.kt TRUSTED_SENDER_KEYWORDS
/// 与 NotificationWatcher.kt TRUSTED_PACKAGES),命中率与 native 过滤一致,
/// 产出唯一渠道名供:
/// 1. entry 文本前缀(【来源:X】喂给 AI,账户/分类强先验);
/// 2. M4 渠道→账户映射(BillCreationService 按渠道名回退账户)。
/// 未命中返回 null(未知渠道,不注入)。
class SourceChannelResolver {
  /// 短信规则(顺序敏感:先特化后通用,与 native 白名单保持一致语义)。
  /// 匹配用 sender 大小写不敏感 contains。
  static const smsRules = <({String keyword, String channel})>[
    // 支付平台
    (keyword: '支付宝', channel: '支付宝'),
    (keyword: '微信支付', channel: '微信'),
    (keyword: '微信', channel: '微信'),
    (keyword: '财付通', channel: '微信'),
    (keyword: '京东支付', channel: '京东'),
    (keyword: '京东金融', channel: '京东'),
    (keyword: '美团支付', channel: '美团'),
    (keyword: '云闪付', channel: '云闪付'),
    (keyword: '银联商务', channel: '云闪付'),
    (keyword: '银联', channel: '云闪付'),
    (keyword: 'APPLE PAY', channel: 'Apple Pay'),
    (keyword: '滴滴', channel: '滴滴'),
    // 银行短号/名称(短号优先,避免"招行"与"中国农业银行"交叉)
    (keyword: '95555', channel: '招商银行'),
    (keyword: '招商银行', channel: '招商银行'),
    (keyword: '招商', channel: '招商银行'),
    (keyword: '95588', channel: '中国工商银行'),
    (keyword: '工商银行', channel: '中国工商银行'),
    (keyword: '95533', channel: '中国建设银行'),
    (keyword: '建设银行', channel: '中国建设银行'),
    (keyword: '95599', channel: '中国农业银行'),
    (keyword: '农业银行', channel: '中国农业银行'),
    (keyword: '95566', channel: '中国银行'),
    (keyword: '中国银行', channel: '中国银行'),
    (keyword: '95595', channel: '中国光大银行'),
    (keyword: '光大银行', channel: '中国光大银行'),
    (keyword: '95568', channel: '中国民生银行'),
    (keyword: '民生银行', channel: '中国民生银行'),
    (keyword: '95501', channel: '中国邮政储蓄银行'),
    (keyword: '邮储银行', channel: '中国邮政储蓄银行'),
    (keyword: '95504', channel: '中国邮政储蓄银行'),
    (keyword: '95559', channel: '交通银行'),
    (keyword: '交通银行', channel: '交通银行'),
    (keyword: '95511', channel: '中国平安银行'),
    (keyword: '平安银行', channel: '中国平安银行'),
    (keyword: '95508', channel: '广发银行'),
    (keyword: '95577', channel: '浙商银行'),
    (keyword: '95518', channel: '中国人民保险'),
    (keyword: '95516', channel: '中国银联'),
    (keyword: '95534', channel: '汇付天下'),
    // 运营商
    (keyword: '中国移动', channel: '中国移动'),
    (keyword: '10086', channel: '中国移动'),
    (keyword: '中国联通', channel: '中国联通'),
    (keyword: '10010', channel: '中国联通'),
    (keyword: '中国电信', channel: '中国电信'),
    (keyword: '10000', channel: '中国电信'),
  ];

  /// 短信 sender → 渠道名(大小写不敏感 contains;null = 未知)。
  static String? channelForSmsSender(String sender) {
    final s = sender.toUpperCase();
    for (final rule in smsRules) {
      if (s.contains(rule.keyword.toUpperCase())) return rule.channel;
    }
    return null;
  }

  /// 通知/屏幕文本包名 → 渠道名(与 native TRUSTED_PACKAGES 顺序镜像,更专门的在前)。
  /// 与 native 白名单保持一致;抖音/京东等新包名如需支持无障碍页面记账,
  /// 需同时加入 android/.../ScreenTextWatcher.kt TRUSTED_PACKAGES。
  /// 银行包名 2026-09 已逐家经应用商店核验(同 NotificationWatcher 注释);
  /// 原映射 com.chinabank.mobilebank(中行)/cn.pay.youjian(邮储)已证伪并修正。
  static const packageRules = <({String keyword, String channel})>[
    (keyword: 'com.ss.android.ugc.aweme.lite', channel: '抖音'),
    (keyword: 'com.ss.android.ugc.aweme', channel: '抖音'),
    (keyword: 'com.jingdong.app.mall', channel: '京东'),
    (keyword: 'com.tencent.mm.biz', channel: '微信'),
    (keyword: 'eg.android.AlipayGphone', channel: '支付宝'),
    (keyword: 'tencent.mm', channel: '微信'),
    (keyword: 'com.unionpay', channel: '云闪付'),
    (keyword: 'lianlian.trust', channel: '连连支付'),
    (keyword: 'com.chinamworld.bocmbci', channel: '中国银行'),
    (keyword: 'com.chinamworld.main', channel: '中国建设银行'),
    (keyword: 'com.icbc', channel: '中国工商银行'),
    (keyword: 'android.bankabc', channel: '中国农业银行'),
    (keyword: 'com.bankcomm.Bankcomm', channel: '交通银行'),
    (keyword: 'cmb.pb', channel: '招商银行'),
    (keyword: 'com.yitong.mbank.psbc', channel: '中国邮政储蓄银行'),
    (keyword: 'cn.com.cmbc.newmbank', channel: '中国民生银行'),
    (keyword: 'com.ecitic.bank.mobile', channel: '中信银行'),
    (keyword: 'cn.com.spdb.mobilebank.per', channel: '浦发银行'),
    (keyword: 'com.cib.cibmb', channel: '兴业银行'),
    (keyword: 'com.cgbchina.xpt', channel: '广发银行'),
    (keyword: 'com.hxb.mobile.client', channel: '华夏银行'),
    (keyword: 'com.pingan.paces.ccms', channel: '中国平安银行'),
    (keyword: 'com.webank.wemoney', channel: '微众银行'),
    (keyword: 'com.mybank.android.phone', channel: '网商银行'),
  ];

  /// 通知包名 → 渠道名(null = 未知)。
  static String? channelForPackage(String pkg) {
    for (final rule in packageRules) {
      if (pkg.contains(rule.keyword)) return rule.channel;
    }
    return null;
  }

  /// 组装给 AI 的文本:带【来源:XX】前缀(未知渠道原样返回)。
  static String withSourcePrefix(String? channel, String body) {
    if (channel == null || channel.isEmpty) return body;
    return '【来源:$channel】\n$body';
  }
}
