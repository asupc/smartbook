import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/data/db.dart' as schema;
import 'package:smartbook/services/automation/automation_settings_store.dart';

schema.Ledger ledger({
  required int id,
  String? syncId,
  String name = '账本',
}) =>
    schema.Ledger(
      id: id,
      name: name,
      currency: 'CNY',
      type: 'personal',
      createdAt: DateTime.utc(2026, 1, 1),
      syncId: syncId,
      myRole: 'owner',
      memberCount: 1,
      isShared: false,
      monthStartDay: 1,
    );

AutoBookTarget target({
  required String kind,
  required String value,
  String scope = 'local',
  bool confirmed = true,
}) =>
    AutoBookTarget(
      scope: scope,
      kind: kind,
      value: value,
      confirmedAt: confirmed ? DateTime.utc(2026, 10, 10) : null,
    );

void main() {
  group('稳定引用', () {
    test('有 syncId 用 syncId,没有则用本地 id', () {
      expect(autoBookTargetRefFor(ledger(id: 3, syncId: 'abc')),
          'syncId:abc');
      expect(autoBookTargetRefFor(ledger(id: 3)), 'localId:3');
    });

    test('按引用解析:syncId/localId 各自命中', () {
      final ledgers = [ledger(id: 1, syncId: 'x1'), ledger(id: 2)];
      expect(resolveLedgerIdByRef('syncId:x1', ledgers), 1);
      expect(resolveLedgerIdByRef('localId:2', ledgers), 2);
      expect(resolveLedgerIdByRef('syncId:missing', ledgers), isNull);
      expect(resolveLedgerIdByRef('localId:99', ledgers), isNull);
      expect(resolveLedgerIdByRef('bogus:1', ledgers), isNull);
      expect(resolveLedgerIdByRef('', ledgers), isNull);
    });
  });

  group('作用域', () {
    test('user: 作用域必须与当前账号一致', () {
      expect(autoBookScopeMatches('user:a', 'user:a'), isTrue);
      expect(autoBookScopeMatches('user:a', 'user:b'), isFalse);
      expect(autoBookScopeMatches('user:a', 'local'), isFalse);
    });

    test('local 作用域对任何账号都有效(设备本地目标)', () {
      expect(autoBookScopeMatches('local', 'user:b'), isTrue);
      expect(autoBookScopeMatches('local', 'local'), isTrue);
    });
  });

  group('已确认目标', () {
    final ledgers = [ledger(id: 1, syncId: 's1'), ledger(id: 2)];

    test('syncId 目标解析成功', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'syncId', value: 's1')),
        ledgers: ledgers,
        legacyLedgerId: 2,
        currentScope: 'local',
      );
      expect(r.state, AutoBookTargetState.resolved);
      expect(r.ledgerId, 1);
      expect(r.targetRef, 'syncId:s1');
      expect(r.canWrite, isTrue);
    });

    test('账本被删 → invalid(target_ledger_missing),不回落第一个账本', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'syncId', value: 'gone')),
        ledgers: ledgers,
        legacyLedgerId: 1,
        currentScope: 'local',
      );
      expect(r.state, AutoBookTargetState.invalid);
      expect(r.reason, 'target_ledger_missing');
      expect(r.ledgerId, isNull);
      expect(r.canWrite, isFalse);
    });

    test('账号作用域不匹配 → invalid(target_scope_mismatch)', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(
            target: target(kind: 'localId', value: '1', scope: 'user:a')),
        ledgers: ledgers,
        legacyLedgerId: 2,
        currentScope: 'user:b',
      );
      expect(r.state, AutoBookTargetState.invalid);
      expect(r.reason, 'target_scope_mismatch');
      expect(r.canWrite, isFalse);
    });

    test('浏览账本与目标不同时,仍按目标解析(B2 核心)', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'localId', value: '2')),
        ledgers: ledgers,
        legacyLedgerId: 1, // 浏览账本 = 1
        currentScope: 'local',
      );
      expect(r.ledgerId, 2);
    });
  });

  group('捕获时冻结的快照优先(B0 §3.3)', () {
    final ledgers = [ledger(id: 1, syncId: 's1'), ledger(id: 2, syncId: 's2')];

    test('设置已改,冻结引用仍解析到原目标', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'syncId', value: 's2')),
        ledgers: ledgers,
        legacyLedgerId: 1,
        currentScope: 'local',
        frozenRef: 'syncId:s1',
        frozenState: 'resolved',
        frozenConfigVersion: 3,
      );
      expect(r.ledgerId, 1);
      expect(r.targetRef, 'syncId:s1');
      expect(r.configVersion, 3);
    });

    test('冻结为 undetermined → 等待确定,不回落设置/浏览账本', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'syncId', value: 's2')),
        ledgers: ledgers,
        legacyLedgerId: 1,
        currentScope: 'local',
        frozenRef: 'syncId:s1',
        frozenState: 'undetermined',
      );
      expect(r.state, AutoBookTargetState.undetermined);
      expect(r.ledgerId, isNull);
      expect(r.canWrite, isFalse);
    });

    test('冻结引用对应账本已删 → invalid,不回落', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(target: target(kind: 'syncId', value: 's2')),
        ledgers: ledgers,
        legacyLedgerId: 1,
        currentScope: 'local',
        frozenRef: 'syncId:gone',
        frozenState: 'resolved',
      );
      expect(r.state, AutoBookTargetState.invalid);
      expect(r.reason, 'target_ledger_missing');
      expect(r.ledgerId, isNull);
    });
  });

  group('首次升级迁移(B0 §3.4)', () {
    final ledgers = [ledger(id: 1, syncId: 's1'), ledger(id: 2)];

    test('无目标但有旧口径账本 → unconfirmed(保持兼容路径)', () {
      final r = resolveAutoBookTargetPure(
        settings: const AutomationSettings(),
        ledgers: ledgers,
        legacyLedgerId: 2,
        currentScope: 'local',
      );
      expect(r.state, AutoBookTargetState.unconfirmed);
      expect(r.ledgerId, 2, reason: '未确认前仍按旧口径(浏览账本)');
      expect(r.targetRef, 'localId:2');
      expect(r.canWrite, isTrue);
    });

    test('已迁移未确认 → 沿用旧口径账本,不擅自切到目标账本', () {
      final r = resolveAutoBookTargetPure(
        settings: AutomationSettings(
          target: AutoBookTarget(
            scope: 'local',
            kind: 'syncId',
            value: 's1',
            migratedFrom: 'legacy_current_ledger',
          ),
        ),
        ledgers: ledgers,
        legacyLedgerId: 2,
        currentScope: 'local',
      );
      expect(r.state, AutoBookTargetState.unconfirmed);
      expect(r.ledgerId, 2);
    });

    test('无目标且没有任何账本 → undetermined', () {
      final r = resolveAutoBookTargetPure(
        settings: const AutomationSettings(),
        ledgers: const [],
        legacyLedgerId: null,
        currentScope: 'local',
      );
      expect(r.state, AutoBookTargetState.undetermined);
      expect(r.canWrite, isFalse);
    });

    test('迁移目标的 confirmedAt 为空 → confirmed=false', () {
      final t = AutoBookTarget.fromJson({
        'scope': 'local',
        'kind': 'localId',
        'value': '2',
        'migratedFrom': 'legacy_current_ledger',
      });
      expect(t, isNotNull);
      expect(t!.confirmed, isFalse);
    });
  });
}
