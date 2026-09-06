/// M2-5 / M1 验收:AI 中转的瞬态失败(Relay 未就绪、请求 deadline 超时)必须
/// 落 `retry` 并带退避,绝不能被当成「不是账单」终结事件、ACK 原生队列。
///
/// 回归价值:这条链上任何一环退化都会**永久丢失**原始短信/通知 —— engine 把
/// 失败写成空 bills、bookkeeper 把 retryable 当 noBill、coordinator 用 mark()
/// 写 retry(nextRetryAt=null → 桥接广播/启动 drain 忙循环)、监听层按终态
/// ACK。这里用真实 DB + 真实 coordinator + 真实 engine 串起来钉住,只把
/// [AiRelayClient] 换成「必定超时」的替身。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_extraction_context.dart';
import 'package:smartbook/ai/core/ai_extraction_engine.dart';
import 'package:smartbook/ai/providers/ai_provider_factory.dart';
import 'package:smartbook/ai/relay/ai_relay_client.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/ai/ai_bookkeeper.dart';
import 'package:smartbook/services/ai/bookkeeping_result.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';

/// 每次调用都按「已到 deadline」失败的中转客户端。
///
/// 与真实客户端 `.timeout(deadline)` 抛出的异常同形(transient + `timeout`),
/// 测试因此不依赖真实网络等待,也不需要 fake time。
class _TimeoutRelayClient extends AiRelayClient {
  _TimeoutRelayClient()
      : super(
          baseUrl: 'http://127.0.0.1',
          apiPrefix: 'api/v1',
          accessToken: _emptyToken,
        );

  static Future<String> _emptyToken() async => '';

  @override
  Future<AiRelayChatResult> chat({
    required List<AiRelayMessage> messages,
    required String entryType,
    double temperature = 0.7,
    bool disableThinking = false,
    String? ledgerId,
    String? logInput,
  }) async {
    throw AiRelayException(
      '服务端请求超时(${AiRelayClient.textDeadline.inSeconds}s)',
      transient: true,
      errorCode: 'timeout',
    );
  }

  @override
  Future<String> vision({
    required File image,
    required String prompt,
    bool disableThinking = true,
    String? ledgerId,
    String? logInput,
  }) async {
    throw AiRelayException(
      '服务端请求超时(${AiRelayClient.visionDeadline.inSeconds}s)',
      transient: true,
      errorCode: 'timeout',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late AiBookkeeper bookkeeper;
  late AutoBookCoordinator coordinator;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'test');
    await repo.createCategory(name: '餐饮', kind: 'expense');
    bookkeeper = AiBookkeeper(
      repository: repo,
      engine: const DefaultAiExtractionEngine(),
      persister: BillCreationService(repo),
    );
    coordinator = AutoBookCoordinator(db);
    // 默认「Relay 未就绪」:等价于冷启动未注入 / 未配置云服务。
    AIProviderFactory.relayClient = null;
  });

  tearDown(() async {
    AIProviderFactory.relayClient = null;
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '短信正文',
      );

  Future<AiExtractionContext> context() =>
      AiExtractionContext.forLedger(repository: repo, ledgerId: ledgerId);

  Future<AutoBookExecution<BookkeepingResult>> runText(String key) {
    return coordinator.execute<BookkeepingResult>(
      input: input(key),
      action: () => bookkeeper.fromText(
        text: '工商银行 支出 28.50 元',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      ),
      updateFor: (result) => result.eventUpdate,
    );
  }

  test('Relay 未就绪:文本提取落 retryableFailure(relay_not_ready),不是 noBill', () async {
    final outcome = await const DefaultAiExtractionEngine()
        .extractFromText('工商银行 支出 28.50 元', await context());

    expect(outcome.status, ExtractionStatus.retryableFailure);
    expect(outcome.errorCode, 'relay_not_ready');
    expect(outcome.bills, isEmpty);
    // 只有 noBill 才允许把事件终结为 ignored 并 ACK 原生队列。
    expect(outcome.status, isNot(ExtractionStatus.noBill));
  });

  test('Relay 未就绪:事件落 retry(带退避)且不允许 ACK 原生队列', () async {
    final execution = await runText('sms:v1:relay-not-ready');

    expect(execution.skipped, isFalse);
    expect(execution.value!.retryable, isTrue);
    // handled=false 但这不是「没识别到账单」——状态轴才是判据。
    expect(execution.value!.handled, isFalse);
    expect(execution.state, AutoBookState.retry);
    // 监听层的 ACK 闸门之一:非终态 → 保留原生队列项。
    expect(execution.terminal, isFalse);

    final row = await coordinator.store.findById(execution.eventId);
    expect(row!.state, 'retry');
    expect(row.lastError, 'ai_retryable');
    expect(row.nextRetryAt, isNotNull);
    expect(row.nextRetryAt!.isAfter(DateTime.now()), isTrue);

    // 闸门另一半:retryable 结果 → SmsProcessOutcome.failed → 不 ACK。
    expect(SmsProcessOutcome.failed.canAckNativeQueue, isFalse);
    expect(SmsProcessOutcome.noAiConfigured.canAckNativeQueue, isFalse);
    expect(SmsProcessOutcome.noTransaction.canAckNativeQueue, isTrue);
  });

  test('文本 deadline 超时:事件落 retry,首档退避 30s', () async {
    AIProviderFactory.relayClient = _TimeoutRelayClient();

    final execution = await runText('sms:v1:relay-timeout');

    expect(execution.state, AutoBookState.retry);
    expect(execution.terminal, isFalse);

    final row = await coordinator.store.findById(execution.eventId);
    expect(row!.state, 'retry');
    expect(row.attemptCount, 1);
    // 首次退避 30s:既不能是 null(忙循环),也不该直接跳到更长的档位。
    final gap = row.nextRetryAt!.difference(DateTime.now());
    expect(gap.inSeconds, inInclusiveRange(20, 30));
  });

  test('图片 deadline 超时:抛 AIException(transient/timeout),不退化成空 bills', () async {
    AIProviderFactory.relayClient = _TimeoutRelayClient();
    final dir =
        await Directory.systemTemp.createTemp('smartbook_relay_timeout');
    addTearDown(() => dir.delete(recursive: true));
    final image = File('${dir.path}/shot.png')
      ..writeAsBytesSync(const [1, 2, 3]);

    // 图片路径没有 outcome 结构,靠异常传递失败语义;返回空 list 会被上层
    // 当成「截图里没有账单」而终结事件。
    await expectLater(
      const DefaultAiExtractionEngine()
          .extractFromImage(image, await context()),
      throwsA(isA<AIException>()
          .having((e) => e.transient, 'transient', isTrue)
          .having((e) => e.code, 'code', 'timeout')),
    );
  });

  test('业务抛异常:事件落 retry 且不占用全局处理槽', () async {
    final failing = coordinator.execute<BookkeepingResult>(
      input: input('sms:v1:throwing'),
      action: () async =>
          throw AIException('boom', transient: true, code: 'timeout'),
      updateFor: (result) => result.eventUpdate,
    );
    await expectLater(failing, throwsA(isA<AIException>()));

    final failed = await coordinator.store.findByEventKey('sms:v1:throwing');
    expect(failed!.state, 'retry');
    expect(failed.nextRetryAt, isNotNull);

    // 串行链在失败分支同样推进:下一个事件不会被卡住。
    final next = await coordinator.execute<BookkeepingResult>(
      input: input('sms:v1:after-throw'),
      action: () async => const BookkeepingResult(transactionIds: [9]),
      updateFor: (result) => result.eventUpdate,
    );
    expect(next.state, AutoBookState.booked);
  });
}
