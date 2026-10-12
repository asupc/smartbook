import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart' as schema;

/// 渠道→账户映射规则(M4-B,B2 升级为带作用域的用户规则)。
///
/// 渠道名来自 [SourceChannelResolver](短信 sender / 通知 pkg → 中文渠道名,
/// 如"招商银行"/"支付宝")。
///
/// B2 新增维度(计划 B2 任务 5):**账本作用域、来源、可选卡尾号、币种**。
/// 只存最小必要字段 —— 卡尾号最多 4 位,绝不存完整卡号。
///
/// [ledgerId] 为 null = **旧版渠道规则**:升级前创建,作用账本未确认。
/// 旧规则在确认作用账本之前只走「旧兼容路径」(AI 未给账户名时才生效),
/// 不参与新的「用户规则优先于 AI 猜测」路径,也不会被自动推广到所有账本
/// (计划 B2 任务 6)。
class ChannelAccountRule {
  final String channelName;
  final int accountId;

  /// 规则生效的账本(本地 id);null = 旧版规则,作用账本未确认。
  final int? ledgerId;

  /// 生效来源('sms'/'notification'/'screen'/'image');空 = 不限来源。
  final List<String> sources;

  /// 可选卡号后四位(最多 4 位字符);null = 不限。
  final String? cardLast4;

  /// 规则适用币种;null = 不限。
  final String? currency;

  final bool enabled;

  const ChannelAccountRule({
    required this.channelName,
    required this.accountId,
    this.ledgerId,
    this.sources = const [],
    this.cardLast4,
    this.currency,
    this.enabled = true,
  });

  /// 旧版规则:创建时没有账本作用域(B2 之前的规则全是旧版)。
  bool get isLegacy => ledgerId == null;

  Map<String, dynamic> toJson() => {
        'channelName': channelName,
        'accountId': accountId,
        if (ledgerId != null) 'ledgerId': ledgerId,
        if (sources.isNotEmpty) 'sources': sources,
        if ((cardLast4 ?? '').isNotEmpty) 'cardLast4': cardLast4,
        if ((currency ?? '').isNotEmpty) 'currency': currency,
        if (!enabled) 'enabled': false,
      };

  static ChannelAccountRule? fromJson(Map<String, dynamic> json) {
    final channel = json['channelName'] as String?;
    final accountId = json['accountId'] as num?;
    if (channel == null || channel.isEmpty || accountId == null) return null;
    final cardLast4 = (json['cardLast4'] as String?)?.trim();
    final currency = (json['currency'] as String?)?.trim();
    return ChannelAccountRule(
      channelName: channel,
      accountId: accountId.toInt(),
      ledgerId: (json['ledgerId'] as num?)?.toInt(),
      sources: (json['sources'] is List)
          ? (json['sources'] as List).whereType<String>().toList()
          : const [],
      // 只保留 4 位:完整卡号永不落盘。
      cardLast4: (cardLast4 == null || cardLast4.isEmpty) ? null : cardLast4,
      currency: (currency == null || currency.isEmpty) ? null : currency,
      enabled: json['enabled'] != false,
    );
  }

  ChannelAccountRule copyWith({
    int? ledgerId,
    bool clearLedger = false,
    List<String>? sources,
    String? cardLast4,
    String? currency,
    bool? enabled,
  }) =>
      ChannelAccountRule(
        channelName: channelName,
        accountId: accountId,
        ledgerId: clearLedger ? null : (ledgerId ?? this.ledgerId),
        sources: sources ?? this.sources,
        cardLast4: cardLast4 ?? this.cardLast4,
        currency: currency ?? this.currency,
        enabled: enabled ?? this.enabled,
      );
}

/// 用户规则匹配裁决。
enum ChannelRuleStatus {
  /// 没有适用规则 —— 走既有 AI 匹配路径。
  none,

  /// 命中且有效 —— **优先于 AI 猜测**(B2 行为变更)。
  hit,

  /// 命中但无法验证(账户已删/隐藏/币种不符)—— 进入待确认,不静默回落。
  conflict,
}

class ChannelRuleMatch {
  const ChannelRuleMatch(this.status, {this.rule, this.reason});

  final ChannelRuleStatus status;
  final ChannelAccountRule? rule;

  /// conflict 的原因码:'account_missing' | 'account_hidden' |
  /// 'currency_mismatch' | 'target_ledger_missing'。
  final String? reason;

  static const none = ChannelRuleMatch(ChannelRuleStatus.none);
}

/// 纯函数版规则匹配(可单测)。
///
/// 依次要求:启用 → 非旧版 → 渠道相同 → 账本作用域命中 → 来源命中 →
/// 卡尾号命中 → 币种命中;全部命中后校验账户有效性,失效给 conflict。
ChannelRuleMatch matchChannelRule({
  required List<ChannelAccountRule> rules,
  required String channel,
  required String? source,
  required int ledgerId,
  String? cardLast4,
  String? currency,
  List<schema.Account> accounts = const [],
}) {
  final wantChannel = channel.trim().toLowerCase();
  if (wantChannel.isEmpty) return ChannelRuleMatch.none;
  final last4 = (cardLast4 ?? '').trim();

  for (final rule in rules) {
    if (!rule.enabled) continue;
    if (rule.isLegacy) continue; // 旧版规则走旧兼容路径
    if (rule.channelName.trim().toLowerCase() != wantChannel) continue;
    if (rule.ledgerId != ledgerId) continue;
    if (rule.sources.isNotEmpty &&
        (source == null || !rule.sources.contains(source))) {
      continue;
    }
    if (rule.cardLast4 != null &&
        (last4.isEmpty || rule.cardLast4 != last4)) {
      continue;
    }
    if (rule.currency != null &&
        currency != null &&
        rule.currency != currency) {
      continue;
    }

    // 候选命中 → 校验有效性。规则是用户明确意图,无法验证时不能静默回落。
    schema.Account? account;
    for (final a in accounts) {
      if (a.id == rule.accountId) account = a;
    }
    if (account == null) {
      return ChannelRuleMatch(ChannelRuleStatus.conflict,
          rule: rule, reason: 'account_missing');
    }
    if (account.hidden) {
      return ChannelRuleMatch(ChannelRuleStatus.conflict,
          rule: rule, reason: 'account_hidden');
    }
    if (currency != null &&
        account.currency.isNotEmpty &&
        account.currency != currency) {
      return ChannelRuleMatch(ChannelRuleStatus.conflict,
          rule: rule, reason: 'currency_mismatch');
    }
    return ChannelRuleMatch(ChannelRuleStatus.hit, rule: rule);
  }
  return ChannelRuleMatch.none;
}

/// 命中的用户账户规则**无法验证**(账户已删/隐藏/币种不符)。
///
/// 记账层捕获它后把这笔账单送进**待确认**,而不是静默回落默认账户 ——
/// 规则是用户明确意图,验证不了就必须让用户裁决(B2 任务 5)。
class AccountRuleConflictException implements Exception {
  AccountRuleConflictException(this.reason, {this.accountId});

  /// 'account_missing' | 'account_hidden' | 'currency_mismatch'
  final String reason;
  final int? accountId;

  @override
  String toString() => 'AccountRuleConflictException($reason)';
}

class ChannelAccountStore {
  static const _key = 'channel_account_rules_v1';

  /// 与 DedupExemptStore 同量级的上限,防止无界增长(B2 新增)。
  static const int maxRules = 200;

  // A13(2026-10-11):SharedPreferences 的 read-modify-write 不是原子的 ——
  // upsert/remove 都是「load() → 改 List → save()」,两个协程各自 load 到
  // 同一份快照后各自写回,后写的赢,用户配的账户规则静默消失。
  // 照抄 [PendingCandidateStore._tail] 的进程级尾链统一串行化。
  static Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<List<ChannelAccountRule>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) {
          try {
            return ChannelAccountRule.fromJson(
                Map<String, dynamic>.from(
                    (jsonDecode(s) as Map).cast<String, dynamic>()));
          } catch (_) {
            return null;
          }
        })
        .whereType<ChannelAccountRule>()
        .toList();
  }

  Future<void> save(List<ChannelAccountRule> rules) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, rules.map((r) => jsonEncode(r.toJson())).toList());
  }

  /// 旧兼容路径查询:按渠道名取第一条(含旧版规则),大小写不敏感。
  /// 仅在「AI 未给出账户名」时使用,行为与 B2 之前完全一致。
  Future<ChannelAccountRule?> ruleFor(String channelName) async {
    final rules = await load();
    for (final r in rules) {
      if (r.channelName.toLowerCase() == channelName.toLowerCase()) {
        return r;
      }
    }
    return null;
  }

  /// B2 新优先级路径:只认**有账本作用域**的用户规则。
  Future<ChannelRuleMatch> matchFor({
    required String channel,
    required String? source,
    required int ledgerId,
    String? cardLast4,
    String? currency,
    List<schema.Account> accounts = const [],
  }) async {
    final rules = await load();
    return matchChannelRule(
      rules: rules,
      channel: channel,
      source: source,
      ledgerId: ledgerId,
      cardLast4: cardLast4,
      currency: currency,
      accounts: accounts,
    );
  }

  /// 追加或覆盖同名渠道规则;返回操作后总条数。
  /// A13:整段 read-modify-write 走 [_serial] 尾链,并发调用不丢更新。
  Future<int> upsert(ChannelAccountRule rule) => _serial(() async {
        final rules = await load();
        rules.removeWhere((r) =>
            r.channelName.toLowerCase() == rule.channelName.toLowerCase());
        if (rules.length >= maxRules) {
          rules.removeAt(0);
        }
        rules.add(rule);
        await save(rules);
        return rules.length;
      });

  /// 删除规则;返回是否删除成功。
  /// A13:与 [upsert] 同一条尾链,删除也不会被并发 upsert 的旧快照覆盖。
  Future<bool> remove(String channelName) => _serial(() async {
        final rules = await load();
        final next = rules
            .where(
                (r) => r.channelName.toLowerCase() != channelName.toLowerCase())
            .toList();
        if (next.length == rules.length) return false;
        await save(next);
        return true;
      });

  /// 旧版规则(作用账本未确认)清单 —— 迁移提示用。
  Future<List<ChannelAccountRule>> legacyRules() async =>
      (await load()).where((r) => r.isLegacy).toList();
}
