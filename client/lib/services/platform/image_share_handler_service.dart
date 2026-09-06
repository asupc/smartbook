import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../automation/auto_billing_service.dart';
import '../automation/auto_book_coordinator.dart';
import '../automation/auto_book_event.dart';
import '../../providers/automation_providers.dart';
import '../system/logger_service.dart';

/// 图片分享处理服务（Android专用）
/// 处理从相册或其他应用分享过来的图片，并调用AutoBillingService进行OCR识别和记账
class ImageShareHandlerService {
  static const _channel = MethodChannel('com.smartbook.zhi/share');

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  // 单例模式
  static ImageShareHandlerService? _instance;

  factory ImageShareHandlerService(ProviderContainer container) {
    _instance ??= ImageShareHandlerService._internal(container);
    return _instance!;
  }

  ImageShareHandlerService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  /// 设置方法调用处理器
  void _setupMethodCallHandler() {
    logger.info('ImageShare', '初始化图片分享处理器');
    _channel.setMethodCallHandler((call) async {
      logger.info('ImageShare', '收到方法调用: ${call.method}');
      if (call.method == 'onImageShared') {
        final path = call.arguments as String;
        logger.info('ImageShare', '收到分享的图片，路径: $path');
        await _handleSharedImage(path);
      }
    });
  }

  /// 处理分享的图片
  Future<void> _handleSharedImage(String path) async {
    logger.info('ImageShare', '开始处理分享的图片: $path');

    try {
      // 只在 Android 平台处理
      if (!Platform.isAndroid) {
        logger.warning('ImageShare', '图片分享仅支持 Android 平台');
        return;
      }

      final eventKey = await _coordinator.imageEventKey(path);
      final execution = await _coordinator.execute(
        input: AutoBookInput(
          eventKey: eventKey,
          source: AutoBookSource.sharedImage,
          captureIntent: AutoBookCaptureIntent.userInitiated,
          capturedAt: DateTime.now(),
          contentHash: eventKey.startsWith('image:v1:')
              ? eventKey.substring('image:v1:'.length)
              : null,
        ),
        action: () => _autoBillingService.processScreenshot(
          path,
          showNotification: true,
          eventKey: eventKey,
        ),
        // M1-3:走向映射收敛到 BookkeepingResultEvent(与截图/deep-link 共用)。
        updateFor: (result) => result.eventUpdate,
      );
      if (execution.skipped) {
        logger.info('ImageShare', '分享图片内容已被事件幂等拦截');
        return;
      }
      logger.info('ImageShare', '图片处理完成');
    } catch (e, stackTrace) {
      logger.error('ImageShare', '处理分享图片失败', e, stackTrace);
    }
  }

  /// 释放资源
  void dispose() {
    _autoBillingService.dispose();
  }
}
