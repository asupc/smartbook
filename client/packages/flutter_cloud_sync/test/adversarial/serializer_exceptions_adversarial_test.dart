// 对抗性测试 — 序列化契约 / 异常分类 / 敏感信息暴露
//
// 规则:
//   // ADVERSE FINDING: <标题>  → 已确认缺陷,断言"应有行为",保持失败(红)
//   // HARDENING: <说明>        → 行为可辩护但脆弱,断言当前行为并通过(绿)
//
// 反 flaky: 纯计算 + 内存 mock,无真实网络、无 wall clock。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生产里 `TransactionsSyncManager` 使用的同款指纹(SHA-256 over JSON 文本)。
class _ShaSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async =>
      jsonEncode({'ledgerId': data, 'count': data});

  @override
  Future<int> deserialize(String data) async =>
      (jsonDecode(data) as Map<String, dynamic>)['ledgerId'] as int;

  @override
  String fingerprint(String data) =>
      sha256.convert(utf8.encode(data)).toString();
}

/// 反模式: 业务层实现的"只认字符串键"的反序列化(与主工程同一写法)。
class _StrictSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async => jsonEncode({'ledgerId': data});

  @override
  Future<int> deserialize(String data) async =>
      jsonDecode(data)['ledgerId'] as int;

  @override
  String fingerprint(String data) => data;
}

class _ThrowingErrorSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async => throw StateError('serialize bug');
  @override
  Future<int> deserialize(String data) async => throw StateError('bug');
  @override
  String fingerprint(String data) => throw StateError('bug');
}

/// 模拟"解出 Infinity 后再回写"的业务层:jsonEncode 抛
/// JsonUnsupportedObjectError(Error 家族)。
class _InfinitySerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async =>
      jsonEncode({'amount': double.infinity});
  @override
  Future<int> deserialize(String data) async => 0;
  @override
  String fingerprint(String data) => data;
}

void main() {
  group('DataSerializer — 类型往返', () {
    test('HARDENING: int/double/bool/null/嵌套 往返稳定', () {
      final payload = <String, dynamic>{
        'i': 1,
        'd': 1.0,
        'd2': 0.1,
        'neg0': -0.0,
        'b': true,
        'n': null,
        'nested': {
          'list': [1, 'two', 3.5, null, true],
          'map': {
            'deep': {'deeper': 'v'}
          },
        },
        'emptyMap': <String, dynamic>{},
        'emptyList': <dynamic>[],
      };
      final back = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      expect(back['i'], equals(1));
      expect(back['d'], equals(1.0));
      expect(back['d2'], equals(0.1));
      expect(back['neg0'], equals(-0.0));
      expect(back['b'], isTrue);
      expect(back['n'], isNull);
      expect(back['nested'], equals(payload['nested']));
      expect(back['emptyMap'], isEmpty);
      expect(back['emptyList'], isEmpty);
    });

    test('HARDENING: int64 边界与 2^53+1 保持精确(JSON int 不丢精度)', () {
      final back = jsonDecode(jsonEncode({
        'big': 9007199254740993, // 2^53+1
        'min': -9223372036854775808,
        'max': 9223372036854775807,
      })) as Map<String, dynamic>;
      expect(back['big'], equals(9007199254740993));
      expect(back['min'], equals(-9223372036854775808));
      expect(back['max'], equals(9223372036854775807));
    });

    test('HARDENING: JSON 超范围数字 1e999 解出 Infinity(解得出、编不回)', () {
      // HARDENING: dart:convert 把超范围数字字面量解为 double.infinity 且不报错
      // (SDK 行为,包无法改变);回编码则抛 JsonUnsupportedObjectError —— 不对称。
      // 包内所有 jsonDecode 消费点(_decodeJsonObject:4595-4601 等)必须自行防御;
      // getStatus 的 count 提取有 catch(_) 兜底(见本文件 CloudSyncManager 组的
      // Infinity 计数用例),不会因此崩溃。记录该脆弱点而非断言 SDK 行为。
      final decoded = jsonDecode('{"amount": 1e999}') as Map<String, dynamic>;
      expect(decoded['amount'], isA<num>());
      expect((decoded['amount'] as num).isFinite, isFalse,
          reason: '当前行为:解析为 ${decoded['amount']} (${decoded['amount'].runtimeType})');
      expect(() => jsonEncode(decoded), throwsA(isA<JsonUnsupportedObjectError>()),
          reason: '当前行为:解得出、编不回 —— ${_tryEncode(decoded)}');
    });

    test('HARDENING: NaN / Infinity / DateTime 不是合法 JSON 值', () {
      for (final bad in <Object?>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
        DateTime.utc(2026),
      ]) {
        expect(() => jsonEncode({'v': bad}),
            throwsA(isA<JsonUnsupportedObjectError>()),
            reason: '${bad.runtimeType} 应被拒');
      }
    });

    test('HARDENING: 二进制(Uint8List)被静默编码成数字数组,体积膨胀', () {
      // HARDENING: Uint8List implements List<int>,jsonEncode 当普通数组处理;
      // 256 字节的二进制会变成 ~4x 文本并丢失"这是二进制"的语义。
      // 附件类数据走 multipart 上传,但若业务层误把字节放进 JSON payload,
      // 不会报错而是静默膨胀。
      final bin = Uint8List.fromList(List<int>.generate(256, (i) => i));
      final enc = jsonEncode({'blob': bin});
      expect(enc.length, greaterThan(256 * 3));
      expect((jsonDecode(enc) as Map)['blob'], isA<List<dynamic>>());
      expect((jsonDecode(enc) as Map)['blob'], isNot(isA<Uint8List>()));
    });

    test('HARDENING: 循环引用抛 JsonCyclicError,不会栈溢出', () {
      final cyc = <String, Object?>{};
      cyc['self'] = cyc;
      expect(() => jsonEncode(cyc), throwsA(isA<JsonCyclicError>()));
    });

    test('HARDENING: 100 层嵌套往返一致;10000 层 encode 抛 StackOverflowError', () {
      var listText = '0';
      var mapText = '{"k":0}';
      for (var i = 0; i < 100; i++) {
        listText = '[$listText]';
        mapText = '{"k":$mapText}';
      }
      expect(jsonEncode(jsonDecode(listText)), equals(listText));
      expect(jsonEncode(jsonDecode(mapText)), equals(mapText));

      // 递归 encode 在极深结构上抛 StackOverflowError(Error,非 Exception,
      // 绕过所有 catch(Exception) 的失败处理路径)
      Object deep = 'leaf';
      for (var i = 0; i < 10000; i++) {
        deep = [deep];
      }
      expect(() => jsonEncode({'v': deep}), throwsA(isA<StackOverflowError>()));
    });
  });

  group('DataSerializer — 文本与编码', () {
    test('HARDENING: 1MB 字符串往返,不截断', () {
      final big = 'x' * (1024 * 1024);
      final enc = jsonEncode({'data': big});
      expect(enc.length, greaterThan(1024 * 1024));
      expect((jsonDecode(enc) as Map)['data'], equals(big));
    });

    test('HARDENING: 控制字符 / Emoji / RTL / 零宽 / BOM 往返一致', () {
      for (final s in <String>[
        'a\u0001b',
        'emoji😀🏦',
        'ansi\u001b[31mred',
        'rtl\u202Eabc',
        'zwnj\u200Bh',
        '\uFEFFBOM',
        '\n\t\r"\\/',
      ]) {
        final back = (jsonDecode(jsonEncode({'k': s})) as Map)['k'];
        expect(back, equals(s), reason: '往返不一致: $s');
      }
    });

    test('HARDENING: 孤立代理项 → U+FFFD 静默替换(编码层),指纹分辨率随之丢失', () {
      // HARDENING: 两个不同的 Dart 字符串('a\uD800b' 与 'a\uFFFDb')经
      // utf8.encode 后字节完全相同 → 按 UTF-8 字节算的指纹无法区分。
      // 主工程指纹 = sha256(utf8.encode(序列化文本))
      // (client/lib/cloud/transactions_sync_manager.dart:995+ 同款写法);
      // 因为 jsonEncode 会把孤立代理项写成 \ud800 转义(纯 ASCII),
      // 走「序列化文本」这条路的指纹仍可区分 —— 只有对原始字符串直接
      // 取指纹的写法才会退化。当前包内无此项,故记为脆弱点而非缺陷。
      const lone = 'a\uD800b';
      const replaced = 'a\uFFFDb';
      expect(utf8.encode(lone), equals(utf8.encode(replaced)));

      // 序列化文本层面仍可区分(运气好:转义成 ASCII)
      expect(jsonEncode(lone), isNot(equals(jsonEncode(replaced))));
      final s = _ShaSerializer();
      expect(s.fingerprint(jsonEncode(lone)),
          isNot(equals(s.fingerprint(jsonEncode(replaced)))));
    });

    test('HARDENING: 键含特殊字符 / 空键 / 注入样式字符串安全往返', () {
      final m = <String, dynamic>{};
      m[''] = 'empty key';
      m['a/b'] = 'slash';
      m['a.b'] = 'dot';
      m[r'a\b'] = 'backslash';
      m['ünïcødé🔑'] = 'v';
      m['{"inject":true}'] = 'v2';
      m['<script>alert(1)</script>'] = 'v3';
      expect(jsonDecode(jsonEncode(m)), equals(m));
    });

    test('HARDENING: 日期时间往返 —— UTC 微秒保真;local 无时区标记', () {
      final utc = DateTime.utc(2026, 10, 11, 3, 4, 5, 678, 901);
      expect(utc.toIso8601String(), endsWith('Z'));
      expect(DateTime.parse(utc.toIso8601String()), equals(utc));
      expect(DateTime.parse(utc.toIso8601String()).microsecond, equals(901));

      final local = DateTime(2026, 10, 11, 3, 4, 5, 678);
      final ls = local.toIso8601String();
      expect(ls.endsWith('Z'), isFalse);
      expect(DateTime.parse(ls), equals(local));
      expect(DateTime.parse(ls).isUtc, isFalse);
      // '2026-10-11T10:00:00'(无时区)会按本地时区解释 —— 跨设备比较前的坑
      expect(DateTime.tryParse('2026-10-11T10:00:00')!.isUtc, isFalse);
    });
  });

  group('DataSerializer — 非法输入与契约缺口', () {
    test('HARDENING: 非法 JSON 抛 FormatException(不是 CloudSyncException)', () async {
      final s = _StrictSerializer();
      await expectLater(
          s.deserialize('not json at all'), throwsA(isA<FormatException>()));
    });

    test('HARDENING: 业务层直接调用 serializer 时,失败是裸 FormatException/_TypeError', () async {
      // HARDENING: DataSerializer 契约(lib/src/core/data_serializer.dart:37-54)
      // 未约定失败类型。Manager 内部有 catch-all 包装,但业务层直接调用
      // serializer（主工程 sync_engine 只走 manager,风险面有限）时
      // 需要自己处理 FormatException / _TypeError / NoSuchMethodError 三种。
      final strict = _StrictSerializer();
      await expectLater(strict.deserialize('nope'), throwsA(isA<FormatException>()));
      await expectLater(
          strict.deserialize('{"ledgerId":"x"}'), throwsA(isA<TypeError>()));
      await expectLater(strict.deserialize('[1]'), throwsA(isA<TypeError>()));
    });

    test('HARDENING: DataSerializer 接口无校验钩子 / 无 schema 版本', () {
      // HARDENING: 只有 serialize/deserialize/fingerprint 三方法;
      // 向后兼容(旧字段缺失)的责任完全在实现方
      final s = _ShaSerializer();
      expect(s, isA<DataSerializer<int>>());
      expect(s.serialize(1), isA<Future<String>>());
      expect(s.fingerprint('x'), isNotEmpty);
    });
  });

  group('CloudSyncManager — 异常包裹与信息暴露', () {
    late _MockProvider provider;

    CloudSyncManager<int> buildManager([DataSerializer<int>? ser]) =>
        CloudSyncManager<int>(
          provider: provider,
          serializer: ser ?? _StrictSerializer(),
        );

    setUp(() {
      provider = _MockProvider();
    });

    test('HARDENING: 底层 Exception 被包成 CloudStorageException 并保留 cause', () async {
      provider.files['p.json'] = '{"ledgerId":1}';
      provider.downloadError = const FormatException('bad payload');
      try {
        await buildManager().download(path: 'p.json');
        fail('应当抛出');
      } on CloudStorageException catch (e) {
        expect(e.originalError, isA<FormatException>());
        expect(e.message, equals('Download failed'));
      }
    });

    test('ADVERSE: 云端内容损坏时,FormatException 摘录把云端字段带进异常文本', () async {
      // ADVERSE FINDING: 真实链路是 storage.download 返回损坏内容 →
      // serializer.deserialize → jsonDecode 抛 FormatException。
      // dart:convert 的 FormatException.toString() 会附上**输入文本前 78 字符**
      // 的摘录;CloudSyncManager.download 的 catch(e) 把它原样交给
      // CloudStorageException(..., e) → 异常文本携带云端原始字段。
      // 而 App 端 cloud_sync_page.dart:187-188 (`default: localizedMessage =
      // st.message`)会把 getStatus 的 message 显示到界面,日志侧同样落盘。
      // 源码: lib/src/manager/cloud_sync_manager.dart:174-187 与 387-393
      // 期望: 异常/日志不含云端原始内容(备注、卡号、token)
      // 实际: 短内容时摘录 100% 进入异常文本
      provider.files['p.json'] =
          '{"note":"AAAAAAAAAA","card":"4242-4242-4242-4242",}'; // 尾逗号 → 非法
      try {
        await buildManager().download(path: 'p.json');
        fail('应当抛出');
      } catch (e) {
        expect('$e'.contains('4242-4242-4242-4242'), isFalse,
            reason: '异常文本携带云端敏感字段摘录: $e');
      }
    });

    test('ADVERSE: getStatus 兜底把原始异常文本塞进 SyncStatus.message', () async {
      // ADVERSE FINDING: getStatus 永不抛,所有失败塌缩成 SyncState.error +
      // 自由文本 message(含底层摘录);调用方无法区分"云端文件损坏 /
      // 网络抖动 / 鉴权失败",只能做字符串匹配。
      // 源码: lib/src/manager/cloud_sync_manager.dart:387-394
      // 期望: 结构化错误分类字段(errors 不含原始内容摘录)
      // 实际: message = 'Failed to get sync status: $e'
      provider.files['p.json'] = '{"ledgerId":1}';
      provider.downloadError = const FormatException('boom-secret-fragment');
      final status = await buildManager().getStatus(path: 'p.json');
      expect(status.state, equals(SyncState.error));
      expect(status.message, isNot(contains('boom-secret-fragment')),
          reason: '实际 message=${status.message}');
    });

    test('HARDENING: 未认证时 download/upload/deleteRemote 抛 CloudNotAuthenticatedException;'
        'getStatus 返回 notAuthenticated', () async {
      provider.user = null;
      await expectLater(buildManager().download(path: 'p.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(buildManager().upload(data: 1, path: 'p.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(buildManager().deleteRemote(path: 'p.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      final st = await buildManager().getStatus(path: 'p.json');
      expect(st.state, equals(SyncState.notAuthenticated));
    });

    test('HARDENING: serializer 抛的 Error 也被 catch-all 包成 CloudStorageException', () async {
      // HARDENING: download 的 `catch (e)` 无类型过滤,Error 同样被包
      // (这与「只包 Exception」的直觉相反,但结果是调用方更安全)
      provider.files['p.json'] = '{"ledgerId":1}';
      try {
        await buildManager(_ThrowingErrorSerializer()).download(path: 'p.json');
        fail('应当抛出');
      } on CloudStorageException catch (e) {
        expect(e.originalError, isA<StateError>());
      }
    });

    test('HARDENING: getStatus 的 catch 无类型过滤,Error 也被吞成 SyncState.error', () async {
      // HARDENING(修正):原断言固化"message 含 Bad state: bug"(即异常原文进
      // message 字段),与同文件 ADVERSE: getStatus 兜底把原始异常文本塞进
      // SyncStatus.message(R-10)直接矛盾 —— 同一个 message 不可能既不含
      // 底层摘录又含 'Bad state: bug'。
      // R-10 修复后保真的部分:Error(StateError 等)仍被 catch-all 吞掉、
      // 降级为 SyncState.error,不向上抛(查询状态接口永不抛的契约不变);
      // 变化的部分:message 只保留结构化分类(异常类型),不再回显原文。
      provider.files['p.json'] = '{"ledgerId":1}';
      final st = await buildManager(_ThrowingErrorSerializer())
          .getStatus(path: 'p.json');
      expect(st.state, equals(SyncState.error),
          reason: '当前行为:Error 被吞成业务状态: ${st.message}');
      expect(st.message, contains('StateError'),
          reason: 'message 应保留异常类型分类,便于排查');
      expect(st.message, isNot(contains('Bad state: bug')),
          reason: '异常原文不应进 message(R-10)');
    });

    test('HARDENING: 云端 count 为 Infinity(1e999)时 getStatus 不崩,方向退化 unknown', () async {
      // HARDENING: (json['count'] as num?)?.toInt() 对 Infinity 抛
      // UnsupportedError,但被 287-306 的 catch(_) 吞掉 → cloudCount 保持 null
      // → 方向 unknown。包内健壮;此处固化"不崩溃"这一事实。
      provider.files['p.json'] =
          '{"ledgerId":1,"count":1e999}'; // count 解出 Infinity
      final st = await buildManager().getStatus(data: 1, path: 'p.json');
      expect(st.state, equals(SyncState.outOfSync));
      expect(st.cloudCount, isNull);
      expect(st.direction, equals(SyncDirection.unknown));
    });

    test('HARDENING: 不可编码数据(Infinity)在 upload 被包成 CloudStorageException', () async {
      // HARDENING: serializer.serialize 内 jsonEncode 抛
      // JsonUnsupportedObjectError(Error 家族)时,upload 的 catch(e)
      // (cloud_sync_manager.dart:128-134,无类型过滤)会包成
      // CloudStorageException('Upload failed', e) —— 不会裸抛 Error。
      await expectLater(
        buildManager(_InfinitySerializer()).upload(data: 1, path: 'p.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('HARDENING: 上传路径的 metadata 含指纹与上传时间', () async {
      await buildManager().upload(data: 7, path: 'p.json');
      final meta = provider.uploadedMetadata['p.json']!;
      expect(meta['fingerprint'], isNotEmpty);
      expect(meta.containsKey('uploadedAt'), isTrue);
      expect(meta['userId'], equals('u1'));
      expect(DateTime.tryParse(meta['uploadedAt']!), isNotNull);
    });
  });

  group('异常分类体系', () {
    test('HARDENING: 各类异常构造与继承关系', () {
      final base = CloudSyncException('m', 'orig');
      expect(base.message, equals('m'));
      expect(base.originalError, equals('orig'));
      expect('$base', contains('m'));
      expect('$base', contains('orig'));

      final noOrig = CloudSyncException('m2');
      expect('$noOrig', isNot(contains('Original error')));

      expect(CloudNotAuthenticatedException().message,
          equals('User not authenticated'));
      expect(CloudNotAuthenticatedException('custom').message, equals('custom'));
      expect(CloudConfigurationException('c', 42).originalError, equals(42));
      expect(CloudStorageException('s', 500).originalError, equals(500));
      expect(CloudAuthException('a').originalError, isNull);

      // 全部是 Exception(不是 Error)→ 能被 catch(Exception) 捕获
      for (final e in <Object>[
        CloudSyncException('x'),
        CloudNotAuthenticatedException(),
        CloudConfigurationException('x'),
        CloudStorageException('x'),
        CloudAuthException('x'),
      ]) {
        expect(e, isA<Exception>());
        expect(e, isA<CloudSyncException>());
      }
    });

    test('ADVERSE: CloudStorageException 不携带 statusCode,无法区分 4xx/5xx', () {
      // ADVERSE FINDING: 异常类只有 message + dynamic originalError;
      // 生产代码在少数地方把 statusCode 塞进 originalError
      // (lib/src/providers/smartbook_cloud_provider.dart:2080, 2109),
      // 但绝大多数构造点(lib/src/providers/smartbook_cloud_provider.dart:1893,
      // 1911, 1948, 2000, 2010 … 共 40+ 处)只传 message 字符串。
      // 于是 RetryHelper 只能"凡 CloudStorageException 一律重试"(见
      // path_and_retry_adversarial_test.dart),4xx 终态错误被重复提交 3 次。
      // 期望: 异常暴露统一的可编程字段(如 int? statusCode)
      // 实际: 无该字段(下面用 dynamic 探测)
      final e = CloudStorageException('Upload failed: HTTP 422', 422);
      Object? statusCode;
      try {
        statusCode = (e as dynamic).statusCode;
      } catch (_) {
        statusCode = null;
      }
      expect(statusCode, equals(422),
          reason: '异常缺少结构化 statusCode,调用方只能解析 message 字符串');
    });

    // 低-3(c)(2026-10-11 三轮复查):vendor 部分 raise 点把状态码直接拼进
    // 消息(`'... failed (404): ...'`)而不传 statusCode —— 旧正则只认
    // `HTTP NNN` 形态,消息兜底全部 miss,isClientError 恒 false。
    group('低-3(c): (NNN) 括号消息兜底解析', () {
      test('裸 (404) 括号 → statusCode / isClientError 命中', () {
        final e =
            CloudStorageException('Attachment download failed (404): gone');
        expect(e.statusCode, 404);
        expect(e.isClientError, isTrue,
            reason: 'RetryHelper 依赖它短路终态 4xx');
      });

      test('HTTP 404 显式形态仍命中(不回归)', () {
        expect(CloudStorageException('failed HTTP 404').statusCode, 404);
      });

      test('五位数字 / 非状态码不误伤', () {
        expect(CloudStorageException('file (12345) bytes').statusCode, isNull);
        expect(CloudStorageException('no status here').statusCode, isNull);
      });

      test('显式 statusCode 优先于消息(形态 1 > 兜底)', () {
        expect(CloudStorageException('x', null, 502).statusCode, 502);
      });
    });

    test('ADVERSE: 异常 toString 无条件展开 originalError,敏感响应整包进日志', () {
      // ADVERSE FINDING: toString 把 originalError 全量展开
      // (lib/src/core/exceptions.dart:8-14),而 CloudSyncManager 用
      // logger?.error('Upload failed: $e')(lib/src/manager/cloud_sync_manager.dart:129)
      // 直接写日志;上游大量把 http.Response / 响应体片段作为 originalError 传入。
      // 期望: 记录异常时对 originalError 脱敏(或截断)
      // 实际: 全量展开
      final e = CloudStorageException('Upload failed', {
        'detail': 'token=eyJhbGciOiJIUzI1NiJ9.SECRET.SIG',
      });
      expect('$e'.contains('SECRET'), isFalse,
          reason: '异常文本展开了原始响应: $e');
    });

    test('HARDENING: 包内自身不把 Authorization / Bearer 写进异常文本', () {
      final src = '${CloudStorageException('x')}';
      expect(src.toLowerCase().contains('authorization'), isFalse);
      expect(src.toLowerCase().contains('bearer'), isFalse);
    });
  });
}

String _tryEncode(Object? v) {
  try {
    return jsonEncode(v);
  } catch (e) {
    return '${e.runtimeType}';
  }
}

class _MockProvider implements CloudProvider {
  final Map<String, String> files = {};
  final Map<String, Map<String, String>> uploadedMetadata = {};
  CloudUser? user = const CloudUser(id: 'u1');
  Exception? downloadError;

  @override
  CloudAuthService get auth => _MockAuth(this);
  @override
  CloudStorageService get storage => _MockStorage(this);
  @override
  String get providerId => 'mock';
  @override
  String get providerName => 'mock';
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
}

class _MockAuth implements CloudAuthService {
  _MockAuth(this.p);
  final _MockProvider p;
  @override
  Stream<CloudUser?> get authStateChanges => Stream.value(p.user);
  @override
  Future<CloudUser?> get currentUser async => p.user;
  @override
  Future<CloudUser> signInWithEmail(
          {required String email, required String password}) async =>
      p.user!;
  @override
  Future<CloudUser> signUpWithEmail(
          {required String email, required String password}) async =>
      p.user!;
  @override
  Future<void> signOut() async => p.user = null;
  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}
  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

class _MockStorage implements CloudStorageService {
  _MockStorage(this.p);
  final _MockProvider p;
  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {
    if (p.downloadError != null) throw p.downloadError!;
    p.files[path] = data;
    p.uploadedMetadata[path] = metadata ?? const {};
  }

  @override
  Future<String?> download({required String path}) async {
    final e = p.downloadError;
    if (e != null) throw e;
    return p.files[path];
  }

  @override
  Future<void> delete({required String path}) async {
    if (p.downloadError != null) throw p.downloadError!;
    p.files.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async =>
      p.files.entries.map((e) => CloudFile(name: e.key, path: e.key)).toList();
  @override
  Future<bool> exists({required String path}) async =>
      p.files.containsKey(path);
  @override
  Future<CloudFile?> getMetadata({required String path}) async =>
      p.files.containsKey(path) ? CloudFile(name: path, path: path) : null;
}
