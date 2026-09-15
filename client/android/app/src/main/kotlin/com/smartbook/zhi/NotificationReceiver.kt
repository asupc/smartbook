package com.smartbook.zhi

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class NotificationReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NotificationReceiver"
        // Dart shared_preferences 的持久化文件与 key 前缀(reminder_providers)
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val KEY_REMINDER_ENABLED = "flutter.reminder_enabled"
        private const val KEY_REMINDER_HOUR = "flutter.reminder_hour"
        private const val KEY_REMINDER_MINUTE = "flutter.reminder_minute"
        private const val REMINDER_ID = 1001
        private const val REMINDER_TITLE = "记账提醒"
        private const val REMINDER_BODY = "别忘了记录今天的收支哦 💰"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "收到广播: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_PACKAGE_REPLACED -> {
                Log.d(TAG, "系统启动或应用更新，需要重新调度通知")
                rescheduleNotifications(context)
            }
            else -> {
                // 处理定时通知
                val title = intent.getStringExtra("title") ?: REMINDER_TITLE
                val body = intent.getStringExtra("body") ?: REMINDER_BODY
                val notificationId = intent.getIntExtra("notificationId", REMINDER_ID)
                showNotification(context, title, body, notificationId)
                // C10:boot 重建的闹钟链按天自续(用户下次打开 App 后由 Dart
                // _restoreUserReminder 重建完整调度,双链同 id 通知互相覆盖,
                // 用户侧仍只看到一条)。
                if (intent.getBooleanExtra("boot_rescheduled", false)) {
                    scheduleNextDailyReminder(context, readReminderPrefs(context))
                }
            }
        }
    }

    private data class ReminderPrefs(val enabled: Boolean, val hour: Int, val minute: Int)

    private fun readReminderPrefs(context: Context): ReminderPrefs {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        return ReminderPrefs(
            enabled = prefs.getBoolean(KEY_REMINDER_ENABLED, false),
            hour = prefs.getInt(KEY_REMINDER_HOUR, 21),
            minute = prefs.getInt(KEY_REMINDER_MINUTE, 0),
        )
    }

    /**
     * C10(2026-09-15):BOOT_COMPLETED 后台 startActivity 在 Android 10+ 被
     * 系统后台启动限制拦截(非 vivo 豁免场景静默失败,旧实现即此路径)。
     * 改为原生直读 Dart 侧持久化的提醒配置(reminder_enabled/hour/minute),
     * 用 AlarmManager 重挂下一次提醒;无 workmanager 依赖(pubspec 只读)。
     * 用户下次打开 App 时 Dart _restoreUserReminder 会重建完整调度
     * (每日重复 + 7 天备用 + AlarmManager 备用),本链自然并入。
     */
    private fun rescheduleNotifications(context: Context) {
        val prefs = readReminderPrefs(context)
        if (!prefs.enabled) {
            Log.d(TAG, "记账提醒未启用,跳过重挂")
            return
        }
        scheduleNextDailyReminder(context, prefs)
    }

    /** 重挂下一次 hour:minute 的提醒(已过点则顺延到明天)。 */
    private fun scheduleNextDailyReminder(context: Context, prefs: ReminderPrefs) {
        val cal = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, prefs.hour)
            set(java.util.Calendar.MINUTE, prefs.minute)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) {
                add(java.util.Calendar.DAY_OF_YEAR, 1)
            }
        }
        val intent = Intent(context, NotificationReceiver::class.java).apply {
            action = "${context.packageName}.NOTIFICATION_ALARM"
            putExtra("title", REMINDER_TITLE)
            putExtra("body", REMINDER_BODY)
            putExtra("notificationId", REMINDER_ID)
            putExtra("boot_rescheduled", true)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            REMINDER_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager.canScheduleExactAlarms()
            if (canExact) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, cal.timeInMillis, pendingIntent)
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, cal.timeInMillis, pendingIntent)
            }
            Log.d(TAG, "C10 已重挂下次记账提醒: ${cal.timeInMillis}(boot 链)")
        } catch (e: SecurityException) {
            // 无精确闹钟权限时降级为非精确闹钟,仍然可触发
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, cal.timeInMillis, pendingIntent)
            Log.w(TAG, "精确闹钟不可用,降级非精确: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "重挂记账提醒失败: ${e.message}")
        }
    }

    private fun showNotification(context: Context, title: String, body: String, notificationId: Int) {
        Log.d("NotificationReceiver", "开始显示通知: ID=$notificationId")
        Log.d("NotificationReceiver", "标题: $title")
        Log.d("NotificationReceiver", "内容: $body")

        try {
            val channelId = "accounting_reminder"
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // 创建通知渠道（Android 8.0+）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                val audioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build()

                val channel = NotificationChannel(
                    channelId,
                    "记账提醒",
                    NotificationManager.IMPORTANCE_MAX // 使用最高重要性来显示横幅
                ).apply {
                    description = "每日记账提醒"
                    enableVibration(true)
                    enableLights(true)
                    setBypassDnd(true) // 允许在勿扰模式下显示
                    setSound(soundUri, audioAttributes)
                    vibrationPattern = longArrayOf(0, 500, 250, 500, 250, 500)
                    lightColor = android.graphics.Color.BLUE
                    lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                }
                notificationManager.createNotificationChannel(channel)
                Log.d("NotificationReceiver", "通知渠道已创建/更新 - 包含声音和震动")
            }

            // 检查通知权限
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                if (!notificationManager.areNotificationsEnabled()) {
                    Log.w("NotificationReceiver", "⚠️ 通知权限未开启")
                    return
                }
            }

            // 创建点击通知的PendingIntent - 尝试多种方法
            Log.d("NotificationReceiver", "开始创建PendingIntent")

            // 直接使用MainActivity处理通知点击
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("from_notification", true)
                putExtra("from_notification_click", true)
                putExtra("notification_id", notificationId)
                putExtra("title", title)
                putExtra("timestamp", System.currentTimeMillis())
                putExtra("click_timestamp", System.currentTimeMillis())
            }

            Log.d("NotificationReceiver", "Click Intent: $clickIntent")
            Log.d("NotificationReceiver", "Click Intent flags: ${clickIntent.flags}")

            val pendingIntent = PendingIntent.getActivity(
                context,
                notificationId, // 使用通知ID作为requestCode
                clickIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )

            Log.d("NotificationReceiver", "PendingIntent创建完成: $pendingIntent")

            // 创建通知 - 简化配置，重点确保点击功能
            val notificationBuilder = NotificationCompat.Builder(context, channelId)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true) // 点击后自动取消
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setWhen(System.currentTimeMillis())
                .setShowWhen(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(pendingIntent) // 关键：设置点击Intent

            // 验证点击Intent是否正确设置
            if (pendingIntent != null) {
                Log.d("NotificationReceiver", "✅ 已设置通知点击Intent: $pendingIntent")
            } else {
                Log.e("NotificationReceiver", "❌ PendingIntent为null，通知无法点击")
            }

            val notification = notificationBuilder.build()

            // 显示通知
            notificationManager.notify(notificationId, notification)
            Log.d("NotificationReceiver", "✅ 通知已发送: ID=$notificationId")
        } catch (e: Exception) {
            Log.e("NotificationReceiver", "❌ 显示通知失败: $e")
        }
    }
}