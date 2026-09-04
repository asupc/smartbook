import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用模式枚举
///
/// 历史上还有过一个 `cloud`(仅云端模式)值,数据完全存 Supabase。
/// 但 SmartBook Cloud 上线后,所有云同步统一走「LocalRepository + ChangeTracker
/// + 推送到 SmartBook Cloud」 — 离线优先 + 多设备实时秒同步,跟「数据存远端」
/// 完全是两条范式,cloud-only 没有用户入口,清理时已删。
///
/// 保留 enum 而非改 bool 是为了:
/// 1) SharedPreferences 旧数据 `app_mode=cloud` 能 fallback 到 local,不崩
/// 2) 未来如果又出现"另一种模式"(比如 demo / readonly),不用再改类型
enum AppMode {
  local('本地优先模式');

  final String label;
  const AppMode(this.label);

  /// 从字符串解析,未知值(包括历史 `cloud`)统一回退到 local
  static AppMode fromString(String value) {
    return AppMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppMode.local,
    );
  }
}

/// 当前应用模式 Provider
final appModeProvider = StateNotifierProvider<AppModeNotifier, AppMode>((ref) {
  return AppModeNotifier();
});

/// AppMode 状态管理器
class AppModeNotifier extends StateNotifier<AppMode> {
  AppModeNotifier() : super(AppMode.local) {
    _loadMode();
  }

  Future<void> _loadMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString('app_mode');
      if (modeStr != null) {
        state = AppMode.fromString(modeStr);
      }
    } catch (e) {
      state = AppMode.local;
    }
  }

  Future<void> switchMode(AppMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_mode', mode.name);
    } catch (e) {
      // 保存失败,但状态已经切换
    }
  }

  Future<void> switchToLocal() => switchMode(AppMode.local);
}
