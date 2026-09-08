import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'styles/tokens.dart';

class BeeTheme {
  // Brand colors - Light Mode
  // 新品牌主色：现代科技钴蓝 (Modern Cobalt Blue)，点缀琥珀金。
  static const Color honeyGold = Color(0xFF2563EB); // 主色（亮色模式 - 现代科技钴蓝）
  static const Color hiveBrown = Color(0xFF64748B); // 辅助色（Slate 500）
  static const Color energyOrange = Color(0xFFF59E0B); // 点缀色（暖琥珀金 Amber 500）
  static const Color paperIvory = Color(0xFFF8FAFC); // 背景（清透冷白灰 Slate 50）
  static const Color textDark = Color(0xFF0F172A); // 文字（深青深黑 Slate 900）

  // Brand colors - Dark Mode
  static const Color honeyGoldDark = Color(0xFF3B82F6); // 主色（暗黑模式 - 亮蓝）
  static const Color hiveBrownDark = Color(0xFF94A3B8); // 辅助色（Slate 400）
  static const Color energyOrangeDark = Color(0xFFFBBF24); // 点缀色（Amber 400）

  static ThemeData lightTheme({TargetPlatform? platform}) {
    final base = ThemeData.light();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjustedTextTheme =
        BeeTypography.buildBase(base.textTheme, isIOS: isIOS)
            .apply(bodyColor: textDark, displayColor: textDark);

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: honeyGold,
        secondary: energyOrange,
        surface: Colors.white,
      ),
      primaryColor: honeyGold,
      scaffoldBackgroundColor: paperIvory,
      appBarTheme: const AppBarTheme(
        backgroundColor: paperIvory,
        foregroundColor: textDark,
        elevation: 0.0,
        centerTitle: true,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: honeyGold,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: honeyGold,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        backgroundColor: Colors.transparent, // 悬浮胶囊样式，外层透明
        elevation: 0,
      ),
      cardTheme: CardTheme(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(
            color: Color(0xFFE2E8F0),
            width: 0.8,
          ),
        ),
      ),
      textTheme: adjustedTextTheme,
    );
  }

  static ThemeData darkTheme({TargetPlatform? platform}) {
    final base = ThemeData.dark();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjusted = BeeTypography.buildBase(base.textTheme, isIOS: isIOS)
        .apply(bodyColor: Colors.white, displayColor: Colors.white);

    return base.copyWith(
      brightness: Brightness.dark,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: honeyGoldDark,              // ⭐ 主色
        onPrimary: Colors.white,             // ⭐ 主色上的前景色（深蓝底白字）
        primaryContainer: honeyGoldDark,     // ⭐ Switch thumb 等组件使用
        onPrimaryContainer: Colors.white,    // ⭐ primaryContainer 上的前景色
        secondary: energyOrangeDark,         // ⭐ 辅助色
        surface: const Color(0xFF111726),    // ⭐ 深空卡片背景
        onSurface: Colors.white,
      ),
      primaryColor: honeyGoldDark,     // ⭐ 主题色
      scaffoldBackgroundColor: const Color(0xFF090D16), // ⭐ 深空曜石灰（沉浸护眼且具有层级深度）
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF090D16),  // ⭐ 与背景一致
        foregroundColor: Colors.white,
        elevation: 0.0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: honeyGoldDark,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: honeyGoldDark,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        backgroundColor: Colors.transparent, // 悬浮胶囊样式，外层透明
        elevation: 0,
      ),
      cardTheme: CardTheme(
        color: const Color(0xFF111726),      // ⭐ 曜石灰卡片
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.08), // ⭐ 柔和白色微边框
            width: 0.8,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.08), // ⭐ 柔和微分割线
        thickness: 0.8,
      ),
      iconTheme: const IconThemeData(
        color: Colors.white,
      ),
      textTheme: adjusted,
    );
  }
}
