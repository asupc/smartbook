import 'dart:async';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/providers/sync_providers.dart';
import 'package:smartbook/services/automation/automation_settings_store.dart';

/// 回归背景(2026-10-13):scope 解析旧实现 `await auth.currentUser` 在
/// 服务器域名失效时跟着 auth 网络请求挂满 30s deadline(实测整链 178s),
/// 状态卡转圈数分钟。契约:scope 只做零网络同步读 + 2s 有界兜底。
class _FixedIdAuth extends NoopAuthService {
  @override
  String? get currentUserId => 'user-1';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已加载会话:同步读 currentUserId,零网络', () async {
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWith((ref) async => _FixedIdAuth()),
    ]);
    addTearDown(container.dispose);
    final scope = await currentAutomationUserScope(container);
    expect(scope, 'user:user-1');
  });

  test('auth future 永不完成:2 秒兜底回退 local,不再死等', () async {
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWith(
        (ref) => Completer<CloudAuthService>().future,
      ),
    ]);
    addTearDown(container.dispose);
    final sw = Stopwatch()..start();
    final scope = await currentAutomationUserScope(container);
    expect(scope, 'local');
    // 2s 超时 + 少量调度余量;远小于旧实现的 3 分钟级死等。
    expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
  });

  test('未登录(Noop):回 local', () async {
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWith((ref) async => NoopAuthService()),
    ]);
    addTearDown(container.dispose);
    expect(await currentAutomationUserScope(container), 'local');
  });
}
