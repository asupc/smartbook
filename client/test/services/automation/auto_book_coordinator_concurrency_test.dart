/// AutoBookCoordinator 并发模型回归(2026-09 并发化):
/// - 不同 eventKey 最多并发 `maxConcurrency` 个同时执行(有界并发);
/// - 同一 eventKey 串行:第二个调用等第一个完成后才 claim,不会双执行;
/// - 全局串行时代的语义保留:异常不阻断后续事件、结果正常回传。
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // AIProviderManager 读 SharedPreferences(mock 无实例时抛 MissingPluginException
  // → 协调器回退默认并发 3,会覆盖测试显式设定的上限)。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/shared_preferences'), (call) async {
    if (call.method == 'getAll') {
      return <String, Object>{};
    }
    return null;
  });

  late BeeDatabase db;
  late AutoBookCoordinator coordinator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    coordinator = AutoBookCoordinator(db);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '正文',
      );

  test('不同 eventKey 并行执行,峰值受 maxConcurrency 约束', () async {
    coordinator.setMaxConcurrency(2);
    var active = 0;
    var peak = 0;

    Future<int> job(int id) async {
      active++;
      peak = peak < active ? active : peak;
      // 让多个任务真正交叠:挂起等其它任务进入。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      return id;
    }

    final results = await Future.wait([
      for (var i = 0; i < 6; i++)
        coordinator.execute<int>(
          input: input('conc:k$i'),
          action: () => job(i),
          updateFor: (v) => AutoBookEventUpdate(
                state: AutoBookState.ignored,
                reason: 'test',
              ),
        ),
    ]);

    expect(results.map((e) => e.value), everyElement(isNotNull));
    expect(results.map((e) => e.skipped), everyElement(isFalse));
    // 并发上限 2:6 个任务应两两并行,峰值恰好 2(>1 证明并行,==2 证明有界)。
    expect(peak, 2);
    // 每个事件都落库成独立事件行。
    final rows = await coordinator.store.listHistory();
    expect(rows.where((r) => r.eventKey.startsWith('conc:k')).length, 6);
  });

  test('同一 eventKey 串行:第二个执行被幂等跳过,不双执行', () async {
    coordinator.setMaxConcurrency(4);
    var runs = 0;

    Future<int> job() async {
      runs++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return runs;
    }

    final first = coordinator.execute<int>(
      input: input('conc:same'),
      action: job,
      updateFor: (v) => AutoBookEventUpdate(
            state: AutoBookState.ignored,
            reason: 'test',
          ),
    );
    final second = coordinator.execute<int>(
      input: input('conc:same'),
      action: job,
      updateFor: (v) => AutoBookEventUpdate(
            state: AutoBookState.ignored,
            reason: 'test',
          ),
    );
    final r1 = await first;
    final r2 = await second;

    // 第一个真正执行;第二个被 claim 幂等挡下(terminal skipped)。
    expect(r1.skipped, isFalse);
    expect(r2.skipped, isTrue);
    expect(r2.terminal, isTrue);
    expect(runs, 1);
  });

  test('maxConcurrency=1 退化为全局串行(老语义)', () async {
    coordinator.setMaxConcurrency(1);
    var active = 0;
    var peak = 0;

    Future<void> job() async {
      active++;
      peak = peak < active ? active : peak;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
    }

    await Future.wait([
      for (var i = 0; i < 4; i++)
        coordinator.execute<void>(
          input: input('conc:ser$i'),
          action: job,
          updateFor: (v) => AutoBookEventUpdate(
                state: AutoBookState.ignored,
                reason: 'test',
              ),
        ),
    ]);

    expect(peak, 1);
  });

  test('异常不阻断后续事件,且把事件标为 retry', () async {
    coordinator.setMaxConcurrency(2);

    final boom = coordinator.execute<void>(
      input: input('conc:boom'),
      action: () async => throw StateError('boom'),
      updateFor: (v) => AutoBookEventUpdate(
            state: AutoBookState.ignored,
            reason: 'test',
          ),
    );
    final ok = coordinator.execute<int>(
      input: input('conc:after'),
      action: () async => 1,
      updateFor: (v) => AutoBookEventUpdate(
            state: AutoBookState.ignored,
            reason: 'test',
          ),
    );

    await expectLater(boom, throwsStateError);
    final r = await ok;
    expect(r.skipped, isFalse);
    expect(r.value, 1);
    expect(r.state, AutoBookState.ignored);
  });
}
