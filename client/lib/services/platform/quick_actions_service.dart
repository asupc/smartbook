import 'dart:ui';
import 'package:quick_actions/quick_actions.dart';

import '../../l10n/app_localizations.dart';
import '../system/logger_service.dart';
import 'app_link_service.dart';

/// 快捷操作服务
///
/// 处理 iOS 和 Android 的长按图标快捷操作
/// 支持以下操作：
/// - 图片记账（从相册选择）
/// - 拍照记账
/// - 语音记账
/// - AI 小助手
class QuickActionsService {
  static const String _tag = 'QuickActions';

  /// 快捷操作类型常量
  static const String actionImage = 'action_image';
  static const String actionCamera = 'action_camera';
  static const String actionVoice = 'action_voice';
  static const String actionAiChat = 'action_ai_chat';

  final QuickActions _quickActions = const QuickActions();

  /// 导航回调，由外部设置
  void Function(AppLinkAction action)? onNavigate;

  /// 待处理的快捷操作（应用冷启动时）
  String? _pendingAction;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化快捷操作服务
  void initialize() {
    if (_isInitialized) {
      logger.warning(_tag, '服务已初始化，跳过');
      return;
    }

    logger.info(_tag, '初始化快捷操作服务');

    _quickActions.initialize((String shortcutType) {
      logger.info(_tag, '收到快捷操作: $shortcutType');
      _handleShortcut(shortcutType);
    });

    _isInitialized = true;

    // 设置快捷操作项
    _setupShortcutItems();
  }

  /// 设置快捷操作项
  Future<void> _setupShortcutItems() async {
    try {
      // 获取系统语言的 l10n
      final systemLocale = PlatformDispatcher.instance.locale;
      final l10n = lookupAppLocalizations(systemLocale);

      // iOS 使用 xcassets 中的图标，Android 使用 drawable 资源
      // 两个平台使用相同的图标名称
      final items = <ShortcutItem>[
        ShortcutItem(
          type: actionImage,
          localizedTitle: l10n.quickActionImage,
          icon: 'ic_quick_image',
        ),
        ShortcutItem(
          type: actionCamera,
          localizedTitle: l10n.quickActionCamera,
          icon: 'ic_quick_camera',
        ),
        ShortcutItem(
          type: actionVoice,
          localizedTitle: l10n.quickActionVoice,
          icon: 'ic_quick_voice',
        ),
        ShortcutItem(
          type: actionAiChat,
          localizedTitle: l10n.quickActionAiChat,
          icon: 'ic_quick_ai',
        ),
      ];

      await _quickActions.setShortcutItems(items);
      logger.info(_tag, '快捷操作项已设置: ${items.length} 个');
    } catch (e) {
      // iOS 模拟器可能不支持快捷操作，忽略错误
      logger.warning(_tag, '设置快捷操作项失败（模拟器可能不支持）: $e');
    }
  }

  /// 处理快捷操作
  void _handleShortcut(String shortcutType) {
    final action = _parseAction(shortcutType);

    if (action == null) {
      logger.warning(_tag, '未知的快捷操作类型: $shortcutType');
      return;
    }

    if (onNavigate != null) {
      logger.info(_tag, '执行导航: $action');
      onNavigate!(action);
    } else {
      // 如果导航回调尚未设置，保存待处理的操作
      logger.info(_tag, '导航回调未设置，保存待处理操作: $shortcutType');
      _pendingAction = shortcutType;
    }
  }

  /// 解析快捷操作类型
  AppLinkAction? _parseAction(String shortcutType) {
    switch (shortcutType) {
      case actionImage:
        return AppLinkAction.image;
      case actionCamera:
        return AppLinkAction.camera;
      case actionVoice:
        return AppLinkAction.voice;
      case actionAiChat:
        return AppLinkAction.aiChat;
      default:
        return null;
    }
  }

  /// 处理待处理的快捷操作
  /// 应在导航回调设置后调用
  void processPendingAction() {
    if (_pendingAction != null && onNavigate != null) {
      logger.info(_tag, '处理待处理的快捷操作: $_pendingAction');
      _handleShortcut(_pendingAction!);
      _pendingAction = null;
    }
  }

  /// 清除快捷操作项
  Future<void> clearShortcutItems() async {
    await _quickActions.clearShortcutItems();
    logger.info(_tag, '快捷操作项已清除');
  }
}
