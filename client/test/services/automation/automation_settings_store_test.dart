import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/services/automation/automation_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AutomationSettingsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AutomationSettingsStore();
  });

  group('配置 JSON 与版本', () {
    test('空存储 → 默认配置,开通未完成', () async {
      final settings = await store.load();
      expect(settings.schemaVersion, AutomationSettings.currentSchemaVersion);
      expect(settings.configVersion, 0);
      expect(settings.target, isNull);
      expect(settings.setup.completed, isFalse);
      expect(await store.isSetupCompleted(), isFalse);
    });

    test('保存后可读回,target/setup 都保留', () async {
      final target = AutoBookTarget(
        scope: 'local',
        kind: 'syncId',
        value: 'abc-123',
        accountId: 7,
        confirmedAt: DateTime.utc(2026, 10, 10),
      );
      final setup = const AutoBookSetupProgress(
        serviceChecked: true,
        targetChosen: true,
        sources: {'notify'},
        backgroundChecked: true,
      ).copyWith(verifiedAt: DateTime.utc(2026, 10, 10, 8));

      await store.save(AutomationSettings(target: target, setup: setup));
      final back = await store.load();

      expect(back.target?.kind, 'syncId');
      expect(back.target?.value, 'abc-123');
      expect(back.target?.accountId, 7);
      expect(back.target?.confirmed, isTrue);
      expect(back.setup.completed, isTrue);
      expect(await store.isSetupCompleted(), isTrue);
    });

    test('bumpVersion 单调递增,不丢其它字段', () async {
      await store.save(AutomationSettings(
        target: AutoBookTarget(scope: 'local', kind: 'localId', value: '3'),
      ));
      final v1 = await store.bumpVersion(await store.load());
      final v2 = await store.bumpVersion(v1);
      expect(v2.configVersion, 2);
      expect(v2.target?.value, '3');
    });

    test('读到更高 schemaVersion 不降级覆盖(B0 §3.1)', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AutomationSettingsStore.prefsKey,
        '{"schemaVersion":99,"configVersion":5,"setup":{}}',
      );
      final settings = await store.load();
      expect(settings.schemaVersion, 99);
      expect(settings.configVersion, 5);
    });

    test('损坏的 JSON → 默认配置,不抛异常', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AutomationSettingsStore.prefsKey, 'not json');
      final settings = await store.load();
      expect(settings.schemaVersion, AutomationSettings.currentSchemaVersion);
    });
  });

  group('目标标识口径(B0 §3.2)', () {
    test('scope 缺失或 value 为空 → 视为无效,不产生目标', () {
      expect(
        AutoBookTarget.fromJson(
            {'kind': 'syncId', 'value': '', 'scope': 'local'}),
        isNull,
      );
      expect(
        AutoBookTarget.fromJson({'kind': 'syncId', 'value': 'x', 'scope': ''}),
        isNull,
      );
      expect(
        AutoBookTarget.fromJson({'kind': 'syncId', 'value': 'x'}),
        isNull,
      );
    });

    test('未确认的迁移目标 confirmed=false', () {
      final t = AutoBookTarget.fromJson({
        'scope': 'local',
        'kind': 'localId',
        'value': '4',
        'migratedFrom': 'legacy_current_ledger',
      });
      expect(t, isNotNull);
      expect(t!.confirmed, isFalse);
      expect(t.migratedFrom, 'legacy_current_ledger');
    });
  });

  group('开通进度', () {
    test('步骤未完成时 nextStepIndex 指向第一个缺口', () {
      var p = const AutoBookSetupProgress();
      expect(p.nextStepIndex, 0);
      p = p.copyWith(serviceChecked: true);
      expect(p.nextStepIndex, 1);
      p = p.copyWith(targetChosen: true);
      expect(p.nextStepIndex, 2);
      p = p.copyWith(sources: {'sms'});
      expect(p.nextStepIndex, 3);
      p = p.copyWith(backgroundChecked: true);
      expect(p.nextStepIndex, 4);
      expect(p.completed, isFalse, reason: '未验证也不算完成');
    });

    test('真实验证或显式跳过都能完成', () {
      final base = const AutoBookSetupProgress(
        serviceChecked: true,
        targetChosen: true,
        sources: {'notify'},
        backgroundChecked: true,
      );
      expect(base.completed, isFalse);
      expect(
        base.copyWith(verifiedAt: DateTime.utc(2026, 10, 10)).completed,
        isTrue,
      );
      expect(base.copyWith(verifySkipped: true).completed, isTrue);
    });

    test('没有来源不算完成(至少一个来源)', () {
      final p = const AutoBookSetupProgress(
        serviceChecked: true,
        targetChosen: true,
        backgroundChecked: true,
      ).copyWith(verifiedAt: DateTime.utc(2026, 10, 10));
      expect(p.completed, isFalse);
    });

    test('updateSetup 读改写一致', () async {
      await store.updateSetup((p) => p.copyWith(serviceChecked: true));
      final p = await store.setupProgress();
      expect(p.serviceChecked, isTrue);
      expect(p.targetChosen, isFalse);
    });

    test('进度 JSON 往返', () {
      const p = AutoBookSetupProgress(
        serviceChecked: true,
        targetChosen: true,
        sources: {'notify', 'sms'},
        backgroundChecked: true,
        verifySkipped: true,
      );
      final back = AutoBookSetupProgress.fromJson(p.toJson());
      expect(back.serviceChecked, isTrue);
      expect(back.sources, {'notify', 'sms'});
      expect(back.verifySkipped, isTrue);
      expect(back.completed, isTrue);
    });
  });
}
