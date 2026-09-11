import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 通知点击路由(批次5,2026-09-10)。
///
/// 通知 payload 携带 `smartbook://open?page=xxx` 形态的目标页标识;点击时
/// (前台回调 / 冷启动 launch details)统一经 [onTap] 交给 app 层注册的
/// 处理器 —— 处理器内部复用 AppLink 的 `_openDeepLink` 派发,成功/待确认/
/// 合并通知分别直达账单流 / 待确认页 / 自动记账历史页,不再「点开 App
/// 落首页自己找」。
class NotificationTapRouter {
  /// app 层注册的处理器(签名与 AppLink 的 URI 处理一致)。
  static void Function(String uri)? handler;

  static Future<void> onTap(NotificationResponse response) async {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    final h = handler;
    if (h == null) {
      // app 层未就绪(极早期点击):留待 coldStartDrain 由 app 启动时补发。
      _pendingColdStart = payload;
      return;
    }
    h(payload);
  }

  /// 冷启动补发:App 启动时调用;若点击发生在 handler 注册前,从这里取走。
  static String? consumePending() {
    final p = _pendingColdStart;
    _pendingColdStart = null;
    return p;
  }

  static String? _pendingColdStart;
}
