import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// 通知工具类 - 平台无关的通知抽象层
///
/// 提供统一的通知接口，屏蔽平台差异
abstract class NotificationUtil {
  /// 初始化通知服务
  Future<void> initialize();

  /// 请求通知权限
  Future<bool> requestPermissions();

  /// 调度每日重复提醒
  ///
  /// [id] 通知ID
  /// [title] 通知标题
  /// [body] 通知内容
  /// [hour] 小时 (0-23)
  /// [minute] 分钟 (0-59)
  Future<void> scheduleDailyReminder({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  });

  /// 调度单次提醒
  ///
  /// [id] 通知ID
  /// [title] 通知标题
  /// [body] 通知内容
  /// [scheduledDate] 调度时间
  Future<void> scheduleOnceReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  });

  /// 取消指定通知
  Future<void> cancelNotification(int id);

  /// 取消所有通知
  Future<void> cancelAllNotifications();

  /// 立即显示通知
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  });

  /// 获取待处理的通知列表
  Future<List<PendingNotificationRequest>> getPendingNotifications();

  /// 检查通知权限状态
  Future<bool> checkPermissionStatus();
}

/// 通知详情配置
class NotificationDetails {
  final String channelId;
  final String channelName;
  final String channelDescription;
  final bool enableVibration;
  final bool playSound;
  final bool showBadge;

  const NotificationDetails({
    required this.channelId,
    required this.channelName,
    required this.channelDescription,
    this.enableVibration = true,
    this.playSound = true,
    this.showBadge = true,
  });
}

/// 计算下一次提醒时间
///
/// 如果指定时间已过，返回明天的该时间。
///
/// [hour] 必须在 0-23、[minute] 必须在 0-59 —— 越界直接抛 [ArgumentError]。
/// 不能让 `DateTime` 构造器"溢出进位":`(25, 61)` 会静默变成次日 02:01,
/// 调用方(以及用户)看到的是一个看似合法但完全不是自己设定的提醒时刻。
/// 选择抛错而非钳制:提醒时间是用户显式设定的语义值,静默改写成 23:59
/// 同样是错的时刻,只会把 bug 藏得更深。
DateTime calculateNextReminderTime(int hour, int minute) {
  if (hour < 0 || hour > 23) {
    throw ArgumentError.value(hour, 'hour', 'hour 必须在 0-23 之间');
  }
  if (minute < 0 || minute > 59) {
    throw ArgumentError.value(minute, 'minute', 'minute 必须在 0-59 之间');
  }

  final now = DateTime.now();
  var scheduledDate = DateTime(now.year, now.month, now.day, hour, minute);

  // 如果时间已过，则设置为明天
  if (scheduledDate.isBefore(now)) {
    scheduledDate = scheduledDate.add(const Duration(days: 1));
  }

  return scheduledDate;
}

/// 转换为时区时间
tz.TZDateTime convertToTZDateTime(DateTime dateTime) {
  return tz.TZDateTime(
    tz.local,
    dateTime.year,
    dateTime.month,
    dateTime.day,
    dateTime.hour,
    dateTime.minute,
    dateTime.second,
  );
}
