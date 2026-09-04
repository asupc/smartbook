import 'dart:io';
import 'package:flutter/foundation.dart';

/// 平台信息工具类
class PlatformInfo {
  /// 检查是否为iOS平台
  static bool get isIOS => !kIsWeb && Platform.isIOS;

  /// 检查是否为Android平台
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// 获取iOS主版本号
  /// 返回 null 如果不是iOS平台
  static int? get iOSMajorVersion {
    if (!isIOS) return null;

    try {
      // Platform.operatingSystemVersion 返回类似 "Version 16.0 (Build 20A5283p)"
      final version = Platform.operatingSystemVersion;
      final versionMatch = RegExp(r'Version (\d+)\.').firstMatch(version);

      if (versionMatch != null) {
        return int.tryParse(versionMatch.group(1) ?? '');
      }
    } catch (e) {
      // 解析失败，返回null
    }

    return null;
  }

  /// 检查iOS版本是否 >= 指定版本
  /// 如果不是iOS平台，返回false
  static bool isIOSVersionAtLeast(int majorVersion) {
    final version = iOSMajorVersion;
    return version != null && version >= majorVersion;
  }

  /// 检查是否支持AppIntents (iOS 16+)
  /// 注意：由于App最低部署目标为iOS 16.0，在iOS上此值始终为true
  /// 但保留此检查以便代码清晰和未来可能的条件编译
  static bool get supportsAppIntents => isIOSVersionAtLeast(16);

  /// 检查是否支持截图自动记账
  /// iOS 16+ 使用AppIntents
  /// Android可能有其他实现
  /// 注意：iOS版App最低要求iOS 16.0，因此iOS设备上此值始终为true
  static bool get supportsAutoScreenshotBilling {
    if (isIOS) {
      return supportsAppIntents;
    }
    // Android 暂不支持
    return false;
  }
}
