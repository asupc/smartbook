import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/data/category_service.dart';
import '../services/custom_icon_service.dart';
import '../data/db.dart';
import '../data/models/category_icon.dart';
import '../providers/theme_providers.dart';

/// 获取分类的图标数据。**永远只读 `category.icon` 字段**,不再按名字推导。
///
/// 历史上本函数在 icon 为空时走 `getCategoryIconByName`(40 条中文关键字正则)
/// 模糊推导 —— 问题多(改名换图标、只认中文、web/server 必须复刻两套)。v23
/// DB migration 已把所有 icon 为空的分类按 byName 一次性固化到 DB,此后渲染
/// 路径只信任 icon 字段。彻底删除 byName 逻辑的毒瘤。
///
/// [category] 分类对象
/// [categoryName] 兼容保留:当 category 为 null 但需要提示性显示时使用(兜底
///   永远是 `Icons.category`,不再按名字推导)
IconData getCategoryIconData({Category? category, String? categoryName}) {
  if (category != null && category.icon != null && category.icon!.isNotEmpty) {
    return CategoryService.getCategoryIcon(category.icon);
  }
  // icon 空(v23 后理论上不应该发生,除非分类刚创建还没走过 migration)→
  // 统一兜底 Icons.category,跟 getCategoryIcon(null) 行为一致。
  return CategoryService.getCategoryIcon(null);
}

/// 分类视觉调色板（现代色彩体系：柔和马卡龙底色 + 对应高对比图标色）
class CategoryColorPalette {
  final Color background;
  final Color foreground;
  const CategoryColorPalette({required this.background, required this.foreground});
}

/// 根据分类图标与名称智能推导色彩搭配（自动适配亮/暗色模式）
CategoryColorPalette getCategoryColorPalette({
  Category? category,
  String? categoryName,
  required bool isDark,
  Color? primaryColor,
}) {
  final icon = category?.icon?.toLowerCase() ?? '';
  final name = (categoryName ?? category?.name ?? '').toLowerCase();

  // 1. 餐饮美食 (Amber 琥珀金/暖橙)
  if (icon.contains('restaurant') ||
      icon.contains('dining') ||
      icon.contains('food') ||
      icon.contains('cafe') ||
      icon.contains('coffee') ||
      icon.contains('cake') ||
      icon.contains('bar') ||
      icon.contains('pizza') ||
      icon.contains('ramen') ||
      icon.contains('icecream') ||
      name.contains('餐') ||
      name.contains('饭') ||
      name.contains('吃') ||
      name.contains('外卖') ||
      name.contains('饮') ||
      name.contains('咖啡')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF451A03).withValues(alpha: 0.6),
            foreground: const Color(0xFFFBBF24),
          )
        : const CategoryColorPalette(
            background: Color(0xFFFEF3C7),
            foreground: Color(0xFFD97706),
          );
  }

  // 2. 交通出行 (Sky 天空蓝)
  if (icon.contains('car') ||
      icon.contains('taxi') ||
      icon.contains('subway') ||
      icon.contains('bus') ||
      icon.contains('train') ||
      icon.contains('flight') ||
      icon.contains('transit') ||
      icon.contains('commute') ||
      name.contains('交通') ||
      name.contains('车') ||
      name.contains('出行') ||
      name.contains('机票') ||
      name.contains('地铁') ||
      name.contains('打车') ||
      name.contains('公交') ||
      name.contains('加油')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF082F49).withValues(alpha: 0.6),
            foreground: const Color(0xFF38BDF8),
          )
        : const CategoryColorPalette(
            background: Color(0xFFE0F2FE),
            foreground: Color(0xFF0284C7),
          );
  }

  // 3. 购物消费 (Violet 优雅紫罗兰)
  if (icon.contains('shopping') ||
      icon.contains('cart') ||
      icon.contains('bag') ||
      icon.contains('checkroom') ||
      icon.contains('store') ||
      name.contains('购') ||
      name.contains('买') ||
      name.contains('衣') ||
      name.contains('鞋') ||
      name.contains('服饰') ||
      name.contains('百货') ||
      name.contains('数码') ||
      name.contains('淘宝') ||
      name.contains('京东')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF2E1065).withValues(alpha: 0.6),
            foreground: const Color(0xFFA78BFA),
          )
        : const CategoryColorPalette(
            background: Color(0xFFEDE9FE),
            foreground: Color(0xFF7C3AED),
          );
  }

  // 4. 收入/薪资/理财 (Emerald 翡翠绿)
  if (icon.contains('payments') ||
      icon.contains('money') ||
      icon.contains('trending') ||
      icon.contains('savings') ||
      icon.contains('account_balance') ||
      name.contains('工资') ||
      name.contains('薪') ||
      name.contains('收入') ||
      name.contains('理财') ||
      name.contains('奖金') ||
      name.contains('分红') ||
      name.contains('收益')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF064E3B).withValues(alpha: 0.6),
            foreground: const Color(0xFF34D399),
          )
        : const CategoryColorPalette(
            background: Color(0xFFD1FAE5),
            foreground: Color(0xFF059669),
          );
  }

  // 5. 休闲娱乐 (Rose 活力玫瑰红)
  if (icon.contains('esports') ||
      icon.contains('movie') ||
      icon.contains('game') ||
      icon.contains('sports') ||
      icon.contains('theater') ||
      icon.contains('music') ||
      name.contains('娱乐') ||
      name.contains('游戏') ||
      name.contains('电影') ||
      name.contains('玩') ||
      name.contains('运动')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF4C0519).withValues(alpha: 0.6),
            foreground: const Color(0xFFFB7185),
          )
        : const CategoryColorPalette(
            background: Color(0xFFFFE4E6),
            foreground: Color(0xFFE11D48),
          );
  }

  // 6. 医疗健康 (Teal 清新青绿)
  if (icon.contains('hospital') ||
      icon.contains('medical') ||
      icon.contains('healing') ||
      icon.contains('fitness') ||
      name.contains('医') ||
      name.contains('药') ||
      name.contains('病') ||
      name.contains('体检') ||
      name.contains('健康')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF042F2E).withValues(alpha: 0.6),
            foreground: const Color(0xFF2DD4BF),
          )
        : const CategoryColorPalette(
            background: Color(0xFFCCFBF1),
            foreground: Color(0xFF0D9488),
          );
  }

  // 7. 社交人情 (Coral 珊瑚粉)
  if (icon.contains('gift') ||
      icon.contains('groups') ||
      icon.contains('favorite') ||
      name.contains('礼') ||
      name.contains('请客') ||
      name.contains('聚会') ||
      name.contains('人情') ||
      name.contains('红包')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF4C0519).withValues(alpha: 0.6),
            foreground: const Color(0xFFFDA4AF),
          )
        : const CategoryColorPalette(
            background: Color(0xFFFFF1F2),
            foreground: Color(0xFFF43F5E),
          );
  }

  // 8. 居家生活 (Slate 沉稳灰蓝)
  if (icon.contains('home') ||
      icon.contains('water') ||
      icon.contains('bolt') ||
      icon.contains('chair') ||
      name.contains('房') ||
      name.contains('居') ||
      name.contains('水电') ||
      name.contains('物业') ||
      name.contains('煤气') ||
      name.contains('维修')) {
    return isDark
        ? CategoryColorPalette(
            background: const Color(0xFF1E293B).withValues(alpha: 0.8),
            foreground: const Color(0xFF94A3B8),
          )
        : const CategoryColorPalette(
            background: Color(0xFFF1F5F9),
            foreground: Color(0xFF475569),
          );
  }

  // 默认兜底：科技钴蓝 (Modern Cobalt)
  final cobalt = primaryColor ?? const Color(0xFF2563EB);
  return isDark
      ? CategoryColorPalette(
          background: const Color(0xFF172554).withValues(alpha: 0.6),
          foreground: const Color(0xFF60A5FA),
        )
      : CategoryColorPalette(
          background: const Color(0xFFEFF6FF),
          foreground: cobalt,
        );
}

/// 分类图标组件
/// 支持 Material Icons 和自定义图片，内置现代色彩体系
class CategoryIconWidget extends ConsumerWidget {
  final Category? category;
  final String? categoryName;
  final double size;
  final Color? color;
  final Color? backgroundColor;
  final bool showBackground;
  final bool circular; // 是否使用完全圆形（50%圆角），默认为平滑方圆 Squircle（28%圆角）
  final bool usePalette; // 是否自动启用分类智能配色

  const CategoryIconWidget({
    super.key,
    this.category,
    this.categoryName,
    this.size = 24,
    this.color,
    this.backgroundColor,
    this.showBackground = false,
    this.circular = false,
    this.usePalette = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final palette = usePalette
        ? getCategoryColorPalette(
            category: category,
            categoryName: categoryName,
            isDark: isDark,
            primaryColor: primaryColor,
          )
        : null;

    final iconColor = color ?? palette?.foreground ?? primaryColor;

    // 检查是否有自定义图标
    if (category != null && category!.iconType == 'custom' && category!.customIconPath != null) {
      return _buildCustomIcon(category!.customIconPath!, iconColor, palette?.background);
    }

    // 使用 Material Icon
    final iconData = getCategoryIconData(category: category, categoryName: categoryName);

    if (showBackground) {
      final bgRadius = circular ? size * 0.75 : size * 0.42;
      return Container(
        width: size * 1.6,
        height: size * 1.6,
        decoration: BoxDecoration(
          color: backgroundColor ?? palette?.background ?? iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(bgRadius),
        ),
        child: Center(
          child: Icon(iconData, size: size, color: iconColor),
        ),
      );
    }

    return Icon(iconData, size: size, color: iconColor);
  }

  Widget _buildCustomIcon(String path, Color fallbackColor, Color? paletteBg) {
    // 需要异步解析相对路径,使用 FutureBuilder
    return FutureBuilder<String>(
      future: CustomIconService().resolveIconPath(path),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          // 加载中,显示占位图标
          return Icon(
            Icons.category,
            size: size,
            color: fallbackColor,
          );
        }

        final absolutePath = snapshot.data!;
        final file = File(absolutePath);

        // 图标本身 - 不做圆角裁剪，但填满1:1区域
        final iconWidget = Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover, // 填满整个区域，保持1:1比例
          errorBuilder: (_, __, ___) => Icon(
            Icons.category,
            size: size,
            color: fallbackColor,
          ),
        );

        if (showBackground) {
          // circular 参数只影响背景容器的形状
          final backgroundRadius = circular ? size * 0.75 : size * 0.42;
          return Container(
            width: size * 1.6,
            height: size * 1.6,
            decoration: BoxDecoration(
              color: backgroundColor ?? paletteBg ?? fallbackColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(backgroundRadius),
            ),
            child: Center(child: iconWidget),
          );
        }

        return iconWidget;
      },
    );
  }
}

/// 从 Category 创建 CategoryIconData
CategoryIconData getCategoryIconDataFromCategory(Category category) {
  return CategoryIconData.fromCategory(category);
}
