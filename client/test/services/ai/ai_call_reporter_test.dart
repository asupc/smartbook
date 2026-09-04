import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_extraction_engine.dart';
import 'package:smartbook/services/ai/ai_call_reporter.dart';

/// AiCallReporterHttp 行为测试:URL/鉴权/字段/静默失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // logger_service 落日志需要 SharedPreferences
  SharedPreferences.setMockInitialValues({});
  const report = AiCallReport(
    entryType: 'parse_tx_text',
    status: 'ok',
    providerId: 'OpenAI',
    model: 'gpt-4o',
    inputText: '短信:支出28元',
    outputText: '[{"amount": 28.0}]',
    durationMs: 42,
  );

  group('AiCallReporterHttp', () {
    test('POST 到 baseUrl+apiPrefix+/ai/logs,带 Bearer 与完整字段', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"ok": true}', 201);
      });
      final reporter = AiCallReporterHttp(
        baseUrl: 'https://cloud.example.com',
        apiPrefix: '/api/v1',
        accessToken: () async => 'token-123',
        client: client,
      );

      reporter.call(report);
      // fire-and-forget:等到后台 POST 完成
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(captured, isNotNull);
      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://cloud.example.com/api/v1/ai/logs',
      );
      expect(captured.headers['Authorization'], 'Bearer token-123');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['entry_type'], 'parse_tx_text');
      expect(body['status'], 'ok');
      expect(body['provider_id'], 'OpenAI');
      expect(body['model'], 'gpt-4o');
      expect(body['input_text'], '短信:支出28元');
      expect(body['duration_ms'], 42);
      expect(body['ledger_id'], isNull);
    });

    test('服务端 500 不抛异常(静默失败)', () async {
      final client = MockClient((request) async => http.Response('boom', 500));
      final reporter = AiCallReporterHttp(
        baseUrl: 'https://cloud.example.com',
        apiPrefix: '/api/v1',
        accessToken: () async => 'token-123',
        client: client,
      );

      reporter.call(report);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // 能跑到这里就说明没抛
    });

    test('accessToken 异常(未登录)也不抛', () async {
      final client = MockClient((request) async => http.Response('', 201));
      final reporter = AiCallReporterHttp(
        baseUrl: 'https://cloud.example.com',
        apiPrefix: '/api/v1',
        accessToken: () async => throw Exception('not logged in'),
        client: client,
      );

      reporter.call(report);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('baseUrl 为空(SmartBook Cloud 未配置)时零网络请求', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('', 201);
      });
      final reporter = AiCallReporterHttp(
        baseUrl: '',
        apiPrefix: '/api/v1',
        accessToken: () async => 'token-123',
        client: client,
      );

      reporter.call(report);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(called, isFalse);
    });

    test('带 imageFile 走 multipart 上报 /ai/logs/image(字段+原图)', () async {
      final tmpDir = Directory.systemTemp.createTempSync('ai-report-test');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final img = File('${tmpDir.path}${Platform.pathSeparator}Screenshot_20260903_152911.jpg')
        ..writeAsBytesSync(List<int>.generate(256, (i) => i));
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"ok": true}', 201);
      });
      final reporter = AiCallReporterHttp(
        baseUrl: 'https://cloud.example.com',
        apiPrefix: '/api/v1',
        accessToken: () async => 'token-123',
        client: client,
      );

      reporter.call(AiCallReport(
        entryType: 'parse_tx_image',
        status: 'ok',
        providerId: 'OpenAI',
        model: 'gpt-4o-vision',
        inputText: 'image: Screenshot_20260903_152911.jpg (256 bytes)',
        durationMs: 42,
        imageFile: img,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(captured, isNotNull);
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'https://cloud.example.com/api/v1/ai/logs/image');
      expect(captured.headers['Authorization'], 'Bearer token-123');
      expect(captured.headers['content-type'], contains('multipart/form-data'));
      final body = latin1.decode(captured.bodyBytes, allowInvalid: true);
      expect(body, contains('name="entry_type"'));
      expect(body, contains('parse_tx_image'));
      expect(body, contains('name="status"'));
      expect(body, contains('name="duration_ms"'));
      expect(body, contains('name="image"'));
      expect(body, contains('Screenshot_20260903_152911.jpg'));
      // 原图二进制完整进 body
      expect(captured.bodyBytes,
          containsAllInOrder(List<int>.generate(256, (i) => i)));
    });

    test('图片文件不存在时降级为纯文本 JSON 上报 /ai/logs', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"ok": true}', 201);
      });
      final reporter = AiCallReporterHttp(
        baseUrl: 'https://cloud.example.com',
        apiPrefix: '/api/v1',
        accessToken: () async => 'token-123',
        client: client,
      );

      reporter.call(AiCallReport(
        entryType: 'parse_tx_image',
        status: 'error',
        inputText: 'image: missing.jpg (0 bytes)',
        durationMs: 3,
        imageFile: File('Z:/definitely_missing/shot.jpg'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(captured, isNotNull);
      expect(
        captured.url.toString(),
        'https://cloud.example.com/api/v1/ai/logs',
      );
      expect(captured.headers['content-type'], contains('application/json'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['entry_type'], 'parse_tx_image');
      expect(body['status'], 'error');
    });
  });

  group('AiCallReport.copyWith', () {
    test('只替换 ledgerId,其余字段保留', () {
      const r = AiCallReport(entryType: 'ask', status: 'ok', durationMs: 1);
      final updated = r.copyWith(ledgerId: '7');
      expect(updated.ledgerId, '7');
      expect(updated.entryType, 'ask');
      expect(updated.status, 'ok');
      expect(updated.durationMs, 1);
      expect(r.ledgerId, isNull); // 原对象不可变
    });
  });
}
