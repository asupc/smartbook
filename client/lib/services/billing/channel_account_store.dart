import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 渠道→账户映射规则(M4-B,文档 plan §M4 任务 3)。
///
/// 渠道名来自 [SourceChannelResolver](短信 sender / 通知 pkg → 中文渠道名,
/// 如"招商银行"/"支付宝"),一条规则 = 渠道名 + 目标资产账户 id。
/// 自动记账时 AI 识别不出账户(或干脆没给)按来源渠道回退到这张表,
/// 比硬编码 typeMap(6 条)更符合"渠道→资产账户映射表"的产品语义。
///
/// 存储:SharedPreferences 单 key JSON 数组(规则量级很小,免 DB migration,
/// 与 M2 候选队列同一模式)。
class ChannelAccountRule {
  final String channelName;
  final int accountId;

  const ChannelAccountRule({
    required this.channelName,
    required this.accountId,
  });

  Map<String, dynamic> toJson() => {
        'channelName': channelName,
        'accountId': accountId,
      };

  static ChannelAccountRule? fromJson(Map<String, dynamic> json) {
    final channel = json['channelName'] as String?;
    final accountId = json['accountId'] as num?;
    if (channel == null || channel.isEmpty || accountId == null) return null;
    return ChannelAccountRule(channelName: channel, accountId: accountId.toInt());
  }
}

class ChannelAccountStore {
  static const _key = 'channel_account_rules_v1';

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

  /// 按渠道名查规则(大小写不敏感);无规则返回 null。
  Future<ChannelAccountRule?> ruleFor(String channelName) async {
    final rules = await load();
    for (final r in rules) {
      if (r.channelName.toLowerCase() == channelName.toLowerCase()) {
        return r;
      }
    }
    return null;
  }

  /// 追加或覆盖同名渠道规则;返回操作后总条数。
  Future<int> upsert(ChannelAccountRule rule) async {
    final rules = await load();
    rules.removeWhere(
        (r) => r.channelName.toLowerCase() == rule.channelName.toLowerCase());
    rules.add(rule);
    await save(rules);
    return rules.length;
  }

  /// 删除规则;返回是否删除成功。
  Future<bool> remove(String channelName) async {
    final rules = await load();
    final next = rules
        .where((r) => r.channelName.toLowerCase() != channelName.toLowerCase())
        .toList();
    if (next.length == rules.length) return false;
    await save(next);
    return true;
  }
}
