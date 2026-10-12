// 对抗性测试:AutoBookCoordinator 的并发闸门(lead 亲自)。
//
// 攻击点:
// 1. 有界并发池:并发上限内不得超额执行;上限放宽/收紧时的在飞任务不炸;
// 2. 同 eventKey 串行:并发提交同一 key 时 action 只执行一次(幂等 claim),
//    且第二个调用方拿到 skipped 而非阻塞挂死;
// 3. 跨 key 并行:不同 key 不被彼此阻塞(吞吐语义);
// 4. 异常路径:action 抛异常时事件落 retry,completer 以错误完成但同 key
//    后续任务不被毒化(尾链吞异常);
// 5. dispose 后的行为确定性。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late AutoBookCoordinator coordinator;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    coordinator = AutoBookCoordinator(db);
    // 显式设上限,避免 initialize() 按 AI 配置覆盖(测试环境无 provider)。
    coordinator.setMaxConcurrency(2);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      );

  const booked = AutoBookEventUpdate(state: AutoBookState.booked);

  group('有界并发池', () {
    test('并发上限内允许并行,超过上限的任务排队(不丢、不超额)', () async {
      var running = 0;
      var peak = 0;
      final gate = Completer<void>();

      final futures = <Future<void>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(coordinator
            .execute<int>(
              input: input('k-$i'),
              action: () async {
                running++;
                peak = peak > running ? peak : running;
                await gate.future;
                running--;
                return 1;
              },
              updateFor: (_) => booked,
            )
            .then((_) {}));
      }

      // 让调度推进:上限 2,应只有 2 个任务进入 action
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(running, 2, reason: '上限 2 时只允许 2 个任务在飞');
      expect(peak, lessThanOrEqualTo(2));

      gate.complete();
      await Future.wait(futures);
      expect(peak, lessThanOrEqualTo(2), reason: '全程峰值不得超过上限');
    });

    test('上限放宽后等待者被唤醒(休眠期排队任务不饿死)', () async {
      final started = <int>[];
      final gate = Completer<void>();
      final futures = <Future<void>>[];
      for (var i = 0; i < 4; i++) {
        final idx = i;
        futures.add(coordinator
            .execute<int>(
              input: input('widen-$idx'),
              action: () async {
                started.add(idx);
                if (!gate.isCompleted) gate.complete(); // 首个进 action 的任务放行
                await Future<void>.delayed(const Duration(milliseconds: 20));
                return idx;
              },
              updateFor: (_) => booked,
            )
            .then((_) {}));
      }
      await gate.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final before = started.length;
      coordinator.setMaxConcurrency(8);
      await Future.wait(futures);
      expect(started.length, 4, reason: '全部任务最终都应执行');
      expect(started.length, greaterThanOrEqualTo(before));
    });

    test('上限收紧不打断在飞任务,完成后再按新上限放行', () async {
      final gate = Completer<void>();
      final done = <String>[];
      Future<void> run(String k) => coordinator
          .execute<int>(
            input: input(k),
            action: () async {
              await gate.future;
              done.add(k);
              return 1;
            },
            updateFor: (_) => booked,
          )
          .then((_) {});

      final f1 = run('tight-a');
      final f2 = run('tight-b');
      final f3 = run('tight-c'); // 排队
      await Future<void>.delayed(const Duration(milliseconds: 20));

      coordinator.setMaxConcurrency(1); // 收紧到 1
      gate.complete();
      await Future.wait([f1, f2, f3]);
      expect(done.length, 3, reason: '收紧上限不得导致任务丢失');
    });
  });

  group('同 eventKey 串行与幂等', () {
    test('并发提交同一 key:action 只执行一次,后来者 skipped', () async {
      var calls = 0;
      final gate = Completer<void>();

      Future<AutoBookExecution<int>> run() => coordinator.execute<int>(
            input: input('same-key'),
            action: () async {
              calls++;
              await gate.future;
              return 42;
            },
            updateFor: (_) => const AutoBookEventUpdate(
              state: AutoBookState.booked,
              transactionId: 7,
            ),
          );

      final first = run();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final second = run(); // 串行链上排第一的后面
      gate.complete();

      final r1 = await first;
      final r2 = await second;

      expect(calls, 1, reason: '同一 eventKey 的 action 绝不能双执行(会双记账)');
      expect(r1.skipped, isFalse);
      expect(r1.value, 42);
      expect(r2.skipped, isTrue, reason: '第二个调用方应拿到幂等 skip');
      expect(r2.existingTransactionId, 7,
          reason: 'skip 时应把已关联交易 id 透出给调用方');
    });

    test('同 key 串行链:前一个失败不毒化后一个(失败 key 可重试)', () async {
      var calls = 0;
      // 第一次失败
      await expectLater(
        coordinator.execute<int>(
          input: input('retry-key'),
          action: () async {
            calls++;
            throw StateError('boom');
          },
          updateFor: (_) => booked,
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);

      // 第二次(同一 key)应能继续执行;但事件已被标记 retry,
      // nextRetryAt 未到 → claim 拒绝 → skipped。这是设计语义。
      final second = await coordinator.execute<int>(
        input: input('retry-key'),
        action: () async {
          calls++;
          return 9;
        },
        updateFor: (_) => booked,
      );
      expect(calls, 1, reason: 'retry 闸门未到期的同 key 事件不得重跑 action');
      expect(second.skipped, isTrue);
      expect(second.state, AutoBookState.retry);

      // 事件确实落在 retry,且 lastError 已记录
      final row = await AutoBookEventStore(db).findByEventKey('retry-key');
      expect(row!.state, 'retry');
      expect(row.lastError, isNotNull);
    });

    test('resetRetryGate 后同 key 可被真正重跑', () async {
      await expectLater(
        coordinator.execute<int>(
          input: input('gate-key'),
          action: () async => throw StateError('first'),
          updateFor: (_) => booked,
        ),
        throwsA(isA<StateError>()),
      );
      final store = AutoBookEventStore(db);
      final row = await store.findByEventKey('gate-key');
      await store.resetRetryGate(row!.id);

      var calls = 0;
      final retry = await coordinator.execute<int>(
        input: input('gate-key'),
        action: () async {
          calls++;
          return 5;
        },
        updateFor: (_) => booked,
      );
      expect(calls, 1);
      expect(retry.skipped, isFalse);
      expect(retry.value, 5);
    });
  });

  group('跨 key 并行', () {
    test('不同 key 的任务并行执行(不被单链阻塞)', () async {
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      var aStarted = false;
      var bStarted = false;

      final fa = coordinator
          .execute<int>(
            input: input('par-a'),
            action: () async {
              aStarted = true;
              await gateA.future;
              return 1;
            },
            updateFor: (_) => booked,
          )
          .then((_) {});
      final fb = coordinator
          .execute<int>(
            input: input('par-b'),
            action: () async {
              bStarted = true;
              await gateB.future;
              return 2;
            },
            updateFor: (_) => booked,
          )
          .then((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aStarted, isTrue);
      expect(bStarted, isTrue, reason: '不同 key 不应互相串行阻塞');

      gateA.complete();
      gateB.complete();
      await Future.wait([fa, fb]);
    });
  });

  group('异常与终态映射', () {
    test('业务 retryable(update.state=retry 且 nextRetryAt 为空)走退避阶梯', () async {
      final result = await coordinator.execute<int>(
        input: input('retryable'),
        action: () async => 1,
        updateFor: (_) => const AutoBookEventUpdate(
          state: AutoBookState.retry,
          reason: 'transient',
        ),
      );
      // 回读真实状态:首次退避未耗尽 → retry
      expect(result.state, AutoBookState.retry);
      final row = await AutoBookEventStore(db).findByEventKey('retryable');
      expect(row!.nextRetryAt, isNotNull,
          reason: 'retry 必须写退避闸门,否则会形成忙循环');
      expect(row.attemptCount, 1);
    });

    test('终态映射:booked 带 transactionId 透出给调用方', () async {
      final result = await coordinator.execute<int>(
        input: input('booked-one'),
        action: () async => 11,
        updateFor: (v) => AutoBookEventUpdate(
          state: AutoBookState.booked,
          transactionId: v * 10,
        ),
      );
      expect(result.skipped, isFalse);
      expect(result.state, AutoBookState.booked);
      expect(result.existingTransactionId, 110);
      expect(result.eventId, greaterThan(0));
    });

    test('dispose 后新任务以 StateError 失败,不静默吞掉', () async {
      coordinator.dispose();
      await expectLater(
        coordinator.execute<int>(
          input: input('after-dispose'),
          action: () async => 1,
          updateFor: (_) => booked,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('事件键构造器', () {
    test('textEventKey 对规范化后等价的文本产出同一键(空白/全角差异)', () {
      final a = AutoBookCoordinator.textEventKey('sms', '消费 20.00 元');
      final b = AutoBookCoordinator.textEventKey('sms', '消费  20.00  元');
      expect(a, b, reason: 'normalizeAutoBookText 应折叠空白差异');
    });

    test('不同 source 的同文本键不同', () {
      final a = AutoBookCoordinator.textEventKey('sms', '消费 20 元');
      final b = AutoBookCoordinator.textEventKey('screen', '消费 20 元');
      expect(a, isNot(b));
    });

    test('deepLinkEventKey 优先 idempotencyKey,空白回落到 url', () {
      final byKey = AutoBookCoordinator.deepLinkEventKey('idem-1', 'https://x/y');
      final byKeyWhitespace =
          AutoBookCoordinator.deepLinkEventKey('   ', 'https://x/y');
      final byUrl = AutoBookCoordinator.deepLinkEventKey(null, 'https://x/y');
      expect(byKey, isNot(byUrl));
      expect(byKeyWhitespace, byUrl,
          reason: '空白 idempotencyKey 视同缺失,回落 url 键');
    });

    test('deepLinkEventKey 确定性(同输入同输出)', () {
      expect(
        AutoBookCoordinator.deepLinkEventKey('k', 'u'),
        AutoBookCoordinator.deepLinkEventKey('k', 'u'),
      );
    });

    test('imageEventKey 对不存在文件路径回落稳定的 path 键', () async {
      final k1 = await coordinator.imageEventKey('/no/such/file-xyz.png');
      final k2 = await coordinator.imageEventKey('/no/such/file-xyz.png');
      expect(k1, k2, reason: '同路径应产出确定性键(即使文件不存在)');
      expect(k1, startsWith('image:path:v1:'));
    });
  });
}
