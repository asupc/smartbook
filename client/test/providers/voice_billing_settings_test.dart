import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/providers/voice_billing_providers.dart';

/// #252：语音触发方式 + 静音阈值
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceTriggerModeCodec', () {
    test('往返一致', () {
      for (final mode in VoiceTriggerMode.values) {
        expect(
          VoiceTriggerModeCodec.fromStorage(mode.storageValue),
          mode,
        );
      }
    });

    test('未知/空值兜底 auto', () {
      expect(VoiceTriggerModeCodec.fromStorage(null), VoiceTriggerMode.auto);
      expect(VoiceTriggerModeCodec.fromStorage('???'), VoiceTriggerMode.auto);
    });
  });

  group('VoiceBillingSettings 默认值', () {
    test('默认自动检测 + 1500ms', () {
      const s = VoiceBillingSettings();
      expect(s.triggerMode, VoiceTriggerMode.auto);
      expect(s.silenceTimeoutMs, 1500);
    });
  });

  group('VoiceBillingSettingsNotifier', () {
    test('阈值越界自动夹取到合法区间并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(voiceBillingSettingsProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.setSilenceTimeoutMs(99999);
      expect(
        container.read(voiceBillingSettingsProvider).silenceTimeoutMs,
        VoiceBillingSettings.maxSilenceTimeoutMs,
      );

      await notifier.setSilenceTimeoutMs(10);
      expect(
        container.read(voiceBillingSettingsProvider).silenceTimeoutMs,
        VoiceBillingSettings.minSilenceTimeoutMs,
      );
    });

    test('设置触发方式后持久化，重建可读回', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(voiceBillingSettingsProvider.notifier);
      await notifier.ensureLoaded();
      await notifier.setTriggerMode(VoiceTriggerMode.holdToTalk);

      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final notifier2 = container2.read(voiceBillingSettingsProvider.notifier);
      await notifier2.ensureLoaded();
      expect(
        container2.read(voiceBillingSettingsProvider).triggerMode,
        VoiceTriggerMode.holdToTalk,
      );
    });
  });
}
