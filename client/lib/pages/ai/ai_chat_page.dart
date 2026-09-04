import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:image_picker/image_picker.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/biz/smartbook_icon.dart';
import '../../widgets/ai/typewriter_text.dart';
import '../../widgets/ai/bill_card_widget.dart';
import '../../widgets/ai/ai_quick_commands_bar.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../utils/voice_billing_helper.dart';
import '../../services/billing/post_processor.dart';
import '../../services/ai/bookkeeping_result.dart';
import '../../services/attachment_service.dart';
import '../../services/data/tag_seed_service.dart';
import '../../ai/core/prompt_builder.dart';
import '../../ai/providers/ai_provider_config.dart';
import '../../ai/providers/ai_provider_manager.dart';
import '../../providers.dart';
import '../../providers/ai_chat_providers.dart';
import '../../ai/core/bill_info.dart';
import '../../pages/transaction/transaction_editor_page.dart';
import '../../pages/ai/ai_settings_page.dart';
import '../../widgets/biz/ledger_selector_dialog.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../models/ai_quick_command.dart';
import '../../services/ui/avatar_service.dart';
import '../../services/system/logger_service.dart';
import '../../services/ai/ai_chat_service.dart';
import '../../services/ai/ai_quick_command_service.dart';

/// AI 对话页面
class AIChatPage extends ConsumerStatefulWidget {
  const AIChatPage({super.key});

  @override
  ConsumerState<AIChatPage> createState() => _AIChatPageState();
}

class _AIChatPageState extends ConsumerState<AIChatPage>
    with WidgetsBindingObserver {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int? _conversationId;
  bool _isLoading = false;
  int? _animatingMessageId; // 正在播放动画的消息ID
  String? _userAvatarPath; // 用户头像路径
  AIConfigValidationResult? _apiValidation; // API配置验证结果
  bool _showScrollToBottom = false; // 是否显示"回到底部"按钮
  bool _isFirstLoad = true; // 是否首次加载

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initConversation();
    _loadUserAvatar();
    // 在下一帧后执行 API 验证，完全不阻塞页面渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _validateApiConfig();
    });
    _scrollController.addListener(_handleScroll);
  }

  /// 处理滚动事件
  void _handleScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final scrollOffset = position.pixels;
    final maxScroll = position.maxScrollExtent;

    // 列表可滚动 且 距离底部超过50像素时显示按钮
    final shouldShow = maxScroll > 0 && (maxScroll - scrollOffset) > 50;

    if (shouldShow != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = shouldShow;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 当应用从后台恢复到前台时，重新验证API配置
    if (state == AppLifecycleState.resumed) {
      _validateApiConfig();
    }
  }

  /// 验证 API 配置（仅检查本地配置，不发网络请求）
  Future<void> _validateApiConfig() async {
    try {
      final result = await AIChatService.validateApiKey();
      if (!mounted) return;
      setState(() => _apiValidation = result);
    } catch (e, st) {
      logger.error('AIChat', 'API 配置检查失败', e, st);
      if (!mounted) return;
      setState(() {
        _apiValidation = AIConfigValidationResult.invalid('配置检查失败');
      });
    }
  }

  Future<void> _loadUserAvatar() async {
    final path = await AvatarService.getAvatarPath();
    if (mounted) {
      setState(() {
        _userAvatarPath = path;
      });
    }
  }

  Future<void> _initConversation() async {
    final repo = ref.read(repositoryProvider);

    // 查找全局活跃对话（不限制账本）
    final conv = await repo.getActiveConversation();

    if (conv != null) {
      setState(() => _conversationId = conv.id);
    } else {
      // 创建新对话（全局对话，不关联账本）
      final id = await repo.createConversation(
        ConversationsCompanion.insert(
          title: const Value('AI对话'),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      setState(() => _conversationId = id);
    }

    ref.read(currentConversationIdProvider.notifier).state = _conversationId;
  }

  @override
  Widget build(BuildContext context) {
    if (_conversationId == null) {
      return Scaffold(
        backgroundColor: BeeTokens.scaffoldBackground(context),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final messagesAsync = ref.watch(messagesProvider(_conversationId!));

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          // Header
          PrimaryHeader(
            title: AppLocalizations.of(context).aiChatTitle,
            showBack: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: AppLocalizations.of(context).aiChatClearHistory,
                onPressed: _showClearHistoryDialog,
              ),
            ],
          ),

          // API配置警告横幅
          if (_apiValidation != null && !_apiValidation!.isValid)
            Container(
              margin: EdgeInsets.symmetric(
                horizontal: 12.0.scaled(context, ref),
                vertical: 8.0.scaled(context, ref),
              ),
              padding: EdgeInsets.all(12.0.scaled(context, ref)),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8.0.scaled(context, ref)),
                border: Border.all(
                  color: Colors.red.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.red[700],
                    size: 20.0.scaled(context, ref),
                  ),
                  SizedBox(width: 8.0.scaled(context, ref)),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).aiChatConfigWarning,
                      style: TextStyle(
                        color: Colors.red[700],
                        fontSize: 13.0.scaled(context, ref),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AISettingsPage(),
                        ),
                      );
                      // 返回后重新验证
                      if (mounted) {
                        await _validateApiConfig();
                      }
                    },
                    child: Text(
                      AppLocalizations.of(context).aiChatGoToSettings,
                      style: TextStyle(
                        color: ref.watch(primaryColorProvider),
                        fontSize: 13.0.scaled(context, ref),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 消息列表
          Expanded(
            child: Stack(
              children: [
                messagesAsync.when(
                  data: (messages) {
                    // 首次加载完成且有消息时，自动滚动到底部
                    if (_isFirstLoad && messages.isNotEmpty) {
                      _isFirstLoad = false;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _scrollToBottom();
                      });
                    }

                    if (messages.isEmpty) {
                      return const Center(child: Text('暂无消息'));
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.0.scaled(context, ref),
                        vertical: 8.0.scaled(context, ref),
                      ),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        return _buildMessageBubble(messages[index]);
                      },
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, st) => Center(child: Text('加载失败: $e')),
                ),

                // 回到底部按钮
                if (_showScrollToBottom)
                  Positioned(
                    right: 16.0.scaled(context, ref),
                    bottom: 16.0.scaled(context, ref),
                    child: Material(
                      color: ref.watch(primaryColorProvider),
                      borderRadius:
                          BorderRadius.circular(24.0.scaled(context, ref)),
                      elevation: 8,
                      shadowColor: Colors.black.withOpacity(0.4),
                      child: InkWell(
                        onTap: _scrollToBottomWithAnimation,
                        borderRadius:
                            BorderRadius.circular(24.0.scaled(context, ref)),
                        child: Container(
                          width: 48.0.scaled(context, ref),
                          height: 48.0.scaled(context, ref),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white,
                            size: 30.0.scaled(context, ref),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 加载指示器
          if (_isLoading)
            Container(
              padding: EdgeInsets.symmetric(
                vertical: 8.0.scaled(context, ref),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16.0.scaled(context, ref),
                    height: 16.0.scaled(context, ref),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        ref.watch(primaryColorProvider),
                      ),
                    ),
                  ),
                  SizedBox(width: 8.0.scaled(context, ref)),
                  Text(
                    AppLocalizations.of(context).aiChatThinking,
                    style: TextStyle(
                      color: BeeTokens.textSecondary(context),
                      fontSize: 13.0.scaled(context, ref),
                    ),
                  ),
                ],
              ),
            ),

          // 快捷指令横条
          AIQuickCommandsBar(
            onCommandTap: _handleQuickCommand,
          ),

          // 输入区域
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    final isUser = message.role == 'user';

    // 只对正在播放动画的消息ID启用动画
    final shouldAnimate = !isUser && message.id == _animatingMessageId;

    // 记账卡片
    if (message.messageType == 'bill_card' && message.metadata != null) {
      final parsed = _parseBillMetadata(message);

      // 单笔走原有 UI(保持视觉一致)
      if (parsed.bills.length == 1) {
        final bill = parsed.bills.first;
        final txId = parsed.txIds.isNotEmpty ? parsed.txIds.first : null;
        final isUndone = txId != null && parsed.undoneIds.contains(txId);
        return GestureDetector(
          onLongPressStart: (details) => _showBillCardMenu(
            details.globalPosition,
            message,
          ),
          child: BillCardWidget(
            billInfo: bill,
            transactionId: txId,
            isUndone: isUndone,
            onUndo: txId != null && !isUndone
                ? () => _handleUndoOne(message.id, txId)
                : null,
            onEdit: txId != null && !isUndone
                ? () => _handleEdit(message.id, txId)
                : null,
            onChangeLedger: txId != null && !isUndone
                ? () => _handleChangeLedger(message.id, txId)
                : null,
          ),
        );
      }

      // 多笔
      return _buildMultiBillBubble(message, parsed);
    }

    // 用户发送的图片消息(图片记账)
    if (message.messageType == 'image') {
      return _buildImageBubble(message);
    }

    // 用户语音记账消息
    if (message.messageType == 'voice') {
      return _buildVoiceBubble(message);
    }

    // 普通文字消息 - 带头像
    return Padding(
      padding: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          // AI头像（左侧）
          if (!isUser) ...[
            _buildAIAvatar(),
            SizedBox(width: 8.0.scaled(context, ref)),
          ],
          // 消息气泡
          Flexible(
            child: GestureDetector(
              onLongPressStart: (details) => _showTextMessageMenu(
                details.globalPosition,
                message,
                isUser,
              ),
              child: Container(
                margin: EdgeInsets.only(
                  left: isUser ? 60.0.scaled(context, ref) : 0,
                  right: isUser ? 0 : 60.0.scaled(context, ref),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: 12.0.scaled(context, ref),
                  vertical: 10.0.scaled(context, ref),
                ),
                decoration: BoxDecoration(
                  color: isUser
                      ? ref.watch(primaryColorProvider).withOpacity(0.1)
                      : BeeTokens.surface(context),
                  borderRadius:
                      BorderRadius.circular(12.0.scaled(context, ref)),
                  border: Border.all(
                    color: isUser
                        ? ref.watch(primaryColorProvider).withOpacity(0.3)
                        : BeeTokens.border(context),
                  ),
                ),
                child: TypewriterText(
                  text: message.content,
                  animate: shouldAnimate, // 只对标记的消息启用动画
                  onTextChange: shouldAnimate
                      ? () {
                          // 每次文本更新时滚动到底部
                          _scrollToBottomSmooth();
                        }
                      : null,
                  onComplete: shouldAnimate
                      ? () {
                          // 动画完成后清除标记
                          if (mounted) {
                            setState(() {
                              _animatingMessageId = null;
                            });
                          }
                        }
                      : null,
                  style: TextStyle(
                    color: BeeTokens.textPrimary(context),
                    fontSize: 14.0.scaled(context, ref),
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          // 用户头像（右侧，仅在有头像时显示）
          if (isUser && _userAvatarPath != null) ...[
            SizedBox(width: 8.0.scaled(context, ref)),
            _buildUserAvatar(),
          ],
        ],
      ),
    );
  }

  // 构建AI头像
  Widget _buildAIAvatar() {
    return Container(
      width: 32.0.scaled(context, ref),
      height: 32.0.scaled(context, ref),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ref.watch(primaryColorProvider).withOpacity(0.3),
          width: 1.5,
        ),
        color: ref.watch(primaryColorProvider).withOpacity(0.1),
      ),
      child: Center(
        child: SmartBookIcon(
          size: 18.0.scaled(context, ref),
        ),
      ),
    );
  }

  // 构建用户头像
  Widget _buildUserAvatar() {
    return Container(
      width: 32.0.scaled(context, ref),
      height: 32.0.scaled(context, ref),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: BeeTokens.border(context),
          width: 1,
        ),
      ),
      child: ClipOval(
        child: Image.file(
          File(_userAvatarPath!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // 加载失败时不显示
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  // ============================================================
  // 图片 / 语音消息气泡
  // ============================================================

  /// 用户图片消息气泡:展示原图缩略图(路径存 metadata.imagePath),
  /// 点击打开全屏大图(手势缩放/拖动查看)。
  Widget _buildImageBubble(Message message) {
    String? imagePath;
    try {
      if (message.metadata != null) {
        final meta = jsonDecode(message.metadata!) as Map<String, dynamic>;
        imagePath = meta['imagePath'] as String?;
      }
    } catch (_) {
      // metadata 解析失败按无图处理
    }

    final imageSize = 160.0.scaled(context, ref);
    final imageExists = imagePath != null && File(imagePath).existsSync();
    Widget imageWidget;
    if (imageExists) {
      imageWidget = Image.file(
        File(imagePath),
        width: imageSize,
        height: imageSize * 1.25,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildImageErrorBox(imageSize),
      );
    } else {
      imageWidget = _buildImageErrorBox(imageSize);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: GestureDetector(
              onLongPressStart: (details) => _showTextMessageMenu(
                  details.globalPosition, message, true),
              // 点击查看全图(文件存在时)
              onTap: imageExists ? () => _openFullImage(imagePath!) : null,
              child: Container(
                padding: EdgeInsets.all(6.0.scaled(context, ref)),
                decoration: BoxDecoration(
                  color: ref.watch(primaryColorProvider).withOpacity(0.1),
                  borderRadius:
                      BorderRadius.circular(12.0.scaled(context, ref)),
                  border: Border.all(
                    color: ref.watch(primaryColorProvider).withOpacity(0.3),
                  ),
                ),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(8.0.scaled(context, ref)),
                  child: imageWidget,
                ),
              ),
            ),
          ),
          if (_userAvatarPath != null) ...[
            SizedBox(width: 8.0.scaled(context, ref)),
            _buildUserAvatar(),
          ],
        ],
      ),
    );
  }

  /// 全屏查看发送给 AI 的原图:黑底 + 手势缩放/拖动,点击/下滑关闭。
  void _openFullImage(String imagePath) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => _FullScreenImageViewer(
          imagePath: imagePath,
          heroTag: 'ai-chat-image-$imagePath',
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Widget _buildImageErrorBox(double size) {
    return Container(
      width: size,
      height: size * 1.25,
      color: BeeTokens.surface(context),
      child: Icon(
        Icons.broken_image_outlined,
        color: BeeTokens.textTertiary(context),
        size: 32.0.scaled(context, ref),
      ),
    );
  }

  /// 用户语音记账消息气泡:麦克风图标 + 识别文本
  Widget _buildVoiceBubble(Message message) {
    final primaryColor = ref.watch(primaryColorProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: GestureDetector(
              onLongPressStart: (details) => _showTextMessageMenu(
                  details.globalPosition, message, true),
              child: Container(
                margin: EdgeInsets.only(left: 60.0.scaled(context, ref)),
                padding: EdgeInsets.symmetric(
                  horizontal: 12.0.scaled(context, ref),
                  vertical: 10.0.scaled(context, ref),
                ),
                decoration: BoxDecoration(
                  color: primaryColor.withOpacity(0.1),
                  borderRadius:
                      BorderRadius.circular(12.0.scaled(context, ref)),
                  border: Border.all(
                    color: primaryColor.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mic_rounded, size: 16, color: primaryColor),
                    SizedBox(width: 6.0.scaled(context, ref)),
                    Flexible(
                      child: Text(
                        message.content,
                        style: TextStyle(
                          color: BeeTokens.textPrimary(context),
                          fontSize: 14.0.scaled(context, ref),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_userAvatarPath != null) ...[
            SizedBox(width: 8.0.scaled(context, ref)),
            _buildUserAvatar(),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final primaryColor = ref.watch(primaryColorProvider);
    return Container(
      padding: EdgeInsets.all(16.0.scaled(context, ref)),
      decoration: BoxDecoration(
        color: BeeTokens.surface(context),
        border: Border(
          top: BorderSide(
            color: BeeTokens.divider(context),
          ),
        ),
      ),
      child: SafeArea(
        top: false, // 不保护顶部，避免额外空白
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context).aiChatInputHint,
                  hintStyle: TextStyle(
                    color: BeeTokens.textTertiary(context),
                  ),
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(20.0.scaled(context, ref)),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: BeeTokens.scaffoldBackground(context),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16.0.scaled(context, ref),
                    vertical: 10.0.scaled(context, ref),
                  ),
                ),
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                enabled: !_isLoading,
              ),
            ),
            SizedBox(width: 8.0.scaled(context, ref)),
            // 图片记账(相册/拍照)
            IconButton(
              icon: Icon(
                Icons.image_outlined,
                color: _isLoading
                    ? BeeTokens.textTertiary(context)
                    : primaryColor,
              ),
              tooltip: AppLocalizations.of(context).fabActionGallery,
              onPressed: _isLoading ? null : _showMediaSourceSheet,
            ),
            // 语音记账
            IconButton(
              icon: Icon(
                Icons.mic_none,
                color: _isLoading
                    ? BeeTokens.textTertiary(context)
                    : primaryColor,
              ),
              tooltip: AppLocalizations.of(context).fabActionVoice,
              onPressed: _isLoading ? null : _startVoiceBilling,
            ),
            IconButton(
              icon: Icon(
                Icons.send,
                color: _isLoading
                    ? BeeTokens.textTertiary(context)
                    : primaryColor,
              ),
              onPressed: _isLoading ? null : _sendMessage,
            ),
          ],
        ),
      ),
    );
  }

  /// 显示图片记账来源选择(相册 / 拍照)
  void _showMediaSourceSheet() {
    if (_isLoading) return;
    final l10n = AppLocalizations.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: BeeTokens.surface(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.fabActionGallery),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _handleImageBilling(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(l10n.fabActionCamera),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _handleImageBilling(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 图片记账:选图 → 用户图片消息 → 识别入库 → AI 卡片消息
  Future<void> _handleImageBilling(ImageSource source) async {
    if (_isLoading) return;
    final l10n = AppLocalizations.of(context);

    // 与「相册/拍照」入口一致:未配置 vision 能力时直接提示
    if (!await AIProviderManager.isCapabilityConfigured(
        AICapabilityType.vision)) {
      if (mounted) showToast(context, l10n.aiNotConfiguredHint);
      return;
    }
    if (!mounted) return;

    // 选图(与 ImageBillingHelper 同参数,压缩成不超过 1920、质量 85)
    final pickedFile = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (pickedFile == null || !mounted) return;
    final imageFile = File(pickedFile.path);

    // 先插入用户图片消息(气泡展示缩略图)
    await _insertUserMessage(
      messageType: 'image',
      content: l10n.aiChatImageLabel,
      metadata: {'imagePath': imageFile.path},
    );

    setState(() => _isLoading = true);
    try {
      final ledgerId = ref.read(currentLedgerIdProvider);
      final autoAddAttachment = ref.read(smartBillingAutoAttachmentProvider);
      final attachmentService = ref.read(attachmentServiceProvider);

      // 委托 AiBookkeeper(与 ImageBillingHelper 同款配置)
      final bookkeeper = ref.read(aiBookkeeperProvider);
      final result = await bookkeeper.fromImage(
        image: imageFile,
        ledgerId: ledgerId,
        billGuard: PromptBuilder.billGuardForImage,
        billingTypes: [
          source == ImageSource.gallery
              ? TagSeedService.billingTypeImage
              : TagSeedService.billingTypeCamera,
          TagSeedService.billingTypeAi,
        ],
        l10n: l10n,
        // 多笔时每笔都挂同一张原图,方便后续从任意一笔溯源
        onSaved: autoAddAttachment
            ? (txId, _) => attachmentService.saveAttachment(
                  transactionId: txId,
                  sourceFile: imageFile,
                  index: 0,
                )
            : null,
      );
      if (!mounted) return;

      if (!result.success) {
        // failedCount>0:提取到账单但入库失败(真·错误);否则=AI 判定不是账单
        await _insertAssistantText(
            result.failedCount > 0 ? l10n.aiOcrCheckLog : l10n.aiOcrNoBill);
        return;
      }

      // 刷新标签/附件/统计 + 触发云同步
      await PostProcessor.run(
        ref,
        ledgerId: ledgerId,
        tags: true,
        attachments: autoAddAttachment,
      );
      if (!mounted) return;
      await _insertBillCard(result);
    } catch (e, st) {
      logger.error('AIChat', '图片记账失败', e, st);
      if (mounted) showToast(context, l10n.aiOcrFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 语音记账:复用 VoiceBillingHelper(权限/配置检查 + 录音对话框),
  /// 识别结果通过 onResult 流回聊天。
  void _startVoiceBilling() {
    if (_isLoading) return;
    VoiceBillingHelper.startVoiceBilling(
      context,
      ref,
      onResult: _handleVoiceResult,
    );
  }

  /// 语音识别结束(成功或失败):插入用户语音气泡 + AI 回复
  Future<void> _handleVoiceResult(
    BookkeepingResult result,
    String? recognizedText,
  ) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);

    // 用户语音气泡:展示识别到的文字,让用户看到「机器听到了什么」
    await _insertUserMessage(
      messageType: 'voice',
      content: recognizedText ?? l10n.aiChatVoiceLabel,
    );
    if (!mounted) return;

    if (!result.success) {
      // 识别有文字但没提取出账单 → 展示原文;完全没识别到 → 通用失败
      await _insertAssistantText(
        recognizedText != null
            ? l10n.voiceRecordingNoInfoDetected(recognizedText)
            : l10n.voiceRecordingNoInfo,
      );
      return;
    }

    // 同步已在录音对话框内由 PostProcessor.run(tags: true) 完成
    await _insertBillCard(result);
  }

  /// 插入一条用户消息(图片/语音等媒体类型)
  Future<void> _insertUserMessage({
    required String messageType,
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final repo = ref.read(repositoryProvider);
    await repo.createMessage(
      MessagesCompanion.insert(
        conversationId: _conversationId!,
        role: 'user',
        content: content,
        messageType: messageType,
        metadata: metadata != null
            ? Value(jsonEncode(metadata))
            : const Value.absent(),
        createdAt: Value(DateTime.now()),
      ),
    );
    _scrollToBottom();
  }

  /// 插入一条 AI 纯文本消息
  Future<void> _insertAssistantText(String text) async {
    final repo = ref.read(repositoryProvider);
    final messageId = await repo.createMessage(
      MessagesCompanion.insert(
        conversationId: _conversationId!,
        role: 'assistant',
        content: text,
        messageType: 'text',
        createdAt: Value(DateTime.now()),
      ),
    );
    if (mounted) {
      setState(() => _animatingMessageId = messageId);
    }
    _scrollToBottom();
  }

  /// 把图片/语音记账结果插入为 AI 账单卡片消息(与 AIResponse.billCards 同款)
  Future<void> _insertBillCard(BookkeepingResult result) async {
    final repo = ref.read(repositoryProvider);
    final bills = result.savedBills;
    final txIds = result.transactionIds;
    if (bills.isEmpty || txIds.isEmpty) return;

    final n = bills.length;
    final base = n == 1 ? '✅ 记账成功' : '✅ 已记账 $n 笔';
    final note = result.unconvertedCurrencies.isEmpty
        ? null
        : AppLocalizations.of(context).aiBillingRateMissingHint(
            result.unconvertedCurrencies.join('、'));
    final text = note == null ? base : '$base\n$note';

    final messageId = await repo.createMessage(
      MessagesCompanion.insert(
        conversationId: _conversationId!,
        role: 'assistant',
        content: text,
        messageType: 'bill_card',
        metadata: Value(_encodeBillMetadata(bills, txIds, const <int>{})),
        transactionId: Value(txIds.first),
        createdAt: Value(DateTime.now()),
      ),
    );

    // 刷新统计信息(云同步已由调用方 PostProcessor.run 触发)
    ref.read(statsRefreshProvider.notifier).state++;

    if (mounted) {
      setState(() => _animatingMessageId = messageId);
    }
    _scrollToBottom();
  }

  /// 处理快捷指令点击
  Future<void> _handleQuickCommand(AIQuickCommand command) async {
    if (_isLoading) return;

    try {
      final ledgerId = ref.read(currentLedgerIdProvider);
      final commandService = ref.read(aiQuickCommandServiceProvider(ledgerId));
      final l10n = AppLocalizations.of(context);

      // 生成完整的 Prompt
      final prompt = await commandService.generatePrompt(command, context);

      // 获取快捷指令的标题作为显示文本
      String displayText;
      switch (command.titleKey) {
        case 'aiQuickCommandFinancialHealthTitle':
          displayText = l10n.aiQuickCommandFinancialHealthTitle;
          break;
        case 'aiQuickCommandMonthlyExpenseTitle':
          displayText = l10n.aiQuickCommandMonthlyExpenseTitle;
          break;
        case 'aiQuickCommandCategoryAnalysisTitle':
          displayText = l10n.aiQuickCommandCategoryAnalysisTitle;
          break;
        case 'aiQuickCommandBudgetPlanningTitle':
          displayText = l10n.aiQuickCommandBudgetPlanningTitle;
          break;
        case 'aiQuickCommandAbnormalExpenseTitle':
          displayText = l10n.aiQuickCommandAbnormalExpenseTitle;
          break;
        case 'aiQuickCommandSavingTipsTitle':
          displayText = l10n.aiQuickCommandSavingTipsTitle;
          break;
        default:
          displayText = command.titleKey;
      }

      // 发送完整prompt给AI，但在对话中只显示标题
      await _sendMessageText(
        prompt,
        displayText: displayText,
        forceChat: true,
      );
    } catch (e, st) {
      logger.error('AIChat', '处理快捷指令失败', e, st);
      if (mounted) {
        showToast(context, '${AppLocalizations.of(context).commonFailed}: $e');
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isLoading) return;

    _inputController.clear();
    await _sendMessageText(text);
  }

  /// 发送消息文本
  ///
  /// [text] - 发送给AI的完整文本
  /// [displayText] - 在对话框中显示的文本（可选，默认使用text）
  /// [forceChat] - 强制为自由对话模式
  Future<void> _sendMessageText(
    String text, {
    String? displayText,
    bool forceChat = false,
  }) async {
    if (text.isEmpty || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(repositoryProvider);

      // 保存用户消息（使用displayText作为显示内容，如果没有则使用text）
      await repo.createMessage(
        MessagesCompanion.insert(
          conversationId: _conversationId!,
          role: 'user',
          content: displayText ?? text,
          messageType: 'text',
          createdAt: Value(DateTime.now()),
        ),
      );

      _scrollToBottom();

      // chat_service 内部走 BillExtractionService.forLedger,会自动查
      // 当前账本可用分类 + 同币种账户,page 层不再预查。
      final chatService = ref.read(aiChatServiceProvider);
      final currentLocale = Localizations.localeOf(context);
      final ledgerId = ref.read(currentLedgerIdProvider);
      final l10n = AppLocalizations.of(context);

      logger.info('AIChat', '当前账本ID: $ledgerId');

      final response = await chatService.processMessage(
        text,
        ledgerId: ledgerId,
        languageCode: currentLocale.languageCode,
        forceChat: forceChat, // 快捷指令强制为自由对话
        l10n: l10n,
      );

      // 保存 AI 回复。多笔 metadata 用新格式 {bills, txIds, undoneIds};
      // transactionId 列仍存第一笔 id(getMessageByTransactionId 兼容)。
      final messageId = await repo.createMessage(
        MessagesCompanion.insert(
          conversationId: _conversationId!,
          role: 'assistant',
          content: response.text,
          messageType: response.type,
          metadata: response.bills.isNotEmpty
              ? Value(_encodeBillMetadata(
                  response.bills,
                  response.transactionIds,
                  const <int>{},
                ))
              : const Value.absent(),
          transactionId: response.transactionId != null
              ? Value(response.transactionId)
              : const Value.absent(),
          createdAt: Value(DateTime.now()),
        ),
      );

      // 如果是记账成功，刷新统计信息
      if (response.type == 'bill_card' && response.transactionId != null) {
        // 刷新全局统计信息
        ref.read(statsRefreshProvider.notifier).state++;

        // 触发云同步
        final billLedgerId = response.billInfo?.ledgerId ?? ledgerId;
        await PostProcessor.sync(ref, ledgerId: billLedgerId);

        logger.info('AIChat', '记账成功，已刷新统计信息和触发云同步');
      }

      // 设置动画消息ID
      setState(() {
        _animatingMessageId = messageId;
      });

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        showToast(
            context, '${AppLocalizations.of(context).aiChatSendFailed}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients && mounted) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 点击按钮时滚动到底部（立即执行）
  void _scrollToBottomWithAnimation() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// 平滑滚动到底部（用于打字机效果期间）
  /// 使用 jumpTo 避免频繁调用 animateTo 造成性能问题
  void _scrollToBottomSmooth() {
    // 使用 postFrameCallback 确保在布局完成后滚动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && mounted) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _showClearHistoryDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.aiChatClearHistoryDialogTitle),
        content: Text(l10n.aiChatClearHistoryDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              _clearHistory();
              Navigator.pop(context);
            },
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  Future<void> _clearHistory() async {
    final repo = ref.read(repositoryProvider);
    await repo.deleteMessagesByConversation(_conversationId!);

    if (mounted) {
      showToast(context, AppLocalizations.of(context).aiChatHistoryCleared);
    }
  }

  /// 撤销单笔(多笔卡片里的某一笔,或单笔卡片)
  Future<void> _handleUndoOne(int messageId, int transactionId) async {
    final chatService = ref.read(aiChatServiceProvider);
    final success = await chatService.undoTransaction(transactionId);

    if (!success) {
      if (mounted) {
        showToast(context, AppLocalizations.of(context).aiChatUndoFailed);
      }
      return;
    }

    final repo = ref.read(repositoryProvider);
    final message = await repo.getMessageById(messageId);
    if (message == null || message.metadata == null) {
      if (mounted) showToast(context, AppLocalizations.of(context).aiChatUndone);
      return;
    }

    final parsed = _parseBillMetadata(message);
    final newUndone = {...parsed.undoneIds, transactionId};
    await repo.updateMessage(message.copyWith(
      metadata: Value(_encodeBillMetadata(
        parsed.bills,
        parsed.txIds,
        newUndone,
      )),
    ));

    ref.read(statsRefreshProvider.notifier).state++;

    // 找出这笔对应的账本触发同步
    final idx = parsed.txIds.indexOf(transactionId);
    if (idx >= 0 && idx < parsed.bills.length) {
      final ledgerId = parsed.bills[idx].ledgerId;
      if (ledgerId != null) {
        await PostProcessor.sync(ref, ledgerId: ledgerId);
        logger.info('AIChat', '撤销单笔成功 txId=$transactionId,已同步');
      }
    }

    if (mounted) {
      showToast(context, AppLocalizations.of(context).aiChatUndone);
    }
  }

  Future<void> _handleEdit(int messageId, int transactionId) async {
    try {
      final repo = ref.read(repositoryProvider);

      final transaction = await repo.getTransactionById(transactionId);

      if (transaction == null) {
        if (mounted) {
          showToast(
              context, AppLocalizations.of(context).aiChatTransactionNotFound);
        }
        return;
      }

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TransactionEditorPage(
              initialKind: transaction.type,
              quickAdd: true,
              initialCategoryId: transaction.categoryId,
              initialAmount: transaction.amount,
              initialDate: transaction.happenedAt,
              initialNote: transaction.note,
              editingTransactionId: transaction.id,
              initialAccountId: transaction.accountId,
              initialToAccountId: transaction.toAccountId,
            ),
          ),
        );

        // 从编辑页面返回后，无论是否保存，都刷新账单卡片
        if (mounted) {
          logger.info('AIChat',
              '编辑页面返回,刷新账单卡片: messageId=$messageId, txId=$transactionId');
          await _refreshBillCard(messageId, transactionId);
        }
      }
    } catch (e) {
      if (mounted) {
        showToast(context, AppLocalizations.of(context).aiChatOpenEditorFailed);
      }
    }
  }

  /// 刷新账单卡片信息(根据 messageId 定位消息,根据 txId 在多笔里定位行)
  Future<void> _refreshBillCard(int messageId, int transactionId) async {
    try {
      final repo = ref.read(repositoryProvider);
      final message = await repo.getMessageById(messageId);
      if (message == null || message.metadata == null) return;

      final transaction = await repo.getTransactionById(transactionId);
      if (transaction == null) return;

      String? categoryName;
      if (transaction.categoryId != null) {
        final category = await repo.getCategoryById(transaction.categoryId!);
        categoryName = category?.name;
      }
      String? accountName;
      if (transaction.accountId != null) {
        final account = await repo.getAccount(transaction.accountId!);
        accountName = account?.name;
      }

      final updatedBillInfo = BillInfo(
        amount: transaction.amount,
        time: transaction.happenedAt,
        note: transaction.note,
        category: categoryName,
        type: transaction.type == 'expense'
            ? BillType.expense
            : (transaction.type == 'transfer'
                ? BillType.transfer
                : BillType.income),
        account: accountName,
        ledgerId: transaction.ledgerId,
        confidence: 1.0,
      );

      final parsed = _parseBillMetadata(message);
      final idx = parsed.txIds.indexOf(transactionId);
      if (idx < 0 || idx >= parsed.bills.length) {
        logger.warning('AIChat',
            '_refreshBillCard: 在 message $messageId 中找不到 txId=$transactionId');
        return;
      }
      final newBills = List<BillInfo>.from(parsed.bills);
      newBills[idx] = updatedBillInfo;

      await repo.updateMessage(message.copyWith(
        metadata: Value(_encodeBillMetadata(
          newBills,
          parsed.txIds,
          parsed.undoneIds,
        )),
      ));

      logger.info(
          'AIChat', '账单卡片已刷新: messageId=$messageId, txId=$transactionId');
    } catch (e, st) {
      logger.error('AIChat', '刷新账单卡片失败', e, st);
    }
  }

  /// 修改账本
  Future<void> _handleChangeLedger(int messageId, int transactionId) async {
    try {
      final repo = ref.read(repositoryProvider);

      // 获取当前交易
      final transaction = await repo.getTransactionById(transactionId);

      if (transaction == null) {
        if (mounted) {
          showToast(
              context, AppLocalizations.of(context).aiChatTransactionNotFound);
        }
        return;
      }

      if (!mounted) return;

      // 显示账本选择对话框
      final selectedLedgerId = await showLedgerSelector(
        context,
        currentLedgerId: transaction.ledgerId,
      );

      if (selectedLedgerId == null ||
          selectedLedgerId == transaction.ledgerId) {
        return; // 用户取消或选择了相同的账本
      }

      // 更新交易的账本
      await repo.updateTransactionLedger(
        id: transactionId,
        ledgerId: selectedLedgerId,
      );

      // 更新消息的 metadata(多笔:仅更新匹配 txId 的那一笔)
      final message = await repo.getMessageById(messageId);

      if (message != null && message.metadata != null) {
        final parsed = _parseBillMetadata(message);
        final idx = parsed.txIds.indexOf(transactionId);
        if (idx >= 0 && idx < parsed.bills.length) {
          final newBills = List<BillInfo>.from(parsed.bills);
          newBills[idx] = parsed.bills[idx].copyWith(ledgerId: selectedLedgerId);
          await repo.updateMessage(message.copyWith(
            metadata: Value(_encodeBillMetadata(
              newBills,
              parsed.txIds,
              parsed.undoneIds,
            )),
          ));
        } else {
          logger.warning('AIChat',
              '_handleChangeLedger: 在 message $messageId 中找不到 txId=$transactionId');
        }

        // 刷新统计信息（修改账本后，需要刷新旧账本和新账本的统计）
        ref.read(statsRefreshProvider.notifier).state++;

        // 触发云同步（旧账本和新账本都需要同步）
        await PostProcessor.sync(ref, ledgerId: transaction.ledgerId);
        await PostProcessor.sync(ref, ledgerId: selectedLedgerId);

        logger.info('AIChat',
            '修改账本成功: ${transaction.ledgerId} -> $selectedLedgerId,已刷新统计信息和触发云同步');

        if (mounted) {
          setState(() {}); // 触发重建以显示新的账本名称
        }
      }

      if (mounted) {
        showToast(context, AppLocalizations.of(context).commonSuccess);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, AppLocalizations.of(context).commonFailed);
      }
    }
  }

  /// 显示文字消息的长按菜单
  void _showTextMessageMenu(Offset position, Message message, bool isUser) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.read(primaryColorProvider);

    MessagePopoverMenu.show(
      context: context,
      globalPosition: position,
      primaryColor: primaryColor,
      items: [
        PopoverMenuItem(
          icon: Icons.copy,
          label: l10n.aiChatCopy,
          onTap: () {
            Clipboard.setData(ClipboardData(text: message.content));
            showToast(context, l10n.aiChatCopied);
          },
        ),
        PopoverMenuItem(
          icon: Icons.delete_outline,
          label: l10n.commonDelete,
          color: Colors.red,
          onTap: () => _deleteMessage(message),
        ),
      ],
    );
  }

  /// 显示记账卡片的长按菜单
  void _showBillCardMenu(Offset position, Message message) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.read(primaryColorProvider);

    MessagePopoverMenu.show(
      context: context,
      globalPosition: position,
      primaryColor: primaryColor,
      items: [
        PopoverMenuItem(
          icon: Icons.delete_outline,
          label: l10n.commonDelete,
          color: Colors.red,
          onTap: () => _deleteMessage(message),
        ),
      ],
    );
  }

  /// 删除单条消息
  Future<void> _deleteMessage(Message message) async {
    final l10n = AppLocalizations.of(context);

    // 确认删除
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.commonDelete,
      message: l10n.aiChatDeleteMessageConfirm,
    );

    if (confirmed != true) return;

    try {
      final repo = ref.read(repositoryProvider);
      await repo.deleteMessage(message.id);

      if (mounted) {
        showToast(context, l10n.aiChatMessageDeleted);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, l10n.commonFailed);
      }
    }
  }

  // ============================================================
  // 多笔账单 metadata 编解码
  //
  // 新格式: {"bills":[...], "txIds":[...], "undoneIds":[...]}
  // 老格式: {"billInfo":{...}, "isUndone":bool}  ← 自动转
  //
  // bills.length == txIds.length;undoneIds 是 txIds 的子集。
  // ============================================================

  ({List<BillInfo> bills, List<int> txIds, Set<int> undoneIds})
      _parseBillMetadata(Message m) {
    final raw = jsonDecode(m.metadata!) as Map<String, dynamic>;

    // 新格式
    if (raw['bills'] is List) {
      final bills = (raw['bills'] as List)
          .whereType<Map>()
          .map((j) => BillInfo.fromJson(Map<String, dynamic>.from(j)))
          .toList();
      final txIds = ((raw['txIds'] as List?) ?? const [])
          .whereType<int>()
          .toList();
      final undoneIds = ((raw['undoneIds'] as List?) ?? const [])
          .whereType<int>()
          .toSet();
      return (bills: bills, txIds: txIds, undoneIds: undoneIds);
    }

    // 老格式
    final billJson = raw['billInfo'] is Map
        ? Map<String, dynamic>.from(raw['billInfo'] as Map)
        : raw;
    final bill = BillInfo.fromJson(billJson);
    final txId = m.transactionId;
    final isUndone = raw['isUndone'] == true;
    return (
      bills: [bill],
      txIds: txId != null ? <int>[txId] : <int>[],
      undoneIds: (isUndone && txId != null) ? <int>{txId} : <int>{},
    );
  }

  String _encodeBillMetadata(
    List<BillInfo> bills,
    List<int> txIds,
    Set<int> undoneIds,
  ) {
    return jsonEncode({
      'bills': bills.map((b) => b.toJson()).toList(),
      'txIds': txIds,
      'undoneIds': undoneIds.toList(),
    });
  }

  // ============================================================
  // 多笔账单气泡: 直接渲染 N 张 BillCardWidget,无额外汇总/折叠/全部撤销。
  // 每张卡保留单笔已有的 undo/edit/changeLedger。
  // ============================================================

  Widget _buildMultiBillBubble(
    Message message,
    ({List<BillInfo> bills, List<int> txIds, Set<int> undoneIds}) parsed,
  ) {
    final bills = parsed.bills;
    final txIds = parsed.txIds;
    final undoneIds = parsed.undoneIds;

    return GestureDetector(
      onLongPressStart: (details) => _showBillCardMenu(
        details.globalPosition,
        message,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < bills.length; i++)
            Builder(builder: (_) {
              final txId = i < txIds.length ? txIds[i] : null;
              final isUndone = txId != null && undoneIds.contains(txId);
              return BillCardWidget(
                billInfo: bills[i],
                transactionId: txId,
                isUndone: isUndone,
                onUndo: txId != null && !isUndone
                    ? () => _handleUndoOne(message.id, txId)
                    : null,
                onEdit: txId != null && !isUndone
                    ? () => _handleEdit(message.id, txId)
                    : null,
                onChangeLedger: txId != null && !isUndone
                    ? () => _handleChangeLedger(message.id, txId)
                    : null,
              );
            }),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// 全屏图片查看器(发送给 AI 的原图):黑底,手势缩放/拖动,点击或下滑关闭。
class _FullScreenImageViewer extends StatefulWidget {
  final String imagePath;
  final String heroTag;

  const _FullScreenImageViewer({
    required this.imagePath,
    required this.heroTag,
  });

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  final TransformationController _transformer = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _transformer.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_transformer.value != Matrix4.identity()) {
      // 已放大 → 回到原尺寸
      _transformer.value = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition;
      const scale = 2.5;
      if (position != null) {
        _transformer.value = Matrix4.identity()
          ..translate(-position.dx * (scale - 1), -position.dy * (scale - 1))
          ..scale(scale);
      } else {
        _transformer.value = Matrix4.identity()..scale(scale);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 顶部关闭按钮(安全区之下)
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          // 图片:手势缩放/拖动;未缩放时下滑关闭
          Center(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              onDoubleTapDown: (details) => _doubleTapDetails = details,
              onDoubleTap: _handleDoubleTap,
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                final zoomed = _transformer.value != Matrix4.identity();
                if (!zoomed && velocity > 300) Navigator.of(context).pop();
              },
              child: InteractiveViewer(
                transformationController: _transformer,
                maxScale: 5,
                minScale: 0.5,
                child: Hero(
                  tag: widget.heroTag,
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(48),
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white38, size: 64),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
