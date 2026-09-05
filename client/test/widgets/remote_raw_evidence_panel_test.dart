import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/pages/data/remote_raw_evidence_panel.dart';
import 'package:smartbook/providers/sync_providers.dart';
import 'package:smartbook/services/privacy/raw_evidence_remote_store.dart';

class FakeRemote implements RawEvidenceRemoteStore {
  final offsets = <int>[];
  final deleted = <String>[];
  String? source;
  bool fail = false;
  int cleanups = 0;
  Completer<SmartBookCloudRawEvidence>? pendingDetail;
  SmartBookCloudRawEvidence row(String body) => SmartBookCloudRawEvidence(
      id: 'remote-1',
      eventKey: 'sms:key',
      source: 'sms',
      capturedAt: DateTime.utc(2026),
      body: body);
  @override
  Future<SmartBookCloudRawEvidenceList> list(
      {String? source, int offset = 0}) async {
    if (fail) throw StateError('secret HTTP input');
    this.source = source;
    offsets.add(offset);
    return SmartBookCloudRawEvidenceList(
        total: deleted.isEmpty && cleanups == 0 ? 31 : 0,
        items: deleted.isEmpty && cleanups == 0 ? [row('preview only')] : []);
  }

  @override
  Future<SmartBookCloudRawEvidence> get(String id) async =>
      pendingDetail?.future ??
      row('FULL original <script>not executable</script>');
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
  }

  @override
  Future<int> cleanup({String? source, DateTime? before}) async {
    this.source = source;
    cleanups++;
    return 31;
  }
}

Future<void> show(WidgetTester tester, FakeRemote? remote) async {
  await tester.pumpWidget(ProviderScope(
      overrides: [
        rawEvidenceRemoteStoreProvider.overrideWith((ref) async => remote)
      ],
      child: const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(child: RemoteRawEvidencePanel())))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'unconfigured cloud explains sign-in without reading any evidence',
      (tester) async {
    await show(tester, null);
    expect(find.text('Configure and sign in to SmartBook Cloud first.'),
        findsOneWidget);
  });
  testWidgets(
      'preview/detail pagination and confirmed deletion stay on remote channel',
      (tester) async {
    final remote = FakeRemote();
    await show(tester, remote);
    expect(find.textContaining('preview only'), findsOneWidget);
    expect(find.textContaining('FULL original'), findsNothing);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('FULL original'), findsOneWidget);
    await tester.ensureVisible(find.text('Delete server record'));
    await tester.tap(find.text('Delete server record'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(remote.deleted, isEmpty);
    await tester.tap(find.text('Delete server record'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm delete'));
    await tester.pumpAndSettle();
    expect(remote.deleted, ['remote-1']);
    expect(find.textContaining('FULL original'), findsNothing);
  });
  testWidgets('server pagination, source filter, and cleanup are explicit',
      (tester) async {
    final remote = FakeRemote();
    await show(tester, remote);
    await tester.ensureVisible(find.byTooltip('Next page'));
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(remote.offsets.last, 30);
    await tester.ensureVisible(find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMS').last);
    await tester.pumpAndSettle();
    expect(remote.source, 'sms');
    expect(remote.offsets.last, 0);
    await tester.tap(find.text('Clear server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm delete'));
    await tester.pumpAndSettle();
    expect(remote.cleanups, 1);
  });
  testWidgets('errors do not echo sensitive HTTP messages', (tester) async {
    await show(tester, FakeRemote()..fail = true);
    expect(find.textContaining('Request failed'), findsOneWidget);
    expect(find.textContaining('secret HTTP input'), findsNothing);
  });
  testWidgets('late detail cannot reappear after refresh', (tester) async {
    final remote = FakeRemote()
      ..pendingDetail = Completer<SmartBookCloudRawEvidence>();
    await show(tester, remote);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    await tester.tap(find.byTooltip('Refresh server'));
    await tester.pumpAndSettle();
    remote.pendingDetail!.complete(remote.row('STALE secret'));
    await tester.pumpAndSettle();
    expect(find.textContaining('STALE secret'), findsNothing);
  });
}
