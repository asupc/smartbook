import 'dart:async';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/privacy/raw_evidence_policy.dart';
import 'package:smartbook/services/privacy/raw_evidence_sync_service.dart';

/// 原始证据落库/上传:永久保存语义 —— 调用方带了原文就落库,
/// 本地/服务端恒启用、无过期、默认进上传队列。
class _RecordingUploader implements RawEvidenceUploader {
  _RecordingUploader({this.fail = false});

  final bool fail;
  final List<RawEvidenceEnvelope> received = [];

  @override
  Future<RawEvidenceUploadResult> upload(RawEvidenceEnvelope evidence) async {
    received.add(evidence);
    if (fail) throw StateError('network down');
    return const RawEvidenceUploadResult.accepted(remoteId: 'remote-1');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late AutoBookEventStore eventStore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    eventStore = AutoBookEventStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  AutoBookInput input({
    required String key,
    required AutoBookSource source,
    DateTime? capturedAt,
  }) {
    return AutoBookInput(
      eventKey: key,
      source: source,
      capturedAt: capturedAt ?? DateTime.now().toUtc(),
      rawTitle: source == AutoBookSource.notification ? '支付通知' : null,
      rawText: '消费 20.00 元',
      rawActor: source == AutoBookSource.sms ? '95555' : 'com.example.pay',
      rawMetadata: const {'nativeId': 'n-1'},
    );
  }

  test('no raw content: event lifecycle works, upload not requested', () async {
    final event = await eventStore.ensure(AutoBookInput(
      eventKey: 'sms:empty',
      source: AutoBookSource.sms,
      capturedAt: DateTime.now().toUtc(),
    ));

    expect(event.rawText, isNull);
    expect(event.rawTitle, isNull);
    expect(event.rawActor, isNull);
    expect(event.rawMetadataJson, isNull);
    expect(event.rawEvidenceLocalEnabled, isFalse);
    expect(event.rawEvidenceServerEnabled, isFalse);
    expect(
        event.rawEvidenceUploadState, RawEvidenceUploadState.notRequested);
    expect(await db.select(db.localChanges).get(), isEmpty,
        reason: 'raw evidence must not enter sync_changes/local_changes');
  });

  test(
      'raw content is stored permanently: local+server enabled, no expiry, queued for upload',
      () async {
    final capturedAt = DateTime.now().toUtc().subtract(const Duration(days: 1));

    final event = await eventStore.ensure(
      input(
        key: 'sms:local',
        source: AutoBookSource.sms,
        capturedAt: capturedAt,
      ),
    );

    expect(event.rawText, '消费 20.00 元');
    expect(event.rawActor, '95555');
    expect(event.rawMetadataJson, contains('nativeId'));
    expect(event.rawEvidenceLocalEnabled, isTrue);
    expect(event.rawEvidenceServerEnabled, isTrue);
    expect(event.rawEvidenceLocalExpiresAt, isNull);
    expect(event.rawEvidenceServerExpiresAt, isNull);
    expect(event.rawEvidenceRetentionUntil, isNull);
    expect(event.rawEvidenceUploadState, RawEvidenceUploadState.pending);
  });

  test('successful upload marks uploaded and retains local body', () async {
    final event = await eventStore.ensure(
      input(
        key: 'notification:server',
        source: AutoBookSource.notification,
      ),
    );
    final uploader = _RecordingUploader();
    final sync = RawEvidenceSyncService(eventStore, uploader: uploader);

    expect(event.rawEvidenceLocalEnabled, isTrue);
    expect(event.rawEvidenceServerEnabled, isTrue);
    expect(event.rawEvidenceUploadState, RawEvidenceUploadState.pending);
    expect(await sync.uploadPending(), 1);

    final uploaded = await eventStore.findById(event.id);
    expect(uploader.received.single.eventKey, 'notification:server');
    expect(uploader.received.single.rawTitle, '支付通知');
    expect(uploader.received.single.toJson(),
        containsPair('event_key', 'notification:server'));
    expect(
        uploader.received.single.toJson(), containsPair('body', '消费 20.00 元'));
    expect(uploader.received.single.toJson(), isNot(contains('expires_at')),
        reason: '永久保存:上传信封不再带 expires_at');
    expect(uploaded!.rawEvidenceUploadedAt, isNotNull);
    expect(uploaded.rawEvidenceUploadAttempts, 1);
    expect(uploaded.rawEvidenceUploadState, RawEvidenceUploadState.uploaded);
    expect(uploaded.rawText, '消费 20.00 元',
        reason: '永久保留:上传成功后本地原文不再清理');
  });

  test('query/count/clear can be scoped by source without deleting event rows',
      () async {
    final sms = await eventStore.ensure(
      input(key: 'sms:clear', source: AutoBookSource.sms),
    );
    await eventStore.ensure(
      input(key: 'screen:keep', source: AutoBookSource.screenText),
    );

    expect(await eventStore.countRawEvidence(), 2);
    expect(
      await eventStore.listRawEvidence(source: AutoBookSource.sms.value),
      hasLength(1),
    );
    expect(
        await eventStore.clearRawEvidence(source: AutoBookSource.sms.value), 1);
    expect(await eventStore.countRawEvidence(), 1);
    expect(await eventStore.findById(sms.id), isNotNull,
        reason: 'clearing raw content must keep bookkeeping history');
    expect((await eventStore.findById(sms.id))!.rawText, isNull);

    await eventStore.ensure(
      input(key: 'sms:clear', source: AutoBookSource.sms),
    );
    final replayed = await eventStore.findById(sms.id);
    expect(replayed!.rawText, isNull,
        reason: 'a duplicate native replay must not undo a manual clear');
    expect(replayed.rawEvidenceUploadState, RawEvidenceUploadState.cleared);
  });

  test('failed upload remains retryable and records an attempt without raw log',
      () async {
    final event = await eventStore.ensure(
      input(key: 'sms:retry', source: AutoBookSource.sms),
    );
    final sync = RawEvidenceSyncService(
      eventStore,
      uploader: _RecordingUploader(fail: true),
    );

    expect(await sync.uploadPending(), 0);
    final failed = await eventStore.findById(event.id);
    expect(failed!.rawEvidenceUploadState, RawEvidenceUploadState.retry);
    expect(failed.rawEvidenceUploadAttempts, 1);
    expect(failed.rawEvidenceLastError, 'upload_failed');
    expect(failed.rawText, isNotNull);
  });

  test(
      'cold queue waits for login; syncPending uploads once uploader is set',
      () async {
    final event = await eventStore
        .ensure(input(key: 'sms:login', source: AutoBookSource.sms));
    final sync = RawEvidenceSyncService(eventStore);
    await sync.syncPending();
    expect((await eventStore.findById(event.id))!.rawText, isNotNull);
    final uploader = _RecordingUploader();
    sync.uploader = uploader;
    await sync.syncPending();
    expect(uploader.received, hasLength(1));
    // 永久保留:上传成功后本地原文仍保留(旧语义 server-only 会清掉)。
    expect((await eventStore.findById(event.id))!.rawText, isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test(
      'failed backoff persists across service recreation and does not change bookkeeping lease',
      () async {
    final event = await eventStore
        .ensure(input(key: 'sms:backoff', source: AutoBookSource.sms));
    await RawEvidenceSyncService(eventStore,
            uploader: _RecordingUploader(fail: true))
        .syncPending();
    final failed = (await eventStore.findById(event.id))!;
    expect(failed.rawEvidenceNextRetryAt!.isAfter(DateTime.now()), isTrue);
    expect(failed.updatedAt, event.updatedAt);
    expect(failed.rawEvidenceLastError, 'upload_failed');
    final uploader = _RecordingUploader();
    final restarted = RawEvidenceSyncService(eventStore, uploader: uploader);
    await restarted.syncPending();
    expect(uploader.received, isEmpty);
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
        .write(AutoBookEventsCompanion(
            rawEvidenceNextRetryAt:
                d.Value(DateTime.now().subtract(const Duration(seconds: 1)))));
    await restarted.syncPending();
    expect(uploader.received, hasLength(1));
    final uploaded = (await eventStore.findById(event.id))!;
    expect(uploaded.rawEvidenceNextRetryAt, isNull);
    expect(uploaded.rawEvidenceUploadAttempts, 2);
    expect(uploaded.updatedAt, event.updatedAt);
  });

  test('interrupted upload lease expires and retries with the same event key',
      () async {
    final event = await eventStore
        .ensure(input(key: 'sms:interrupted', source: AutoBookSource.sms));
    await eventStore.markRawEvidenceUploading(event.id);
    final uploader = _RecordingUploader();
    final restarted = RawEvidenceSyncService(eventStore, uploader: uploader);
    await restarted.syncPending();
    expect(uploader.received, isEmpty);
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
        .write(AutoBookEventsCompanion(
            rawEvidenceNextRetryAt:
                d.Value(DateTime.now().subtract(const Duration(seconds: 1)))));
    await restarted.syncPending();
    expect(uploader.received.single.eventKey, event.eventKey);
  });

  test('concurrent recovery triggers coalesce and manual clear is never undone',
      () async {
    final event = await eventStore
        .ensure(input(key: 'sms:concurrent', source: AutoBookSource.sms));
    final started = Completer<void>(), finish = Completer<void>();
    var calls = 0;
    final uploader = _CallbackUploader((_) async {
      calls++;
      started.complete();
      await finish.future;
      return const RawEvidenceUploadResult.accepted();
    });
    final sync = RawEvidenceSyncService(eventStore, uploader: uploader);
    final first = sync.syncPending();
    await started.future;
    final second = sync.syncPending();
    await eventStore.clearRawEvidence();
    finish.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
    final cleared = (await eventStore.findById(event.id))!;
    expect(cleared.rawEvidenceUploadState, RawEvidenceUploadState.cleared);
    expect(cleared.rawText, isNull);
  });

  test('invalid payload rejection is terminal and does not starve other events',
      () async {
    final rejected = await eventStore
        .ensure(input(key: 'sms:rejected', source: AutoBookSource.sms));
    final uploader = _CallbackUploader(
        (_) async => const RawEvidenceUploadResult.rejected());
    await RawEvidenceSyncService(eventStore, uploader: uploader).syncPending();
    expect((await eventStore.findById(rejected.id))!.rawEvidenceUploadState,
        RawEvidenceUploadState.rejected);
    await eventStore
        .ensure(input(key: 'sms:other', source: AutoBookSource.sms));
    final recording = _RecordingUploader();
    await RawEvidenceSyncService(eventStore, uploader: recording)
        .syncPending(limit: 1);
    expect(recording.received.single.eventKey, 'sms:other');
  });
}

class _CallbackUploader implements RawEvidenceUploader {
  final Future<RawEvidenceUploadResult> Function(RawEvidenceEnvelope) callback;
  _CallbackUploader(this.callback);
  @override
  Future<RawEvidenceUploadResult> upload(RawEvidenceEnvelope evidence) =>
      callback(evidence);
}
