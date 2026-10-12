import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/data/db.dart' as schema;
import 'package:smartbook/services/billing/channel_account_store.dart';

schema.Account account({
  required int id,
  String currency = 'CNY',
  bool hidden = false,
  String name = '账户',
}) =>
    schema.Account(
      id: id,
      ledgerId: 0,
      name: name,
      type: 'bank',
      currency: currency,
      initialBalance: 0,
      sortOrder: 0,
      hidden: hidden,
    );

ChannelAccountRule rule({
  int? ledgerId = 1,
  List<String> sources = const [],
  String? cardLast4,
  String? currency,
  bool enabled = true,
  int accountId = 10,
  String channel = '招商银行',
}) =>
    ChannelAccountRule(
      channelName: channel,
      accountId: accountId,
      ledgerId: ledgerId,
      sources: sources,
      cardLast4: cardLast4,
      currency: currency,
      enabled: enabled,
    );

void main() {
  final accounts = [
    account(id: 10, name: '招行储蓄卡'),
    account(id: 11, name: '隐藏卡', hidden: true),
    account(id: 12, name: '美元卡', currency: 'USD'),
  ];

  group('新优先级路径只认有作用账本的规则', () {
    test('旧版规则(ledgerId=null)不参与 —— 保持旧兼容路径', () {
      final m = matchChannelRule(
        rules: [rule(ledgerId: null)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('停用的规则不生效', () {
      final m = matchChannelRule(
        rules: [rule(enabled: false)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('账本作用域不命中 → none', () {
      final m = matchChannelRule(
        rules: [rule(ledgerId: 1)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 2,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('来源作用域:限短信的规则不作用于通知', () {
      final rules = [rule(sources: ['sms'])];
      expect(
        matchChannelRule(
          rules: rules,
          channel: '招商银行',
          source: 'notification',
          ledgerId: 1,
          accounts: accounts,
        ).status,
        ChannelRuleStatus.none,
      );
      expect(
        matchChannelRule(
          rules: rules,
          channel: '招商银行',
          source: 'sms',
          ledgerId: 1,
          accounts: accounts,
        ).status,
        ChannelRuleStatus.hit,
      );
    });

    test('卡尾号:本笔没有尾号/尾号不符都不命中', () {
      final rules = [rule(cardLast4: '1234')];
      expect(
        matchChannelRule(
          rules: rules,
          channel: '招商银行',
          source: 'sms',
          ledgerId: 1,
          accounts: accounts,
        ).status,
        ChannelRuleStatus.none,
        reason: '本笔无尾号',
      );
      expect(
        matchChannelRule(
          rules: rules,
          channel: '招商银行',
          source: 'sms',
          ledgerId: 1,
          cardLast4: '9999',
          accounts: accounts,
        ).status,
        ChannelRuleStatus.none,
        reason: '尾号不符',
      );
      expect(
        matchChannelRule(
          rules: rules,
          channel: '招商银行',
          source: 'sms',
          ledgerId: 1,
          cardLast4: '1234',
          accounts: accounts,
        ).status,
        ChannelRuleStatus.hit,
      );
    });

    test('币种作用域:规则限 CNY 而本笔是 USD → 不命中(可回落 AI)', () {
      final m = matchChannelRule(
        rules: [rule(currency: 'CNY')],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        currency: 'USD',
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.none);
    });

    test('渠道名大小写/空白不敏感', () {
      final m = matchChannelRule(
        rules: [rule(channel: '招商银行')],
        channel: '  招商银行 ',
        source: 'sms',
        ledgerId: 1,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.hit);
    });
  });

  group('命中但无法验证 → conflict(进待确认,不静默回落)', () {
    test('账户已被删除', () {
      final m = matchChannelRule(
        rules: [rule(accountId: 999)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.conflict);
      expect(m.reason, 'account_missing');
    });

    test('账户已隐藏', () {
      final m = matchChannelRule(
        rules: [rule(accountId: 11)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.conflict);
      expect(m.reason, 'account_hidden');
    });

    test('账户币种与本笔不符', () {
      final m = matchChannelRule(
        rules: [rule(accountId: 12)],
        channel: '招商银行',
        source: 'sms',
        ledgerId: 1,
        currency: 'CNY',
        accounts: accounts,
      );
      expect(m.status, ChannelRuleStatus.conflict);
      expect(m.reason, 'currency_mismatch');
    });
  });

  group('规则序列化', () {
    test('旧 JSON(只有渠道+账户)→ 旧版规则', () {
      final parsed = ChannelAccountRule.fromJson({
        'channelName': '支付宝',
        'accountId': 5,
      });
      expect(parsed, isNotNull);
      expect(parsed!.isLegacy, isTrue);
      expect(parsed.enabled, isTrue);
      expect(parsed.sources, isEmpty);
    });

    test('新字段往返;卡尾号只保留 4 位输入', () {
      final original = rule(
        ledgerId: 3,
        sources: ['sms', 'notification'],
        cardLast4: '1234',
        currency: 'CNY',
        enabled: false,
        accountId: 42,
      );
      final back = ChannelAccountRule.fromJson(original.toJson())!;
      expect(back.ledgerId, 3);
      expect(back.sources, ['sms', 'notification']);
      expect(back.cardLast4, '1234');
      expect(back.currency, 'CNY');
      expect(back.enabled, isFalse);
      expect(back.isLegacy, isFalse);
    });

    test('copyWith 换作用账本后不再是旧版规则', () {
      final legacy = rule(ledgerId: null);
      expect(legacy.isLegacy, isTrue);
      final confirmed = legacy.copyWith(ledgerId: 1);
      expect(confirmed.isLegacy, isFalse);
      expect(confirmed.ledgerId, 1);
    });
  });
}
