import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 操作表单项定义（iOS ActionSheet 风格）
class ActionSheetItem<T> {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final T? value;
  final VoidCallback? onTap;
  final bool isDestructive;
  final bool isSelected;

  const ActionSheetItem({
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.value,
    this.onTap,
    this.isDestructive = false,
    this.isSelected = false,
  });
}

/// 统一弹窗与操作表（基础 UI 组件）
class AppDialog {
  /// 确认弹窗
  static Future<T?> confirm<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? cancelLabel,
    String? okLabel,
    VoidCallback? onCancel,
    VoidCallback? onOk,
    bool isDestructive = false,
    Widget? icon,
    bool barrierDismissible = true,
  }) {
    final l10n = AppLocalizations.of(context);
    cancelLabel ??= l10n.commonCancel;
    okLabel ??= isDestructive ? (l10n.commonDelete) : l10n.commonConfirm;

    Widget? effectiveIcon = icon;
    if (effectiveIcon == null) {
      if (isDestructive) {
        effectiveIcon = _buildIconBadge(
          icon: Icons.delete_outline_rounded,
          color: const Color(0xFFFF3B30),
          bgColor: const Color(0xFFFF3B30).withValues(alpha: 0.12),
        );
      } else {
        effectiveIcon = Builder(
          builder: (ctx) => _buildIconBadge(
            icon: Icons.help_outline_rounded,
            color: Theme.of(ctx).colorScheme.primary,
            bgColor: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.12),
          ),
        );
      }
    }

    return _show<T>(
      context,
      title: title,
      message: message,
      icon: effectiveIcon,
      barrierDismissible: barrierDismissible,
      actions: [
        (
          label: cancelLabel,
          onTap: () {
            Navigator.pop(context, false);
            if (onCancel != null) onCancel();
          },
          primary: false,
          isDestructive: false,
        ),
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
          isDestructive: isDestructive,
        ),
      ],
    );
  }

  /// 信息提示弹窗
  static Future<T?> info<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
    Widget? icon,
    bool barrierDismissible = true,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    final effectiveIcon = icon ??
        _buildIconBadge(
          icon: Icons.info_outline_rounded,
          color: const Color(0xFF0284C7),
          bgColor: const Color(0xFF0284C7).withValues(alpha: 0.12),
        );

    return _show<T>(
      context,
      title: title,
      message: message,
      icon: effectiveIcon,
      barrierDismissible: barrierDismissible,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
          isDestructive: false,
        ),
      ],
    );
  }

  /// 错误提示弹窗
  static Future<T?> error<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
    Widget? icon,
    bool barrierDismissible = true,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    final effectiveIcon = icon ??
        _buildIconBadge(
          icon: Icons.highlight_off_rounded,
          color: const Color(0xFFEF4444),
          bgColor: const Color(0xFFEF4444).withValues(alpha: 0.12),
        );

    return _show<T>(
      context,
      title: title,
      message: message,
      icon: effectiveIcon,
      barrierDismissible: barrierDismissible,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
          isDestructive: false,
        ),
      ],
    );
  }

  /// 警告提示弹窗
  static Future<T?> warning<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
    Widget? icon,
    bool barrierDismissible = true,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    final effectiveIcon = icon ??
        _buildIconBadge(
          icon: Icons.warning_amber_rounded,
          color: const Color(0xFFF59E0B),
          bgColor: const Color(0xFFF59E0B).withValues(alpha: 0.12),
        );

    return _show<T>(
      context,
      title: title,
      message: message,
      icon: effectiveIcon,
      barrierDismissible: barrierDismissible,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
          isDestructive: false,
        ),
      ],
    );
  }

  /// 标准文本输入提示弹窗（替代零散的临时 Dialog）
  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    String? message,
    String? initialValue,
    String? hintText,
    int? maxLength,
    TextInputType keyboardType = TextInputType.text,
    String? cancelLabel,
    String? okLabel,
    String? Function(String?)? validator,
    bool barrierDismissible = true,
  }) {
    final l10n = AppLocalizations.of(context);
    cancelLabel ??= l10n.commonCancel;
    okLabel ??= l10n.commonSave;

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim1, anim2) {
        return _PromptDialogWidget(
          title: title,
          message: message,
          initialValue: initialValue,
          hintText: hintText,
          maxLength: maxLength,
          keyboardType: keyboardType,
          cancelLabel: cancelLabel!,
          okLabel: okLabel!,
          validator: validator,
        );
      },
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curve = CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic);
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 5 * curve.value,
            sigmaY: 5 * curve.value,
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(curve),
            child: FadeTransition(
              opacity: curve,
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// iOS 风格底部操作面板（ActionSheet）
  static Future<T?> showActionSheet<T>(
    BuildContext context, {
    String? title,
    String? message,
    required List<ActionSheetItem<T>> actions,
    String? cancelLabel,
  }) {
    final l10n = AppLocalizations.of(context);
    cancelLabel ??= l10n.commonCancel;

    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final isDark = BeeTokens.isDark(ctx);
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final dividerColor = isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主操作区域卡片
                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (title != null || message != null) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                            child: Column(
                              children: [
                                if (title != null)
                                  Text(
                                    title,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: BeeTokens.textPrimary(ctx),
                                    ),
                                  ),
                                if (message != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    message,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: BeeTokens.textSecondary(ctx),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Divider(height: 1, thickness: 0.5, color: dividerColor),
                        ],
                        for (int i = 0; i < actions.length; i++) ...[
                          _ActionSheetTile(
                            item: actions[i],
                            onTap: () {
                              Navigator.pop(ctx, actions[i].value);
                              actions[i].onTap?.call();
                            },
                          ),
                          if (i < actions.length - 1)
                            Divider(height: 1, thickness: 0.5, color: dividerColor),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 取消按钮
                Material(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  elevation: 0,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.pop(ctx),
                    child: Container(
                      width: double.infinity,
                      height: 52,
                      alignment: Alignment.center,
                      child: Text(
                        cancelLabel!,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: BeeTokens.textPrimary(ctx),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 内部核心弹窗展示逻辑
  static Future<T?> _show<T>(
    BuildContext context, {
    required String title,
    required String message,
    Widget? icon,
    bool barrierDismissible = true,
    List<({String label, VoidCallback onTap, bool primary, bool isDestructive})>? actions,
  }) {
    final l10n = AppLocalizations.of(context);
    actions ??= [
      (
        label: l10n.commonCancel,
        onTap: () => Navigator.pop(context),
        primary: false,
        isDestructive: false,
      ),
      (
        label: l10n.commonConfirm,
        onTap: () => Navigator.pop(context),
        primary: true,
        isDestructive: false,
      ),
    ];

    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim1, anim2) {
        final isDark = BeeTokens.isDark(ctx);

        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              margin: const EdgeInsets.symmetric(horizontal: 28),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
              decoration: BoxDecoration(
                color: BeeTokens.surfaceElevated(ctx),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.05),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                    blurRadius: 28,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    icon,
                    const SizedBox(height: 14),
                  ],
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: BeeTokens.textPrimary(ctx),
                      letterSpacing: -0.3,
                    ),
                  ),
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          message.replaceAll('\\n', '\n'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: BeeTokens.textSecondary(ctx),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  // 操作按钮组
                  if (actions!.length == 1)
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: _buildButton(ctx, actions[0]),
                    )
                  else if (actions.length == 2)
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: _buildButton(ctx, actions[0]),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: _buildButton(ctx, actions[1]),
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        for (int i = 0; i < actions.length; i++) ...[
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: _buildButton(ctx, actions[i]),
                          ),
                          if (i < actions.length - 1) const SizedBox(height: 8),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curve = CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic);
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 5 * curve.value,
            sigmaY: 5 * curve.value,
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(curve),
            child: FadeTransition(
              opacity: curve,
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// 构建圆形柔和背景图标徽标
  static Widget _buildIconBadge({
    required IconData icon,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(icon, size: 26, color: color),
      ),
    );
  }

  /// 构建风格统一的弹窗按钮
  static Widget _buildButton(
    BuildContext context,
    ({String label, VoidCallback onTap, bool primary, bool isDestructive}) action,
  ) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    const destructiveColor = Color(0xFFFF3B30);

    if (!action.primary) {
      // 次要按钮（取消等）
      return TextButton(
        onPressed: action.onTap,
        style: TextButton.styleFrom(
          backgroundColor: BeeTokens.surfaceSecondary(context),
          foregroundColor: BeeTokens.textPrimary(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: Text(
          action.label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      );
    }

    if (action.isDestructive) {
      // 破坏性操作确认按钮（红色）
      return ElevatedButton(
        onPressed: action.onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: destructiveColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: Text(
          action.label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      );
    }

    // 主要操作确认按钮（主题色）
    return ElevatedButton(
      onPressed: action.onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 0,
      ),
      child: Text(
        action.label,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 标准文本输入弹窗私有组件
class _PromptDialogWidget extends StatefulWidget {
  final String title;
  final String? message;
  final String? initialValue;
  final String? hintText;
  final int? maxLength;
  final TextInputType keyboardType;
  final String cancelLabel;
  final String okLabel;
  final String? Function(String?)? validator;

  const _PromptDialogWidget({
    required this.title,
    this.message,
    this.initialValue,
    this.hintText,
    this.maxLength,
    required this.keyboardType,
    required this.cancelLabel,
    required this.okLabel,
    this.validator,
  });

  @override
  State<_PromptDialogWidget> createState() => _PromptDialogWidgetState();
}

class _PromptDialogWidgetState extends State<_PromptDialogWidget> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    if (widget.validator != null) {
      final err = widget.validator!(text);
      if (err != null) {
        setState(() => _errorText = err);
        return;
      }
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = BeeTokens.isDark(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 320,
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: BeeTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.05),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: BeeTokens.textPrimary(context),
                ),
              ),
              if (widget.message != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: BeeTokens.textSecondary(context),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLength: widget.maxLength,
                keyboardType: widget.keyboardType,
                textInputAction: TextInputAction.done,
                style: TextStyle(
                  fontSize: 15,
                  color: BeeTokens.textPrimary(context),
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: BeeTokens.textTertiary(context),
                  ),
                  errorText: _errorText,
                  counterText: '',
                  filled: true,
                  fillColor: BeeTokens.surfaceInput(context),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (ctx, val, _) {
                      if (val.text.isEmpty) return const SizedBox.shrink();
                      return IconButton(
                        icon: Icon(
                          Icons.cancel,
                          size: 18,
                          color: BeeTokens.iconTertiary(context),
                        ),
                        onPressed: () {
                          _controller.clear();
                          if (_errorText != null) {
                            setState(() => _errorText = null);
                          }
                        },
                      );
                    },
                  ),
                ),
                onChanged: (_) {
                  if (_errorText != null) {
                    setState(() => _errorText = null);
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          backgroundColor: BeeTokens.surfaceSecondary(context),
                          foregroundColor: BeeTokens.textPrimary(context),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          widget.cancelLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          widget.okLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ActionSheet 单项视图组件
class _ActionSheetTile<T> extends StatelessWidget {
  final ActionSheetItem<T> item;
  final VoidCallback onTap;

  const _ActionSheetTile({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = item.isDestructive
        ? const Color(0xFFFF3B30)
        : (item.isSelected
            ? Theme.of(context).colorScheme.primary
            : BeeTokens.textPrimary(context));

    final iconColor = item.iconColor ??
        (item.isDestructive
            ? const Color(0xFFFF3B30)
            : (item.isSelected
                ? Theme.of(context).colorScheme.primary
                : BeeTokens.textSecondary(context)));

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(item.icon, size: 22, color: iconColor),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          item.isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: titleColor,
                    ),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: BeeTokens.textSecondary(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (item.isSelected)
              Icon(
                Icons.check,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}
