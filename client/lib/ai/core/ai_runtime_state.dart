import 'dart:async';

import '../../services/system/logger_service.dart';

/// AI 运行时状态(M1-1)。
///
/// 「本地存在能力配置」和「现在真的能调用」是两件事。旧实现只有
/// `AIProviderManager.isCapabilityConfigured` 一个信号,冷启动时配置缓存有效
/// 但 `AiRelayClient` 还没注入,自动入口照样发起识别 → 拿到异常 → 被当成
/// 「不是账单」→ 终结事件并 ACK 原生队列 → 真实短信永久丢失。
enum AiRuntimeState {
  /// 云服务未配置 / 未登录:保留 captured,不 ACK。
  unconfigured,

  /// 正在恢复登录 / 注入 Relay:保留队列,等 ready 事件。
  initializing,

  /// 可以正常识别。
  ready,

  /// 网络不可达:保留草稿并退避。
  offline,

  /// 会话失效需要用户重新登录:保留并提示登录。
  authenticationRequired,

  /// 服务商配置/上游明确失败:failed 或长退避,必须对用户可见。
  providerError,
}

/// AI 运行时就绪状态的唯一权威源。
///
/// 故意做成不依赖 Riverpod 的全局单例 —— 与 [AIProviderFactory.relayClient]
/// 的静态注入保持同一套生命周期,`services/automation` 下的 Monitor 可以直接
/// 读,不必为了一个布尔值把 UI 层容器传进后台链路。
///
/// 自动事件策略(计划 §6.2):只有 [AiRuntimeState.ready] 才允许发起识别;
/// 其余状态一律**保留队列不 ACK**,由 drain 调度稍后重试。
class AiRuntimeCoordinator {
  AiRuntimeCoordinator._();

  static final AiRuntimeCoordinator instance = AiRuntimeCoordinator._();

  static const String _tag = 'AiRuntime';

  AiRuntimeState _state = AiRuntimeState.initializing;

  final StreamController<AiRuntimeState> _changes =
      StreamController<AiRuntimeState>.broadcast();

  AiRuntimeState get state => _state;

  /// 状态变化流(只在状态真的变化时发事件)。
  Stream<AiRuntimeState> get changes => _changes.stream;

  /// 可以发起 AI 调用。
  bool get isReady => _state == AiRuntimeState.ready;

  /// 状态已可判定:再等下去也不会自动变好,调用方可以立刻按当前状态决策
  /// (保留队列 / 退避 / 提示登录),不必继续阻塞。
  bool get isDecidable => _state != AiRuntimeState.initializing;

  void markInitializing() => _set(AiRuntimeState.initializing);

  void markReady() => _set(AiRuntimeState.ready);

  void markUnconfigured() => _set(AiRuntimeState.unconfigured);

  void markOffline() => _set(AiRuntimeState.offline);

  void markAuthenticationRequired() =>
      _set(AiRuntimeState.authenticationRequired);

  void markProviderError() => _set(AiRuntimeState.providerError);

  /// 按 AI 调用失败的错误码回写运行时状态(错误码见 `AIException.code`)。
  /// 只在**确定**是运行时问题时改状态,解析类失败不动状态。
  void applyFailureCode(String? code) {
    switch (code) {
      case 'relay_not_ready':
        // Relay 还没注入:可能是冷启动竞态,也可能是从未配置云服务。
        // 保持 initializing 让 drain 继续等;已判定过就不回退。
        if (_state == AiRuntimeState.ready) _set(AiRuntimeState.initializing);
      case 'network':
      case 'timeout':
        _set(AiRuntimeState.offline);
      case 'unauthorized':
        _set(AiRuntimeState.authenticationRequired);
      case 'upstream_unavailable':
        _set(AiRuntimeState.providerError);
      default:
        break;
    }
  }

  /// 等待进入 [AiRuntimeState.ready]。
  ///
  /// 返回 true = 已就绪可以识别;false = 超时或已判定为不可用,调用方必须
  /// **保留队列不 ACK**。只在 [AiRuntimeState.initializing] 时才真的等待,
  /// 其它状态立即返回,不让自动事件白占处理槽。
  Future<bool> awaitReady({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (isReady) return true;
    if (isDecidable) return false;
    try {
      final next = await changes
          .firstWhere((s) => s != AiRuntimeState.initializing)
          .timeout(timeout);
      return next == AiRuntimeState.ready;
    } on TimeoutException {
      logger.info(_tag, 'AI Runtime 等待就绪超时,保留队列');
      return false;
    }
  }

  void _set(AiRuntimeState next) {
    if (_state == next) return;
    _state = next;
    logger.info(_tag, 'AI Runtime 状态: $next');
    if (!_changes.isClosed) _changes.add(next);
  }

  /// 仅测试用:恢复初始状态。
  void resetForTest() {
    _state = AiRuntimeState.initializing;
  }
}
