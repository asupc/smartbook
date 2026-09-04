import 'package:smartbook/services/billing/channel_account_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 渠道→账户映射(M4)存储测试:upsert/查/删/大小写不敏感。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('upsert 新增 + ruleFor 命中(大小写不敏感)', () async {
    final store = ChannelAccountStore();
    await store.upsert(const ChannelAccountRule(channelName: '招商银行', accountId: 3));
    await store.upsert(const ChannelAccountRule(channelName: '支付宝', accountId: 5));
    expect((await store.load()).length, 2);
    expect((await store.ruleFor('招商银行'))?.accountId, 3);
    expect((await store.ruleFor('招商银行 '))?.accountId, null);
  });

  test('同名渠道 upsert 覆盖', () async {
    final store = ChannelAccountStore();
    await store.upsert(const ChannelAccountRule(channelName: '微信', accountId: 1));
    await store.upsert(const ChannelAccountRule(channelName: '微信', accountId: 7));
    expect((await store.load()).length, 1);
    expect((await store.ruleFor('微信'))?.accountId, 7);
  });

  test('remove 删除规则', () async {
    final store = ChannelAccountStore();
    await store.upsert(const ChannelAccountRule(channelName: '云闪付', accountId: 2));
    expect(await store.remove('云闪付'), isTrue);
    expect(store.ruleFor('云闪付'), completion(isNull));
    expect(await store.remove('云闪付'), isFalse);
  });

  test('损坏 JSON 跳过,不影响其余规则', () async {
    SharedPreferences.setMockInitialValues(
        {'channel_account_rules_v1': ['{bad json', '{}', 'x']});
    final store = ChannelAccountStore();
    expect(await store.load(), isEmpty);
  });
}
