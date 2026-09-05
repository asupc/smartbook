import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/core/prompt_builder.dart';
import '../../ai/providers/ai_provider_config.dart';
import '../../ai/providers/ai_provider_factory.dart';
import '../../ai/providers/ai_provider_manager.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/ai_chat_providers.dart';
import '../ai/bookkeeping_result.dart';
import '../attachment_service.dart';
import '../billing/pending_candidate.dart';
import '../billing/post_processor.dart';
import '../data/source_channel_resolver.dart';
import '../data/tag_seed_service.dart';
import '../system/logger_service.dart';
import 'auto_billing_config.dart';
import 'auto_book_event.dart';
import 'auto_book_event_store.dart';

/// 短信一次处理的走向。队列管理侧据此决定丢弃 or 保留待补记。
enum SmsProcessOutcome {
  /// 已入账(成功)
  success,

  /// AI 判定不是交易短信(正常情况,直接丢弃)
  noTransaction,

  /// AI 识别到有效账单，但按安全策略进入待确认队列，尚未创建交易。
  pending,

  /// AI 识别到的账单已与已有 canonical transaction 判重，未创建新交易。
  duplicate,

  /// 处理失败(AI 调用/落库异常,丢弃,避免对同一短信反复重试)
  failed,

  /// 影子模式识别完成，但刻意没有创建交易。
  shadow,

  /// 短信已接收但 AI text 未配置 —— 保留队列,配置后下次启动补记
  noAiConfigured,
}

/// 自动记账服务 - 通用核心逻辑
/// Android和iOS共用的OCR识别和自动记账逻辑
class AutoBillingService {
  static const _ledgerIdKey = 'current_ledger_id';
  static const _processedScreenshotsKey = 'processed_screenshots';
  static const _processedSmsFingerprintsKey = 'processed_sms_fingerprints';
  static const _processedNotifyFingerprintsKey =
      'processed_notify_fingerprints';
  static const _processedScreenTextFingerprintsKey =
      'processed_screen_text_fingerprints';
  static const _processedBillFingerprintsKey = 'processed_bill_fingerprints';
  static const _shadowModeKey = 'auto_book_shadow_mode';

  final ProviderContainer _container;
  final AutoBookEventStore? _eventStore;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 防重复处理
  final Set<String> _processedPaths = {};
  final Set<String> _processedSmsFingerprints = {};
  final Set<String> _processedNotifyFingerprints = {};
  final Set<String> _processedScreenTextFingerprints = {};
  String? _lastProcessedPath;
  int _lastProcessedTime = 0;

  // 静默截图流的「AI 未配置」一次性提示:每会话只弹一次,不重复打扰
  bool _aiUnconfiguredWarnedOnce = false;

  // 账单级去重指纹(渠道|金额|备注|交易日期),跨页面文本/跨会话持久化,
  // 用于「同一账单重复进入详情页」这类页面指纹挡不住的场景。
  final Set<String> _processedBillFingerprints = {};

  AutoBillingService(this._container, {AutoBookEventStore? eventStore})
      : _eventStore = eventStore {
    _initNotifications();
    _loadProcessedScreenshots();
    _loadProcessedSmsFingerprints();
    _loadProcessedNotifyFingerprints();
    _loadProcessedScreenTextFingerprints();
    _loadProcessedBillFingerprints();
  }

  /// 自动入口始终经过候选/语义安全层。旧版「自动入账校验」开关不能
  /// 关闭硬闸门或 event 幂等，否则一次误触发就可能把账单汇总写成消费；
  /// 语义硬闸门恒开。开关现在接回为「自动入账总闸」(P0-2):关=所有识别
  /// 结果一律先进待确认队列，开=仅低置信/疑似重复进待确认(原候选制行为)。
  Future<AutoBookFlow> _autoBookFlow({String? eventKey}) async {
    final prefs = await SharedPreferences.getInstance();
    return AutoBookFlow(
      store: PendingCandidateStore(),
      eventKey: eventKey,
      eventStore: _eventStore,
      strictSemantic: true,
      shadowMode: prefs.getBool(_shadowModeKey) ?? false,
      requireConfirmationForAll: !(prefs.getBool('auto_book_enabled') ?? true),
    );
  }

  /// 影子模式只识别和记录摘要，不创建交易/候选，默认关闭。
  Future<bool> isShadowModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shadowModeKey) ?? false;
  }

  Future<void> setShadowModeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shadowModeKey, enabled);
  }

  /// 解析当前账本 ID(Provider → SharedPreferences → 数据库默认)。
  Future<int?> _resolveLedgerId() async {
    try {
      final id = _container.read(currentLedgerIdProvider);
      return id;
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    final fromPrefs = prefs.getInt(_ledgerIdKey);
    if (fromPrefs != null) return fromPrefs;
    final repo = _container.read(repositoryProvider);
    final ledgers = await repo.getAllLedgers();
    if (ledgers.isEmpty) return null;
    final fallback = ledgers.first.id;
    await prefs.setInt(_ledgerIdKey, fallback);
    return fallback;
  }

  /// 初始化通知
  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // 同 _showNotification:通知子系统任何异常都不允许影响记账主流程
    try {
      await _notificationsPlugin.initialize(initSettings);
    } catch (e) {
      logger.warning('AutoBilling', '通知初始化失败(仅影响进度通知,不影响记账): $e');
    }
  }

  /// 加载已处理的截图列表
  Future<void> _loadProcessedScreenshots() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_processedScreenshotsKey) ?? [];
    _processedPaths.addAll(list);

    // 只保留最近N个，避免内存占用过大
    if (_processedPaths.length > AutoBillingConfig.maxProcessedCache) {
      final toRemove =
          _processedPaths.length - AutoBillingConfig.maxProcessedCache;
      _processedPaths.removeAll(_processedPaths.take(toRemove));
      await _saveProcessedScreenshots();
      logger.debug('AutoBilling', '清理已处理缓存',
          '移除=$toRemove, 保留=${AutoBillingConfig.maxProcessedCache}');
    }
  }

  /// 保存已处理的截图列表
  Future<void> _saveProcessedScreenshots() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _processedScreenshotsKey, _processedPaths.toList());
  }

  /// 标记截图已处理
  Future<void> _markAsProcessed(String path) async {
    _processedPaths.add(path);
    await _saveProcessedScreenshots();
  }

  /// 检查截图是否已处理
  bool _isProcessed(String path) {
    return _processedPaths.contains(path);
  }

  /// 加载已处理的短信指纹(与 native SmsReceiver 的指纹备忘录是两层防护:
  /// native 挡"重复入队",这里挡"队列被重复 drain"——同一指纹只入账一次)
  Future<void> _loadProcessedSmsFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_processedSmsFingerprintsKey) ?? [];
      _processedSmsFingerprints.addAll(list);
      if (_processedSmsFingerprints.length >
          AutoBillingConfig.maxProcessedCache) {
        final toRemove = _processedSmsFingerprints.length -
            AutoBillingConfig.maxProcessedCache;
        _processedSmsFingerprints
            .removeAll(_processedSmsFingerprints.take(toRemove));
        await _saveProcessedSmsFingerprints();
      }
    } catch (_) {}
  }

  Future<void> _saveProcessedSmsFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _processedSmsFingerprintsKey, _processedSmsFingerprints.toList());
  }

  bool _isSmsProcessed(String fingerprint) {
    return _processedSmsFingerprints.contains(fingerprint);
  }

  /// 供短信队列管理侧处理前预检(已处理 → 直接 ack,不再调用 AI)。
  bool isSmsProcessed(String fingerprint) => _isSmsProcessed(fingerprint);

  /// 加载已处理的通知指纹(与短信指纹相互独立,key 不同)
  Future<void> _loadProcessedNotifyFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_processedNotifyFingerprintsKey) ?? [];
      _processedNotifyFingerprints.addAll(list);
      if (_processedNotifyFingerprints.length >
          AutoBillingConfig.maxProcessedCache) {
        final toRemove = _processedNotifyFingerprints.length -
            AutoBillingConfig.maxProcessedCache;
        _processedNotifyFingerprints
            .removeAll(_processedNotifyFingerprints.take(toRemove));
        await _saveProcessedNotifyFingerprints();
      }
    } catch (_) {}
  }

  Future<void> _saveProcessedNotifyFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _processedNotifyFingerprintsKey, _processedNotifyFingerprints.toList());
  }

  bool _isNotifyProcessed(String fingerprint) {
    return _processedNotifyFingerprints.contains(fingerprint);
  }

  /// 加载已处理的屏幕文本指纹(与短信/通知相互独立,key 不同)
  Future<void> _loadProcessedScreenTextFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list =
          prefs.getStringList(_processedScreenTextFingerprintsKey) ?? [];
      _processedScreenTextFingerprints.addAll(list);
      if (_processedScreenTextFingerprints.length >
          AutoBillingConfig.maxProcessedCache) {
        final toRemove = _processedScreenTextFingerprints.length -
            AutoBillingConfig.maxProcessedCache;
        _processedScreenTextFingerprints
            .removeAll(_processedScreenTextFingerprints.take(toRemove));
        await _saveProcessedScreenTextFingerprints();
      }
    } catch (e) {
      logger.warning('AutoBilling', '加载屏幕文本指纹失败(继续运行,仅影响去重)', '$e');
    }
  }

  Future<void> _saveProcessedScreenTextFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_processedScreenTextFingerprintsKey,
        _processedScreenTextFingerprints.toList());
  }

  bool _isScreenTextProcessed(String fingerprint) {
    return _processedScreenTextFingerprints.contains(fingerprint);
  }

  /// 供屏幕文本队列管理侧处理前预检(已处理 → 直接 ack)。
  bool isScreenTextProcessed(String fingerprint) =>
      _isScreenTextProcessed(fingerprint);

  /// 供通知队列管理侧处理前预检(已处理 → 直接 ack)。
  bool isNotifyProcessed(String fingerprint) => _isNotifyProcessed(fingerprint);

  /// 标记短信已处理(不管成败,与截图路径一致:避免重复消费同一短信)
  Future<void> _markSmsProcessed(String fingerprint) async {
    _processedSmsFingerprints.add(fingerprint);
    await _saveProcessedSmsFingerprints();
  }

  /// 核心：处理截图并自动记账
  /// [imagePath] 截图文件路径
  /// [showNotification] 是否显示通知（默认true）
  /// [notifyOnlyOnSuccess] 最小打扰模式(截图自动监听用):触发/识别中/非账单/
  /// 失败一律静默,只在**成功入账**时通知;「AI 未配置」保留会话级一次性提示
  /// (否则用户无法感知为何截图没反应)。
  /// 返回：完整识别结果(全失败时为 [BookkeepingResult.empty])
  Future<BookkeepingResult> processScreenshot(
    String imagePath, {
    bool showNotification = true,
    bool notifyOnlyOnSuccess = false,
    String? eventKey,
  }) async {
    final totalStartTime = DateTime.now().millisecondsSinceEpoch;
    print('📸 [AutoBilling] 开始处理截图: $imagePath');
    logger.info('AutoBilling', '开始处理截图',
        'pathHash=${autoBookHash(imagePath, length: 12)}');

    // 防重复处理: 已处理过的跳过
    if (_isProcessed(imagePath)) {
      print('⚠️ [AutoBilling] 截图已处理过，跳过');
      logger.warning('AutoBilling', '截图已处理过，跳过', imagePath);
      return const BookkeepingResult(duplicateCount: 1);
    }

    // 防重复处理: 配置时间窗口内相同路径只处理一次
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProcessedPath == imagePath &&
        (now - _lastProcessedTime) < AutoBillingConfig.duplicateCheckWindow) {
      final timeDiff = now - _lastProcessedTime;
      print('⚠️ [AutoBilling] 重复截图，跳过处理 (${timeDiff}ms前已处理)');
      logger.warning('AutoBilling', '重复截图，跳过处理', '${timeDiff}ms前已处理');
      return const BookkeepingResult(duplicateCount: 1);
    }

    _lastProcessedPath = imagePath;
    _lastProcessedTime = now;

    const notificationId = 1001;
    // 最终结果(成功/失败)用独立 ID,避免 iOS 把它当成对 1001 的静默更新
    const resultNotificationId = 1101;

    try {
      // 检查文件是否存在
      final file = File(imagePath);

      // 如果文件不存在,可能需要短暂等待
      // (无障碍服务直接截图时文件已就绪,ContentObserver 可能需要等待)
      if (!await file.exists()) {
        logger.info('AutoBilling', '文件尚未就绪，开始等待',
            '路径=$imagePath, 超时=${AutoBillingConfig.fileWaitTimeout}ms');

        if (showNotification && !notifyOnlyOnSuccess) {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showNotification(
            id: notificationId,
            title: l10n.autoBillingNotifyDetectedTitle,
            body: l10n.autoBillingNotifyWaitingFileBody,
          );
        }

        final waitStartTime = DateTime.now().millisecondsSinceEpoch;
        var waitTime = 0;
        final maxWait = AutoBillingConfig.fileWaitTimeout;

        while (waitTime < maxWait) {
          if (await file.exists() && await file.length() > 0) {
            print('✅ 文件已就绪，等待时间=${waitTime}ms');
            logger.info('AutoBilling', '文件就绪', '等待时间=${waitTime}ms');
            break;
          }
          await Future.delayed(
              Duration(milliseconds: AutoBillingConfig.fileCheckInterval));
          waitTime = DateTime.now().millisecondsSinceEpoch - waitStartTime;
        }

        if (!await file.exists() || await file.length() == 0) {
          logger.error('AutoBilling', '截图文件等待超时',
              '路径=$imagePath, 等待时间=${waitTime}ms, 文件存在=${await file.exists()}');
          if (showNotification && !notifyOnlyOnSuccess) {
            final l10n =
                lookupAppLocalizations(PlatformDispatcher.instance.locale);
            await _showFinalNotification(
              progressId: notificationId,
              finalId: resultNotificationId,
              title: l10n.autoBillingNotifyFileUnavailableTitle,
              body: l10n.autoBillingNotifyFileUnavailableBody,
            );
          }
          return const BookkeepingResult(failedCount: 1, retryable: true);
        }
      } else {
        print('✅ 文件已就绪,无需等待');
        logger.debug('AutoBilling', '文件已就绪，无需等待');
      }

      // 兜底:AI vision 未配置 → 系统通知告警,引导用户去设置(后台路径无 UI
      // context,只能 push 系统通知。点击跳转由 deep link 处理,这里先不带
      // payload)
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.vision)) {
        logger.warning('AutoBilling', 'AI vision 未配置,跳过自动记账');
        // 静默模式:只在会话首次提示,之后不再打扰
        if (showNotification &&
            (!notifyOnlyOnSuccess || !_aiUnconfiguredWarnedOnce)) {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.aiNotConfiguredNotificationTitle,
            body: l10n.aiNotConfiguredNotificationBody,
          );
          _aiUnconfiguredWarnedOnce = true;
        }
        return const BookkeepingResult(aiNotConfigured: true);
      }

      // 更新通知：开始识别
      if (showNotification && !notifyOnlyOnSuccess) {
        final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);
        await _showNotification(
          id: notificationId,
          title: l10n.autoBillingNotifyRecognizingScreenshotTitle,
          body: l10n.autoBillingNotifyVisionAnalyzingBody,
        );
      }

      // AI 视觉识别 + 多笔保存(全部委托 AiBookkeeper)
      final ledgerId = await _resolveLedgerId();
      if (ledgerId == null) {
        logger.error('AutoBilling', '无可用账本');
        if (showNotification && !notifyOnlyOnSuccess) {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoLedgerTitle,
            body: l10n.autoBillingNotifyNoLedgerBody,
          );
        }
        return const BookkeepingResult(failedCount: 1, retryable: true);
      }

      final aiStartTime = DateTime.now().millisecondsSinceEpoch;
      logger.info('AutoBilling', '开始 AI 视觉识别 + 落库');

      final autoAddAttachment =
          _container.read(smartBillingAutoAttachmentProvider);
      final result = await _container.read(aiBookkeeperProvider).fromImage(
            image: file,
            ledgerId: ledgerId,
            billGuard: PromptBuilder.billGuardForImage,
            billingTypes: const [
              TagSeedService.billingTypeImage,
              TagSeedService.billingTypeAi,
            ],
            l10n: lookupAppLocalizations(PlatformDispatcher.instance.locale),
            autoBookFlow: await _autoBookFlow(eventKey: eventKey),
            source: 'image',
            // 多笔截图(罕见,但 AI 可能识别出一张账单页里的多笔)时,每笔都挂
            // 同一张原图,与相册路径行为对齐。
            //
            // 走 urgent 模式:跳过 FlutterImageCompress(platform channel,后台冻
            // 结时会卡)和 _getImageInfo,用 sync File.copy 几十 ms 内完成。
            // 这样 attachment 在 perform() return 前就写完,不依赖用户开 app。
            onSaved: autoAddAttachment
                ? (txId, _) async {
                    try {
                      final attachmentService =
                          _container.read(attachmentServiceProvider);
                      await attachmentService.saveAttachment(
                        transactionId: txId,
                        sourceFile: file,
                        index: 0,
                        urgent: true,
                      );
                      _container
                          .read(attachmentListRefreshProvider.notifier)
                          .state++;
                    } catch (e, st) {
                      logger.error('AutoBilling', '保存截图附件失败', e, st);
                    }
                  }
                : null,
          );

      final aiElapsed = DateTime.now().millisecondsSinceEpoch - aiStartTime;
      logger.info('AutoBilling', 'AI 识别 + 落库完成',
          '耗时=${aiElapsed}ms, 成功=${result.savedCount} 笔, 失败=${result.failedCount}');

      // 只有已进入终态的结果才写入旧路径缓存。临时失败必须让 Coordinator
      // 重试；事件表是主幂等来源，路径缓存只是旧版本兼容兜底。
      if (result.failedCount == 0 &&
          !result.retryable &&
          !result.aiNotConfigured) {
        await _markAsProcessed(imagePath);
      }

      if (result.success) {
        _container.read(statsRefreshProvider.notifier).state++;
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
        await _syncBillingToAiChat(result);
      }

      // P0-3:截图路候选必反馈(不受 notifyOnlyOnSuccess 静默约束)
      await _notifyPendingCandidates('screenshot', result);
      // P1-1:强判重合并轻通知
      await _notifyMergedCandidates(result);

      if (result.retryable || result.failedCount > 0) {
        if (showNotification && !notifyOnlyOnSuccess) {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        }
        return result;
      }

      if (!result.handled) {
        if (showNotification && !notifyOnlyOnSuccess) {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoBillTitle,
            body: l10n.autoBillingNotifyNoBillBody,
          );
        }
        return result;
      }

      if (result.success && showNotification) {
        final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: _successTitle(result, l10n),
          body: _successBody(result, l10n),
        );
      }
      logger.info('AutoBilling', '自动记账事件已处理',
          'saved=${result.savedCount}, pending=${result.awaitingCount}, duplicate=${result.duplicateCount}, ignored=${result.ignoredCount}');
      return result;
    } catch (e, stackTrace) {
      print('❌ 处理截图失败: $e');
      logger.error(
          'AutoBilling',
          '处理截图失败',
          {'pathHash': autoBookHash(imagePath, length: 12), 'stage': '未知阶段'},
          stackTrace);
      if (_isTransientAiError(e)) {
        // 连不上服务端:保留原图路径为草稿(文件被系统清理时重试会自动放弃)
        await _saveDraftForEvent(
            eventKey,
            AutoBookDraftPayload(
                isImage: true, imagePath: imagePath, actor: 'screenshot'));
      }
      if (showNotification && !notifyOnlyOnSuccess) {
        try {
          final l10n =
              lookupAppLocalizations(PlatformDispatcher.instance.locale);
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        } catch (_) {}
      }
      return const BookkeepingResult(failedCount: 1, retryable: true);
    } finally {
      final totalElapsed =
          DateTime.now().millisecondsSinceEpoch - totalStartTime;
      print('⏱️ [性能] 整个流程完成, 总耗时=${totalElapsed}ms');
    }
  }

  /// 核心：直接处理文本并自动记账(快捷指令推荐方式)
  /// [text] 快捷指令传递的识别文本
  /// [showNotification] 是否显示通知（默认true）
  /// 返回：交易记录ID，失败返回null
  /// 兼容旧调用方的文本记账入口。需要知道 pending/duplicate/retry 状态时，
  /// 使用 [processTextResult]。
  Future<int?> processText(
    String text, {
    bool showNotification = true,
    String? eventKey,
  }) async {
    final result = await processTextResult(
      text,
      showNotification: showNotification,
      eventKey: eventKey,
    );
    return result.firstTransactionId;
  }

  /// 文本自动记账的完整结果入口。
  Future<BookkeepingResult> processTextResult(
    String text, {
    bool showNotification = true,
    String? eventKey,
  }) async {
    final totalStartTime = DateTime.now().millisecondsSinceEpoch;
    final textHash =
        sha256.convert(utf8.encode(text)).toString().substring(0, 12);
    logger.debug(
        'AutoBilling', '开始处理文本', 'length=${text.length}, hash=$textHash');

    try {
      const notificationId = 1002;
      const resultNotificationId = 1102;
      final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);

      // 兜底:AI text 未配置 → 系统通知,引导用户去配置。保留 captured 状态，
      // 由启动 drain 在用户完成配置后再次尝试。
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.text)) {
        logger.warning('AutoBilling', 'AI text 未配置,跳过文本记账');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: l10n.aiNotConfiguredNotificationTitle,
            body: l10n.aiNotConfiguredNotificationBody,
          );
        }
        return const BookkeepingResult(aiNotConfigured: true);
      }

      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: l10n.autoBillingNotifyRecognizingTextTitle,
          body: l10n.autoBillingNotifyTextAnalyzingBody,
        );
      }

      final ledgerId = await _resolveLedgerId();
      if (ledgerId == null) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoLedgerTitle,
            body: l10n.autoBillingNotifyNoLedgerBody,
          );
        }
        return const BookkeepingResult(failedCount: 1, retryable: true);
      }

      final result = await _container.read(aiBookkeeperProvider).fromText(
            text: text,
            ledgerId: ledgerId,
            billingTypes: const [
              TagSeedService.billingTypeImage,
              TagSeedService.billingTypeAi,
            ],
            billGuard: PromptBuilder.billGuardForText,
            l10n: l10n,
            autoBookFlow: await _autoBookFlow(eventKey: eventKey),
            source: 'text',
            evidenceText: text,
          );

      if (result.retryable || result.failedCount > 0) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        }
      } else if (!result.handled && showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: l10n.autoBillingNotifyRecognizeFailedTitle,
          body: l10n.autoBillingNotifyNoAmountBody,
        );
      }

      if (result.success) {
        _container.read(statsRefreshProvider.notifier).state++;
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
        await _syncBillingToAiChat(result);
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: _successTitle(result, l10n),
            body: _successBody(result, l10n),
          );
        }
      }
      return result;
    } catch (e, st) {
      logger.error('AutoBilling', '文本处理失败', e, st);
      if (_isTransientAiError(e)) {
        // 连不上服务端:保存离线草稿,联网恢复/手动触发后重试
        await _saveDraftForEvent(
            eventKey, AutoBookDraftPayload(isImage: false, text: text));
      }
      if (showNotification) {
        final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);
        await _showNotification(
          id: 1002,
          title: l10n.autoBillingNotifyProcessFailedTitle,
          body: l10n.autoBillingNotifyProcessFailedBody(e.toString()),
        );
      }
      return const BookkeepingResult(failedCount: 1, retryable: true);
    } finally {
      final totalElapsed =
          DateTime.now().millisecondsSinceEpoch - totalStartTime;
      logger.debug('AutoBilling', '文本处理完成', '总耗时=${totalElapsed}ms');
    }
  }

  /// 核心:处理银行/支付短信并自动记账(M1 短信监听)。
  ///
  /// native 侧([SmsReceiver])已做过白名单/垃圾过滤/指纹去重,这里只做:
  /// AI 提取(fromText 复用,注入 [PromptBuilder.billGuardForSms] 兜底过滤)
  /// + 指纹二次去重(队列被重复 drain / native 与 Dart 指纹口径一致时兜底)。
  ///
  /// 指纹规则:sha256(sender|body) 前 16 位,与 native 侧完全同口径。
  /// 处理前先标记指纹 —— 进程在 AI 调用中被杀时,宁可丢一笔也不重复入账。
  ///
  /// 隐私:短信正文**不写日志**;处理结果为 success/noTransaction/failed 时
  /// 指纹入缓存,正文随队列项一起被丢弃。
  Future<SmsProcessOutcome> processSms(
    String sender,
    String body, {
    bool showNotification = true,
    bool skipDedup = false,
    String? eventKey,
  }) async {
    final fingerprint = smsFingerprint(sender, body);

    // 二次去重(预检由队列管理侧调用 isSmsProcessed 先行处理)。
    // skipDedup:仅「模拟短信」调试入口使用 —— 同一模板可反复发送验证链路。
    if (!skipDedup && _isSmsProcessed(fingerprint)) {
      logger.debug('AutoBilling', '短信指纹已处理过,跳过', fingerprint);
      return SmsProcessOutcome.duplicate;
    }

    const notificationId = 1003;
    const resultNotificationId = 1103;
    final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);

    try {
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.text)) {
        // 不标记:队列项保留,AI 配置后下次启动补记
        logger.warning('AutoBilling', 'AI text 未配置,短信保留待补记');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: l10n.aiNotConfiguredNotificationTitle,
            body: l10n.aiNotConfiguredNotificationBody,
          );
        }
        return SmsProcessOutcome.noAiConfigured;
      }

      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: l10n.autoSmsBillingRecognizingTitle,
          body: l10n.autoSmsBillingAnalyzingBody,
        );
      }

      final ledgerId = await _resolveLedgerId();
      if (ledgerId == null) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoLedgerTitle,
            body: l10n.autoBillingNotifyNoLedgerBody,
          );
        }
        return SmsProcessOutcome.failed;
      }

      // M4:短信发送号 → 渠道名(如 95555→招商银行),拼进 AI 文本作
      // 账户/分类先验 + 传递给账户映射回退。
      final channel = SourceChannelResolver.channelForSmsSender(sender);
      final result = await _container.read(aiBookkeeperProvider).fromText(
            text: SourceChannelResolver.withSourcePrefix(channel, body),
            ledgerId: ledgerId,
            billingTypes: const [
              TagSeedService.billingTypeSms,
              TagSeedService.billingTypeAi,
            ],
            billGuard: PromptBuilder.billGuardForSms,
            l10n: l10n,
            autoBookFlow: await _autoBookFlow(eventKey: eventKey),
            source: 'sms',
            sourceChannel: channel,
            evidenceText: body,
          );

      if (result.success) {
        _container.read(statsRefreshProvider.notifier).state++;
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
        await _syncBillingToAiChat(result);
      }

      final outcome = _outcomeForResult(result);
      if (outcome == SmsProcessOutcome.noTransaction) {
        await _markSmsProcessed(fingerprint);
        logger.info('AutoBilling', '短信非交易,已丢弃');
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoBillTitle,
            body: l10n.autoBillingNotifyNoBillBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.failed) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.pending ||
          outcome == SmsProcessOutcome.duplicate ||
          outcome == SmsProcessOutcome.shadow) {
        await _markSmsProcessed(fingerprint);
        // P0-3:待确认必反馈(此前短信路候选静默入队)
        if (outcome == SmsProcessOutcome.pending) {
          await _notifyPendingCandidates('sms', result);
        }
        // P1-1:强判重合并轻通知(含 duplicate/静默合并路径)
        await _notifyMergedCandidates(result);
        logger.info('AutoBilling', '短信已处理但未新建交易', outcome.name);
        return outcome;
      }

      await _markSmsProcessed(fingerprint);
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: _successTitle(result, l10n),
          body: _successBody(result, l10n),
        );
      }
      logger.info('AutoBilling', '短信自动记账成功',
          'ids=${result.transactionIds}, 总金额=${result.totalAbsAmount}');
      return SmsProcessOutcome.success;
    } catch (e) {
      logger.error('AutoBilling', '短信处理失败', e);
      if (_isTransientAiError(e)) {
        await _saveDraftForEvent(eventKey,
            AutoBookDraftPayload(isImage: false, text: body, actor: sender));
      }
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: l10n.autoBillingNotifyProcessFailedTitle,
          body: l10n.autoBillingNotifyProcessFailedBody(e.toString()),
        );
      }
      return SmsProcessOutcome.failed;
    }
  }

  /// 短信指纹:sha256(sender|body) 前 16 位 hex。
  /// 与 native [com.smartbook.zhi.SmsReceiver] 同口径(取前 8 字节),
  /// 保证两层去重共用同一指纹。
  static String smsFingerprint(String sender, String body) {
    return sha256
        .convert(utf8.encode('$sender|$body'))
        .toString()
        .substring(0, 16);
  }

  /// 通知指纹:sha256(pkg|title|body) 前 16 位 hex。
  /// 与 native NotificationWatcher 同口径。
  static String notifyFingerprint(String pkg, String title, String body) {
    return sha256
        .convert(utf8.encode('$pkg|$title|$body'))
        .toString()
        .substring(0, 16);
  }

  /// 屏幕文本指纹:sha256(pkg|text) 前 16 位 hex。
  /// 与 native [com.smartbook.zhi.ScreenTextWatcher] 同口径。
  static String screenTextFingerprint(String pkg, String text) {
    return sha256
        .convert(utf8.encode('$pkg|$text'))
        .toString()
        .substring(0, 16);
  }

  // ────────────────────────────────────────────────────────────────────
  // 离线识别草稿:连不上服务端(瞬态失败)时保存输入,等重试
  // ────────────────────────────────────────────────────────────────────

  /// 可恢复的临时失败:中转超时/断连(AIException.transient)或进程内网络异常。
  /// 只有这类失败才保存草稿;4xx 校验失败(未配置/参数不合法)重试也不会好。
  bool _isTransientAiError(Object error) {
    if (error is AIException) return error.transient;
    if (error is SocketException || error is TimeoutException) return true;
    return false;
  }

  /// 瞬态失败时把识别输入存为草稿(挂到事件行上),供手动/自动重试。
  /// 任何失败都静默 —— 草稿是增强能力,不能影响失败路径本身。
  Future<void> _saveDraftForEvent(
    String? eventKey,
    AutoBookDraftPayload payload,
  ) async {
    if (eventKey == null || eventKey.isEmpty) return;
    final store = _eventStore;
    if (store == null) return;
    try {
      final saved = await store.saveDraftByEventKey(eventKey, payload);
      logger.info(
        'AutoBilling',
        saved ? '服务端不可达,已保存离线识别草稿' : '草稿保存跳过(事件不存在)',
        'key=${autoBookHash(eventKey, length: 12)} kind=${payload.isImage ? "image" : "text"}',
      );
    } catch (e) {
      logger.warning('AutoBilling', '保存离线识别草稿失败: $e');
    }
  }

  /// 手动重试一个草稿(解除退避闸门后按原通道重跑识别)。
  /// 返回 true = 事件被重新执行(结果由通道通知/待确认页体现)。
  Future<bool> retryDraft(AutoBookEvent event) async {
    var payload = AutoBookDraftPayload.fromJson(event.draftPayloadJson);
    // P1-2:retry 事件不一定有草稿(非瞬态异常不走草稿保存),用事件行上的
    // 原始证据文本兜底重建;截图类没有路径无法重放,明示失败。
    payload ??= _payloadFromRawEvidence(event);
    if (payload == null) return false;
    // 手动重试无视退避窗口
    await _eventStore?.resetRetryGate(event.id);
    return _replayDraft(event, payload);
  }

  /// 从事件行留存的原证据重建重放输入(文本通道);无可用证据返回 null。
  AutoBookDraftPayload? _payloadFromRawEvidence(AutoBookEvent event) {
    final text = event.rawText?.trim();
    if (event.source == 'screenshot' || event.source == 'sharedImage') {
      // 原图路径不落事件行,证据清理后无法重放
      return null;
    }
    if (text == null || text.isEmpty) return null;
    return AutoBookDraftPayload(
      isImage: false,
      text: text,
      title: event.rawTitle,
      actor: event.rawActor,
    );
  }

  /// 自动重试所有到期草稿(联网恢复/登录就绪/周期触发)。
  /// 返回重跑的事件数。并发触发用简单互斥挡掉。
  bool _draftRetryRunning = false;
  Future<int> retryDueDrafts({int limit = 10}) async {
    if (_draftRetryRunning) return 0;
    _draftRetryRunning = true;
    try {
      final store = _eventStore;
      if (store == null) return 0;
      final drafts = await store.dueDrafts(limit: limit);
      var replayed = 0;
      for (final event in drafts) {
        final payload = AutoBookDraftPayload.fromJson(event.draftPayloadJson);
        if (payload == null) {
          await store.clearDraft(event.id);
          continue;
        }
        final replayed0 = await _replayDraft(event, payload);
        if (replayed0) replayed++;
      }
      if (drafts.isNotEmpty) {
        logger.info('AutoBilling', '离线草稿自动重试完成', 'due=${drafts.length}, replayed=$replayed');
      }
      return replayed;
    } catch (e) {
      logger.warning('AutoBilling', '离线草稿自动重试失败: $e');
      return 0;
    } finally {
      _draftRetryRunning = false;
    }
  }

  /// 按事件原通道重跑识别(coordinator 复用同一 eventKey 幂等)。
  Future<bool> _replayDraft(AutoBookEvent event, AutoBookDraftPayload payload) async {
    final key = event.eventKey;
    switch (event.source) {
      case 'screenshot':
      case 'sharedImage':
        final path = payload.imagePath ?? '';
        if (path.isEmpty || !File(path).existsSync()) {
          // 原图已被清理,无法重跑:清草稿,用户可在草稿列表刷新后看到它消失
          await _eventStore?.clearDraft(event.id);
          return false;
        }
        await processScreenshot(path, showNotification: true, eventKey: key);
        return true;
      case 'sms':
        await processSms(
          payload.actor ?? event.rawActor ?? '',
          payload.text ?? event.rawText ?? '',
          showNotification: true,
          skipDedup: true,
          eventKey: key,
        );
        return true;
      case 'notification':
        await processNotification(
          payload.actor ?? event.rawActor ?? '',
          payload.title ?? event.rawTitle ?? '',
          payload.text ?? event.rawText ?? '',
          showNotification: true,
          skipDedup: true,
          eventKey: key,
        );
        return true;
      case 'screenText':
        await processScreenText(
          payload.actor ?? event.rawActor ?? '',
          payload.text ?? event.rawText ?? '',
          showNotification: true,
          skipDedup: true,
          eventKey: key,
        );
        return true;
      default:
        // deepLinkText / 其它文本通道
        final text = payload.text ?? event.rawText ?? '';
        if (text.isEmpty) {
          await _eventStore?.clearDraft(event.id);
          return false;
        }
        await processTextResult(text, showNotification: true, eventKey: key);
        return true;
    }
  }

  /// 将统一结果映射为队列可理解的状态。失败优先于 pending，避免部分
  /// 成功时把尚未落库的账单误当作已完成；saved transaction 会在调用方先做
  /// post-process，下一次 retry 再由语义去重兜底。
  SmsProcessOutcome _outcomeForResult(BookkeepingResult result) {
    if (result.failedCount > 0 || result.retryable) {
      return SmsProcessOutcome.failed;
    }
    if (result.awaitingCount > 0) return SmsProcessOutcome.pending;
    if (result.shadowCount > 0) return SmsProcessOutcome.shadow;
    if (result.success) return SmsProcessOutcome.success;
    if (result.duplicateCount > 0) return SmsProcessOutcome.duplicate;
    return SmsProcessOutcome.noTransaction;
  }

  /// 核心:处理支付通知文本并自动记账(通知监听)。
  ///
  /// 与 [processSms] 流程一致(native 过滤 → 指纹二次去重 → fromText),
  /// 差异:指纹命名空间独立、正文为通知 title+text 合并、billingTypes 带
  /// notification 标签。处理前先标记指纹:进程被杀宁可丢一笔不重复入账。
  Future<SmsProcessOutcome> processNotification(
    String pkg,
    String title,
    String body, {
    bool showNotification = true,
    bool skipDedup = false,
    String? eventKey,
  }) async {
    final fingerprint = notifyFingerprint(pkg, title, body);

    if (!skipDedup && _isNotifyProcessed(fingerprint)) {
      logger.debug('AutoBilling', '通知指纹已处理过,跳过', fingerprint);
      return SmsProcessOutcome.duplicate;
    }

    const notificationId = 1004;
    const resultNotificationId = 1104;
    final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);

    try {
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.text)) {
        // 不标记:队列项保留,AI 配置后下次启动补记
        logger.warning('AutoBilling', 'AI text 未配置,通知保留待补记');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: l10n.aiNotConfiguredNotificationTitle,
            body: l10n.aiNotConfiguredNotificationBody,
          );
        }
        return SmsProcessOutcome.noAiConfigured;
      }

      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: l10n.autoNotifyBillingRecognizingTitle,
          body: l10n.autoNotifyBillingAnalyzingBody,
        );
      }

      final ledgerId = await _resolveLedgerId();
      if (ledgerId == null) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoLedgerTitle,
            body: l10n.autoBillingNotifyNoLedgerBody,
          );
        }
        return SmsProcessOutcome.failed;
      }

      // M4:通知包名 → 渠道名,同样注入文本先验 + 账户映射回退
      final channel = SourceChannelResolver.channelForPackage(pkg);
      final rawText = title.trim().isEmpty ? body : '$title\n$body';
      final text = SourceChannelResolver.withSourcePrefix(channel, rawText);
      final result = await _container.read(aiBookkeeperProvider).fromText(
            text: text,
            ledgerId: ledgerId,
            billingTypes: const [
              TagSeedService.billingTypeNotification,
              TagSeedService.billingTypeAi,
            ],
            billGuard: PromptBuilder.billGuardForNotification,
            l10n: l10n,
            autoBookFlow: await _autoBookFlow(eventKey: eventKey),
            source: 'notification',
            sourceChannel: channel,
            evidenceText: rawText,
          );

      if (result.success) {
        _container.read(statsRefreshProvider.notifier).state++;
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
        await _syncBillingToAiChat(result);
      }

      final outcome = _outcomeForResult(result);
      if (outcome == SmsProcessOutcome.noTransaction) {
        await _markNotifyProcessed(fingerprint);
        logger.info('AutoBilling', '通知非交易,已丢弃');
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoBillTitle,
            body: l10n.autoBillingNotifyNoBillBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.failed) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.pending ||
          outcome == SmsProcessOutcome.duplicate ||
          outcome == SmsProcessOutcome.shadow) {
        await _markNotifyProcessed(fingerprint);
        // P0-3:待确认必反馈(此前通知路候选静默入队)
        if (outcome == SmsProcessOutcome.pending) {
          await _notifyPendingCandidates('notification', result);
        }
        // P1-1:强判重合并轻通知
        await _notifyMergedCandidates(result);
        logger.info('AutoBilling', '通知已处理但未新建交易', outcome.name);
        return outcome;
      }

      await _markNotifyProcessed(fingerprint);
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: _successTitle(result, l10n),
          body: _successBody(result, l10n),
        );
      }
      logger.info('AutoBilling', '通知自动记账成功',
          'ids=${result.transactionIds}, 总金额=${result.totalAbsAmount}');
      return SmsProcessOutcome.success;
    } catch (e) {
      logger.error('AutoBilling', '通知处理失败', e);
      if (_isTransientAiError(e)) {
        await _saveDraftForEvent(
            eventKey,
            AutoBookDraftPayload(
                isImage: false, text: body, title: title, actor: pkg));
      }
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: l10n.autoBillingNotifyProcessFailedTitle,
          body: l10n.autoBillingNotifyProcessFailedBody(e.toString()),
        );
      }
      return SmsProcessOutcome.failed;
    }
  }

  /// 核心:处理账单详情页屏幕文本并自动记账(屏幕文本监听)。
  ///
  /// 与 [processNotification] 流程一致(native 过滤 → 指纹二次去重 →
  /// fromText),差异:指纹命名空间独立、正文为无障碍抓取的页面文本
  /// (含 UI 噪音,由 AI 守卫判定)、billingTypes 带 screen 标签。
  /// 处理前先标记指纹:进程被杀宁可丢一笔不重复入账。
  Future<SmsProcessOutcome> processScreenText(
    String pkg,
    String text, {
    bool showNotification = true,

    /// 最小打扰模式:进入页面触发识别时静默,只在「识别完成且成功入账」时通知;
    /// 非交易/失败/已去重一律不通知(与截图自动监听 notifyOnlyOnSuccess 一致)。
    bool notifyOnlyOnSuccess = true,

    /// 「AI text 未配置」引导提示(必要的一次性引导,不由 notifyOnlyOnSuccess
    /// 静默;是否提示由调用方用会话级去重控制)。
    bool notifyAiUnconfigured = true,
    bool skipDedup = false,
    String? eventKey,
  }) async {
    final fingerprint = screenTextFingerprint(pkg, text);

    if (!skipDedup && _isScreenTextProcessed(fingerprint)) {
      logger.debug('AutoBilling', '屏幕文本指纹已处理过,跳过', fingerprint);
      return SmsProcessOutcome.duplicate;
    }

    const notificationId = 1005;
    const resultNotificationId = 1105;
    final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);

    try {
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.text)) {
        // 不标记:队列项保留,AI 配置后下次启动补记
        logger.warning('AutoBilling', 'AI text 未配置,屏幕文本保留待补记');
        if (notifyAiUnconfigured) {
          await _showNotification(
            id: notificationId,
            title: l10n.aiNotConfiguredNotificationTitle,
            body: l10n.aiNotConfiguredNotificationBody,
          );
        }
        return SmsProcessOutcome.noAiConfigured;
      }

      if (showNotification && !notifyOnlyOnSuccess) {
        await _showNotification(
          id: notificationId,
          title: l10n.autoScreenBillingRecognizingTitle,
          body: l10n.autoScreenBillingAnalyzingBody,
        );
      }

      final ledgerId = await _resolveLedgerId();
      if (ledgerId == null) {
        if (showNotification) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoBillingNotifyNoLedgerTitle,
            body: l10n.autoBillingNotifyNoLedgerBody,
          );
        }
        return SmsProcessOutcome.failed;
      }

      // M4:检测到页面包名 → 渠道名,注入文本先验 + 账户映射回退
      final channel = SourceChannelResolver.channelForPackage(pkg);
      final textWithSource =
          SourceChannelResolver.withSourcePrefix(channel, text);
      // 账单级去重:同一账单(渠道+金额+备注+日期)已入账过则跳过;
      // 落库成功后回填指纹,跨会话生效。
      final channelKey = channel ?? pkg;
      final result = await _container.read(aiBookkeeperProvider).fromText(
            text: textWithSource,
            ledgerId: ledgerId,
            billingTypes: const [
              TagSeedService.billingTypeScreen,
              TagSeedService.billingTypeAi,
            ],
            billGuard: PromptBuilder.billGuardForScreen,
            l10n: l10n,
            autoBookFlow: await _autoBookFlow(eventKey: eventKey),
            source: 'screen',
            sourceChannel: channel,
            evidenceText: text,
            skipIfProcessed: (bill) async {
              final amount = bill.amount;
              if (amount == null || amount.abs() <= 0) return false;
              final fp = billFingerprint(
                channel: channelKey,
                amount: amount,
                note: bill.note,
                time: bill.time,
              );
              return _isBillProcessed(fp);
            },
          );

      // 入账成功的笔,把账单级指纹持久化(避免下次进同一详情页重复入账)。
      if (result.failedCount == 0) {
        for (final bill in result.savedBills) {
          final amount = bill.amount;
          if (amount == null || amount.abs() <= 0) continue;
          final fp = billFingerprint(
            channel: channelKey,
            amount: amount,
            note: bill.note,
            time: bill.time,
          );
          if (!_isBillProcessed(fp)) {
            _processedBillFingerprints.add(fp);
          }
        }
      }

      if (_processedBillFingerprints.length >
          AutoBillingConfig.maxProcessedCache) {
        final toRemove = _processedBillFingerprints.length -
            AutoBillingConfig.maxProcessedCache;
        _processedBillFingerprints
            .removeAll(_processedBillFingerprints.take(toRemove));
      }
      await _saveProcessedBillFingerprints();

      if (result.success) {
        _container.read(statsRefreshProvider.notifier).state++;
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
        await _syncBillingToAiChat(result);
      }

      final outcome = _outcomeForResult(result);
      if (outcome == SmsProcessOutcome.noTransaction) {
        await _markScreenTextProcessed(fingerprint);
        logger.info('AutoBilling', '屏幕文本非交易页面,已丢弃');
        if (showNotification && !notifyOnlyOnSuccess) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoScreenBillingNoBillTitle,
            body: l10n.autoScreenBillingNoBillBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.failed) {
        if (showNotification && !notifyOnlyOnSuccess) {
          await _showFinalNotification(
            progressId: notificationId,
            finalId: resultNotificationId,
            title: l10n.autoScreenBillingRecognizeFailedTitle,
            body: l10n.autoBillingNotifyRecognizeFailedBody,
          );
        }
        return outcome;
      }
      if (outcome == SmsProcessOutcome.pending ||
          outcome == SmsProcessOutcome.duplicate ||
          outcome == SmsProcessOutcome.shadow) {
        await _markScreenTextProcessed(fingerprint);
        // P0-3:待确认必反馈(此前屏幕文本路候选静默入队)
        if (outcome == SmsProcessOutcome.pending) {
          await _notifyPendingCandidates('screenText', result);
        }
        // P1-1:强判重合并轻通知
        await _notifyMergedCandidates(result);
        logger.info('AutoBilling', '屏幕文本已处理但未新建交易', outcome.name);
        return outcome;
      }

      await _markScreenTextProcessed(fingerprint);
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: _successTitle(result, l10n),
          body: _successBody(result, l10n),
        );
      }
      logger.info('AutoBilling', '屏幕文本自动记账成功',
          'ids=${result.transactionIds}, 总金额=${result.totalAbsAmount}');
      return SmsProcessOutcome.success;
    } catch (e) {
      logger.error('AutoBilling', '屏幕文本处理失败', e);
      if (_isTransientAiError(e)) {
        await _saveDraftForEvent(eventKey,
            AutoBookDraftPayload(isImage: false, text: text, actor: pkg));
      }
      if (showNotification) {
        await _showFinalNotification(
          progressId: notificationId,
          finalId: resultNotificationId,
          title: l10n.autoScreenBillingProcessFailedTitle,
          body: l10n.autoBillingNotifyProcessFailedBody(e.toString()),
        );
      }
      return SmsProcessOutcome.failed;
    }
  }

  Future<void> _markScreenTextProcessed(String fingerprint) async {
    _processedScreenTextFingerprints.add(fingerprint);
    await _saveProcessedScreenTextFingerprints();
  }

  // ------------------------------------------------------------
  // 账单级去重:渠道|金额|备注|交易日期 → 指纹,跨页面文本/跨会话。
  // 页面文本指纹 sha256(pkg|text) 依赖「页面文本完全一致」,列表页动态内容
  // (时间/推荐位/广告)一变就会失效;账单级指纹按业务要素去重,同一账单隔天
  // 再进详情页也不会重复入账。
  // ------------------------------------------------------------

  Future<void> _loadProcessedBillFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_processedBillFingerprintsKey) ?? [];
      _processedBillFingerprints.addAll(list);
      if (_processedBillFingerprints.length >
          AutoBillingConfig.maxProcessedCache) {
        final toRemove = _processedBillFingerprints.length -
            AutoBillingConfig.maxProcessedCache;
        _processedBillFingerprints
            .removeAll(_processedBillFingerprints.take(toRemove));
        await _saveProcessedBillFingerprints();
      }
    } catch (_) {}
  }

  Future<void> _saveProcessedBillFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _processedBillFingerprintsKey, _processedBillFingerprints.toList());
  }

  bool _isBillProcessed(String fingerprint) =>
      _processedBillFingerprints.contains(fingerprint);

  /// 账单级指纹:sha256(渠道|金额|备注|交易日期) 前 16 位。
  /// 金额用绝对值(收/支同额不同向不误判)、日期用 yyyy-MM-dd(去掉时分秒,
  /// 避免同一账单在不同时刻进入详情页时日期抖动)。
  static String billFingerprint({
    required String channel,
    required double amount,
    required String? note,
    required DateTime? time,
  }) {
    final date = time == null
        ? ''
        : '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    final normalizedNote = (note ?? '').trim();
    return sha256
        .convert(utf8.encode(
            '$channel|${amount.abs().toStringAsFixed(2)}|$normalizedNote|$date'))
        .toString()
        .substring(0, 16);
  }

  Future<void> _markNotifyProcessed(String fingerprint) async {
    _processedNotifyFingerprints.add(fingerprint);
    await _saveProcessedNotifyFingerprints();
  }

  /// 把自动记账结果同步到 AI 助手消息记录(「同步消息记录」方案)。
  ///
  /// 与对话页不同:这里是**后台无 UI** 路径,没有页面持有的
  /// `currentConversationId`,所以取**全局活跃对话**(`getActiveConversation`),
  /// 无则创建一条名为「自动记账」的对话。写入一条 `bill_card` 系统消息,复用
  /// 对话页已有的 `{bills, txIds, undoneIds}` metadata 格式,因此自动记账的
  /// 卡片在 AI 助手页同样支持撤销/编辑/改账本。
  ///
  /// 隐私:只写摘要/金额/商户,不写短信/通知/页面文本的**原始正文**。
  /// 失败只记日志,**不进主流程**——消息同步是展示性增强,不能因它中断记账。
  Future<void> _syncBillingToAiChat(BookkeepingResult result) async {
    final repo = _container.read(repositoryProvider);
    try {
      var conv = await repo.getActiveConversation();
      if (conv == null) {
        final id = await repo.createConversation(
          ConversationsCompanion.insert(
            title: const Value('自动记账'),
            createdAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
        conv = await repo.getConversationById(id);
        if (conv == null) return;
      }

      final bills = result.savedBills;
      final txIds = result.transactionIds;
      if (bills.isEmpty || txIds.isEmpty) return;

      final n = bills.length;
      final base = n == 1 ? '✅ 记账成功' : '✅ 已记账 $n 笔';
      final note = result.unconvertedCurrencies.isEmpty
          ? null
          : '多币种:部分外币按 1:1 暂记,请到统计页补折算';
      final text = note == null ? base : '$base\n$note';

      await repo.createMessage(
        MessagesCompanion.insert(
          conversationId: conv.id,
          role: 'assistant',
          content: text,
          messageType: 'bill_card',
          metadata: Value(jsonEncode({
            'bills': bills.map((b) => b.toJson()).toList(),
            'txIds': txIds,
            'undoneIds': <int>[],
          })),
          transactionId: Value(txIds.first),
          createdAt: Value(DateTime.now()),
        ),
      );
      logger.debug('AutoBilling', '已同步自动记账到 AI 会话',
          'conversationId=${conv.id}, txIds=$txIds');
    } catch (e, st) {
      logger.error('AutoBilling', '同步自动记账到 AI 会话失败(不影响记账)', e, st);
    }
  }

  /// 通知标题统一格式
  String _successTitle(BookkeepingResult result, AppLocalizations l10n) {
    if (result.isMulti) {
      return l10n.autoBillingNotifySuccessMultiTitle(result.savedCount);
    }
    return l10n.autoBillingNotifySuccessSingleTitle(
        result.totalAbsAmount.toStringAsFixed(2));
  }

  /// 通知正文统一格式
  String _successBody(BookkeepingResult result, AppLocalizations l10n) {
    if (result.isMulti) {
      return l10n.autoBillingNotifySuccessMultiBody(
          result.totalAbsAmount.toStringAsFixed(2));
    }
    final note = result.firstBill?.note;
    return (note != null && note.isNotEmpty)
        ? l10n.autoBillingNotifySuccessSingleBodyNote(note)
        : l10n.autoBillingNotifySuccessSingleBodyDefault;
  }

  // ------------------------------------------------------------
  // 待确认候选通知(P0-3):候选入队曾四路全静默,用户几天后才发现积压。
  // 必反馈,但正文只含金额与笔数(与成功通知口径一致,不含商户名/原始
  // 短信/通知/页面文本);独立通知 channel,可在系统设置单独关。
  // 同一来源 10 分钟窗口内聚合计数,同一通知 ID 累加更新,不逐条轰炸。
  // 自身通知已由 native NotificationWatcher 按包名过滤,无自反馈循环。
  // ------------------------------------------------------------

  /// 每来源的聚合状态(内存态;进程重启最多导致多弹一条,可接受)
  static final Map<String, ({DateTime firstAt, int count, double amount})>
      _pendingNotifyState = {};

  static const _pendingNotifyIds = {
    'screenshot': 1201,
    'image': 1201,
    'sms': 1202,
    'notification': 1203,
    'screenText': 1204,
  };

  /// 四路产生 pending 候选时调用;awaitingCount=0 时为 no-op。
  Future<void> _notifyPendingCandidates(
    String source,
    BookkeepingResult result,
  ) async {
    final n = result.awaitingCount;
    if (n <= 0) return;
    final now = DateTime.now();
    final prev = _pendingNotifyState[source];
    final state = (prev != null && now.difference(prev.firstAt).inMinutes < 10)
        ? (
            firstAt: prev.firstAt,
            count: prev.count + n,
            amount: prev.amount + result.pendingAbsAmount,
          )
        : (firstAt: now, count: n, amount: result.pendingAbsAmount);
    _pendingNotifyState[source] = state;

    final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);
    const androidDetails = AndroidNotificationDetails(
      'auto_book_pending',
      '待确认提醒',
      channelDescription: '自动记账进入待确认队列时的提醒(只含金额与笔数)',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _notificationsPlugin.show(
        _pendingNotifyIds[source] ?? 1209,
        l10n.autoBillingNotifyPendingTitle,
        l10n.autoBillingNotifyPendingBody(
            state.count, state.amount.toStringAsFixed(2)),
        details,
      );
    } catch (e) {
      logger.warning('AutoBilling', '待确认通知发送失败(不中断记账): $e');
    }
  }

  /// 强判重合并轻通知(P1-1):强语义(≥0.92)合并曾完全静默,真实消费被吞
  /// 用户毫无感知。正文只含目标交易日期/金额/笔数(不含商户名,与 §6 隐私
  /// 口径一致);撤销入口在自动记账历史详情页。
  Future<void> _notifyMergedCandidates(BookkeepingResult result) async {
    final ids = result.duplicateTransactionIds;
    if (result.duplicateCount <= 0 || ids.isEmpty) return;
    String dateLabel = '';
    String amountLabel = '';
    try {
      final tx =
          await _container.read(repositoryProvider).getTransactionById(ids.first);
      if (tx != null) {
        dateLabel = '${tx.happenedAt.month}/${tx.happenedAt.day}';
        amountLabel = tx.amount.abs().toStringAsFixed(2);
      }
    } catch (e) {
      logger.debug('AutoBilling', '查询判重目标交易失败,跳过合并通知', '$e');
      return;
    }
    if (dateLabel.isEmpty) return;

    final l10n = lookupAppLocalizations(PlatformDispatcher.instance.locale);
    const androidDetails = AndroidNotificationDetails(
      'auto_book_merge',
      '判重合并提醒',
      channelDescription: '强语义判重合并到已有交易时的轻提醒',
      importance: Importance.low,
      priority: Priority.low,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _notificationsPlugin.show(
        1251,
        l10n.autoBillingNotifyMergeTitle,
        l10n.autoBillingNotifyMergeBody(
            result.duplicateCount, dateLabel, amountLabel),
        details,
      );
    } catch (e) {
      logger.warning('AutoBilling', '合并通知发送失败(不中断记账): $e');
    }
  }

  /// 显示通知。
  ///
  /// 通知失败**绝不向外抛**:通知只是进度提示,记账主流程不能因它中断。
  /// iOS 27 起对未授权通知的应用调 show() 会抛 PlatformException(Error 2003,
  /// "Source is not authorized"),而 iOS ≤26 同场景是静默不弹 —— 不隔离的话
  /// 截图还没进 AI 识别就在"开始识别"通知处整链失败(#322)。
  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'screenshot_ocr',
      '截图识别',
      channelDescription: '截图自动识别通知',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      await _notificationsPlugin.show(id, title, body, details);
    } catch (e) {
      logger.warning('AutoBilling', '通知发送失败(未授权通知时属预期,不中断记账流程): $e');
    }
  }

  /// 显示「最终结果」通知。
  ///
  /// iOS 上,**用同一 ID 重复 `show()` 只会静默更新通知中心条目,不会重新弹
  /// banner**。所以「正在识别 → 成功/失败」如果共用 ID,用户只能看到第一条
  /// banner,直到进通知中心才看到结果。
  ///
  /// 这个方法用**新 ID** 发结果通知,iOS 把它当作新通知重新弹 banner。
  /// 不 cancel 旧的「正在识别」—— 实测在 AppIntent background-launch 状态下
  /// cancel + show 紧挨着的组合 iOS 会把它当成一次「替换」处理,banner 不弹;
  /// 留着旧的反而能保证新的作为独立通知正常弹出(旧的在结果通知出现后用户可自
  /// 行清理或自然过期)。
  Future<void> _showFinalNotification({
    required int progressId,
    required int finalId,
    required String title,
    required String body,
  }) async {
    await _showNotification(id: finalId, title: title, body: body);
  }

  /// 释放资源(AI 服务无 native handle,不需要 dispose,保留方法以备后续添加)
  void dispose() {}
}
