import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归背景(2026-10-13):服务器域名失效时,`SmartBookCloudAuthService.initialize`
/// 旧实现 `await _refreshSessionOrClear()` 把每个 auth 请求挂满 30s deadline,
/// 整条 `authServiceProvider.future` 链(状态卡/目标解析)被拖住实测 178s。
/// 契约:initialize 只做本地会话加载(毫秒级),刷新挪到后台;
/// `currentUserId` 同步可读、零网络。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseUrl = 'https://dead.example.com';
  const apiPrefix = '/api/v1';

  (SmartBookCloudAuthService, int Function()) fixture() {
    // 会话:access token 已过期(exp 在过去),触发 initialize 的刷新分支。
    final expired = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final digest =
        sha1.convert(utf8.encode('$baseUrl|$apiPrefix')).toString();
    SharedPreferences.setMockInitialValues({
      'smartbook_cloud_session_$digest': jsonEncode({
        'userId': 'user-abc',
        'email': 'a@b.c',
        'accessToken': 'at',
        'refreshToken': 'rt',
        'accessTokenExpiresAt': expired.toIso8601String(),
        'deviceId': 'dev',
      }),
    });
    var requested = 0;
    // 永不响应的 HTTP 客户端:模拟域名指向不回包的服务器。
    final client = MockClient((request) {
      requested++;
      return Completer<http.Response>().future;
    });
    final auth = SmartBookCloudAuthService(
      baseUrl: baseUrl,
      apiPrefix: apiPrefix,
      httpClient: client,
    );
    return (auth, () => requested);
  }

  test('initialize 在刷新挂死时也毫秒级完成(会话先行可见)', () async {
    final (auth, requested) = fixture();
    final sw = Stopwatch()..start();
    await auth.initialize();
    expect(sw.elapsed.inMilliseconds, lessThan(2000),
        reason: 'initialize 只做本地会话加载,不等网络刷新');
    // 会话已可同步读取,后台刷新已发出(不要求完成)。
    expect(auth.currentUserId, 'user-abc');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requested(), greaterThanOrEqualTo(1));
  });

  test('authStateChanges 立即发出缓存用户,不等刷新', () async {
    final (auth, _) = fixture();
    final emitFuture = auth.authStateChanges.first
        .timeout(const Duration(seconds: 2));
    await auth.initialize();
    final first = await emitFuture;
    expect(first?.id, 'user-abc');
  });

  test('currentUserId 零网络:无请求也能读到', () async {
    final (auth, requested) = fixture();
    // 故意不 initialize(会话未加载)→ null;initialize 后可读且只发后台刷新。
    expect(auth.currentUserId, isNull);
    expect(requested(), 0);
    await auth.initialize();
    expect(auth.currentUserId, 'user-abc');
  });
}
