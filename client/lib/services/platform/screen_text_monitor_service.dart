import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../automation/auto_billing_service.dart'
    show AutoBookTestOptions, AutoBillingService, SmsProcessOutcome, SmsProcessOutcomeEvent;
import '../automation/auto_book_coordinator.dart';
import '../automation/auto_book_event.dart';

import '../automation/automation_settings_store.dart';
import '../data/source_channel_resolver.dart';
import '../../ai/core/ai_runtime_state.dart';
import '../../providers/automation_providers.dart';
import '../system/logger_service.dart' show logger;

/// 屏幕文本监听服务(账单详情页自动记账,Android 专用)。
///
/// 原生 [ScreenTextWatcher](AccessibilityService) 在系统「无障碍」授权后
/// 永续监听白名单 App(支付宝/抖音/京东/微信)前台页面,检测到金额+交易特征
/// 后经过滤/去重入队;本服务负责:
/// - 进程存活时经桥接广播即时处理(onScreenTextCaptured);
/// - 启动时 [drainPending] 补处理积压队列(peek + 逐项 ack,同短信队列语义)。
///
/// 启用前置条件:用户在系统「无障碍」中授权,
/// [isAccessibilityGranted] 可查,`enable()` 未授权时抛 StateError 由 UI 引导。
class ScreenTextMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/screen_text');
  static const _enabledKey = 'screen_text_monitor_enabled';

  /// L1:单条页面文本从目标解析到落库 ACK 的限时(含 AI 中转,正常 10~60s,
  /// 3min 只截真挂起)。见 [drainPending] 批处理处的注释。
  static const processOneTimeout = Duration(minutes: 3);

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  bool _isEnabled = false;
  bool _bridgeRegistered = false;

  // 本会话已就"AI 未配置"提醒过的指纹:避免每次启动都重复打扰
  final Set<String> _noAiNotified = {};

  Future<void> _processingChain = Future.value();

  static ScreenTextMonitorService? _instance;

  factory ScreenTextMonitorService(ProviderContainer container) {
    _instance ??= ScreenTextMonitorService._internal(container);
    return _instance!;
  }

  ScreenTextMonitorService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onScreenTextCaptured') {
        _enqueue(() async {
          if (!_isEnabled) return;
          await drainPending();
        });
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() task) {
    _processingChain = _processingChain.catchError((_) {}).then((_) => task());
    return _processingChain;
  }

  /// 系统「无障碍」服务是否已授权(监听生效的硬前提)
  Future<bool> isAccessibilityGranted() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isAccessibilityGranted') ?? false;
  }

  /// 是否 vivo/iQOO 设备(「无障碍一开就关」高发,引导 UI 据此展示自救提示)
  Future<bool> isVivoDevice() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isVivoDevice') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「无障碍」设置页
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_enabledKey) ?? false;
    return _isEnabled;
  }

  /// 启用屏幕文本监听。未授权「无障碍」时抛 StateError(UI 层应引导授权)。
  ///
  /// M2-2:只 await 到桥接注册,积压队列交给 [scheduleDrain] 后台跑。
  Future<void> enable() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 平台');
    }
    if (!await isAccessibilityGranted()) {
      throw StateError('accessibility_grant_not_granted');
    }
    await _channel.invokeMethod('setEnabled', {'enabled': true});
    await _registerBridge();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    _isEnabled = true;
    scheduleDrain();
  }

  /// 调度一次积压处理,不阻塞调用方(M2-2)。返回值只给测试 await。
  Future<void> scheduleDrain() {
    final done = _enqueue(drainPending);
    unawaited(done);
    return done;
  }

  Future<void> disable() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setEnabled', {'enabled': false});
      } catch (_) {}
      await _unregisterBridge();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    _isEnabled = false;
  }

  /// 补处理积压屏幕文本(启动时 / 桥接触发 / 启用时),语义同通知 drain。
  Future<void> drainPending() async {
    if (!_isEnabled) return;
    // M1-1:AI 运行时未就绪时保留整条队列,不消耗事件的退避窗口。
    final runtime = AiRuntimeCoordinator.instance;
    if (!await runtime.awaitReady()) {
      logger.info('ScreenTextMonitor',
          'AI 运行时未就绪(${runtime.state.name}),保留详情页队列待下次 drain');
      await _logDecision('drain_deferred', 'AI 运行时未就绪(${runtime.state.name})');
      return;
    }
    try {
      final items =
          await _channel.invokeMethod<List<dynamic>>('peekPending') ?? const [];
      if (!_isEnabled) return; // 用户中途关闭:整条队列留在 native
      // 并行分发:逐条交给 Coordinator(有界并发,同 eventKey 串行),每条完成
      // 即 ACK,不再逐条 await —— 一批积压页面文本的识别墙钟时间 ≈ 1/并发数。
            // B3:分批读取、有界处理 —— 每批最多 10 条,批内并发、批间串行,
      // 避免一次把整队(单来源上限 500 条)同时压进 Coordinator。
      const batchSize = 10;
      for (var start = 0; start < items.length; start += batchSize) {
        if (!_isEnabled) return; // 用户中途关闭:剩余项留队
        final futures = <Future<void>>[];
        for (final raw in items.skip(start).take(batchSize)) {
          if (raw is! Map) continue;
          final pkg = (raw['package'] ?? '').toString();
          final text = (raw['text'] ?? '').toString();
          final fingerprint = (raw['fingerprint'] ?? '').toString();
          final nativeEventKey = (raw['eventKey'] ?? '').toString().trim();
          final timestamp = int.tryParse((raw['timestamp'] ?? '').toString());
          final eventKey = nativeEventKey.isNotEmpty
              ? 'screen:v3:$nativeEventKey'
              : 'screen:v2:$fingerprint:${timestamp ?? 0}';
          // L1(2026-10-14):单条处理限时。_processOne 内的 DB 查询/AI 调用
          // 均无自身超时,一旦挂死(DB 事务排队/网络栈停滞)会把 Future.wait、
          // drainPending 与整条 _processingChain 一起永久拖死 —— 此后所有
          // 桥接广播只排队不执行,「已捕获入队」停滞直到杀进程重启。截断后
          // 该项不 ACK 留在原生队列(事件侧由 10min 处理租约兜底),下轮
          // drain 重试;后台仍在跑的原任务由 eventKey 幂等 claim 兜住不双跑。
          futures.add(
            _processOne(
              pkg: pkg,
              text: text,
              fingerprint: fingerprint,
              eventKey: eventKey,
              timestamp: timestamp,
              queueItem: raw is Map ? raw : null,
            ).timeout(processOneTimeout, onTimeout: () {
              unawaited(_logDecision(
                'drain_timeout',
                'pkg=$pkg 单条处理超 ${processOneTimeout.inMinutes}min 截断'
                '(挂起点在 target 解析/AI/落库之一,不 ACK 留队重试)',
                pkg: pkg,
              ));
            }),
          );
        }
        await Future.wait(futures);
      }
    } catch (_) {
      // 队列读取/通道异常不抛;未 ack 的项下次 drain 通过指纹预检补 ack
    }
  }

  /// 单条页面文本的识别 + ACK(与 drain 并行分发配套;异常自吞,原样保留队列)。
  Future<void> _processOne({
    required String pkg,
    required String text,
    required String fingerprint,
    required String eventKey,
    int? timestamp,
    Map? queueItem,
  }) async {
    // 微信账单页强约束(与 native isWechatBillPage 同口径):旧版本已入队的
    // 微信聊天列表文本(会话预览「已支付¥8.00」命中强锚点)在 drain 时也
    // 要拦下,直接 ACK 丢弃,不再送 AI —— 既省一次识别,也杜绝复发。
    // 状态字段行「当前状态/支付状态」任一命中 + 状态值「支付成功/已存入
    // 零钱/退款成功/已退款」(支出/收款/退款三向;微信多代账单 UI 字段名并存,
    // 2026-09-11 真机 dump 实测新版支出页为「当前状态 支付成功」;2026-09-15
    // B6 补退款向:退款详情页状态值是「退款成功」,旧词表不认 → 微信退款
    // 详情页系统性漏记)。
    if (!isWechatBillPageText(pkg, text)) {
      await _logDecision(
        'wechat_not_bill_page',
        'pkg=$pkg len=${text.length}(缺少 支付状态+支付成功 双特征)',
        pkg: pkg,
      );
      await _ack(fingerprint, eventKey);
      return;
    }
    final alreadyWarned = _noAiNotified.contains(eventKey);
    final capturedAt = DateTime.now();
    // B2:优先用捕获时冻结的目标快照,没有才按当前配置解析。
    final snapshot = AutoBookQueueTargetSnapshot.fromQueueItem(queueItem);
    final target = await resolveAutoBookTarget(
      _container,
      frozenRef: snapshot.ref,
      frozenState: snapshot.state,
      frozenConfigVersion: snapshot.version,
    );
    // 目标判定是「不调 AI 也不 ACK」的静默分支,识别记录页因此空白 ——
    // 真机排查只能靠日志。记一条含冻结快照与解析结果的决策,冻结快照被
    // 污染(旧 ref/旧 state)时在这里一眼可见。
    final diag = '目标解析 frozen=${snapshot.ref}/${snapshot.state}'
        '/v${snapshot.version} -> state=${target.stateName} '
        'ledger=${target.ledgerId} canWrite=${target.canWrite} '
        'reason=${target.reason}';
    logger.info('ScreenTextMonitor', diag);
    // release 包 logger 不进 logcat(debugPrint 受 kDebugMode 限制),而自动记账
    // 停摆只能靠真机日志定位 → 额外走 developer.log,prod 也能在
    // `adb logcat -s flutter` 看到。
    developer.log(diag, name: 'AutoBookDiag');
    final input = AutoBookInput(
      eventKey: eventKey,
      source: AutoBookSource.screenText,
      captureIntent: AutoBookCaptureIntent.automatic,
      capturedAt: capturedAt,
      // A2:证据有效期 30 天(capturedAt 起算),到期由 cleanupExpired 清理。
      expiresAt: AutoBookInput.defaultExpiresAt(capturedAt),
      sourceOccurredAt: timestamp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestamp),
      contentHash: fingerprint,
      targetRef: target.targetRef,
      targetConfigVersion: target.configVersion,
      targetState: target.stateName,
      sourceChannel: SourceChannelResolver.channelForPackage(pkg),
      rawText: text,
      rawActor: pkg,
      rawMetadata: {
        'fingerprint': fingerprint,
        if (eventKey.startsWith('screen:v3:'))
          'nativeEventKey': eventKey.substring('screen:v3:'.length),
        if (timestamp != null) 'timestamp': timestamp,
      },
    );
    if (!target.canWrite) {
      // B2:目标失效/待确定 —— 不调 AI、不 ACK,页面文本留到目标修好再处理。
      // 必须记决策:该分支不产生任何 Dart 段记录,识别记录页只看到原生
      // 「已捕获入队」就再无下文,用户无从判断卡在哪一步(真机排查死角)。
      await _logDecision(
        target.state == AutoBookTargetState.invalid
            ? 'target_invalid'
            : 'target_undetermined',
        'state=${target.stateName} reason=${target.reason} '
        'frozen=${snapshot.ref}/${snapshot.state}/v${snapshot.version}',
        pkg: pkg,
      );
      await _coordinator.execute<SmsProcessOutcome>(
        input: input,
        action: () async => target.state == AutoBookTargetState.invalid
            ? SmsProcessOutcome.targetInvalid
            : SmsProcessOutcome.targetUndetermined,
        updateFor: (o) => o.eventUpdate,
      );
      return;
    }
    final execution = await _coordinator.execute(
      input: input,
      action: () => _autoBillingService.processScreenText(
        pkg,
        text,
        // 成功入账始终通知;「AI 未配置」引导按指纹只提示一次
        showNotification: true,
        notifyAiUnconfigured: !alreadyWarned,
        // 内容指纹去重(持久化,跨会话)在 processScreenText 内已是**降级**
        // 语义(C1,2026-09-15):命中不再直接丢弃,交语义判重裁决 —— 与
        // sms/notify 路 2026-09-10 改法一致,同店同款第二笔不被静默吞掉。
        // Coordinator 按 eventKey 幂等,兜住重复 drain。
        skipDedup: false,
        eventKey: eventKey,
        targetLedgerId: target.ledgerId,
      ),
      // M1-3:与短信/通知共用一份走向映射。
      updateFor: (outcome) => outcome.eventUpdate,
    );

    if (execution.skipped) {
      await _logDecision(
        'drain_skipped',
        'pkg=$pkg state=${execution.state.value}',
        pkg: pkg,
      );
      if (execution.terminal) await _ack(fingerprint, eventKey);
      return;
    }

    final outcome = execution.value;
    if (outcome == null) return;
    await _logDecision('drain_${outcome.name}', 'pkg=$pkg', pkg: pkg);
    if (outcome == SmsProcessOutcome.noAiConfigured) {
      _noAiNotified.add(eventKey);
    }
    if (outcome.canAckNativeQueue) {
      await _ack(fingerprint, eventKey);
    }
  }

  /// 模拟屏幕文本(调试/验证入口):直接注入详情页文本走完整 AI 提取 →
  /// 落库流程,用于没有真实页面时验证「自动记账是否正常」。skipDedup 保证
  /// 同一模板可反复发送。
  /// [testOptions] 缺省 = 解析链路测试**只解析不入账**(影子模式);
  /// 显式传入 testLedgerId 时才写入该测试账本。
  Future<void> mockScreenText(String pkg, String text,
      {AutoBookTestOptions? testOptions}) {
    return _enqueue(() async {
      await _autoBillingService.processScreenText(
        pkg,
        text,
        skipDedup: true,
        testOptions: testOptions,
      );
    });
  }

  /// 最近识别决策(原生环形队列,「自动识别记录」页排查真机漏记用)。
  /// 不含页面文本 —— 只有决策码/命中关键词/长度计数。
  Future<List<Map<String, String>>> recentDecisions() async {
    if (!Platform.isAndroid) return const [];
    try {
      final res =
          await _channel.invokeMethod<List<dynamic>>('getDecisions') ?? const [];
      return [
        for (final e in res)
          if (e is Map) e.map((k, v) => MapEntry('$k', '$v')),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 获取已安装 App 的应用图标(PNG 字节数组),仅 Android 平台支持。
  Future<Uint8List?> getAppIcon(String pkg) async {
    if (!Platform.isAndroid || pkg.isEmpty || pkg == 'app') return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getAppIcon', {'pkg': pkg});
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 追加一条 Dart 段(drain/AI)决策记录,与原生判定拼成完整链路。失败静默。
  Future<void> _logDecision(String decision, String detail, {String? pkg}) {
    return logAutoDecision(
      source: AutoDecisionSource.screen,
      pkg: pkg,
      decision: decision,
      detail: detail,
    );
  }

  /// 追加一条自动记账决策记录(供「自动识别记录」页分类展示)。
  ///
  /// [source] 标记来源通道:screen=无障碍详情页,screenshot=截图 OCR,
  /// notification=通知监听;各自动入口在关键决策点调用,失败静默。
  Future<void> logAutoDecision({
    required String source,
    String? pkg,
    required String decision,
    String detail = '',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('appendDecision', {
        'pkg': pkg ?? 'app',
        'decision': decision,
        'detail': detail,
        'source': source,
      });
    } catch (_) {}
  }

  /// 微信账单页双特征判定(drain 侧;与 native
  /// [ScreenTextWatcher.isWechatBillPage] 同口径,纯函数便于单测)。
  ///
  /// 微信是高频 IM,无障碍抓全页文本的场景几乎全是聊天列表/会话页 —— 列表
  /// 里「微信支付」服务号会话预览「已支付¥8.00」同时命中强锚点与金额闸。
  /// 因此微信页面只在「确认是账单详情页」时放行:
  ///  - 状态字段行:「当前状态」或「支付状态」任一命中;
  ///  - 状态值:「支付成功」(支出)/「已存入零钱」(收款)/**「退款成功」/
  ///    「已退款」(退款,B6 2026-09-15:微信退款详情页状态值是「退款成功」,
  ///    旧词表不认导致系统性漏记)**。
  /// 其余 App 不受影响(返回 true)。
  static bool isWechatBillPageText(String pkg, String text) {
    if (!pkg.contains('com.tencent.mm')) return true;
    final hasStatusField =
        text.contains('当前状态') || text.contains('支付状态');
    final hasSettledValue = text.contains('支付成功') ||
        text.contains('已存入零钱') ||
        text.contains('退款成功') ||
        text.contains('已退款');
    return hasStatusField && hasSettledValue;
  }

  Future<void> _ack(String fingerprint, String? eventKey) async {
    if (fingerprint.isEmpty && (eventKey == null || eventKey.isEmpty)) return;
    try {
      await _channel.invokeMethod('ackPending', {
        'fingerprints': fingerprint.isEmpty ? const <String>[] : [fingerprint],
        'eventKeys': eventKey == null || eventKey.isEmpty
            ? const <String>[]
            : [eventKey.replaceFirst('screen:v3:', '')],
      });
    } catch (_) {}
  }

  Future<void> _registerBridge() async {
    if (_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('registerBridge');
      _bridgeRegistered = true;
    } catch (_) {}
  }

  Future<void> _unregisterBridge() async {
    if (!_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unregisterBridge');
      _bridgeRegistered = false;
    } catch (_) {}
  }

  void dispose() {
    _autoBillingService.dispose();
  }
}

/// 自动记账决策来源(「自动识别记录」页分类展示用)。
abstract final class AutoDecisionSource {
  static const screen = 'screen'; // 无障碍详情页抓取
  static const notification = 'notification'; // 通知监听
  static const screenshot = 'screenshot'; // 截图 OCR
}
