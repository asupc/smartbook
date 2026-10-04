import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';

/// 类 iOS 高品质侧滑操作单元格
///
/// 特性：
/// 1. 左滑露出红底「删除」按钮并吸附停靠（80px）；
/// 2. 点击删除按钮立即删除；
/// 3. 任意其它项滑动或点击内容区时，自动弹性闭合当前展开项；
/// 4. 展开状态下点击主内容区仅闭合操作栏，不穿透触发进入详情。
class IosSwipeActionCell extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? onDelete;
  final bool enabled;
  final BorderRadius? borderRadius;
  final double actionWidth;

  const IosSwipeActionCell({
    super.key,
    required this.child,
    this.onDelete,
    this.enabled = true,
    this.borderRadius,
    this.actionWidth = 80.0,
  });

  /// 全局关闭当前打开的侧滑项（可由外部滚动监听调用）
  static void closeAll() {
    _IosSwipeActionCellState._openCell?.close();
  }

  @override
  State<IosSwipeActionCell> createState() => _IosSwipeActionCellState();
}

class _IosSwipeActionCellState extends State<IosSwipeActionCell>
    with SingleTickerProviderStateMixin {
  /// 全局单例：当前展开的单元格，保证同一时间最多只有一项处于展开状态
  static _IosSwipeActionCellState? _openCell;

  late AnimationController _controller;
  double _dragOffset = 0.0;
  bool _isDeleting = false;

  bool get isOpen => _dragOffset < -10.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        setState(() {
          _dragOffset = _controller.value;
        });
      });
  }

  @override
  void dispose() {
    if (_openCell == this) {
      _openCell = null;
    }
    _controller.dispose();
    super.dispose();
  }

  /// 平滑闭合到 0
  void close() {
    if (_dragOffset == 0.0) return;
    _controller.value = _dragOffset;
    _controller.animateTo(
      0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (_openCell == this) {
      _openCell = null;
    }
  }

  /// 平滑展开到吸附宽度
  void open() {
    if (_openCell != null && _openCell != this) {
      _openCell?.close();
    }
    _openCell = this;
    _controller.value = _dragOffset;
    _controller.animateTo(
      -widget.actionWidth,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    HapticFeedback.lightImpact();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!widget.enabled || widget.onDelete == null) return;
    if (_openCell != null && _openCell != this) {
      _openCell?.close();
    }
    _controller.stop();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled || widget.onDelete == null) return;

    final newOffset =
        (_dragOffset + details.primaryDelta!).clamp(-widget.actionWidth, 0.0);
    setState(() {
      _dragOffset = newOffset;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.enabled || widget.onDelete == null) return;

    // 拖动超过吸附阈值（一半的 actionWidth）
    if (_dragOffset <= -widget.actionWidth / 2) {
      open();
    } else {
      close();
    }
  }

  Future<void> _handleActionTap() async {
    if (_isDeleting) return;
    setState(() => _isDeleting = true);
    HapticFeedback.mediumImpact();
    try {
      await widget.onDelete?.call();
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.onDelete == null) {
      return widget.child;
    }

    final l10n = AppLocalizations.of(context);
    final deleteLabel = l10n.commonDelete;
    final revealWidth = (-_dragOffset).clamp(0.0, double.infinity);

    return ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // 底层右侧 iOS 风格红色删除操作区域
          if (_dragOffset < 0)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: revealWidth,
              child: Material(
                color: const Color(0xFFFF3B30), // iOS 原生删除红
                child: InkWell(
                  onTap: _isDeleting ? null : _handleActionTap,
                  child: Center(
                    child: SizedBox(
                      width: widget.actionWidth,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            deleteLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 上层主内容视图
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              child: Stack(
                children: [
                  widget.child,
                  // 展开时覆盖一个轻量拦截层，点击直接收起，避免误触进入详情
                  if (isOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          close();
                        },
                        child: const ColoredBox(color: Colors.transparent),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
