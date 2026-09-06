/// M0-1 验收:自动记账 Trace 必须能用**同一个 trace_id** 还原一条事件的阶段
/// 耗时,并且日志里搜不到原文。
///
/// 回归价值:trace 是后续所有性能优化的唯一测量口径 —— 阶段丢了(下层拿不到
/// 当前 trace)就没法定位慢在哪;字段写宽了(把短信正文/通知 title-body 带进
/// 日志)就是隐私事故,而两者都不会报错。这里用真实 Coordinator 串起来钉住:
/// Zone 传递、阶段顺序、时间线单调、跳过/异常分支各留一行、原文零出现。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_trace.dart';
import 'package:smartbook/services/system/logger_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 故意带敏感原文:金额、卡尾号、余额都不允许出现在任何日志行里。
  const rawText = '【工商银行】您账户9527于09-06支出人民币28.50元,余额1234.56元';

  late BeeDatabase db;
  late AutoBookCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    coordinator = AutoBookCoordinator(db);
    logger.clear();
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        sourceChannel: 'com.android.mms',
        ledgerId: 1,
        capturedAt: DateTime.now().toUtc(),
        rawText: rawText,
      );

  List<String> traceLines() => logger.logs
      .where((e) => e.tag == 'AutoBookTrace')
      .map((e) => e.message)
      .toList();

  String? field(String line, String key) =>
      RegExp('(?:^| )$key=(\\S*)').firstMatch(line)?.group(1);

  /// booked 收尾的正常事件;[onAction] 用来模拟下层(中转客户端)打点。
  Future<AutoBookExecution<int>> runBooked(
    String key, {
    void Function()? onAction,
  }) {
    return coordinator.execute<int>(
      input: input(key),
      action: () async {
        onAction?.call();
        return 1;
      },
      updateFor: (_) => const AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: 1,
      ),
    );
  }

  test('一条事件的各阶段共享同一 trace_id,阶段耗时可还原', () async {
    final execution = await runBooked('sms:v1:trace-ok', onAction: () {
      // 真实实现在 AiRelayClient._traceProviderCall:靠 Zone 取当前 trace,
      // 不改函数签名。取不到就意味着阶段会静默丢失。
      expect(AutoBookTrace.current, isNotNull);
      AutoBookTrace.current!.stage(
        'provider_call',
        durationMs: 7,
        payloadBytes: 128,
        providerId: 'zhipu',
        model: 'glm-4',
      );
    });
    expect(execution.state, AutoBookState.booked);

    final lines = traceLines();
    expect(
      lines.map((l) => field(l, 'stage')),
      ['claim', 'provider_call', 'event_terminal'],
    );
    expect(lines.map((l) => field(l, 'trace_id')).toSet(), hasLength(1));

    // 每行都带阶段耗时 + 累计耗时,累计值单调不减 → 时间线可还原。
    var previousTotal = -1;
    for (final line in lines) {
      expect(field(line, 'duration_ms'), isNotNull);
      final total = int.parse(field(line, 'total_ms')!);
      expect(total, greaterThanOrEqualTo(previousTotal));
      previousTotal = total;
    }

    final claim = lines.first;
    expect(field(claim, 'source'), 'sms');
    expect(field(claim, 'source_channel'), 'com.android.mms');
    expect(field(claim, 'ledger_id'), '1');
    // 事件身份只有短 hash,原始 eventKey 都不进日志。
    expect(field(claim, 'event_key_hash'), hasLength(12));
    expect(field(claim, 'attempt_count'), '1');

    final providerCall = lines[1];
    expect(field(providerCall, 'duration_ms'), '7');
    expect(field(providerCall, 'payload_bytes'), '128');
    expect(field(providerCall, 'provider_id'), 'zhipu');
    expect(field(providerCall, 'model'), 'glm-4');

    expect(field(lines.last, 'outcome'), 'booked');
  });

  test('全量日志里搜不到短信原文', () async {
    await runBooked('sms:v1:trace-privacy', onAction: () {
      AutoBookTrace.current!.stage('provider_call', payloadBytes: 128);
    });

    for (final entry in logger.logs) {
      expect(entry.message, isNot(contains('工商银行')));
      expect(entry.message, isNot(contains('28.50')));
      expect(entry.message, isNot(contains('9527')));
      expect(entry.message, isNot(contains(rawText)));
    }
  });

  test('重复事件:claim 阶段记 skipped_<state>,不产生后续阶段', () async {
    await runBooked('sms:v1:trace-dup');
    logger.clear();

    final again = await coordinator.execute<int>(
      input: input('sms:v1:trace-dup'),
      action: () async => throw StateError('已终结的事件不应再执行'),
      updateFor: (_) => const AutoBookEventUpdate(state: AutoBookState.booked),
    );
    expect(again.skipped, isTrue);

    final lines = traceLines();
    expect(lines, hasLength(1));
    expect(field(lines.single, 'stage'), 'claim');
    expect(field(lines.single, 'outcome'), 'skipped_booked');
  });

  test('业务抛异常:仍记 event_terminal(outcome=exception)', () async {
    await expectLater(
      coordinator.execute<int>(
        input: input('sms:v1:trace-throw'),
        action: () async => throw StateError('boom'),
        updateFor: (_) =>
            const AutoBookEventUpdate(state: AutoBookState.booked),
      ),
      throwsA(isA<StateError>()),
    );

    final lines = traceLines();
    expect(lines.map((l) => field(l, 'stage')), ['claim', 'event_terminal']);
    expect(field(lines.last, 'outcome'), 'exception');
  });

  test('不同事件 trace_id 不同;不经 Coordinator 时没有 trace', () async {
    expect(AutoBookTrace.current, isNull);

    await runBooked('sms:v1:trace-a');
    await runBooked('sms:v1:trace-b');

    expect(traceLines().map((l) => field(l, 'trace_id')).toSet(), hasLength(2));
    expect(AutoBookTrace.current, isNull);
  });
}
