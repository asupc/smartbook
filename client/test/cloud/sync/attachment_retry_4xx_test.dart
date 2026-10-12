/// 低-3(2026-10-11 三轮复查)回归:附件 retry 对终态 4xx 不再盲目重试。
///
/// 旧行为:sync_engine_attachments.dart 手写 3-attempt 循环不检查
/// `CloudStorageException.statusCode` → 400/404/409 重放 3 次(重放同样的
/// 请求永远同结果,白白 2 次退避 + 3 倍服务端 load);
/// RetryHelper 的 4xx 短路(408/429 瞬态除外)此前是零调用点死代码。
///
/// 修复:三个 retry 循环(upload/download/custom-icon)统一接 RetryHelper;
/// vendor 37 处 raise 补 `statusCode:`;`_httpCodeInMessage` 拓宽匹配裸
/// `(NNN)` 括号形态(消息兜底)。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
import 'package:smartbook/cloud/sync/sync_engine.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';

import '_fakes/fake_smartbook_cloud_provider.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
  @override
  Future<String?> getTemporaryPath() async => './tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late FakeSmartBookCloudProvider provider;
  late SyncEngine engine;
  late int ledgerId;
  late int txId;

  setUp(() async {
    PathProviderPlatform.instance = _FakePathProvider();
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    final changeTracker = ChangeTracker(db);
    final repo = LocalRepository(db, changeTracker: changeTracker);
    provider = FakeSmartBookCloudProvider();
    engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: changeTracker,
      repo: repo,
    );
    ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const Value('L1')),
        );
    txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 1.0,
          ),
        );
  });

  tearDown(() async {
    provider.reset();
    await db.close();
  });

  group('exceptions: (NNN) 消息兜底 + isClientError', () {
    test('消息内裸 (404) 括号 → statusCode 解析命中', () {
      final e = CloudStorageException('Attachment download failed (404): gone');
      expect(e.statusCode, 404,
          reason: '低-3(c):消息兜底正则此前只认 "HTTP 404" 形态');
      expect(e.isClientError, isTrue);
    });

    test('HTTP 404 显式形态仍命中(既有行为回归保护)', () {
      final e = CloudStorageException('failed HTTP 404');
      expect(e.statusCode, 404);
      expect(e.isClientError, isTrue);
    });

    test('408 / 429 是瞬态 → isClientError=false(RetryHelper 会重试)', () {
      expect(CloudStorageException('x', null, 408).isClientError, isFalse);
      expect(CloudStorageException('x', null, 429).isClientError, isFalse);
    });

    test('5xx 不算 client error(可重试)', () {
      expect(CloudStorageException('x', null, 503).isClientError, isFalse);
    });

    test('非状态码括号数字不被误伤(200-599 域外)', () {
      final e = CloudStorageException('file (12345) bytes');
      expect(e.statusCode, isNull,
          reason: '五位数字不是 HTTP 状态码,不误判');
    });

    test('RetryHelper:CloudStorageException(404) 立即 rethrow 不重试', () async {
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            throw CloudStorageException('Attachment download failed '
                '(404): gone', null, 404);
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(calls, 1, reason: '终态 4xx 单次尝试即放弃');
    });

    test('RetryHelper:CloudStorageException(429) 保持重试', () async {
      var calls = 0;
      await expectLater(
        RetryHelper.execute(
          () async {
            calls++;
            if (calls < 3) {
              throw CloudStorageException('limited', null, 429);
            }
            return 'ok';
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
        completion('ok'),
      );
      expect(calls, 3, reason: '429 瞬态,重试到成功');
    });
  });

  group('附件下载 retry 行为', () {
    test('4xx(statusCode 显式)→ 只 1 次尝试,不重试', () async {
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: 'a.jpg',
              cloudFileId: const Value('gone-404'),
            ),
          );
      var calls = 0;
      provider.downloadAttachmentErrorInjector = () {
        calls++;
        return CloudStorageException(
            'Attachment download failed (404): gone', null, 404);
      };

      await engine.downloadAttachments(ledgerId: ledgerId);

      expect(calls, 1,
          reason: '低-3(a):终态 4xx 不再 3 连击(旧行为 attempts=3)');
    });

    test('4xx(仅消息含 (409),statusCode 未知)→ 同样只 1 次(兜底解析)', () async {
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: 'b.jpg',
              cloudFileId: const Value('conflict-409'),
            ),
          );
      var calls = 0;
      provider.downloadAttachmentErrorInjector = () {
        calls++;
        // 模拟未 plumb statusCode 的老 raise 形态:消息带 (409)。
        return CloudStorageException(
            'Attachment download failed (409): conflict');
      };

      await engine.downloadAttachments(ledgerId: ledgerId);

      expect(calls, 1,
          reason: '低-3(c):消息兜底正则命中 (409) → isClientError 短路');
    });

    test('瞬态失败(网络异常)→ 重试满 3 次', () async {
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: 'c.jpg',
              cloudFileId: const Value('flaky'),
            ),
          );
      var calls = 0;
      provider.downloadAttachmentErrorInjector = () {
        calls++;
        // 非 HTTP 异常(如 socket 失败被包成普通 storage 异常)→ 可重试。
        return CloudStorageException('SocketException: connection reset');
      };

      await engine.downloadAttachments(ledgerId: ledgerId);

      expect(calls, 3, reason: '瞬态错误保持 3-attempt 语义(旧行为不变)');
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
