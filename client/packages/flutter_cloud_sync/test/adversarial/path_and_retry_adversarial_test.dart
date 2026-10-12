// 对抗性测试 — PathHelper 路径构造 / RetryHelper 重试策略
//
// 规则:
//   // ADVERSE FINDING: <标题>  → 已确认缺陷,断言"应有行为",测试保持激活并失败(红)
//   // HARDENING: <说明>        → 行为可辩护但脆弱,断言当前行为并通过(绿)
//
// 反 flaky: 纯计算 + fake_async + MockClient,无真实网络、无 wall clock 依赖。
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

const _okLogin = {
  'user': {'id': 'u1', 'email': 'a@b.c'},
  'access_token': 'tok',
  'refresh_token': 'ref',
  'expires_in': 3600,
  'device_id': 'dev1',
};

/// 按 POSIX 语义解析 `.` / `..` 段,用于表达"期望值"。
String resolveDots(String path) {
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

void main() {
  group('PathHelper — 目录穿越', () {
    test('ADVERSE: ../ 段不被解析,穿越路径原样存活', () {
      // ADVERSE FINDING: normalize 只处理斜杠,不解析 . / .. 段
      // 源码: lib/src/utils/path_helper.dart:14-27 (normalize)
      // 期望: 穿越段被解析 → 'etc/passwd'
      // 实际: 'users/../../etc/passwd' 原样返回
      expect(PathHelper.normalize('users/../../etc/passwd'),
          equals('etc/passwd'));
    });

    test('ADVERSE: userPath 允许 userId 逃出 users/ 命名空间', () {
      // ADVERSE FINDING: join → normalize 不做 .. 解析,用户目录可被逃逸
      // 源码: lib/src/utils/path_helper.dart:38-41 (join) / 108-110 (userPath)
      // 期望: 解析后仍落在 'users/' 之下
      // 实际: 'users/../../x.json' → 解析后为 'x.json'
      final p = PathHelper.userPath('../..', ['x.json']);
      expect(resolveDots(p), startsWith('users/'));
    });

    test('ADVERSE: . 与 .. 被当作普通文件名字段', () {
      // ADVERSE FINDING: '.'/'..' 既不归一化也不拒绝
      // 源码: lib/src/utils/path_helper.dart:14-27, 71-79
      // 期望: 'a/./b' → 'a/b';'a/.' 的"文件名"是目录 a
      // 实际: 'a/./b' 原样;basename('a/.') == '.'
      expect(PathHelper.normalize('a/./b'), equals('a/b'));
      expect(PathHelper.basename('a/.'), equals('a'));
    });

    test('HARDENING: 斜杠收敛本身正确(但与 .. 解析无关)', () {
      expect(PathHelper.normalize('//a//b//c//'), equals('a/b/c'));
      expect(PathHelper.normalize('/'), equals(''));
      expect(PathHelper.normalize(''), equals(''));
    });
  });

  group('PathHelper — 分隔符与特殊字符', () {
    test('HARDENING: 反斜杠不当分隔符(云对象键 POSIX 语义),Windows 路径整串透传', () {
      // HARDENING: 云存储键以 '/' 为唯一分隔符,'\' 视为普通字符是可辩护的
      // 对象键语义(与 S3/WebDAV 一致);代价:调用方若误传 OS 路径,
      // 整串(含盘符)会原样成为对象键/ledger_id。前置结论:不存在
      // "反斜杠穿越" —— '\' 不解析时其内的 .. 也只是普通字符(见下一条)。
      expect(PathHelper.basename(r'C:\x\y.json'), equals(r'C:\x\y.json'));
      expect(PathHelper.normalize(r'C:\x\y.json'), equals(r'C:\x\y.json'));
    });

    test('HARDENING: 反斜杠段整体透传,不解析其中的 ..(正斜杠穿越见红项)', () {
      // HARDENING: '\' 非分隔符 → 'users\u\..\..\x' 是单串键,不会被 URL/
      // 服务端按 '.'/'..' 语义解析成正斜杠穿越;风险由正斜杠 '..' 红项统一覆盖。
      expect(
          PathHelper.normalize(r'users\u\..\..\x'), equals(r'users\u\..\..\x'));
    });

    test('HARDENING: 纯 "." / ".." 单段输入按 POSIX 解析为空(不成为对象键)', () {
      // HARDENING(修正):原断言固化"'.'/'..' 原样透传进对象键",与同文件
      // ADVERSE: ". 与 .. 被当作普通文件名字段"(R-3)直接矛盾 —— 同一个
      // '.' 段不可能既被解析(在 'a/./b' 中折叠)又原样保留(单独出现)。
      // R-3 修复后统一按 POSIX 语义处理:'.' 是当前目录、'..' 在根之上被
      // 丢弃,二者都不再能充当对象键/ledger_id。仍然保真的是:它们不会被
      // 抛错拒绝,只是归一化为"无内容"。
      expect(PathHelper.normalize('.'), equals(''));
      expect(PathHelper.normalize('..'), equals(''));
      expect(PathHelper.basename('..'), equals(''));
      expect(PathHelper.dirname('..'), equals(''));
      expect(PathHelper.join(['.', '..', 'x']), equals('x'));
      expect(PathHelper.userPath('.', ['a.json']), equals('users/a.json'));
      // 归一化为空后没有扩展名可言
      expect(PathHelper.extension('..'), equals(''));
    });

    test('HARDENING: 空段与空路径', () {
      expect(PathHelper.join([]), equals(''));
      expect(PathHelper.normalize('/'), equals(''));
      expect(PathHelper.basename(''), equals(''));
      expect(PathHelper.dirname(''), equals(''));
    });

    test('HARDENING: 空 userId 静默丢段', () {
      // HARDENING: userPath('', ['a.json']) → 'users/a.json',入参非法但无任何信号
      expect(PathHelper.userPath('', ['a.json']), equals('users/a.json'));
      expect(PathHelper.userPath('u', []), equals('users/u'));
    });

    test('HARDENING: %00 / NUL / Unicode 原样透传,不转义不拒绝', () {
      expect(PathHelper.normalize('a%00b.json'), equals('a%00b.json'));
      expect(PathHelper.normalize('a\u0000b.json'), equals('a\u0000b.json'));
      expect(PathHelper.basename('账本/流水.json'), equals('流水.json'));
      expect(PathHelper.normalize('users/😀/data.json'),
          equals('users/😀/data.json'));
      expect(PathHelper.extension('a%00.json'), equals('.json'));
    });

    test('HARDENING: 大小写不折叠、盘符不识别', () {
      expect(PathHelper.normalize('Users/X/DATA.json'),
          equals('Users/X/DATA.json'));
      expect(PathHelper.normalize('C:/x/y.json'), equals('C:/x/y.json'));
      expect(PathHelper.basename('C:/x/y.json'), equals('y.json'));
      // 盘符不算绝对路径 —— isAbsolute 只认前导 '/'
      expect(PathHelper.isAbsolute(r'C:\x'), isFalse);
    });

    test('HARDENING: 超长路径(400+ 字符)不报错不截断', () {
      final long = 'a' * 400;
      final p = PathHelper.join(['users', long, 'data.json']);
      expect(p.length, equals('users/'.length + 400 + '/data.json'.length));
      expect(PathHelper.basename(p), equals('data.json'));
    });

    test('HARDENING: makeAbsolute / makeRelative 回环不对称', () {
      // HARDENING: makeAbsolute('') == '/' 但 normalize('/') == '' ,空路径信息丢失
      expect(PathHelper.makeAbsolute(''), equals('/'));
      expect(PathHelper.makeRelative(PathHelper.makeAbsolute('')), equals(''));
      expect(PathHelper.makeAbsolute('a/b'), equals('/a/b'));
    });
  });

  group('PathHelper → Provider: 穿越路径落到请求体', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('HARDENING: 穿越路径经 basename 变成"合法" ledger_id 发给服务端', () async {
      // HARDENING(证据性): provider 用 PathHelper.basename 从 path 派生 ledger_id
      // (lib/src/providers/smartbook_cloud_provider.dart:3384-3390),
      // 服务端把 ledger_id 当 external_id,未知值会自动建账本
      // (server/src/routers/sync/push.py:380+ auto-create / 376 ghost-ledger guard)。
      // 当前 upload() 是公开 API,调用方传任意 path 都能走到这里。
      final bodies = <String>[];
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_okLogin);
        if (req.url.path.endsWith('/sync/push')) {
          bodies.add(req.body);
          return _json({'accepted': 1, 'server_cursor': 1});
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      final storage = SmartBookCloudStorageService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1',
          auth: auth,
          httpClient: client);

      await storage.upload(path: 'users/u/../../loot.json', data: '{}');
      final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
      final change = (sent['changes'] as List).single as Map<String, dynamic>;
      expect(change['ledger_id'], equals('loot.json'));
      expect(change['entity_sync_id'], equals('loot.json'));
      auth.dispose();
      storage.dispose();
    });

    test('HARDENING: 反斜杠路径整串成为 ledger_id(服务端会孤立成新账本)', () async {
      final bodies = <String>[];
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/login')) return _json(_okLogin);
        if (req.url.path.endsWith('/sync/push')) {
          bodies.add(req.body);
          return _json({'accepted': 1, 'server_cursor': 1});
        }
        return _json({'ok': 1});
      });
      final auth = SmartBookCloudAuthService(
          baseUrl: 'https://h.test', apiPrefix: '/api/v1', httpClient: client);
      await auth.signInWithEmail(email: 'e', password: 'p');
      final storage = SmartBookCloudStorageService(
          baseUrl: 'https://h.test',
          apiPrefix: '/api/v1',
          auth: auth,
          httpClient: client);

      await storage.upload(path: r'users\u\..\..\x.json', data: '{}');
      final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
      final change = (sent['changes'] as List).single as Map<String, dynamic>;
      expect(change['ledger_id'], equals(r'users\u\..\..\x.json'));
      auth.dispose();
      storage.dispose();
    });
  });

  group('RetryHelper — 次数与边界', () {
    test('HARDENING: maxAttempts=0 → 操作执行 0 次,兜底抛 CloudSyncException', () async {
      // HARDENING: while(0 < 0) 不进循环 → 兜底 throw(retry_helper.dart:87,120-122)。
      // "maxAttempts=0 次尝试"与参数名自洽,可辩护;脆弱点:配置非法(<=0)
      // 没有专门的参数错误,调用方收到的是语义含混的
      // CloudSyncException('Retry exhausted with no exception recorded')。
      var calls = 0;
      Object? err;
      try {
        await RetryHelper.execute(
          () async {
            calls++;
            return 'unreachable';
          },
          config: const RetryConfig(maxAttempts: 0),
        );
      } catch (e) {
        err = e;
      }
      expect(calls, equals(0), reason: '当前行为:操作从未被执行(实际 $calls 次)');
      expect(err, isA<CloudSyncException>());
      expect('$err', contains('Retry exhausted with no exception recorded'));
    });

    test('HARDENING: maxAttempts<0 兜底抛基类 CloudSyncException(非 ArgumentError)', () async {
      // HARDENING: 负数尝试次数同样落到"no exception recorded"兜底
      // (retry_helper.dart:120-122)—— 配置写错与业务失败不可区分,
      // 但这是分类学上的欠缺而非崩溃。
      Object? err;
      try {
        await RetryHelper.execute(() async => 1,
            config: const RetryConfig(maxAttempts: -3));
      } catch (e) {
        err = e;
      }
      expect(err, isA<CloudSyncException>(),
          reason: '当前行为: ${err.runtimeType} → $err(非法配置无 ArgumentError)');
      expect(err, isNot(isA<ArgumentError>()));
    });

    test('HARDENING: onRetry 回调抛错会中断重试并顶掉原始异常', () async {
      // HARDENING: onRetry 在 try/catch 之外调用(retry_helper.dart:106),
      // 回调自身的异常直接冒出 —— 原始 CloudStorageException 丢失、重试中断。
      // 可辩护:回调是调用方代码,快速失败合理;脆弱:日志/回调一行 bug
      // 就会掩盖真实失败,回调必须自行兜底。
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('original failure');
          },
          config: const RetryConfig(
              maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
          onRetry: (attempt, error) => throw StateError('logger bug'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, equals(1),
          reason: '当前行为:第 1 次尝试后回调抛错,原错误被顶掉(重试 $calls 次)');
    });

    test('HARDENING: 极大 maxAttempts 无总时长预算 → 事实上无界重试', () {
      // HARDENING: execute 只有"次数"上限,没有总时长/deadline 概念
      // (清单项:极大 maxAttempts)。次数给到 10^12 + 恒定 1ms 间隔,
      // 10 秒 fake 时间内仍不结束、已打 ~10^4 次 —— 调用方若传大数,
      // 失败的服务端会被持续轰击,只能靠上层超时兜底。
      fakeAsync((async) {
        var calls = 0;
        var settled = false;
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 1000000000000, // 10^12
            initialDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 1),
          ),
        ).then((_) => settled = true, onError: (Object _) => settled = true);

        async.elapse(const Duration(seconds: 10));
        expect(settled, isFalse,
            reason: '10^12 次上限在 10s 内不可能跑完(当前 calls=$calls)');
        expect(calls, greaterThan(5000),
            reason: '10s / 1ms ≈ 10^4 次,无总预算约束');
      });
    });
  });

  group('RetryHelper — 退避计算', () {
    test('ADVERSE: initialDelay 不受 maxDelay 约束(30s 首等 vs 100ms 上限)', () {
      // ADVERSE FINDING: 首次等待直接用 initialDelay;maxDelay 只 clamp 后续计算值
      // 源码: lib/src/utils/retry_helper.dart:84, 109, 112-116
      // 期望: 任何单次等待 ≤ maxDelay
      // 实际: maxDelay=100ms 时仍睡满 initialDelay=30s
      fakeAsync((async) {
        var completed = false;
        var calls = 0;
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 2,
            initialDelay: Duration(seconds: 30),
            maxDelay: Duration(milliseconds: 100),
          ),
        ).then((_) => completed = true,
            onError: (Object _) => completed = true);

        async.elapse(const Duration(milliseconds: 500));
        expect(completed, isTrue,
            reason: 'maxDelay=100ms 下 500ms 内应已完成;实际 calls=$calls');
      });
    });

    test('ADVERSE: 巨大 initialDelay(2^40 ms)原样睡下去', () {
      // ADVERSE FINDING: 退避参数无上界校验,maxDelay 也管不到首等
      // 源码: lib/src/utils/retry_helper.dart:109-116
      // 期望: 单次等待被 maxDelay(1s)截断
      // 实际: 睡 2^40 ms(约 34.8 年)
      fakeAsync((async) {
        var completed = false;
        RetryHelper.execute(
          () async {
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 2,
            initialDelay: Duration(milliseconds: 1099511627776), // 2^40
            maxDelay: Duration(seconds: 1),
          ),
        ).then((_) => completed = true,
            onError: (Object _) => completed = true);

        async.elapse(const Duration(hours: 1));
        expect(completed, isTrue, reason: 'maxDelay=1s 应截断;1 小时后仍未完成');
      });
    });

    test('ADVERSE: backoffMultiplier=infinity 用 UnsupportedError 掩盖真实失败', () async {
      // ADVERSE FINDING: (x * infinity).round() 抛 UnsupportedError,原异常被替换
      // 源码: lib/src/utils/retry_helper.dart:112-116
      // 期望: 抛原始 CloudStorageException(并按次数重试 3 次)
      // 实际: 第 1 次失败后抛 UnsupportedError: Infinity or NaN toInt
      var calls = 0;
      Object? err;
      try {
        await RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('real cause');
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration.zero,
            backoffMultiplier: double.infinity,
          ),
        );
      } catch (e) {
        err = e;
      }
      expect(err, isA<CloudStorageException>(),
          reason: '实际抛出: $err');
      expect(calls, equals(3));
    });

    test('ADVERSE: backoffMultiplier=0 退化为零延迟重试风暴', () {
      // ADVERSE FINDING: 系数 0 把 currentDelay 压成 0,后续重试无间隔连发
      // 源码: lib/src/utils/retry_helper.dart:112-116 (×0 → clamp(0,…) = 0)
      // 期望: 退避系数被校验(>=1),每次重试至少间隔 initialDelay
      //       → 时间点 [0, 5000, 10000, 15000]
      // 实际: 首等 5s 后剩余尝试零延迟连发 → 时间点 [0, 5000, 5000, 5000]
      fakeAsync((async) {
        var calls = 0;
        final stamps = <int>[];
        RetryHelper.execute(
          () async {
            calls++;
            stamps.add(async.elapsed.inMilliseconds);
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 4,
            initialDelay: Duration(seconds: 5),
            maxDelay: Duration(seconds: 30),
            backoffMultiplier: 0,
          ),
        ).then((_) {}, onError: (Object _) {});

      // 修复后:系数被校验(0 → 退化为常系数 1),每次重试间隔 initialDelay
      // → [0, 5000, 10000, 15000];需要覆盖到 t=15000 的等待窗口。
      async.elapse(const Duration(seconds: 16));
      expect(stamps, equals(const [0, 5000, 10000, 15000]),
          reason: '零延迟重试风暴:实际时间点 $stamps(第 2 次之后无任何间隔)');
      });
    });

    test('HARDENING: 合法退避序列被 maxDelay 正确截断', () {
      fakeAsync((async) {
        final stamps = <int>[];
        var calls = 0;
        RetryHelper.execute(
          () async {
            calls++;
            stamps.add(async.elapsed.inMilliseconds);
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 5,
            initialDelay: Duration(seconds: 1),
            maxDelay: Duration(seconds: 3),
            backoffMultiplier: 2,
          ),
        ).then((_) {}, onError: (Object _) {});
        async.elapse(const Duration(seconds: 30));
        // 等待: 1s, 2s, 3s(4s→clamp 3s), 3s(6s→clamp 3s)
        expect(stamps, equals(const [0, 1000, 3000, 6000, 9000]));
        expect(calls, equals(5));
      });
    });

    test('HARDENING: 大但有限的后退系数按 int64 饱和,不溢出', () async {
      // HARDENING: 1e300.round() 饱和到 int64 max,(饱和值*...) 再被 clamp 到 maxDelay,
      // 因此有限系数不会崩,只是每次都会用满 maxDelay
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('x');
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 1),
            backoffMultiplier: 1e300,
          ),
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(calls, equals(3));
    });
  });

  group('RetryHelper — 可重试分类与取消', () {
    test('ADVERSE: HTTP 4xx(终态校验失败)仍被重试 3 次', () async {
      // ADVERSE FINDING: 默认策略对任何 CloudStorageException 都重试,
      // 且异常类(core/exceptions.dart:30-33)不携带 statusCode 供区分 4xx/5xx
      // 源码: lib/src/utils/retry_helper.dart:203-205
      // 期望: 4xx 终态错误只尝试 1 次
      // 实际: 连打 3 次(生产里等于把无效请求重复提交)
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('Upload failed: HTTP 422');
          },
          config: const RetryConfig(
              maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(calls, equals(1), reason: '实际重试了 $calls 次');
    });

    test('HARDENING: retryableExceptions 按 runtimeType 精确匹配,子类不继承', () async {
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('x');
          },
          config: RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
            retryableExceptions: const [CloudSyncException],
          ),
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(calls, equals(1));
    });

    test('HARDENING: auth / 配置类异常不重试(默认策略)', () async {
      for (final e in <Exception>[
        CloudNotAuthenticatedException(),
        CloudConfigurationException('bad cfg'),
        CloudAuthException('bad creds'),
      ]) {
        var calls = 0;
        await expectLater(
          RetryHelper.execute(
            () async {
              calls++;
              throw e;
            },
            config: const RetryConfig(
                maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
          ),
          throwsA(same(e)),
        );
        expect(calls, equals(1), reason: '${e.runtimeType} 被重试了');
      }
    });

    test('HARDENING: Error(非 Exception)不重试且直穿', () async {
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw StateError('programming error');
          },
          config: const RetryConfig(
              maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, equals(1));
    });

    test('HARDENING: 无 per-attempt 超时、无取消能力', () {
      // HARDENING: execute 没有 deadline / CancellationToken;
      // 卡死的操作会永远挂着,上层必须自己包 timeout
      fakeAsync((async) {
        var calls = 0;
        var settled = false;
        RetryHelper.execute(
          () {
            calls++;
            return Completer<String>().future; // 永不完成
          },
          config: const RetryConfig(
              maxAttempts: 3, initialDelay: Duration(milliseconds: 10)),
        ).then((_) => settled = true, onError: (Object _) => settled = true);

        async.elapse(const Duration(hours: 1));
        expect(settled, isFalse);
        expect(calls, equals(1));
      });
    });

    test('HARDENING: 重试不含幂等键,副作用按次数叠加', () async {
      // HARDENING: 重试仅重新调用同一闭包;upload 类操作若调用层不加
      // Idempotency-Key,重复提交会叠加副作用(包内未代为注入幂等键)
      final effects = <int>[];
      var n = 0;
      final r = await RetryHelper.execute(
        () async {
          n++;
          effects.add(n); // 模拟一次有副作用的写入
          if (n < 3) throw CloudStorageException('retry me');
          return n;
        },
        config: const RetryConfig(
            maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
      );
      expect(r, equals(3));
      expect(effects, equals([1, 2, 3]));
    });

    test('HARDENING: 首次成功即返回,不多打', () async {
      var calls = 0;
      final r = await RetryHelper.execute(
        () async {
          calls++;
          return 'ok';
        },
        config: const RetryConfig(maxAttempts: 5),
      );
      expect(r, equals('ok'));
      expect(calls, equals(1));
    });

    test('HARDENING: executeSimple / executeWithBackoff 与 execute 语义一致', () async {
      var calls = 0;
      await expectLater(
        RetryHelper.executeSimple(
          () async {
            calls++;
            throw CloudStorageException('x');
          },
          maxAttempts: 2,
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(calls, equals(2));
    });
  });
}
