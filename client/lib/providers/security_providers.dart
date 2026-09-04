import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/security/app_lock_service.dart';

// 应用是否处于锁定状态
final isAppLockedProvider = StateProvider<bool>((ref) => false);

// 隐私模糊屏是否显示（多任务切换时）
final showPrivacyScreenProvider = StateProvider<bool>((ref) => false);

// 应用锁是否启用
final appLockEnabledProvider = StateProvider<bool>((ref) => false);

// 生物识别是否启用
final appLockBiometricEnabledProvider = StateProvider<bool>((ref) => false);

// 超时时间（秒）：0=立即, 60=1分钟, 300=5分钟, 900=15分钟
final appLockTimeoutProvider = StateProvider<int>((ref) => 0);

// 初始化安全相关 Provider（在 splash 阶段调用）
final securityInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();

  // 读取应用锁状态
  final enabled = prefs.getBool('app_lock_enabled') ?? false;
  final biometric = prefs.getBool('app_lock_biometric_enabled') ?? false;
  final timeout = prefs.getInt('app_lock_timeout_seconds') ?? 0;

  ref.read(appLockEnabledProvider.notifier).state = enabled;
  ref.read(appLockBiometricEnabledProvider.notifier).state = biometric;
  ref.read(appLockTimeoutProvider.notifier).state = timeout;

  // 安全检查：锁已启用但无 PIN，自动禁用
  if (enabled && !(await AppLockService.hasPin())) {
    ref.read(appLockEnabledProvider.notifier).state = false;
    await prefs.setBool('app_lock_enabled', false);
    return;
  }

  // 启动时如果锁启用，设置为锁定状态
  if (enabled) {
    ref.read(isAppLockedProvider.notifier).state = true;
  }

  // 监听 Provider 变化并持久化
  ref.listen<bool>(appLockEnabledProvider, (prev, next) async {
    await prefs.setBool('app_lock_enabled', next);
  });
  ref.listen<bool>(appLockBiometricEnabledProvider, (prev, next) async {
    await prefs.setBool('app_lock_biometric_enabled', next);
  });
  ref.listen<int>(appLockTimeoutProvider, (prev, next) async {
    await prefs.setInt('app_lock_timeout_seconds', next);
  });
});
