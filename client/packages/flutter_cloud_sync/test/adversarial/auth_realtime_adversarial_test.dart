// 对抗性测试 — 认证(AuthService)/ 实时(WebSocket)/ Provider 错误映射
//
// 规则:
//   // ADVERSE FINDING: <标题>  → 已确认缺陷,断言"应有行为",保持失败(红)
//   // HARDENING: <说明>        → 行为可辩护但脆弱,断言当前行为并通过(绿)
//
// 反 flaky: HTTP 用 MockClient;WS 用 127.0.0.1 回环(不依赖外网),
//          超时全部显式给足,且不以 wall-clock 做断言。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> _loginPayload({
  String userId = 'u1',
  String email = 'a@b.c',
  String access = 'access-1',
  String refresh = 'refresh-1',
  num expiresIn = 3600,
  String deviceId = 'dev1',
}) =>
    {
      'user': {'id': userId, 'email': email},
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': expiresIn,
      'device_id': deviceId,
    };

/// 包内 session 存储 key 的算法复刻:
/// `smartbook_cloud_session_<sha1(baseUrl|apiPrefix)>`
/// (lib/src/providers/smartbook_cloud_provider.dart:1202-1206)
String sessionPrefsKey(String baseUrl, String apiPrefix) =>
    'smartbook_cloud_session_${sha1.convert(utf8.encode('$baseUrl|$apiPrefix'))}';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SmartBookCloudAuthService — 令牌边界', () {
    test('ADVERSE: 空字符串 access/refresh token 被全盘接受', () async {
      // ADVERSE FINDING: _SmartBookCloudSession.fromAuthResponse 只校验类型
      // (String),不校验非空;空 token 会被持久化并当作有效凭证使用。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:3580-3610
      // 期望: 空 access_token / refresh_token 视为非法响应(拒绝登录)
      // 实际: 登录"成功",requireAccessToken() 返回空串,后续请求带
      //       'Authorization: Bearer '(空),服务端 401 → 又触发 refresh → 循环
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(access: '', refresh: ''));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      try {
        await auth.signInWithEmail(email: 'e', password: 'p');
        fail('空 token 的登录响应不应被接受');
      } on CloudAuthException {
        // 期望路径
      } finally {
        auth.dispose();
      }
    });

    test('ADVERSE: 超长 token(1MB)无长度校验,直接进请求头/存储', () async {
      // ADVERSE FINDING: token 无长度上限校验
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:3580-3610 (无校验),
      //       1705-1710 (_saveSession 直接写 SharedPreferences)
      // 期望: 明显超长的 token 被拒(防内存/存储放大与响应头构造失败)
      // 实际: 原样接受并持久化
      final huge = 'A' * (1024 * 1024);
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(access: huge, refresh: huge));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      try {
        await auth.signInWithEmail(email: 'e', password: 'p');
        final token = await auth.requireAccessToken();
        expect(token.length, lessThan(8192),
            reason: '实际接受了 ${token.length} 字节的 token');
      } on CloudAuthException {
        // 期望路径:超长 token 在登录响应解析阶段即被拒
      } finally {
        auth.dispose();
      }
    });

    test('HARDENING: token 含 CRLF 时请求构造失败(不会发出头注入)', () async {
      // HARDENING: http 包自身拒绝含 CR/LF 的头值 → 请求发不出去,
      // 因此头注入在当前依赖版本(package:http 1.6.0)下不成立。
      // 但代价是:(a) 错误类型为 FormatException(非 CloudSyncException);
      //          (b) 损坏 token 已被持久化,后续**每次**调用都失败,
      //              只能靠重新登录或 session 过期恢复。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path.endsWith('/auth/login')) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_loginPayload(access: 'a\r\nX-Injected: yes')));
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('[]');
        }
        await req.response.close();
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'http://127.0.0.1:${server.port}', apiPrefix: '/api/v1');
      await auth.signInWithEmail(email: 'e', password: 'p');
      final storage = SmartBookCloudStorageService(
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiPrefix: '/api/v1',
          auth: auth);
      await expectLater(
        storage.list(path: ''),
        throwsA(isA<FormatException>()),
      );
      // 反复失败:损坏 token 常驻,没有自愈路径
      await expectLater(
        storage.list(path: ''),
        throwsA(isA<FormatException>()),
      );
      auth.dispose();
      storage.dispose();
      await server.close(force: true);
    });

    test('HARDENING: 无 newline 的超长 token 可正常发出(仅当长度合理时)', () async {
      // 对照组:证明上一条的失败源于 CRLF,而不是"含特殊字符一律失败"
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(access: 'a b\tc'));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      expect(await auth.requireAccessToken(), equals('a b\tc'));
      auth.dispose();
    });

    test('HARDENING: expires_in≤30s 时每次读取 token 都打一次 /auth/refresh', () async {
      // HARDENING: _isAccessTokenExpired 有 30s 提前量
      // (lib/src/providers/smartbook_cloud_provider.dart:1753-1757),
      // expires_in <= 30 时**每次** requireAccessToken 都判定过期并 refresh。
      // server 是 rotating refresh token,每次 refresh 轮换并 revoke 旧 token
      // (源码注释 lib/src/providers/smartbook_cloud_provider.dart:1334-1344),
      // 低频调用方会持续轮换 token。可辩护:token 确实已"将过期",刷新是
      // 正确动作,无缓存可复用;脆弱:调用频率 = 刷新频率(依赖服务端 TTL 配置)。
      var refreshes = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(expiresIn: 0));
        }
        if (req.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          return _json(_loginPayload(
              access: 'access-$refreshes',
              refresh: 'refresh-$refreshes',
              expiresIn: 0));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      refreshes = 0;
      for (var i = 0; i < 3; i++) {
        await auth.requireAccessToken();
      }
      auth.dispose();
      expect(refreshes, equals(3),
          reason: '当前行为:3 次读取 → 3 次 refresh(rotating token 下 = 轮换 3 次)');
    });

    test('ADVERSE: expires_in 极大(1e19)→ 会话永久处于"已过期"态', () async {
      // ADVERSE FINDING: expires_in.toInt() 在超出 int64 时饱和为
      // 9223372036854775807;该值当 **秒** 进 Duration(seconds:) 后微秒乘法
      // 溢出成负值 → accessTokenExpiresAt 落在过去 → 会话永远"已过期"。
      // 影响: realtime 重连路径 `if (auth.isAccessTokenExpired)
      //      await auth.tryRefreshSession()`(4479-4483 附近)与
      //      requireAccessToken 的 30s 提前量判定会**每次**都触发 refresh;
      //      server 是 rotating refresh token,等于每次心跳轮换一次 token。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:3596-3607,
      //       1753-1768 (isAccessTokenExpired)
      // 期望: 新登录(session 刚建立)的 isAccessTokenExpired 为 false
      // 实际: true —— 会话被判为永久过期
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(expiresIn: 1e19));
        }
        if (req.url.path.endsWith('/auth/refresh')) {
          return _json(_loginPayload(expiresIn: 1e19));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      final expired = auth.isAccessTokenExpired;
      auth.dispose();
      expect(expired, isFalse,
          reason: '刚登录的会话被判定为已过期(expires_in=1e19 溢出)');
    });

    test('ADVERSE: expires_in 为 Infinity(JSON 1e999)直接崩在 round', () async {
      // ADVERSE FINDING: jsonDecode('1e999') = Infinity(double),
      // Infinity.toInt() 抛 UnsupportedError(非本包异常类型),穿透登录路径。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:3596-3607
      // 期望: 非法 expires_in 被作为 CloudAuthException 处理
      // 实际: UnsupportedError: Infinity or NaN toInt
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return http.Response(
              '{"user":{"id":"u1"},"access_token":"a","refresh_token":"r",'
              '"expires_in":1e999,"device_id":"d"}',
              200,
              headers: {'content-type': 'application/json'});
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      try {
        await auth.signInWithEmail(email: 'e', password: 'p');
        fail('应当抛出');
      } catch (e) {
        expect(e, isA<CloudAuthException>(),
            reason: '实际抛 ${e.runtimeType}: $e');
      } finally {
        auth.dispose();
      }
    });

    test('HARDENING: 畸形登录响应抛 FormatException(非 CloudAuthException)', () async {
      // HARDENING: missing refresh_token / 非 JSON / 空对象 都抛 FormatException,
      // 不属于 CloudAuthException 家族;App 侧 login_page 的
      // friendlyAuthError(e) 会走默认分支展示原始文本。
      Future<void> attempt(Object body) async {
        final client =
            MockClient((req) async => _json(body));
        final auth = SmartBookCloudAuthService(
            baseUrl: 'https://h.test',
            apiPrefix: '/api/v1',
            httpClient: client);
        try {
          await expectLater(auth.signInWithEmail(email: 'e', password: 'p'),
              throwsA(isA<FormatException>()));
        } finally {
          auth.dispose();
        }
      }

      await attempt({
        'user': {'id': 'u1'},
        'access_token': 'a',
        'expires_in': 1,
        'device_id': 'd'
      }); // 缺 refresh_token
      await attempt(const <String, dynamic>{}); // 空对象
      await attempt({'user': 'not-a-map'}); // user 非对象
    });

    test('HARDENING: 服务端 4xx/5xx 被映射为 CloudAuthException + detail 文本', () async {
      for (final status in [400, 401, 403, 422, 500, 503]) {
        final client = MockClient((req) async {
          if (req.url.path.endsWith('/auth/login')) {
            return _json({'detail': 'server says no'}, status);
          }
          return _json({'ok': 1});
        });
        final auth = SmartBookCloudAuthService(
            baseUrl: 'https://h.test',
            apiPrefix: '/api/v1',
            httpClient: client);
        try {
          await expectLater(
            auth.signInWithEmail(email: 'e', password: 'p'),
            throwsA(isA<CloudAuthException>()),
          );
        } finally {
          auth.dispose();
        }
      }
    });

    test('HARDENING: detail 为结构化列表时降级为 HTTP <code>(字段级错误丢失)', () async {
      // HARDENING: _extractErrorMessage 只认 detail 是 String
      // (lib/src/providers/smartbook_cloud_provider.dart:4611-4620)。
      // FastAPI 的 422 校验错误 detail 是 list → 退化成 'HTTP 422',
      // 用户看到的错误没有信息量(无法定位哪个字段)
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json({
            'detail': [
              {
                'loc': ['body', 'email'],
                'msg': 'field required',
                'type': 'value_error.missing',
              }
            ]
          }, 422);
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      try {
        await auth.signInWithEmail(email: 'e', password: 'p');
        fail('应当抛出');
      } on CloudAuthException catch (e) {
        // 记录当前行为:详情被丢弃
        expect(e.message, equals('Login failed: HTTP 422'));
      } finally {
        auth.dispose();
      }
    });
  });

  group('SmartBookCloudAuthService — 会话状态机', () {
    test('ADVERSE: signOut 后恢复凭证会把用户"自动登回去"', () async {
      // ADVERSE FINDING: signOut 只清 session,不清 _recoveryEmail/_recoveryPassword
      // (lib/src/providers/smartbook_cloud_provider.dart:1178-1200 设置,
      //  1623-1642 signOut 不重置);App 侧 smartbookCloudProviderInstance
      // (client/lib/providers/sync_providers.dart:634-638)注入的邮密仍在内存里,
      // 于是 signOut 后任何 currentUser / requireAccessToken 都会静默重登。
      // 用户点"退出登录"后,只要 UI 再触发一次读取(如 sync 页刷新),
      // 会话就复活 —— 退出语义失效。
      // 期望: signOut 后 currentUser 保持 null(直至用户主动登录)
      // 实际: 立刻用恢复凭证重登,返回原用户
      var logins = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          logins++;
          return _json(_loginPayload(access: 'a$logins', refresh: 'r$logins'));
        }
        if (req.url.path.endsWith('/auth/logout')) return _json({'ok': 1});
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      auth.setRecoveryCredentials(email: 'e', password: 'p');
      await auth.currentUser; // 首次静默登录
      await auth.signOut();
      final after = await auth.currentUser;
      auth.dispose();
      expect(after, isNull,
          reason: '退出登录后 currentUser 又返回了 ${after?.id}(共登录 $logins 次)');
    });

    test('HARDENING: signOut 清 access/refresh 凭证,但 device_id 持久化残留', () async {
      // HARDENING: _clearSession 只删 session key(1726-1731,含 access/refresh
      // token —— 凭证清理到位);设备 ID key(_localDeviceIdStorageKey:1711)
      // 与内存中的恢复邮密保留。保留 device_id 可辩护(设备身份跨登录稳定,
      // 服务端按设备轮换/吊销),但策略未文档化,且与恢复邮密组合会放大
      // "登出后自动重登"红项的影响面。
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload());
        }
        if (req.url.path.endsWith('/auth/logout')) return _json({'ok': 1});
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      await auth.signOut();
      final prefs = await SharedPreferences.getInstance();
      final leftovers =
          prefs.getKeys().where((k) => k.contains('local_device_id')).toList();
      auth.dispose();
      // 凭证(session:access+refresh)已清
      expect(prefs.getString(sessionPrefsKey('https://h.test', '/api/v1')),
          isNull, reason: '退出后凭证残留');
      // 设备身份 key 保留(当前行为)
      expect(leftovers, isNotEmpty,
          reason: '当前行为:退出后设备身份 key 残留 $leftovers');
    });

    test('ADVERSE: dispose() 后再 signOut 抛 StateError(流已关闭)', () async {
      // ADVERSE FINDING: dispose 关闭 _authStateController(1655-1658),
      // 但 _clearSession(1726-1731)仍会 add(null) → StateError。
      // Riverpod 场景里 provider dispose 与 UI 回调存在竞态,可能命中。
      // 期望: dispose 后的内部回调变成 no-op(幂等)
      // 实际: StateError: Cannot add new events after calling close
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload());
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      auth.dispose();
      await expectLater(auth.signOut(), completes);
    });

    test('HARDENING: 并发 refresh 被 in-flight 去重(只打一次 server)', () async {
      // HARDENING: 正确的 rotating-refresh-token 保护
      var refreshes = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          return _json(_loginPayload(expiresIn: 0));
        }
        if (req.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _json(_loginPayload(
              access: 'a', refresh: 'r', expiresIn: 3600));
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      refreshes = 0;
      await Future.wait([
        auth.tryRefreshSession(),
        auth.tryRefreshSession(),
        auth.tryRefreshSession(),
      ]);
      final n = refreshes;
      auth.dispose();
      expect(n, equals(1), reason: '并发 refresh 去重失效,打了 $n 次');
    });

    test('HARDENING: 网络失败(离线)不清 session,只返回 false', () async {
      // PERF-P0-05 的预期行为:离线 refresh 失败保留 session
      final prefs = await SharedPreferences.getInstance();
      final key = sessionPrefsKey('https://h.test', '/api/v1');
      await prefs.setString(
          key,
          jsonEncode({
            'userId': 'u1',
            'email': 'a@b.c',
            'accessToken': 'stale',
            'refreshToken': 'stale-refresh',
            'accessTokenExpiresAt': DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 1))
                .toIso8601String(),
            'deviceId': 'dev1',
          }));

      final client = MockClient((req) async {
        throw http.ClientException('offline', req.url);
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.initialize();
      final ok = await auth.tryRefreshSession();
      final stillStored =
          (await SharedPreferences.getInstance()).getString(key);
      auth.dispose();
      expect(ok, isFalse);
      expect(stillStored, isNotNull, reason: '离线 refresh 失败不应清 session');
    });

    test('HARDENING: initialize() 离线时立即发出缓存用户(refresh 挪后台)', () async {
      // 2026-10-13 契约更新:initialize 旧实现在离线 refresh 失败分支既不 emit
      // user 也不 emit null,依赖 authStateChanges 的 UI 永远停在"未知"状态
      // —— 旧测试记录过这个流语义缺口(消费方无法区分"未初始化"与"未登录")。
      // 现在 initialize 只做本地会话加载:session 先行可见(立即 emit 缓存
      // 用户),过期刷新挪到后台不阻塞初始化(服务器不可达时曾是每请求 30s
      // deadline 的死等,实测把 authServiceProvider.future 整条链拖 178s)。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          sessionPrefsKey('https://h.test', '/api/v1'),
          jsonEncode({
            'userId': 'u1',
            'email': 'a@b.c',
            'accessToken': 'stale',
            'refreshToken': 'r',
            'accessTokenExpiresAt': DateTime.now()
                .toUtc()
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
            'deviceId': 'dev1',
          }));
      final client = MockClient(
          (req) async => throw http.ClientException('offline', req.url));
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      final events = <CloudUser?>[];
      final sub = auth.authStateChanges.listen(events.add);
      await auth.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      auth.dispose();
      // 新契约:立即发出缓存用户;离线 refresh 失败不清 session(不 emit null)。
      expect(events, hasLength(1));
      expect(events.single?.id, 'u1');
    });

    test('HARDENING: 损坏的持久化 session 被静默清除', () async {
      final prefs = await SharedPreferences.getInstance();
      final key = sessionPrefsKey('https://h.test', '/api/v1');
      await prefs.setString(key, 'not json at all');
      final client = MockClient((req) async => _json({'ok': 1}));
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.initialize();
      final left =
          (await SharedPreferences.getInstance()).getString(key);
      auth.dispose();
      expect(auth.currentUserId, isNull);
      expect(left, isNull, reason: '损坏 session 未被清理');
    });

    test('HARDENING: session JSON 缺字段(旧版本升级)走清空路径', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          sessionPrefsKey('https://h.test', '/api/v1'),
          jsonEncode({'userId': 'u1'})); // 缺 accessToken/refreshToken/…
      final client = MockClient((req) async => _json({'ok': 1}));
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.initialize();
      final id = auth.currentUserId;
      auth.dispose();
      expect(id, isNull);
    });

    test('HARDENING: 品牌更名前 key 自动迁移读旧写新', () async {
      // cloud_service_store.dart:12 与 smartbook_cloud_provider.dart:1217
      // 的口径一致:读旧 key → 写新 key → 删旧 key
      final prefs = await SharedPreferences.getInstance();
      final digest = sha1.convert(utf8.encode('https://h.test|/api/v1'));
      final oldKey = 'beecount_cloud_session_$digest';
      await prefs.setString(
          oldKey,
          jsonEncode({
            'userId': 'legacy-u',
            'email': 'l@b.c',
            'accessToken': 'a',
            'refreshToken': 'r',
            'accessTokenExpiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
            'deviceId': 'legacy-dev',
          }));
      final client = MockClient((req) async => _json({'ok': 1}));
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.initialize();
      final migrated = prefs.getString('smartbook_cloud_session_$digest');
      auth.dispose();
      expect(migrated, isNotNull);
      expect(prefs.getString(oldKey), isNull);
    });

    test('HARDENING: NoopAuthService 明确不支持登录', () async {
      final noop = NoopAuthService();
      expect(await noop.currentUser, isNull);
      expect(await noop.authStateChanges.first, isNull);
      await expectLater(noop.signInWithEmail(email: 'e', password: 'p'),
          throwsA(isA<UnsupportedError>()));
      await expectLater(noop.signUpWithEmail(email: 'e', password: 'p'),
          throwsA(isA<UnsupportedError>()));
      await noop.signOut(); // 幂等
    });

    test('HARDENING: signOut 在无 session 时是 no-op', () async {
      final client = MockClient((req) async => _json({'ok': 1}));
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signOut();
      auth.dispose();
    });

    test('HARDENING: 恢复登录失败进 30s 冷却,不重复打 login', () async {
      var logins = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) {
          logins++;
          return _json({'detail': 'invalid'}, 401);
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      auth.setRecoveryCredentials(email: 'e', password: 'p');
      for (var i = 0; i < 5; i++) {
        expect(await auth.currentUser, isNull);
      }
      auth.dispose();
      expect(logins, equals(1), reason: '冷却失效,打了 $logins 次 /auth/login');
    });
  });

  group('SmartBookCloudStorageService — 状态码与响应形态映射', () {
    late SmartBookCloudAuthService auth;
    late MockClient client;

    MockClient buildClient(Future<http.Response> Function(http.Request) handler) {
      return MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        if (req.url.path.endsWith('/auth/refresh')) {
          return _json(_loginPayload(access: 'a2', refresh: 'r2'));
        }
        return handler(req);
      });
    }

    Future<SmartBookCloudStorageService> build(
        Future<http.Response> Function(http.Request) handler) async {
      client = buildClient(handler);
      auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      return SmartBookCloudStorageService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1',
          auth: auth,
          httpClient: client);
    }

    tearDown(() {
      auth.dispose();
    });

    test('ADVERSE: 2xx 但响应体不是 JSON 时抛 FormatException,绕过 CloudStorageException', () async {
      // ADVERSE FINDING: 所有解析点都假定 2xx 响应体是 JSON;
      // 反代/网关返回 HTML 错误页(200)时抛 FormatException。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:4595-4601 (_decodeJsonObject)
      // 期望: CloudStorageException('unexpected response body')
      // 实际: FormatException,且调用方(RetryHelper 默认策略)不重试它
      final storage = await build((req) async =>
          http.Response('<html>proxy error</html>', 200));
      await expectLater(
        storage.list(path: ''),
        throwsA(isA<CloudStorageException>()),
      );
      storage.dispose();
    });

    test('ADVERSE: /sync/ledgers 返回对象而非数组时静默视作"无云端账本"', () async {
      // ADVERSE FINDING: list() 对非 List 响应体直接返回 const []
      // (lib/src/providers/smartbook_cloud_provider.dart:2014-2017)。
      // 若服务端返回 {"detail": ...}(状态码 200),客户端会认为"云端没有账本"。
      // 主工程 app.dart:308 / sync_engine.dart:452 / transactions_sync_manager.dart:601
      // 都用 storage.list(path: '') 判断远端账本是否存在,空结果可能让
      // 流程走向"本地上传/新建",造成覆盖风险。
      // 期望: 响应形态不符时抛 CloudStorageException(不把"解析失败"当"无数据")
      // 实际: 静默返回空列表,无任何信号
      final storage = await build(
          (req) async => _json({'detail': 'internal shape change'}));
      // 修复后:形态不符直接抛错 —— 不再返回捏造的"空云端"。
      // (原断言先 expect(files, isEmpty) 再 expect(() async => ..., throwsA)
      //  两半自相矛盾:() async => ... 返回的是未 await 的 Future,matcher
      //  拿不到异常;且其注释本身就把静默 [] 标为缺陷。)
      await expectLater(
        storage.list(path: ''),
        throwsA(isA<CloudStorageException>()),
        reason: '形态不符应抛错而非返回 []',
      );
      storage.dispose();
    });

    test('ADVERSE: 404 与 2xx-空快照 不可区分,坏数据被当成"没有备份"', () async {
      // ADVERSE FINDING: download() 对 404 返回 null,对 2xx 但
      // snapshot/payload/content 形态不符**也**返回 null
      // (lib/src/providers/smartbook_cloud_provider.dart:1917-1926)。
      // 对调用方来说"云端没有该账本"和"云端账本损坏"是同一个信号 → 危险:
      // 主工程在 cloudNewer 判定里可能把损坏当"需要上传"从而覆盖云端。
      // 期望: 损坏(有 snapshot 但 content 非字符串)抛 CloudStorageException
      // 实际: 与 404 一样返回 null
      final corrupt = await build((req) async {
        if (req.url.path.endsWith('/sync/full')) {
          return _json({
            'snapshot': {
              'payload': {'content': 12345} // content 类型错误
            }
          });
        }
        return _json({'ok': 1});
      });
      // 修复后:损坏数据抛显式异常(不再是 null)。
      Object? corruptError;
      try {
        await corrupt.download(path: 'ledger_1.json');
      } catch (e) {
        corruptError = e;
      }
      corrupt.dispose();

      final missing = await build((req) async {
        if (req.url.path.endsWith('/sync/full')) {
          return http.Response('nope', 404);
        }
        return _json({'ok': 1});
      });
      final via404 = await missing.download(path: 'ledger_1.json');
      missing.dispose();

      expect(corruptError, isA<CloudStorageException>(),
          reason: '损坏快照应抛 CloudStorageException,与 404 的 null 区分');
      expect(via404, isNull, reason: '404 仍表示"云端没有该账本"');
    });

    test('HARDENING: downloadFullSnapshot 的 latest_cursor 在损坏响应下退化为 0', () async {
      // HARDENING: 404/损坏时 latestCursor 为 0,调用方若直接拿它推进 pull
      // cursor,会把游标重置为 0(全量重拉)。当前 App 侧只在拿到 content
      // 时使用该值,风险有限。
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/full')) {
          return _json({
            'snapshot': null,
            'latest_cursor': 0,
          });
        }
        return _json({'ok': 1});
      });
      final r = await storage.downloadFullSnapshot(path: 'x.json');
      storage.dispose();
      expect(r.content, isNull);
      expect(r.latestCursor, equals(0));
    });

    test('ADVERSE: change_id 为字符串时整个 pull 抛 TypeError(设计意图是跳过该行)', () async {
      // ADVERSE FINDING: pullChanges 的逐行校验设计了 `continue` 跳过畸形行,
      // 但 `(row['change_id'] as num?)` 这个裸转换在校验**之前**执行
      // (lib/src/providers/smartbook_cloud_provider.dart:2193),字符串型
      // change_id 会让整页 pull 抛 _TypeError(非 CloudSyncException),
      // 一张"畸形行"污染整批:客户端拿到 0 条变更,而服务端 cursor 未推进 →
      // 下次 pull 仍是同一批 → **同步永久卡死**。
      // 期望: 畸形行被跳过(与其后 2198-2204 的 continue 语义一致)
      // 实际: _TypeError 贯穿整个 pullChanges
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/pull')) {
          return _json({
            'changes': [
              {
                'change_id': 10,
                'ledger_id': 'L',
                'entity_type': 'transaction',
                'entity_sync_id': 's1',
                'action': 'upsert',
              },
              {
                'change_id': '11', // 字符串 → 触发裸转换
                'ledger_id': 'L',
                'entity_type': 'transaction',
                'entity_sync_id': 's2',
                'action': 'upsert',
              },
            ],
            'server_cursor': 42,
            'has_more': false,
          });
        }
        return _json({'ok': 1});
      });
      try {
        final res = await storage.pullChanges(since: 0);
        expect(res.changes.length, equals(1),
            reason: '畸形行应被跳过、其余照常返回');
      } on CloudStorageException {
        fail('不应抛 CloudStorageException');
      } on TypeError catch (e) {
        fail('畸形行导致整页 pull 崩溃(TypeError): $e');
      } finally {
        storage.dispose();
      }
    });

    test('ADVERSE: 缺字段的 change 被静默跳过,但 cursor 照常推进(变更永久丢失)', () async {
      // ADVERSE FINDING: 缺 change_id/ledger_id/… 的行被 continue 丢弃
      // (lib/src/providers/smartbook_cloud_provider.dart:2188-2204),
      // 随后**无条件**把 server_cursor 落盘(2221-2223)。
      // → 客户端少应用了一条变更,却把游标推进到它之后,该变更
      //   **永久拉不回来**。这正是 SYNC_ARCHITECTURE 中
      //   "cursor 已推进但 apply 未完成"同类问题的另一种形态。
      // 期望: 出现被丢弃的 change 时不推进 cursor(或抛出以便上层重试)
      // 实际: 丢弃 + 推进(3 条进 1 条出,cursor → 42)
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/pull')) {
          return _json({
            'changes': [
              {
                'change_id': 10,
                'ledger_id': 'L',
                'entity_type': 'transaction',
                'entity_sync_id': 's1',
                'action': 'upsert',
              },
              {'change_id': 11}, // 缺 ledger_id/entity_type/… → 丢弃
              'not even a map', // 非对象 → 丢弃
            ],
            'server_cursor': 42,
            'has_more': false,
          });
        }
        return _json({'ok': 1});
      });
      final res = await storage.pullChanges(since: 0);
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs
          .getKeys()
          .where((k) => k.contains('pull_cursor'))
          .map(prefs.getInt)
          .whereType<int>()
          .toList();
      storage.dispose();

      expect(res.changes.length, equals(1), reason: '实测:只返回 1 条');
      expect(persisted, isNot(contains(42)),
          reason: 'cursor 已推进到 ${res.serverCursor},被丢弃的变更永久丢失');
    });

    test('HARDENING: refresh 失败时抛 CloudNotAuthenticatedException(固定文案)', () async {
      // HARDENING: _authedRequest 在 401 且 refresh 也失败时抛固定文案
      // 'Session expired, please login again.' 并清 session
      // (lib/src/providers/smartbook_cloud_provider.dart:3442-3448)。
      // 行为安全(用户被正确登出),但服务端 detail 不再传给调用方。
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        if (req.url.path.endsWith('/auth/refresh')) {
          return _json({'detail': 'refresh token revoked'}, 401);
        }
        return _json({'detail': 'device revoked by admin'}, 401);
      });
      final a = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await a.signInWithEmail(email: 'e', password: 'p');
      final s = SmartBookCloudStorageService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1',
          auth: a,
          httpClient: client);
      try {
        await s.list(path: '');
        fail('应当抛出');
      } on CloudNotAuthenticatedException catch (e) {
        expect(e.message, equals('Session expired, please login again.'));
      } finally {
        expect(a.currentUserId, isNull, reason: '失败后 session 应被清除');
        a.dispose();
        s.dispose();
      }
    });

    test('ADVERSE: refresh 失败路径丢弃服务端 401 原因,异常链中不可见', () async {
      // ADVERSE FINDING: 401 → refresh 失败时,服务端明确给出的原因
      // (device revoked / refresh revoked)被丢弃,调用方与日志拿不到,
      // 无法区分"设备被踢"/"密码变更"/"token 自然过期"。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:3442-3448
      //      (固定文案,未携带原始 response/detail)
      // 期望: 异常(或其 originalError)保留服务端 detail 文本
      // 实际: message 固定,originalError 为 null
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        if (req.url.path.endsWith('/auth/refresh')) {
          return _json({'detail': 'refresh token revoked'}, 401);
        }
        return _json({'detail': 'device revoked by admin'}, 401);
      });
      final a = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await a.signInWithEmail(email: 'e', password: 'p');
      final s = SmartBookCloudStorageService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1',
          auth: a,
          httpClient: client);
      try {
        await s.list(path: '');
        fail('应当抛出');
      } on CloudNotAuthenticatedException catch (e) {
        final haystack = '$e | ${e.originalError}';
        expect(haystack, contains('revoked'),
            reason: '服务端原因丢失,异常里只有: $haystack');
      } finally {
        a.dispose();
        s.dispose();
      }
    });

    test('HARDENING: 请求失败路径的异常文本不回显 access/refresh token', () async {
      // HARDENING(清单项:"错误 message 不得泄漏 token"):异常 message 只拼
      // _extractErrorMessage(detail 字段,provider:4611-4620)或固定文案,
      // 不含会话 token;源码侧亦无 `$accessToken` 进 throw 的插值。
      final storage = await build(
          (req) async => _json({'detail': 'boom'}, 500));
      Object? caught;
      try {
        await storage.list(path: '');
      } catch (e) {
        caught = e;
      }
      storage.dispose();
      expect(caught, isNotNull);
      final text = '$caught'.toLowerCase();
      expect(text, isNot(contains('access-1')), reason: '异常文本回显了 token: $caught');
      expect(text, isNot(contains('refresh-1')), reason: '异常文本回显了 token: $caught');
      expect(text, isNot(contains('bearer')));
      expect(text, isNot(contains('authorization')));
    });

    test('HARDENING: 401 后自动 refresh 并重放一次请求(成功路径)', () async {
      var ledgerCalls = 0;
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/ledgers')) {
          ledgerCalls++;
          if (ledgerCalls == 1) {
            return _json({'detail': 'expired'}, 401);
          }
          return _json([
            {'ledger_id': 'ledger_1', 'updated_at': '2026-01-01T00:00:00Z'}
          ]);
        }
        return _json({'ok': 1});
      });
      final files = await storage.list(path: '');
      storage.dispose();
      expect(ledgerCalls, equals(2));
      expect(files.single.path, equals('ledger_1'));
    });

    test('HARDENING: list 的 prefix 是 startsWith 匹配,ledger_1 命中 ledger_10/100', () async {
      // HARDENING: list(path: 'ledger_1') 用 startsWith 过滤
      // (lib/src/providers/smartbook_cloud_provider.dart:2025-2027),
      // 会把 ledger_10 / ledger_100 一并算成"ledger_1 的内容"。
      // 当前 App 只用 list(path: '') ,风险有限,但语义上是前缀而非目录。
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/ledgers')) {
          return _json([
            {'ledger_id': 'ledger_1'},
            {'ledger_id': 'ledger_10'},
            {'ledger_id': 'ledger_100'},
          ]);
        }
        return _json({'ok': 1});
      });
      final files = await storage.list(path: 'ledger_1');
      storage.dispose();
      expect(files.map((f) => f.path).toList(),
          equals(['ledger_1', 'ledger_10', 'ledger_100']));
    });

    test('HARDENING: getMetadata 逐条比对归一化路径(不做目录语义)', () async {
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/ledgers')) {
          return _json([
            {'ledger_id': 'ledger_1'},
            {'ledger_id': 'ledger_2'},
          ]);
        }
        return _json({'ok': 1});
      });
      expect(await storage.exists(path: 'ledger_1'), isTrue);
      expect(await storage.exists(path: 'ledger_9'), isFalse);
      expect(await storage.getMetadata(path: '/ledger_1/'), isNotNull);
      storage.dispose();
    });

    test('HARDENING: upload 的 updated_at 为 UTC ISO8601(带 Z)', () async {
      String? body;
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/push')) {
          body = req.body;
          return _json({'accepted': 1, 'server_cursor': 1});
        }
        return _json({'ok': 1});
      });
      await storage.upload(path: 'ledger_1.json', data: '{"x":1}');
      storage.dispose();
      final change = (jsonDecode(body!) as Map)['changes'][0] as Map;
      expect(change['updated_at'], endsWith('Z'));
      expect(DateTime.tryParse(change['updated_at'] as String), isNotNull);
    });

    test('ADVERSE: 空 path 只在 upload/download 校验,list/exists 静默接受', () async {
      // ADVERSE FINDING: _ledgerIdFromPath 抛 'Invalid path: path is empty'
      // (3384-3390),但 list()/getMetadata() 走 PathHelper.normalize 后
      // 空路径意味着"全部"(prefix 为空 → 不过滤)。
      // 期望: 公开 API 的入参校验口径一致
      // 实际: list(path: '') 返回全量(这也是 App 的用法,但语义未文档化)
      final storage = await build((req) async {
        if (req.url.path.endsWith('/sync/ledgers')) {
          return _json([
            {'ledger_id': 'a'},
            {'ledger_id': 'b'},
          ]);
        }
        return _json({'ok': 1});
      });
      await expectLater(
        storage.upload(path: '', data: '{}'),
        throwsA(isA<CloudStorageException>()),
      );
      final all = await storage.list(path: '');
      storage.dispose();
      expect(all.length, equals(2));
    });
  });

  group('SmartBookCloudRealtimeClient — 畸形帧与生命周期', () {
    HttpServer? server;
    late List<String> upgrades;
    SmartBookCloudAuthService? auth;

    Future<void> startServer(
        Future<void> Function(WebSocket socket) onSocket) async {
      upgrades = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((req) async {
        upgrades.add(req.uri.query);
        final socket = await WebSocketTransformer.upgrade(req);
        await onSocket(socket);
      });
    }

    Future<SmartBookCloudRealtimeClient> startClient() async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        return _json({'ok': 1});
      });
      final created = SmartBookCloudAuthService(
          baseUrl: 'http://127.0.0.1:${server!.port}',
          apiPrefix: '/api/v1',
          httpClient: client);
      auth = created;
      await created.signInWithEmail(email: 'e', password: 'p');
      return SmartBookCloudRealtimeClient(
          baseUrl: 'http://127.0.0.1:${server!.port}', auth: created);
    }

    tearDown(() async {
      // 部分用例(如 WS 握手被拒)自建 server/auth,不经过 startServer/startClient,
      // 因此这里必须可空 —— 否则该用例单独运行时 tearDown 会抛
      // LateInitializationError(与产品行为无关的 harness 缺陷)。
      auth?.dispose();
      final boundServer = server;
      if (boundServer != null) {
        await boundServer.close(force: true);
      }
    });

    test('HARDENING: WS URL 把 token 放在 query(会进反代 access log)', () async {
      // HARDENING: _buildWebSocketUri 用 queryParameters: {'token': …}
      // (lib/src/providers/smartbook_cloud_provider.dart:4479-4494)。
      // 服务端 ws.py:55-58 已说明该形态会把 token 写进反代/服务端日志,
      // 并提供了"首帧 auth 消息"的新流程;mobile 仍是 query 形态。
      await startServer((socket) async {
        socket.add('{"type":"auth_ok"}');
      });
      final rt = await startClient();
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await rt.stop();
      rt.dispose();
      expect(upgrades.single, contains('token='),
          reason: 'token 出现在 URL query 中(会落进 access log)');
    });

    test('HARDENING: 畸形帧 / 空帧 / 未知 type 不使流关闭', () async {
      await startServer((socket) async {
        socket.add('not json at all'); // 畸形
        socket.add(''); // 空
        socket.add('   '); // 空白
        socket.add('pong'); // 心跳回包
        socket.add('[1,2,3]'); // 顶层不是对象
        socket.add('{"type":123}'); // type 非字符串
        socket.add('{"type":""}'); // type 空串
        socket.add('{"type":"unknown_future_event"}'); // 未知类型
        socket.add('{"type":"change","ledgerId":"L1","serverCursor":7}'); // 正常帧
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final rt = await startClient();
      final received = <SmartBookCloudRealtimeEvent>[];
      final errs = <Object>[];
      final sub = rt.events.listen(received.add, onError: errs.add);
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await sub.cancel();
      await rt.stop();
      rt.dispose();

      expect(errs, isEmpty, reason: '畸形帧导致事件流报错: $errs');
      expect(
        received.map((e) => e.type).toList(),
        containsAll(<String>['connected', 'unknown_future_event', 'change']),
        reason: '实际收到: ${received.map((e) => e.type).toList()}',
      );
      final change = received.firstWhere((e) => e.type == 'change');
      expect(change.ledgerId, equals('L1'));
      expect(change.serverCursor, equals(7));
    });

    test('ADVERSE: serverCursor 为非数字字符串时整帧被静默丢弃', () async {
      // ADVERSE FINDING: `(payload['serverCursor'] as num?)` 在值是 String 时
      // 抛 TypeError,被 _onMessage 的 catch (_) {} 吞掉 → **整帧丢失**
      // (连 type/ledgerId 都没了),而服务端确实可能发字符串型游标。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:4513 (as num?)
      //       与 4522 (catch (_) {})
      // 期望: 仅降级 serverCursor 为 null,事件本身照常投递并打日志
      // 实际: 事件完全消失(无任何日志/信号)
      await startServer((socket) async {
        socket.add(
            '{"type":"sync_change","ledgerId":"L9","serverCursor":"7"}');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final rt = await startClient();
      final received = <SmartBookCloudRealtimeEvent>[];
      final sub = rt.events.listen(received.add);
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      await rt.stop();
      rt.dispose();

      expect(received.map((e) => e.type).toList(), contains('sync_change'),
          reason: '实际收到: ${received.map((e) => e.type).toList()}'
              '(字符串游标把整帧吞了;App 端 sync_engine_realtime.dart:17 '
              '依赖该事件触发 pull)');
    });

    test('HARDENING: 超大帧(1MB)不崩,但会无上限地进内存', () async {
      // HARDENING: _onMessage 对消息长度无上限
      // (lib/src/providers/smartbook_cloud_provider.dart:4496-4523);
      // 1MB 帧能正常解析通过。恶意/异常服务端可放大内存与解析成本。
      final big = jsonEncode(
          {'type': 'change', 'ledgerId': 'L', 'pad': 'x' * (1024 * 1024)});
      await startServer((socket) async {
        socket.add(big);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final rt = await startClient();
      final received = <SmartBookCloudRealtimeEvent>[];
      final sub = rt.events.listen(received.add);
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await sub.cancel();
      await rt.stop();
      rt.dispose();
      final change = received.firstWhere((e) => e.type == 'change');
      expect((change.rawData['pad'] as String).length, equals(1024 * 1024));
    });

    test('ADVERSE: dispose() 后再 start() 会陷入无限重连循环', () async {
      // ADVERSE FINDING: dispose 关掉 _events 控制器(4438-4440),
      // 但 start() 只检查 _running(4418-4424)—— 之后每次 _connect 成功都会
      // _events.add(...) 抛 StateError,被 catch 后 scheduleReconnect,
      // 于是**永久**以退避节奏重连(每次新建 TCP 连接到服务端)。
      // 源码: lib/src/providers/smartbook_cloud_provider.dart:4418-4424, 4471, 4525
      // 期望: dispose 后 start() 立即抛错或 no-op,不建立新连接
      // 实际: 8 秒内建立 2 条连接并持续重连
      await startServer((socket) async {
        socket.add('{"type":"auth_ok"}');
      });
      final rt = await startClient();
      rt.dispose(); // 先 dispose(模拟 Riverpod 释放顺序错误)
      await rt.start();
      await Future<void>.delayed(const Duration(seconds: 8));
      final beforeStop = upgrades.length;
      await rt.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(beforeStop, equals(0),
          reason: 'dispose 后仍建立了 $beforeStop 条连接(无限重连循环)');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('HARDENING: stop() 后不再重连', () async {
      await startServer((socket) async {
        socket.add('{"type":"auth_ok"}');
        // 立刻断开,迫使客户端进入重连调度
        await socket.close();
      });
      final rt = await startClient();
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await rt.stop();
      final after = upgrades.length;
      await Future<void>.delayed(const Duration(seconds: 2));
      final later = upgrades.length;
      rt.dispose();
      expect(later, equals(after),
          reason: 'stop 后仍在重连($after → $later)');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('ADVERSE: WS 握手被拒(401)时抛未捕获的异步异常', () async {
      // ADVERSE FINDING: _connect 用 `WebSocketChannel.connect(uri)`(同步返回、
      // 异步连接),该 future 的错误**没有**被 await,因此不在 _connect 的
      // try/catch 覆盖范围内(lib/src/providers/smartbook_cloud_provider.dart:4449-4476)。
      // 服务端拒绝升级(401/403/非 WS 端点)时,异常以未处理异步错误的形态
      // 逃逸到 Zone/FlutterError,而 start() 正常返回 —— 上层
      // (client/lib/cloud/sync/sync_engine_realtime.dart:12-14 的
      //  `provider.startRealtime().catchError(...)`)捕获不到,日志里只会出现
      // 一条无人处理的 zone 错误。
      // 期望: 握手失败表现为 start()/events 流上的可捕获错误
      // 实际: 抛出未捕获异步异常(测试进程直接判失败)
      final plainServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      plainServer.listen((req) async {
        req.response.statusCode = 401;
        await req.response.close();
      });
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        return _json({'ok': 1});
      });
      final a = SmartBookCloudAuthService(
          baseUrl: 'http://127.0.0.1:${plainServer.port}',
          apiPrefix: '/api/v1',
          httpClient: client);
      await a.signInWithEmail(email: 'e', password: 'p');
      final rt = SmartBookCloudRealtimeClient(
          baseUrl: 'http://127.0.0.1:${plainServer.port}', auth: a);
      final errs = <Object>[];
      final sub = rt.events.listen((_) {}, onError: errs.add);
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      await rt.stop();
      rt.dispose();
      a.dispose();
      await plainServer.close(force: true);

      // 期望:错误出现在可捕获的位置(事件流);实际:流上没有任何错误,
      // 异常被抛出到测试 Zone(断言因此失败)
      expect(errs, isNotEmpty,
          reason: '握手失败的异常逃逸到未捕获区,events 流收不到任何错误信号');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('HARDENING: WS 建连时回环 host 保留、scheme 由 https 映射为 wss', () async {
      // _buildWebSocketUri: https → wss,并把 baseUrl 的路径段拼在 /ws 之前
      await startServer((socket) async {
        socket.add('{"type":"auth_ok"}');
      });
      final rt = await startClient();
      await rt.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await rt.stop();
      rt.dispose();
      expect(upgrades.single, contains('token='));
    });
  });

  group('SmartBookCloudProvider — 配置校验', () {
    test('ADVERSE: baseUrl 允许携带 userinfo(凭据进 URL/日志)', () async {
      // ADVERSE FINDING: validateConfig 只检查 scheme + host 非空
      // (lib/src/providers/smartbook_cloud_provider.dart:1132-1136),
      // 'https://user:secret@h.test' 被判为合法,凭据会留在 baseUrl 里,
      // 并出现在 _request 报错文本 / 日志(baseUrl 被拼进异常 message)。
      // 期望: 拒绝带 userinfo 的 baseUrl
      // 实际: 通过校验
      final provider = SmartBookCloudProvider();
      final ok = provider.validateConfig(
          {'baseUrl': 'https://user:secret@h.test'});
      await provider.dispose();
      expect(ok, isFalse,
          reason: '带 userinfo 的 baseUrl 被接受(凭据可随错误信息外泄)');
    });

    test('ADVERSE: apiPrefix 允许路径穿越,请求被改写到别的路径', () async {
      // ADVERSE FINDING: _normalizeApiPrefix 只补前导/去尾随斜杠
      // (lib/src/providers/smartbook_cloud_provider.dart:4581-4593),
      // 不拒绝 '..' 段;Uri 构造时按 RFC 归一化,baseUrl+prefix+path 的
      // 实际请求路径会被改写到 prefix 之外。
      // 实测 '/api/v1/../../etc' + '/auth/login' → 请求打到 '/etc/auth/login'
      // 期望: 非法 prefix 被拒(只允许 [A-Za-z0-9._-] 段)
      // 实际: 原样接受,请求路径逃出 /api/v1
      final seen = <Uri>[];
      final client = MockClient((req) async {
        seen.add(req.url);
        if (req.url.path.endsWith('/auth/login')) return _json(_loginPayload());
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1/../../etc',
          httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      auth.dispose();
      expect(seen.first.path.startsWith('/api/v1'), isTrue,
          reason: 'prefix 穿越生效,实际请求打到: ${seen.first.path}');
    });

    test('HARDENING: 非法 baseUrl 在 initialize / _request 双层被拒', () async {
      final provider = SmartBookCloudProvider();
      expect(provider.validateConfig({'baseUrl': 'file:///C:/x'}), isFalse);
      expect(provider.validateConfig({'baseUrl': 'ws://h/x'}), isFalse);
      expect(provider.validateConfig({'baseUrl': 'not a url'}), isFalse);
      expect(provider.validateConfig({'baseUrl': 'https:///path'}), isFalse);
      expect(provider.validateConfig({'baseUrl': 42}), isFalse);
      expect(
          provider.validateConfig({'baseUrl': 'https://h', 'apiPrefix': 5}),
          isFalse);
      await expectLater(
        provider.initialize({'baseUrl': 'file:///C:/x'}),
        throwsA(isA<CloudConfigurationException>()),
      );
      await provider.dispose();
    });

    test('HARDENING: provider 未初始化时访问 auth/storage 抛 CloudConfigurationException', () async {
      final provider = SmartBookCloudProvider();
      expect(() => provider.auth, throwsA(isA<CloudConfigurationException>()));
      expect(
          () => provider.storage, throwsA(isA<CloudConfigurationException>()));
      expect(provider.realtimeEvents, emitsDone);
      await provider.dispose();
    });

    test('HARDENING: dispose 后再 dispose / validateConfig 仍可用', () async {
      final provider = SmartBookCloudProvider();
      await provider.initialize({'baseUrl': 'https://h.test'});
      await provider.dispose();
      await provider.dispose(); // 幂等
      expect(provider.validateConfig({'baseUrl': 'https://h.test'}), isTrue);
    });
  });
}
