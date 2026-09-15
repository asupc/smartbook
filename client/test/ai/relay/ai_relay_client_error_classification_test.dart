/// P0-3 验收:AI 中转错误分类必须是「默认 transient,显式白名单 permanent」。
///
/// 只有 400/404/422(请求本身不合法、重试无意义)允许判 permanentFailure →
/// 终结事件并 ACK 删除原始短信/通知;401 / 403 / 全部 5xx / 429 / 网络层
/// 异常一律 transient → retryableFailure,事件回 retry、原生队列不 ACK。
/// 这条链上任何一环退化(比如把服务端一次 500 判成永久失败)都会**永久
/// 销毁记账证据** —— 这里从真实 [AiRelayClient](注入 MockClient)出发,
/// 分层钉住:HTTP 分类 → factory 透传 → engine outcome → bookkeeper
/// 结果轴 → SmsProcessOutcome 的 ACK 闸门。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_extraction_context.dart';
import 'package:smartbook/ai/core/ai_extraction_engine.dart';
import 'package:smartbook/ai/core/ai_runtime_state.dart';
import 'package:smartbook/ai/providers/ai_provider_factory.dart';
import 'package:smartbook/ai/relay/ai_relay_client.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/ai/ai_bookkeeper.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';

Future<String> _token() async => 'test-token';

/// 底层 HTTP 永远返回指定状态码的 mock(走真实 `_send`/`_errorFrom`)。
AiRelayClient _relayWithStatus(int status) => AiRelayClient(
      baseUrl: 'http://127.0.0.1',
      apiPrefix: 'api/v1',
      accessToken: _token,
      client: MockClient(
        (request) async => http.Response('{"message": "mock failure"}', status),
      ),
    );

const _parseMessages = [
  AiRelayMessage(role: 'user', content: '工商银行 支出 28.50 元'),
];

Future<void> _expectRelayError(
  AiRelayClient relay, {
  required bool transient,
  required String errorCode,
  required int statusCode,
}) {
  return expectLater(
    relay.chat(messages: _parseMessages, entryType: 'parse_tx_text'),
    throwsA(isA<AiRelayException>()
        .having((e) => e.transient, 'transient', transient)
        .having((e) => e.errorCode, 'errorCode', errorCode)
        .having((e) => e.statusCode, 'statusCode', statusCode)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // logger 走 SharedPreferences 异步持久化,统一给 mock 初值。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AiRelayClient HTTP 错误分类(默认 transient,白名单 permanent)', () {
    test('500 → transient(upstream_unavailable),不得判为永久失败', () async {
      await _expectRelayError(_relayWithStatus(500),
          transient: true, errorCode: 'upstream_unavailable', statusCode: 500);
    });

    test('501 / 503(白名单外的 5xx)同样 transient —— 全部 5xx 覆盖', () async {
      await _expectRelayError(_relayWithStatus(501),
          transient: true, errorCode: 'upstream_unavailable', statusCode: 501);
      await _expectRelayError(_relayWithStatus(503),
          transient: true, errorCode: 'upstream_unavailable', statusCode: 503);
    });

    test('429 限流 → transient(upstream_unavailable)', () async {
      await _expectRelayError(_relayWithStatus(429),
          transient: true, errorCode: 'upstream_unavailable', statusCode: 429);
    });

    test('403 → transient(http_error):临时权限/网关问题不能销毁证据', () async {
      await _expectRelayError(_relayWithStatus(403),
          transient: true, errorCode: 'http_error', statusCode: 403);
    });

    test('401 → transient(unauthorized):等用户登录恢复', () async {
      await _expectRelayError(_relayWithStatus(401),
          transient: true, errorCode: 'unauthorized', statusCode: 401);
    });

    test('网络层异常(ClientException)→ transient(network)', () async {
      final relay = AiRelayClient(
        baseUrl: 'http://127.0.0.1',
        apiPrefix: 'api/v1',
        accessToken: _token,
        client: MockClient(
          (request) async => throw http.ClientException('connection refused'),
        ),
      );
      await expectLater(
        relay.chat(messages: _parseMessages, entryType: 'parse_tx_text'),
        throwsA(isA<AiRelayException>()
            .having((e) => e.transient, 'transient', isTrue)
            .having((e) => e.errorCode, 'errorCode', 'network')),
      );
    });

    test('permanent 白名单 400/404/422 → transient=false(http_error)', () async {
      await _expectRelayError(_relayWithStatus(400),
          transient: false, errorCode: 'http_error', statusCode: 400);
      await _expectRelayError(_relayWithStatus(404),
          transient: false, errorCode: 'http_error', statusCode: 404);
      await _expectRelayError(_relayWithStatus(422),
          transient: false, errorCode: 'http_error', statusCode: 422);
    });
  });

  group('AIProviderFactory 透传(中转异常 → AIException)', () {
    setUp(() => AIProviderFactory.relayClient = null);
    tearDown(() => AIProviderFactory.relayClient = null);

    test('500 → AIException(transient=true, code=upstream_unavailable)', () async {
      AIProviderFactory.relayClient = _relayWithStatus(500);
      await expectLater(
        AIProviderFactory.chatWithMeta('工商银行 支出 28.50 元',
            entryType: 'parse_tx_text'),
        throwsA(isA<AIException>()
            .having((e) => e.transient, 'transient', isTrue)
            .having((e) => e.code, 'code', 'upstream_unavailable')),
      );
    });

    test('400 → AIException(transient=false, code=http_error)', () async {
      AIProviderFactory.relayClient = _relayWithStatus(400);
      await expectLater(
        AIProviderFactory.chatWithMeta('工商银行 支出 28.50 元',
            entryType: 'parse_tx_text'),
        throwsA(isA<AIException>()
            .having((e) => e.transient, 'transient', isFalse)
            .having((e) => e.code, 'code', 'http_error')),
      );
    });
  });

  group('P0-3 全链语义(engine → bookkeeper → 原生队列 ACK 闸门)', () {
    late BeeDatabase db;
    late LocalRepository repo;
    late AiBookkeeper bookkeeper;
    late int ledgerId;

    setUp(() async {
      db = BeeDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      ledgerId = await repo.createLedger(name: 'test');
      await repo.createCategory(name: '餐饮', kind: 'expense');
      bookkeeper = AiBookkeeper(
        repository: repo,
        engine: const DefaultAiExtractionEngine(),
        persister: BillCreationService(repo),
      );
    });

    tearDown(() async {
      AIProviderFactory.relayClient = null;
      await db.close();
    });

    Future<AiExtractionContext> context() =>
        AiExtractionContext.forLedger(repository: repo, ledgerId: ledgerId);

    test('中转 500:engine 判 retryableFailure,bookkeeper 落 retryable,不允许 ACK',
        () async {
      AIProviderFactory.relayClient = _relayWithStatus(500);

      final outcome = await const DefaultAiExtractionEngine()
          .extractFromText('工商银行 支出 28.50 元', await context());
      expect(outcome.status, ExtractionStatus.retryableFailure);
      expect(outcome.errorCode, 'upstream_unavailable');

      final result = await bookkeeper.fromText(
        text: '工商银行 支出 28.50 元',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );
      expect(result.retryable, isTrue);
      expect(result.permanentFailure, isFalse);
      // retryable → SmsProcessOutcome.failed → 原始短信/通知必须保留。
      expect(SmsProcessOutcome.failed.canAckNativeQueue, isFalse);
    });

    test('中转 403:engine 同样判 retryableFailure(http_error)', () async {
      AIProviderFactory.relayClient = _relayWithStatus(403);

      final outcome = await const DefaultAiExtractionEngine()
          .extractFromText('工商银行 支出 28.50 元', await context());
      expect(outcome.status, ExtractionStatus.retryableFailure);
      expect(outcome.errorCode, 'http_error');
      expect(SmsProcessOutcome.failed.canAckNativeQueue, isFalse);
    });

    test('中转 400(白名单 permanent):engine 判 permanentFailure,允许 ACK 终结',
        () async {
      AIProviderFactory.relayClient = _relayWithStatus(400);

      final outcome = await const DefaultAiExtractionEngine()
          .extractFromText('工商银行 支出 28.50 元', await context());
      expect(outcome.status, ExtractionStatus.permanentFailure);
      expect(outcome.errorCode, 'http_error');

      final result = await bookkeeper.fromText(
        text: '工商银行 支出 28.50 元',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );
      expect(result.permanentFailure, isTrue);
      expect(result.retryable, isFalse);
      // 真正的永久失败依然 ACK,不会无限重推(重试放大由 maxAttempts 兜底)。
      expect(SmsProcessOutcome.permanentFailure.canAckNativeQueue, isTrue);
    });
  });

  group('AiRuntimeCoordinator.applyFailureCode(http_error)', () {
    setUp(() => AiRuntimeCoordinator.instance.resetForTest());
    tearDown(() => AiRuntimeCoordinator.instance.resetForTest());

    test('http_error → providerError,状态机可感知', () {
      AiRuntimeCoordinator.instance.markReady();
      AiRuntimeCoordinator.instance.applyFailureCode('http_error');
      expect(AiRuntimeCoordinator.instance.state, AiRuntimeState.providerError);
    });

    test('upstream_unavailable → providerError;未知码不改状态', () {
      AiRuntimeCoordinator.instance.markReady();
      AiRuntimeCoordinator.instance.applyFailureCode('upstream_unavailable');
      expect(AiRuntimeCoordinator.instance.state, AiRuntimeState.providerError);

      AiRuntimeCoordinator.instance.markReady();
      AiRuntimeCoordinator.instance.applyFailureCode('totally_unknown');
      expect(AiRuntimeCoordinator.instance.state, AiRuntimeState.ready);
    });
  });
}
