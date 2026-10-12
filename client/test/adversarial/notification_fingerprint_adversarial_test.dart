// 对抗性测试 — 通知/短信指纹与文本工具域。
//
// 攻击面:`lib/services/automation/auto_billing_service.dart` 的
// `smsFingerprint` / `notifyFingerprint` / `screenTextFingerprint` /
// `billFingerprint`(与 `android/.../SmsReceiver.kt`、`NotificationWatcher.kt`、
// `ScreenTextWatcher.kt` 的 native 同口径契约),`lib/utils/notification_util.dart`、
// `lib/utils/notification_tap_router.dart`,以及
// `lib/services/data_import_service.dart` 的状态归一(退款/非可记账)。
//
// 红绿纪律:
// - 确认缺陷 → 断言当前错误行为并失败,行内标 `// ADVERSE FINDING: <标题>`。
// - 行为可辩护但脆弱 → 断言当前行为并通过,行内标 `// HARDENING: <说明>`。
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:smartbook/services/data_import_service.dart';
import 'package:smartbook/services/import/parsers/alipay_parser.dart';
import 'package:smartbook/services/import/parsers/wechat_parser.dart';
import 'package:smartbook/utils/notification_tap_router.dart';
import 'package:smartbook/utils/notification_util.dart';

/// 构造一个真实的 `NotificationResponse`(与 local notifications 插件同型)。
NotificationResponse tapResponse(String payload) => NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotification,
      payload: payload,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('smsFingerprint:分隔符拼接的碰撞面', () {
    test('同 sender+body 稳定;hex 16 位', () {
      final a = AutoBillingService.smsFingerprint('95555', '尾号1234消费100元');
      final b = AutoBillingService.smsFingerprint('95555', '尾号1234消费100元');
      expect(a, b);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    });

    test('内容差一字 → 指纹变', () {
      expect(AutoBillingService.smsFingerprint('95555', '消费100元'),
          isNot(AutoBillingService.smsFingerprint('95555', '消费200元')));
    });

    test('sender 不同 → 指纹变;中文多字节稳定(UTF-8)', () {
      expect(AutoBillingService.smsFingerprint('95555', '消费100元'),
          isNot(AutoBillingService.smsFingerprint('招商银行', '消费100元')));
      final a = AutoBillingService.smsFingerprint(
          '招商银行', '您尾号8888的储蓄卡于14:32消费人民币¥1,234.56元');
      final b = AutoBillingService.smsFingerprint(
          '招商银行', '您尾号8888的储蓄卡于14:32消费人民币¥1,234.56元');
      expect(a, b);
    });

    // ADVERSE FINDING: 指纹输入是 `'$sender|$body'` 裸拼接,不转义分隔符。
    // 短信发送号(sender)由系统给出、正文(body)来自用户可见内容 ——
    // 只要正文里出现 `|`,就能与 sender 边界互换构造出**不同来源的相同指纹**:
    //   ('95555', '消费100|转账') 与 ('95555|消费100', '转账') 撞同一指纹。
    // 真实危害有限(sender 是号码,不含 `|`),性质属"契约脆弱/可构造碰撞"。
    // 源码:`lib/services/automation/auto_billing_service.dart:1077-1082`;
    // native 同口径:`android/app/src/main/kotlin/com/smartbook/zhi/SmsReceiver.kt:139-144`。
    test('sender/body 边界互换 → 指纹碰撞', () {
      final a = AutoBillingService.smsFingerprint('95555', '消费100|转账');
      final b = AutoBillingService.smsFingerprint('95555|消费100', '转账');
      expect(a, isNot(b),
          reason: 'ADVERSE FINDING: 裸拼接无转义,不同 (sender, body) 组合撞出同一指纹'
              '(a=$a b=$b)');
    });

    // HARDENING: 正文空白**不**归一 —— 前后空格/尾部换行都会改变指纹。
    // 短信正文由系统原样给出,一般不含首尾空白;但同一笔交易经不同
    // 网关(native 队列 vs 人工模拟)可能导致指纹 miss 一次,由语义判重兜底。
    test('正文首尾空白不做归一(指纹按逐字节算)', () {
      final base = AutoBillingService.smsFingerprint('95555', '消费100元');
      expect(AutoBillingService.smsFingerprint('95555', ' 消费100元 '),
          isNot(base),
          reason: 'HARDENING 标记:空白敏感,指纹不归一');
      expect(AutoBillingService.smsFingerprint('95555', '消费100元\n'),
          isNot(base));
    });

    test('换行/制表差异 → 不同指纹(不做 NFC 归一)', () {
      expect(AutoBillingService.smsFingerprint('95555', 'a\nb'),
          isNot(AutoBillingService.smsFingerprint('95555', 'a b')));
    });

    test('组合字符 vs 预组合字符 → 不同指纹(不做 Unicode 归一)', () {
      // 'é' U+00E9 vs 'e' + U+0301
      final precomposed = AutoBillingService.smsFingerprint('a', 'é');
      final decomposed = AutoBillingService.smsFingerprint('a', 'e\u0301');
      expect(precomposed, isNot(decomposed),
          reason: 'HARDENING 标记:不做 NFC/NFD 归一(短信场景风险低)');
    });

    test('超长正文(200KB)不崩,仍 16 字符', () {
      expect(AutoBillingService.smsFingerprint('a', 'x' * 200000), hasLength(16));
    });

    test('空 sender / 空 body 可算(package 层不校验空)', () {
      expect(AutoBillingService.smsFingerprint('', ''), hasLength(16));
      expect(AutoBillingService.smsFingerprint('', ''),
          isNot(AutoBillingService.smsFingerprint('', ' ')));
    });
  });

  group('notifyFingerprint:身份字段与内容字段的边界', () {
    test('同身份稳定;缺身份时退回内容指纹', () {
      final a = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00',
          notificationKey: 'pkg|id|tag', notificationId: 42, postTime: 1757900000000);
      final b = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00',
          notificationKey: 'pkg|id|tag', notificationId: 42, postTime: 1757900000000);
      expect(a, b);

      final legacy = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00');
      final legacyEq = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00',
          notificationKey: '', notificationId: 0, postTime: 0);
      expect(legacy, legacyEq);
    });

    test('postTime 变化 → 指纹变(同通知被更新会重新入队)', () {
      final a = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00',
          notificationKey: 'k', notificationId: 42, postTime: 1757900000000);
      final b = AutoBillingService.notifyFingerprint('com.tencent.mm', '微信支付', '已支付¥8.00',
          notificationKey: 'k', notificationId: 42, postTime: 1757900005000);
      expect(a, isNot(b));
    });

    // HARDENING: 身份字段"部分提供"时口径切换。只给 notificationId(不给 key/postTime)
    // 会走新格式;三个都缺才走旧格式。Dart 侧与 native 用同一判据
    // (`isNullOrBlank && id==0 && postTime==0`),所以两侧不会分叉 ——
    // 但**只要任一个非零**,后到的 title/body 就必须逐字相同才判重。
    test('部分身份字段即启用新格式(与 native 判据一致)', () {
      final onlyId = AutoBillingService.notifyFingerprint('pkg', 't', 'b', notificationId: 42);
      final emptyIdentity = AutoBillingService.notifyFingerprint('pkg', 't', 'b',
          notificationKey: '', notificationId: 0, postTime: 0);
      expect(onlyId, isNot(emptyIdentity),
          reason: 'HARDENING 标记:仅 id 非零即走 6 段格式');
    });

    // ADVERSE FINDING: 6 段格式同样是裸拼接。notificationKey 由系统构造
    // (`"${id}:${tag}"` 或 `s.key`),title/body 来自通知内容 ——
    // title 里出现 `|` 就能与 notificationKey 边界互换撞指纹。
    // native 侧 `NotificationWatcher.kt:180-191` 同公式同样脆弱。
    test('notificationKey/title/body 边界互换 → 指纹碰撞', () {
      final a = AutoBillingService.notifyFingerprint('p', 't|x', 'y',
          notificationKey: 'k', notificationId: 1, postTime: 2);
      final b = AutoBillingService.notifyFingerprint('p', 't', 'x|y',
          notificationKey: 'k', notificationId: 1, postTime: 2);
      expect(a, isNot(b),
          reason: 'ADVERSE FINDING: 裸拼接无长度前缀/转义,'
              'title 与 body 的 `|` 可互换构造同一指纹(a=$a b=$b)');
    });

    // HARDENING: "缺身份"路径的指纹格式是 3 段 `pkg|title|body`,
    // 与 6 段格式共享前缀 `pkg`。理论上存在 3 段串与 6 段串的跨格式碰撞:
    // 3 段 `A|B|C|D|E|F`? 不可能(3 段只有两个分隔符),除非
    // pkg/title/body 自身含 `|`。上面的边界互换缺陷是同一根因。
    test('超长 title+body 不崩', () {
      expect(
          AutoBillingService.notifyFingerprint('pkg', 't' * 100000, 'b' * 100000),
          hasLength(16));
    });
  });

  group('通知内容变体:标题/正文微改对指纹的影响', () {
    // HARDENING: 支付通知的"标题体变体""字段顺序调换""多余空白"都会
    // 改变指纹。native 侧以 `postTime` 与 `notificationKey` 为身份,
    // 所以同一通知被系统更新(正文追加"已送达"等)会重新入队 ——
    // 这是**有意**的口径(C6),真正的去重交给语义判重。
    // 这里把所有变体锁成"指纹都不同",作为口径文档。
    test('同通知不同标题体 → 不同指纹', () {
      final bodies = <String, String>{};
      for (final title in ['微信支付', '微信支付通知', '微信', '微信支付 ']) {
        bodies[title] = AutoBillingService.notifyFingerprint(
            'com.tencent.mm', title, '已支付¥8.00',
            notificationKey: 'k', notificationId: 1, postTime: 1);
      }
      expect(bodies.values.toSet(), hasLength(bodies.length),
          reason: 'HARDENING 标记:标题变体各自独立指纹(靠语义判重收敛)');
    });

    test('正文多余空白/换行/字段顺序调换 → 不同指纹', () {
      final variants = [
        '已支付¥8.00 商户A',
        '已支付¥8.00 商户A ',
        '已支付¥8.00  商户A',
        '已支付¥8.00\n商户A',
        '商户A 已支付¥8.00',
      ];
      final fps = variants
          .map((b) => AutoBillingService.notifyFingerprint('pkg', 't', b))
          .toSet();
      expect(fps, hasLength(variants.length),
          reason: 'HARDENING 标记:空白与字段顺序都进指纹,不做归一');
    });

    test('正文改一个字 → 指纹变(去重不会误吞真实第二笔)', () {
      expect(
          AutoBillingService.notifyFingerprint('pkg', '微信支付', '已支付¥8.00'),
          isNot(AutoBillingService.notifyFingerprint('pkg', '微信支付', '已支付¥8.01')));
    });

    // HARDENING: 不同的**来源**(短信 / 通知 / 屏幕文本)走三套独立指纹且互不
    // 相通 —— 同一笔支付被多路捕获时,各路指纹都不命中对方的缓存。去重完全
    // 依赖下游 SemanticDedupMatcher(金额+1 分钟窗口)。这里锁定"指纹层
    // 不做跨源协调"这一事实。
    test('相同文本经不同入口 → 指纹互不相同(跨源去重只在语义层)', () {
      const pkg = 'com.tencent.mm';
      const title = '微信支付';
      const body = '已支付¥8.00';
      final notify = AutoBillingService.notifyFingerprint(pkg, title, body);
      final screen = AutoBillingService.screenTextFingerprint(pkg, '$title\n$body');
      final sms = AutoBillingService.smsFingerprint('95555', body);
      expect({notify, screen, sms}, hasLength(3),
          reason: 'HARDENING 标记:三路指纹互不相同 —— 指纹层不做跨源协调,'
              '同笔支付的多路捕获只能靠语义判重兜底');
    });

    test('超长正文(100KB)在 notify/screen 两路都不崩', () {
      final big = 'x' * 100000;
      expect(AutoBillingService.notifyFingerprint('pkg', big, big), hasLength(16));
      expect(AutoBillingService.screenTextFingerprint('pkg', big), hasLength(16));
    });

    // HARDENING: 渠道(支付宝/微信/云闪付)的标题体变体走的是同一条指纹公式,
    // 指纹本身不区分渠道语义 —— 区分靠 `pkg`(包名)。同一包名下的不同
    // 标题体(如"支付宝" vs "支付宝通知")得到不同指纹,由语义判重收敛。
    test('支付宝/微信/云闪付标题体变体的指纹互不相同', () {
      final cases = <String, List<String>>{
        'com.eg.android.AlipayGphone': ['支付宝', '支付宝通知', '支付成功'],
        'com.tencent.mm': ['微信支付', '微信支付凭证', '微信'],
        'com.unionpay': ['云闪付', '云闪付支付', '银联云闪付通知'],
      };
      for (final entry in cases.entries) {
        final fps = entry.value
            .map((t) => AutoBillingService.notifyFingerprint(
                entry.key, t, '支付成功 ¥8.00',
                notificationKey: 'k', notificationId: 1, postTime: 1))
            .toSet();
        expect(fps, hasLength(entry.value.length),
            reason: 'HARDENING 标记:${entry.key} 的标题变体各自独立指纹');
      }
    });

    // HARDENING: pkg 参与指纹 —— 同一渠道的不同 App 包名会得到完全不同的
    // 指纹("支付宝 App 通知" vs 小程序/插件包名),跨包名无法互判已处理。
    // 去重依赖语义判重。当前行为锁在这里。
    test('同渠道不同包名 → 指纹不交叉(跨包名无法互判已处理)', () {
      const body = '支付成功 ¥8.00';
      final a = AutoBillingService.notifyFingerprint(
          'com.eg.android.AlipayGphone', '支付宝', body,
          notificationKey: 'k', notificationId: 1, postTime: 1);
      final b = AutoBillingService.notifyFingerprint(
          'com.alipay.android.app', '支付宝', body,
          notificationKey: 'k', notificationId: 1, postTime: 1);
      expect(a, isNot(b),
          reason: 'HARDENING 标记:pkg 参与指纹,同渠道多包名场景无互判');
    });
  });

  group('screenTextFingerprint / billFingerprint', () {
    // ADVERSE FINDING: `sha256(pkg|text)` 同款裸拼接 ——
    // 屏幕文本来自无障碍抓取的整棵文本树,含大量用户内容与 `|`。
    test('pkg/text 边界互换 → 指纹碰撞', () {
      final a = AutoBillingService.screenTextFingerprint('com.x', 'a|b');
      final b = AutoBillingService.screenTextFingerprint('com.x|a', 'b');
      expect(a, isNot(b),
          reason: 'ADVERSE FINDING: pkg|text 裸拼接可碰撞(a=$a b=$b)');
    });

    test('内容差一字 → 指纹变;同输入稳定', () {
      final base = AutoBillingService.screenTextFingerprint('com.x', '实付金额:¥25.00');
      expect(base, AutoBillingService.screenTextFingerprint('com.x', '实付金额:¥25.00'));
      expect(base,
          isNot(AutoBillingService.screenTextFingerprint('com.x', '实付金额:¥25.01')));
    });

    group('billFingerprint(小时粒度 + 方向)', () {
      test('同日同小时同账单 → 相同', () {
        final a = AutoBillingService.billFingerprint(
            channel: '支付宝', amount: -19.9, note: '瑞幸咖啡',
            time: DateTime(2026, 9, 10, 14, 3), type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: '支付宝', amount: -19.9, note: '瑞幸咖啡',
            time: DateTime(2026, 9, 10, 14, 58), type: 'expense');
        expect(a, b);
      });

      test('同日不同小时 → 不同(真实第二笔不被吞)', () {
        final a = AutoBillingService.billFingerprint(
            channel: '支付宝', amount: -19.9, note: '瑞幸咖啡',
            time: DateTime(2026, 9, 10, 9, 5), type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: '支付宝', amount: -19.9, note: '瑞幸咖啡',
            time: DateTime(2026, 9, 10, 15, 2), type: 'expense');
        expect(a, isNot(b));
      });

      test('方向不同 → 不同(退款不被吞)', () {
        final pay = AutoBillingService.billFingerprint(
            channel: '微信支付', amount: -88.0, note: '京东',
            time: DateTime(2026, 9, 15, 10), type: 'expense');
        final refund = AutoBillingService.billFingerprint(
            channel: '微信支付', amount: 88.0, note: '京东',
            time: DateTime(2026, 9, 15, 10), type: 'income');
        expect(pay, isNot(refund));
      });

      // 接受风险锁定(计划 §五「不修/接受风险清单」):金额 `toStringAsFixed(2)`
      // 的精度归一是**去重的有意设计**(源码注释已说明),本轮明确保留 ——
      // 因此这条不再作为 ADVERSE 待修项,改为锁定"归一保留"这一产品决策,
      // 并记录其代价:0.01 元以内的真实第二笔会被判为重复。
      // (若未来改口径,应同步改这里与 §五。)
      test('HARDENING(接受风险):金额 0.01 元内差异归一到同指纹', () {
        final a = AutoBillingService.billFingerprint(
            channel: 'c', amount: -88.004, note: 'x',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: 'c', amount: -88.0, note: 'x',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        expect(a, b,
            reason: '接受风险:toFixed(2) 让 88.004/88.00 同指纹(去重有意设计);'
                '金额忠实性由上游金额解析把关,不靠指纹区分 4 厘差异');
        // 对照:跨越分位(0.006 元以上)仍能区分 —— 归一粒度是"分"
        final c = AutoBillingService.billFingerprint(
            channel: 'c', amount: -88.006, note: 'x',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        expect(b, isNot(c),
            reason: '分位以上的差异仍可区分(归一粒度=分,不是"金额无关")');
      });

      // HARDENING: 时间用**本地**年月日时拼串(不转 UTC)。
      // 同一 wall-clock 但 isUtc=true 的 DateTime 会与本地时刻同指纹 ——
      // 语义上等价(指纹只关心墙上时刻),可辩护。
      test('isUtc 标记不影响指纹(只取墙上时刻)', () {
        final u = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: 'n',
            time: DateTime.utc(2026, 9, 10, 12), type: 'expense');
        final l = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: 'n',
            time: DateTime(2026, 9, 10, 12), type: 'expense');
        expect(u, l,
            reason: 'HARDENING 标记:UTC 标记被忽略,同一墙上时刻同指纹');
      });

      test('time=null → 空日期段(同日无时间戳的账单全部撞在一起)', () {
        final a = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: 'n', time: null, type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: 'n', time: null, type: 'expense');
        expect(a, b);
        final differentTime = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: 'n', time: DateTime.now(), type: 'expense');
        expect(a, isNot(differentTime),
            reason: 'HARDENING 标记:null 与有值不同指纹,但两个 null 无法区分');
      });

      // 口径更新(2026-10-11,批次 C1 A9 同批):`billFingerprint` 的 channel
      // 已按 A9 归一(trim + lower + 压缩内部空白),`note` 也走
      // `normalizeAutoBookText`(不再只 trim)。原 HARDENING 锁("channel 不归一、
      // 大小写/空白变化即不同指纹")因此失效 —— 该断言锁的是归一缺口本身,
      // A9 修掉后必须反向。这里改为锁定**归一已生效**。
      test('channel 归一已生效:大小写/前后空白不再改变指纹', () {
        final a = AutoBillingService.billFingerprint(
            channel: '支付宝', amount: -1, note: 'n',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: 'alipay', amount: -1, note: 'n',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        final c = AutoBillingService.billFingerprint(
            channel: ' 支付宝 ', amount: -1, note: 'n',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        final d = AutoBillingService.billFingerprint(
            channel: '支 付 宝', amount: -1, note: 'n',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        // 前后空白归一 → 同指纹;不同文字(支付宝 vs alipay)仍是不同渠道
        expect(a, c, reason: 'A9:channel trim 后应同指纹');
        expect(a, isNot(d),
            reason: 'A9 只做 trim/lower/空白压缩 —— 渠道名中间的空白是名字的一部分,'
                '压缩后仍是"支 付 宝"≠"支付宝"');
        expect(a, isNot(b),
            reason: '中英文是不同渠道名,归一不改变语义(仅去空白/大小写)');
      });

      test('note 前后空白被 trim(与 channel 不一致的归一力度)', () {
        final a = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: ' 咖啡 ',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        final b = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: '咖啡',
            time: DateTime(2026, 9, 10, 14), type: 'expense');
        expect(a, b, reason: 'HARDENING 标记:note/type trim,channel 不 trim');
      });

      test('note=null 与 note="" 同口径', () {
        final a = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: null, time: null, type: null);
        final b = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1, note: '', time: null, type: '');
        expect(a, b);
      });

      test('金额 abs 归一小数精度:0.001 差异被舍入吞掉', () {
        final a = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1.001, note: 'n', time: null, type: 'e');
        final b = AutoBillingService.billFingerprint(
            channel: 'c', amount: -1.004, note: 'n', time: null, type: 'e');
        expect(a, b,
            reason: 'HARDENING 标记:toStringAsFixed(2) 让 1.001/1.004 同指纹');
      });
    });
  });

  group('notification_util:下次提醒时间', () {
    // 修复后(2026-10-11,批次 C2):`calculateNextReminderTime` 校验 hour/minute
    // 范围,越界抛 ArgumentError(不再静默进位)。
    // (原断言 `d.hour == 25` 锁的是"溢出进位"这一缺陷形态 —— 它本身永不成立,
    // 只能靠 DateTime 归一化后 hour!=25 而失败;测试名与 reason 已写明
    // "应被拒绝而非静默进位",改为断言抛错才是它声称的期望。)
    test('越界 hour=25 / minute=61 应被拒绝而非静默进位', () {
      expect(() => calculateNextReminderTime(25, 61),
          throwsA(isA<ArgumentError>()),
          reason: '25:61 必须被拒绝,不能静默进位成次日 02:01');
    });

    test('负数 hour/minute 应被拒绝而非反向进位', () {
      expect(() => calculateNextReminderTime(-1, -1),
          throwsA(isA<ArgumentError>()),
          reason: '(-1,-1) 必须被拒绝,不能静默反向进位');
    });

    // HARDENING: 已过的时间点顺延到明天 —— 注释明确此为有意行为。
    // 但"已过"判定把**当前这一分钟**也算进去:now=08:30:45 时 (8,30)
    // 被判为已过并顺延到明天,用户设"每天 8:30"会看到"下次明天"。
    test('当天时刻已过(含当前分钟)→ 顺延到明天或今天', () {
      final now = DateTime.now();
      final d = calculateNextReminderTime(now.hour, now.minute);
      // 构造出的时刻永不早于 now(要么今天晚些、要么明天),
      // 且时分与入参完全一致——非法输入以外的行为可辩护。
      expect(d.isBefore(now), isFalse,
          reason: 'HARDENING 标记:结果不早于 now;当前分钟被判定为已过时'
              '会立刻顺延到明天(用户设"每天 8:30"在 8:30:45 保存看到"下次明天")');
      expect(d.hour, now.hour);
      expect(d.minute, now.minute);
      final todayMidnight = DateTime(now.year, now.month, now.day);
      final tomorrowMidnight = todayMidnight.add(const Duration(days: 1));
      expect(d.isBefore(tomorrowMidnight.add(const Duration(days: 1))), isTrue);
      expect(d.isAfter(todayMidnight.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('未来时刻 → 返回今天', () {
      final now = DateTime.now();
      // 加两小时(跨日则由顺延分支接手,断言仍成立:结果必须在 now 之后)
      final target = now.add(const Duration(hours: 2));
      final d = calculateNextReminderTime(target.hour, target.minute);
      expect(d.isAfter(now), isTrue);
      expect(d.hour, target.hour);
      expect(d.minute, target.minute);
    });
  });

  group('notification_tap_router:冷启动补发', () {
    test('handler 未注册 → payload 入 pending,consume 一次后清空', () {
      NotificationTapRouter.handler = null;
      NotificationTapRouter.consumePending(); // 清残留
      NotificationTapRouter.onTap(tapResponse('smartbook://open?page=x'));
      final first = NotificationTapRouter.consumePending();
      final second = NotificationTapRouter.consumePending();
      expect(first, 'smartbook://open?page=x');
      expect(second, isNull);
    });

    test('handler 已注册 → 直接派发,不进 pending', () {
      String? received;
      NotificationTapRouter.handler = (uri) => received = uri;
      NotificationTapRouter.onTap(tapResponse('smartbook://open?page=y'));
      NotificationTapRouter.handler = null;
      expect(received, 'smartbook://open?page=y');
      expect(NotificationTapRouter.consumePending(), isNull);
    });

    // HARDENING: 空/缺失 payload 直接 return,不派发也不入 pending
    // (无 payload 的通知点击是无意义的,跳转无目标)。
    test('空 payload 被忽略', () {
      String? received;
      NotificationTapRouter.handler = (uri) => received = uri;
      NotificationTapRouter.onTap(tapResponse(''));
      NotificationTapRouter.handler = null;
      expect(received, isNull);
    });

    // HARDENING: onTap 对 payload 原样透传,不做 URI 校验/白名单。
    // handler 侧(AppLink)自行解析;畸形 payload 会到达那里。
    test('畸形 payload 原样透传(不做 URI 校验)', () {
      String? received;
      NotificationTapRouter.handler = (uri) => received = uri;
      for (final bad in ['not-a-uri', 'javascript:alert(1)', '../../etc', '🎉']) {
        NotificationTapRouter.onTap(tapResponse(bad));
        expect(received, bad,
            reason: 'HARDENING 标记:payload 无校验,透传给 AppLink');
      }
      NotificationTapRouter.handler = null;
    });
  });

  group('指纹/工具入口:畸形输入总扫(不抛未捕获异常)', () {
    test('smsFingerprint 对畸形输入不抛异常', () {
      final nasty = [
        ('', ''),
        ('  ', '  '),
        ('a', '\u0000\u0001'),
        ('🎉', '🍜'),
        ('a' * 100000, 'b' * 100000),
        ('95555', '|'),
        ('|', '|'),
      ];
      for (final (sender, body) in nasty) {
        expect(() => AutoBillingService.smsFingerprint(sender, body),
            returnsNormally);
      }
    });

    test('notifyFingerprint / screenTextFingerprint 对畸形输入不抛异常', () {
      final nasty = ['', '   ', '\u0000', '🎉', 'x' * 100000, '|', '\n\n'];
      for (final s in nasty) {
        expect(() => AutoBillingService.notifyFingerprint(s, s, s),
            returnsNormally);
        expect(() => AutoBillingService.screenTextFingerprint(s, s),
            returnsNormally);
        expect(() => AutoBillingService.billFingerprint(
              channel: s,
              amount: -1,
              note: s,
              time: DateTime.now(),
              type: s,
            ), returnsNormally);
      }
    });

    test('billFingerprint 对 NaN/Infinity 金额不抛异常(但指纹会塌缩)', () {
      final nan1 = AutoBillingService.billFingerprint(
          channel: 'c', amount: double.nan, note: 'n', time: null, type: 'e');
      final nan2 = AutoBillingService.billFingerprint(
          channel: 'c', amount: double.nan, note: 'n', time: null, type: 'e');
      final inf = AutoBillingService.billFingerprint(
          channel: 'c', amount: double.infinity, note: 'n', time: null, type: 'e');
      expect(nan1, nan2);
      expect(nan1, isNot(inf),
          reason: 'HARDENING 标记:NaN 指纹自洽且与 Infinity 区分'
              '(amount.abs().toStringAsFixed(2) 产出 "NaN"/"Infinity")');
    });

    test('normalizeStatus / isNonBookableStatus 对畸形状态不抛异常', () {
      for (final s in ['', '   ', '\u0000', '🎉', 'x' * 100000, '|']) {
        expect(() => AlipayBillParser().normalizeStatus(s), returnsNormally);
        expect(() => WechatBillParser().normalizeStatus(s), returnsNormally);
        expect(() => DataImportService.isNonBookableStatus(s), returnsNormally);
        expect(() => DataImportService.isRefundStatus(s), returnsNormally);
      }
      expect(AlipayBillParser().normalizeStatus(''), isNull);
      expect(AlipayBillParser().normalizeStatus('   '), isNull);
    });
  });

  group('导入状态归一:退款与"不可记账"的判定交叉', () {
    test('成功类状态不被误判为不可记账', () {
      for (final s in ['交易成功', '已完成', '支付成功', '已付款']) {
        expect(DataImportService.isNonBookableStatus(s), isFalse,
            reason: '$s 不应被判不可记账');
      }
    });

    test('失败/关闭/取消类被判不可记账', () {
      for (final s in ['待支付', '处理中', '交易关闭', '支付失败', '已取消', '订单关闭']) {
        expect(DataImportService.isNonBookableStatus(s), isTrue, reason: s);
      }
    });

    test('退款状态被单独识别', () {
      expect(DataImportService.isRefundStatus('退款成功'), isTrue);
      expect(DataImportService.isRefundStatus('部分退款'), isTrue);
      expect(DataImportService.isRefundStatus('refund'), isTrue);
      expect(DataImportService.isRefundStatus('交易成功'), isFalse);
    });

    // 修复后(2026-10-11,批次 C2):"退款关闭"同时命中退款与"关闭",
    // 但退款语义更具体,判定顺序改为 **isRefundStatus 优先于
    // isNonBookableStatus** —— 含"退款/退费/refund"的状态一律可记账
    // (资金实际可能已退回,记退款收入),与 AlipayBillParser.normalizeStatus
    // 的「refund 优先于 closed」口径对齐。此前的 ADVERSE 断言
    // (isNonBookableStatus('退款关闭') == true → 退款行被静默丢弃)
    // 正是被测出的缺陷行为,修复后改为断言非碰撞口径。
    // 源码:`lib/services/data_import_service.dart` isNonBookableStatus。
    test('"退款关闭"退款优先:不再被判不可记账', () {
      expect(DataImportService.isNonBookableStatus('退款关闭'), isFalse,
          reason: '修复:退款优先于关闭,退款行不再被 ignored;'
              '与 parser 的 normalizeStatus(\'退款关闭\')==\'refund\' 一致');
    });

    // 修复后(2026-10-11,批次 C2)回归锁:纯"取消/关闭"(不含退款)
    // 仍必须被判不可记账,证明退款优先分支没有放宽 dead row 的拦截面。
    test('纯关闭/取消状态仍被判不可记账(退款优先未放宽 dead row)', () {
      for (final s in ['交易关闭', '已取消', '订单关闭', '取消订单']) {
        expect(DataImportService.isNonBookableStatus(s), isTrue, reason: s);
      }
    });

    // 修复后(2026-10-11,批次 C2):原来 isNonBookableStatus 用 `contains`
    // 子串匹配,"取消退款成功"因含"取消"被判不可记账 —— 与语义相反
    // (它其实是"取消后已退款成功",钱已回来)。退款优先分支落地后该复合态
    // 走退款路径,不再进 ignored。此条原为 HARDENING 锁(记录一刀切行为),
    // 现改为断言修复后的口径。
    test('复合态"取消退款成功"按退款处理,不再被"取消"一刀切', () {
      expect(DataImportService.isRefundStatus('取消退款成功'), isTrue);
      expect(DataImportService.isNonBookableStatus('取消退款成功'), isFalse,
          reason: '修复:含"退款"即退款优先,语义相反的复合态不被"取消"误杀');
    });

    // 回归锁:不含退款语义的复合态仍按子串匹配挡住(如"待支付已取消")。
    test('含退款与否决定复合态判定:无退款语义仍判不可记账', () {
      expect(DataImportService.isNonBookableStatus('待支付已取消'), isTrue);
      expect(DataImportService.isNonBookableStatus('处理中'), isTrue);
    });

    test('支付宝 status 归一:退款优先于关闭', () {
      final p = AlipayBillParser();
      expect(p.normalizeStatus('退款关闭'), 'refund');
      expect(p.normalizeStatus('交易关闭'), 'closed');
      expect(p.normalizeStatus('部分退款'), 'refund');
      expect(p.normalizeStatus('   '), isNull);
    });

    // HARDENING: 微信 parser 缺"已支出/已收入"映射(支付宝有),
    // 状态原样透传;导入侧 isNonBookableStatus 不含这两个词,
    // 所以按成功入账 —— 结果正确,但依赖"未登记词恰好安全"。
    test('微信 normalizeStatus 缺 已支出/已收入 映射', () {
      final w = WechatBillParser();
      expect(w.normalizeStatus('已支出'), '已支出',
          reason: 'HARDENING 标记:原样透传,靠下游白名单侥幸安全');
      expect(w.normalizeStatus('已完成'), 'success');
      expect(w.normalizeStatus('交易失败'), 'failed');
    });

    // HARDENING: 状态判定对英文大小写敏感度不一致 —— isNonBookableStatus
    // 先 toLowerCase 再匹配英文表,但中文表在 lower 后仍可用;
    // 'FAILED' 命中 'failed'。而 parser 的 normalizeStatus 也是小写匹配。
    test('英文状态大小写不敏感', () {
      expect(DataImportService.isNonBookableStatus('FAILED'), isTrue);
      expect(DataImportService.isNonBookableStatus('Canceled'), isTrue);
      expect(WechatBillParser().normalizeStatus('SUCCESS'), 'success');
    });

    // ADVERSE FINDING: 状态里含"退款"就整行按**收入**记账
    // (`isRefundStatus` → effectiveType='income'),包括
    // "退款失败"/"退款处理中"这类**钱还没回来**的状态 ——
    // 而 AlipayBillParser.normalizeStatus 把"退款失败"归一成 'failed',
    // 判 non-bookable 挡住。冲突点:若 status 列被平台写成裸
    // "退款"(无"失败"字样)而实际退款被驳回,会被记成收入。
    test('仅含"退款"二字的模糊状态被判退款收入', () {
      expect(DataImportService.isRefundStatus('退款'), isTrue,
          reason: 'ADVERSE FINDING: 模糊状态"退款"直接按退款收入处理,'
              '结合 isNonBookableStatus("退款")=false → 必然入账');
      expect(DataImportService.isNonBookableStatus('退款'), isFalse);
    });
  });
}
