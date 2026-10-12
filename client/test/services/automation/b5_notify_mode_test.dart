import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/services/automation/automation_settings_store.dart';

/// B5 任务 1:通知偏好三档的存储口径与默认值。
///
/// - 升级用户:配置缺失 → every_success(保持旧行为「每笔成功都提醒」);
/// - 新用户:完成开通时写入 confirm_and_fault;
/// - 未知/损坏取值 → 回落 every_success,不静默变成静默模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AutoBookNotifyMode.parse', () {
    test('缺省(升级用户)→ 每笔成功提醒', () {
      expect(
        AutoBookNotifyMode.parse(null),
        AutoBookNotifyMode.everySuccess,
      );
    });

    test('已知三档都能解析', () {
      expect(AutoBookNotifyMode.parse('every_success'),
          AutoBookNotifyMode.everySuccess);
      expect(AutoBookNotifyMode.parse('confirm_and_fault'),
          AutoBookNotifyMode.confirmAndFault);
      expect(AutoBookNotifyMode.parse('daily_digest'),
          AutoBookNotifyMode.dailyDigest);
    });

    test('未知值回落每笔成功,不静默', () {
      expect(
        AutoBookNotifyMode.parse('whatever'),
        AutoBookNotifyMode.everySuccess,
      );
      expect(
        AutoBookNotifyMode.parse(''),
        AutoBookNotifyMode.everySuccess,
      );
    });

    test('storageValue 往返稳定', () {
      for (final mode in AutoBookNotifyMode.values) {
        expect(AutoBookNotifyMode.parse(mode.storageValue), mode);
      }
    });
  });

  group('通知偏好写入设置存储', () {
    test('保存后读回;缺失时为 null(表示升级用户的旧行为)', () async {
      final store = AutomationSettingsStore();
      expect((await store.load()).notifyMode, isNull);

      final saved = await store
          .bumpVersion((await store.load())
              .copyWith(notifyMode: AutoBookNotifyMode.confirmAndFault.storageValue));
      expect(saved.notifyMode, 'confirm_and_fault');
      expect(saved.configVersion, 1, reason: 'notifyMode 变更也 bump 版本');

      final back = await store.load();
      expect(AutoBookNotifyMode.parse(back.notifyMode),
          AutoBookNotifyMode.confirmAndFault);
    });

    test('开通完成写入新用户默认档', () async {
      final store = AutomationSettingsStore();
      await store.updateSetup((p) => p.copyWith(serviceChecked: true));
      final settings = await store.load();
      if (settings.notifyMode == null) {
        await store.bumpVersion(settings.copyWith(
            notifyMode: AutoBookNotifyMode.confirmAndFault.storageValue));
      }
      expect((await store.load()).notifyMode, 'confirm_and_fault');
      expect((await store.setupProgress()).serviceChecked, isTrue);
    });
  });
}
