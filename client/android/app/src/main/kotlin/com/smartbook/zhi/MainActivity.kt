package com.smartbook.zhi

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContentUris
import android.content.Intent
import android.content.IntentFilter
import android.content.ComponentName
import android.content.IntentSender
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "notification_channel"
    private val INSTALL_CHANNEL = "com.smartbook.zhi/install"
    private val SCREENSHOT_CHANNEL = "com.smartbook.zhi/screenshot"
    private val SMS_CHANNEL = "com.smartbook.zhi/sms"
    private val NOTIFY_CHANNEL = "com.smartbook.zhi/notify"
    private val SCREEN_TEXT_CHANNEL = "com.smartbook.zhi/screen_text"
    private val LOGGER_CHANNEL = "com.smartbook.logger"
    private val SHARE_CHANNEL = "com.smartbook.zhi/share"

    private var screenshotObserver: ScreenshotObserver? = null

    // SMS 桥接:SmsReceiver 的本地广播 → Flutter(SmsMonitorService 的
    // onSmsCaptured)。仅进程存活时注册;进程被杀死时短信只进持久化队列,
    // 等下次启动 drain。
    private var smsBridgeReceiver: BroadcastReceiver? = null

    // 通知桥接:同上(NotificationWatcher → NotifyMonitorService.onNotifyCaptured)
    private var notifyBridgeReceiver: BroadcastReceiver? = null

    // 屏幕文本桥接:同上(ScreenTextWatcher → ScreenTextMonitorService.onScreenTextCaptured)
    private var screenTextBridgeReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleNotificationIntent(intent)
        handleSharedImage(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent) // 重要：更新当前intent
        handleNotificationIntent(intent)
        handleSharedImage(intent)
    }

    private fun handleSharedImage(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("image/") == true) {
            android.util.Log.d("MainActivity", "✅ 收到图片分享")
            LoggerPlugin.info("MainActivity", "收到图片分享")

            val imageUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (imageUri != null) {
                android.util.Log.d("MainActivity", "图片URI: $imageUri")
                LoggerPlugin.info("MainActivity", "分享图片URI: $imageUri")

                try {
                    // 复制图片到临时文件
                    val imagePath = copySharedImageToTemp(imageUri)
                    if (imagePath != null) {
                        android.util.Log.d("MainActivity", "图片已保存到: $imagePath")
                        LoggerPlugin.info("MainActivity", "分享图片已保存: $imagePath")

                        // 通知Flutter端（延迟一下确保Flutter已初始化）
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            notifyFlutterSharedImage(imagePath)
                        }, 500)
                    }
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "处理分享图片失败: $e")
                    LoggerPlugin.error("MainActivity", "处理分享图片失败: ${e.message}")
                }
            }
        }
    }

    private fun copySharedImageToTemp(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null

            // 创建临时文件
            val tempDir = File(cacheDir, "shared_images")
            tempDir.mkdirs()

            val timestamp = System.currentTimeMillis()
            val tempFile = File(tempDir, "shared_$timestamp.jpg")

            // 复制图片数据
            tempFile.outputStream().use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()

            tempFile.absolutePath
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "复制图片失败: $e")
            LoggerPlugin.error("MainActivity", "复制分享图片失败: ${e.message}")
            null
        }
    }

    private fun notifyFlutterSharedImage(imagePath: String) {
        try {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, SHARE_CHANNEL).invokeMethod("onImageShared", imagePath)
                android.util.Log.d("MainActivity", "✅ 已通知Flutter端: $imagePath")
                LoggerPlugin.info("MainActivity", "已通知Flutter端收到分享图片")
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "通知Flutter失败: $e")
            LoggerPlugin.error("MainActivity", "通知Flutter失败: ${e.message}")
        }
    }

    private fun handleNotificationIntent(intent: Intent?) {
        // 检查是否是从通知点击启动的
        val fromNotification = intent?.getBooleanExtra("from_notification", false) ?: false
        val fromNotificationClick = intent?.getBooleanExtra("from_notification_click", false) ?: false
        val notificationId = intent?.getIntExtra("notification_id", -1) ?: -1
        val timestamp = intent?.getLongExtra("timestamp", 0L) ?: 0L
        val clickTimestamp = intent?.getLongExtra("click_timestamp", 0L) ?: 0L

        if (fromNotification || fromNotificationClick) {
            android.util.Log.d("MainActivity", "✅ 应用从通知点击启动!")
            android.util.Log.d("MainActivity", "通知ID: $notificationId")
            android.util.Log.d("MainActivity", "时间戳: $timestamp")
            android.util.Log.d("MainActivity", "点击时间戳: $clickTimestamp")
            android.util.Log.d("MainActivity", "启动方式: ${if (fromNotificationClick) "BroadcastReceiver" else "Direct"}")
            android.util.Log.d("MainActivity", "Intent: $intent")

            // 这里可以添加其他处理逻辑，比如跳转到特定页面
        } else {
            android.util.Log.d("MainActivity", "应用正常启动（非通知点击）")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        android.util.Log.e("MainActivity", "==========================================")
        android.util.Log.e("MainActivity", "configureFlutterEngine 被调用！！！")
        android.util.Log.e("MainActivity", "==========================================")

        // 日志桥接的MethodChannel
        val loggerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOGGER_CHANNEL)
        android.util.Log.e("MainActivity", "即将调用 LoggerPlugin.setup")
        LoggerPlugin.setup(loggerChannel)
        android.util.Log.e("MainActivity", "LoggerPlugin.setup 调用完成")

        // 测试日志
        LoggerPlugin.info("MainActivity", "日志系统已初始化")

        // 延迟发送测试日志，确保 Flutter 端已就绪
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            LoggerPlugin.info("MainActivity", "延迟测试日志 - Flutter 端应该已就绪")
            LoggerPlugin.debug("MainActivity", "这是一条 DEBUG 日志")
            LoggerPlugin.warning("MainActivity", "这是一条 WARNING 日志")
            LoggerPlugin.error("MainActivity", "这是一条 ERROR 日志")
        }, 2000)

        // 截图监听的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREENSHOT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScreenshotObserver" -> {
                    startScreenshotObserver(flutterEngine)
                    result.success(true)
                }
                "stopScreenshotObserver" -> {
                    stopScreenshotObserver()
                    result.success(true)
                }
                // 「记账成功自动删截图」:删除 MediaStore 中的截图
                // (详见 deleteScreenshotFile 注释)
                "deleteScreenshot" -> {
                    val path = call.argument<String>("path")
                    result.success(if (path != null) deleteScreenshotFile(path) else false)
                }
                // 截图事件先持久化入队，Flutter 处理到终态后再 ACK；这样
                // AI/数据库异常或进程被杀不会靠路径缓存静默丢图。
                "peekPendingScreenshots" -> {
                    result.success(ScreenshotObserver.peekQueue(this))
                }
                "ackPendingScreenshots" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    ScreenshotObserver.ackQueue(this, paths)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 短信监听的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // 开关同步:native SmsReceiver 接收前先看该标志,关闭时不进队列
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val prefs = getSharedPreferences(SmsReceiver.PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().putBoolean(SmsReceiver.KEY_ENABLED, enabled).apply()
                    result.success(true)
                }
                "registerBridge" -> {
                    registerSmsBridge(flutterEngine)
                    result.success(true)
                }
                "unregisterBridge" -> {
                    unregisterSmsBridge()
                    result.success(true)
                }
                // peek 不清空;处理完逐项 ack(被杀只丢正在处理的一条)
                "peekPendingSms" -> {
                    result.success(SmsReceiver().peekQueue(this))
                }
                "ackPendingSms" -> {
                    val fingerprints =
                        call.argument<List<String>>("fingerprints") ?: emptyList()
                    val eventKeys =
                        call.argument<List<String>>("eventKeys") ?: emptyList()
                    SmsReceiver().ackSms(this, fingerprints, eventKeys)
                    result.success(true)
                }
                "getQueueSize" -> {
                    result.success(SmsReceiver().queueSize(this))
                }
                else -> result.notImplemented()
            }
        }

        // 通知监听的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val prefs = getSharedPreferences(NotificationWatcher.PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().putBoolean(NotificationWatcher.KEY_ENABLED, enabled).apply()
                    result.success(true)
                }
                // 系统「通知使用权」是否已授权(监听能否真实生效)
                "isListenerGranted" -> {
                    val granted = android.provider.Settings.Secure.getString(
                        contentResolver,
                        "enabled_notification_listeners"
                    )?.let { it.contains(packageName) } ?: false
                    result.success(granted)
                }
                "openListenerSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    } catch (e: Exception) {
                        Log.e("MainActivity", "打开通知使用权设置失败", e)
                    }
                    result.success(true)
                }
                "registerBridge" -> {
                    registerNotifyBridge(flutterEngine)
                    result.success(true)
                }
                "unregisterBridge" -> {
                    unregisterNotifyBridge()
                    result.success(true)
                }
                "peekPending" -> {
                    result.success(NotificationWatcher().peekQueue(this))
                }
                "ackPending" -> {
                    val fingerprints =
                        call.argument<List<String>>("fingerprints") ?: emptyList()
                    NotificationWatcher().ackQueue(this, fingerprints)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 屏幕文本监听(账单详情页自动记账)的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_TEXT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val prefs = getSharedPreferences(ScreenTextWatcher.PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().putBoolean(ScreenTextWatcher.KEY_ENABLED, enabled).apply()
                    result.success(true)
                }
                // 系统「无障碍」服务是否已授权(监听能否真实生效)。
                // enabled_accessibility_services 用 ':' 分隔组件名(pkg/cls),
                // 用 "$packageName/" 精确匹配,避免同前缀包名误判。
                "isAccessibilityGranted" -> {
                    val enabled = Settings.Secure.getString(
                        contentResolver,
                        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                    )?.split(":")?.any { it.trim().startsWith("$packageName/") } ?: false
                    result.success(enabled)
                }
                // 是否 vivo/iQOO 设备(引导 UI 决定是否展示 vivo 专属自救提示)
                "isVivoDevice" -> {
                    result.success(
                        Build.MANUFACTURER.contains("vivo", true) ||
                            Build.MANUFACTURER.contains("iqoo", true)
                    )
                }
                "openAccessibilitySettings" -> {
                    // vivo(含 iQOO):直接落「无障碍」列表页。实测 OriginOS 上
                    // ACCESSIBILITY_DETAILS_SETTINGS 详情页的开关被 ROM 的
                    // 「受限设置/诚信检测」拦截时,开关回弹秒关且用户无任何
                    // 提示(表现为「一开就关」);从列表页进同一服务再开,命中
                    // 的管控路径不同,多数情况能正常保持。其余厂商保持详情页
                    // (少一次跳转)。
                    if (Build.MANUFACTURER.contains("vivo", true) ||
                        Build.MANUFACTURER.contains("iqoo", true)
                    ) {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    } else {
                        // 优先「无障碍」服务详情页(可直接开关本服务),按钮设置
                        // intent 的 action 用字面量(ACTION_ACCESSIBILITY_DETAILS_SETTINGS
                        // 编译常量不可用时,动作语义相同);失败兜底列表页。
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val intent = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").apply {
                                    putExtra(
                                        Intent.EXTRA_COMPONENT_NAME,
                                        ComponentName(
                                            this@MainActivity,
                                            "com.google.android.accessibility.selecttospeak.SelectToSpeakService"
                                        )
                                    )
                                }
                                startActivity(intent)
                            } else {
                                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "打开无障碍设置失败", e)
                            try {
                                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            } catch (e2: Exception) {
                                Log.e("MainActivity", "打开无障碍设置列表页失败", e2)
                            }
                        }
                        result.success(true)
                    }
                }
                "registerBridge" -> {
                    registerScreenTextBridge(flutterEngine)
                    result.success(true)
                }
                "unregisterBridge" -> {
                    unregisterScreenTextBridge()
                    result.success(true)
                }
                "peekPending" -> {
                    result.success(ScreenTextWatcher().peekQueue(this))
                }
                "ackPending" -> {
                    val fingerprints =
                        call.argument<List<String>>("fingerprints") ?: emptyList()
                    val eventKeys =
                        call.argument<List<String>>("eventKeys") ?: emptyList()
                    ScreenTextWatcher().ackQueue(this, fingerprints, eventKeys)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 安装APK的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        val success = installApkWithIntent(filePath)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "文件路径不能为空", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 通知相关的MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleNotification" -> {
                    val title = call.argument<String>("title") ?: "记账提醒"
                    val body = call.argument<String>("body") ?: "别忘了记录今天的收支哦 💰"
                    val scheduledTimeMillis = call.argument<Long>("scheduledTimeMillis") ?: 0
                    val notificationId = call.argument<Int>("notificationId") ?: 1001
                    
                    scheduleNotification(title, body, scheduledTimeMillis, notificationId)
                    result.success(true)
                }
                "cancelNotification" -> {
                    val notificationId = call.argument<Int>("notificationId") ?: 1001
                    cancelNotification(notificationId)
                    result.success(true)
                }
                "requestAutoStartGuide" -> {
                    result.success(requestAutoStartGuide())
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(true)
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                "getBatteryOptimizationInfo" -> {
                    result.success(getBatteryOptimizationInfo())
                }
                "openNotificationChannelSettings" -> {
                    openNotificationChannelSettings()
                    result.success(true)
                }
                "getNotificationChannelInfo" -> {
                    result.success(getNotificationChannelInfo())
                }
                "testDirectNotification" -> {
                    val title = call.argument<String>("title") ?: "直接测试通知"
                    val body = call.argument<String>("body") ?: "这是直接调用NotificationReceiver的测试"
                    val notificationId = call.argument<Int>("notificationId") ?: 7777

                    testDirectNotification(title, body, notificationId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scheduleNotification(title: String, body: String, scheduledTimeMillis: Long, notificationId: Int) {
        try {
            android.util.Log.d("MainActivity", "开始调度通知: ID=$notificationId, 时间=$scheduledTimeMillis")
            android.util.Log.d("MainActivity", "标题: $title")
            android.util.Log.d("MainActivity", "内容: $body")

            val intent = Intent(this, NotificationReceiver::class.java).apply {
                putExtra("title", title)
                putExtra("body", body)
                putExtra("notificationId", notificationId)
                // 使用动态包名构建action
                action = "${packageName}.NOTIFICATION_ALARM"
            }

            val pendingIntent = PendingIntent.getBroadcast(
                this,
                notificationId,
                intent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )

            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager

            // 检查是否有精确闹钟权限
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!alarmManager.canScheduleExactAlarms()) {
                    android.util.Log.w("MainActivity", "⚠️ 没有精确闹钟权限，尝试请求权限")
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                        startActivity(intent)
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "无法打开精确闹钟权限设置: $e")
                    }
                    return
                }
            }

            // 计算时间差用于调试
            val currentTime = System.currentTimeMillis()
            val timeDiff = scheduledTimeMillis - currentTime
            android.util.Log.d("MainActivity", "当前时间: $currentTime")
            android.util.Log.d("MainActivity", "调度时间: $scheduledTimeMillis")
            android.util.Log.d("MainActivity", "时间差: ${timeDiff / 1000}秒")

            if (timeDiff <= 0) {
                android.util.Log.w("MainActivity", "⚠️ 调度时间已过期，立即发送通知")
                // 如果时间已过，立即发送通知
                val receiver = NotificationReceiver()
                receiver.onReceive(this, intent)
                return
            }

            // 使用setExactAndAllowWhileIdle确保在休眠模式下也能触发
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.util.Log.d("MainActivity", "使用 setExactAndAllowWhileIdle 调度通知")
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, scheduledTimeMillis, pendingIntent)
            } else {
                android.util.Log.d("MainActivity", "使用 setExact 调度通知")
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, scheduledTimeMillis, pendingIntent)
            }

            android.util.Log.d("MainActivity", "✅ AlarmManager 通知调度成功")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "❌ AlarmManager 通知调度失败: $e")
        }
    }

    private fun cancelNotification(notificationId: Int) {
        android.util.Log.d("MainActivity", "取消通知: ID=$notificationId")
        val intent = Intent(this, NotificationReceiver::class.java).apply {
            action = "${packageName}.NOTIFICATION_ALARM"
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            notificationId,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent)
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            powerManager.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                try {
                    startActivity(intent)
                } catch (e: Exception) {
                    // 如果无法打开请求页面，则打开应用设置
                    openAppSettings()
                }
            }
        }
    }

    /**
     * 自启动/后台保活引导(M4):按覆盖度依次尝试厂商「自启动管理」设置页
     * (vivo/OPPO/小米/华为),成功返回 true;没有厂商页则兜底打开应用详情
     * 页(用户可手动找"自启动"),失败返回 false。
     */
    private fun requestAutoStartGuide(): Boolean {
        val candidates = listOf(
            // vivo OriginOS(含 iQOO)
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            // OPPO / 一加
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            // 小米 / 红米
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            // 华为 / 荣耀
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity")
        )
        for (component in candidates) {
            try {
                val intent = Intent().setComponent(component)
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (e: Exception) {
                Log.d("MainActivity", "自启动引导失败: ${component.flattenToString()}", e)
            }
        }
        return try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            )
            true
        } catch (e: Exception) {
            Log.e("MainActivity", "打开应用详情页失败", e)
            false
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
    }

    private fun getBatteryOptimizationInfo(): Map<String, Any> {
        val isIgnoring = isIgnoringBatteryOptimizations()
        val canRequest = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
        val manufacturer = Build.MANUFACTURER

        return mapOf(
            "isIgnoring" to isIgnoring,
            "canRequest" to canRequest,
            "manufacturer" to manufacturer,
            "model" to Build.MODEL,
            "androidVersion" to Build.VERSION.RELEASE
        )
    }

    private fun openNotificationChannelSettings() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    putExtra(Settings.EXTRA_CHANNEL_ID, "accounting_reminder")
                }
                startActivity(intent)
                android.util.Log.d("MainActivity", "打开通知渠道设置页面")
            } else {
                // Android 8.0以下版本打开应用通知设置
                openAppSettings()
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "打开通知渠道设置失败: $e")
            // fallback到应用设置
            openAppSettings()
        }
    }

    private fun getNotificationChannelInfo(): Map<String, Any> {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val channel = notificationManager.getNotificationChannel("accounting_reminder")

                if (channel != null) {
                    val importanceLevel = when (channel.importance) {
                        NotificationManager.IMPORTANCE_NONE -> "none"
                        NotificationManager.IMPORTANCE_MIN -> "min"
                        NotificationManager.IMPORTANCE_LOW -> "low"
                        NotificationManager.IMPORTANCE_DEFAULT -> "default"
                        NotificationManager.IMPORTANCE_HIGH -> "high"
                        NotificationManager.IMPORTANCE_MAX -> "max"
                        else -> "unknown"
                    }

                    return mapOf(
                        "isEnabled" to (channel.importance != NotificationManager.IMPORTANCE_NONE),
                        "importance" to importanceLevel,
                        "sound" to (channel.sound != null),
                        "vibration" to channel.shouldVibrate(),
                        "bypassDnd" to channel.canBypassDnd(),
                        "showBadge" to channel.canShowBadge(),
                        "lightColor" to channel.lightColor,
                        "lockscreenVisibility" to channel.lockscreenVisibility
                    )
                } else {
                    android.util.Log.w("MainActivity", "通知渠道 'accounting_reminder' 不存在")
                    return mapOf(
                        "isEnabled" to false,
                        "importance" to "none",
                        "sound" to false,
                        "vibration" to false,
                        "channelExists" to false
                    )
                }
            } else {
                // Android 8.0以下版本的通知设置
                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    notificationManager.areNotificationsEnabled()
                } else {
                    true // 假设旧版本通知是开启的
                }

                return mapOf(
                    "isEnabled" to notificationsEnabled,
                    "importance" to "default",
                    "sound" to true,
                    "vibration" to true,
                    "legacyVersion" to true
                )
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "获取通知渠道信息失败: $e")
            return mapOf(
                "isEnabled" to false,
                "importance" to "unknown",
                "sound" to false,
                "vibration" to false,
                "error" to (e.message ?: "Unknown error")
            )
        }
    }

    private fun testDirectNotification(title: String, body: String, notificationId: Int) {
        android.util.Log.d("MainActivity", "🔨 开始直接测试NotificationReceiver")
        android.util.Log.d("MainActivity", "标题: $title")
        android.util.Log.d("MainActivity", "内容: $body")
        android.util.Log.d("MainActivity", "ID: $notificationId")

        try {
            val receiver = NotificationReceiver()
            val intent = Intent().apply {
                putExtra("title", title)
                putExtra("body", body)
                putExtra("notificationId", notificationId)
            }

            receiver.onReceive(this, intent)
            android.util.Log.d("MainActivity", "✅ NotificationReceiver调用完成")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "❌ 直接测试NotificationReceiver失败: $e")
        }
    }

    // 系统删除确认框的返回码(startIntentSenderForResult),结果无需处理:
    // 确认后由系统完成删除,取消则保留截图。
    private val DELETE_SCREENSHOT_REQUEST = 9801

    /**
     * 「记账成功自动删截图」:删除 MediaStore 中的截图文件。
     *
     * 截图由系统(SystemUI)写入,非本应用媒体,删除权限分三档:
     * - API 29(Android 10):requestLegacyExternalStorage + WRITE_EXTERNAL_STORAGE 下
     *   ContentResolver.delete 可直接删;
     * - API 30+:删除会抛 RecoverableSecurityException / SecurityException,需弹
     *   系统确认框 —— 用户确认后由系统删除(勾选「不再询问」后后续静默完成,
     *   与系统相册类 App 行为一致);
     * - 图中还有 MediaStore 行丢失的兜底:直接 File.delete。
     *
     * 返回 true = 已删除,或成功弹出确认框(结果不阻塞记账流程);false = 保留。
     */
    private fun deleteScreenshotFile(path: String): Boolean {
        return try {
            val uri = findImageUriByPath(path)
            if (uri != null) {
                deleteMediaUri(uri)
            } else {
                File(path).delete()
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "删除截图失败: $path", e)
            LoggerPlugin.error("MainActivity", "删除截图失败: $path")
            false
        }
    }

    /** 通过 DATA 路径反查 MediaStore 行 URI;查不到返回 null。 */
    private fun findImageUriByPath(path: String): Uri? {
        return try {
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID),
                "${MediaStore.Images.Media.DATA} = ?",
                arrayOf(path),
                null
            )?.use { c ->
                if (c.moveToFirst()) {
                    ContentUris.withAppendedId(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        c.getLong(0)
                    )
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "反查截图 MediaStore 行失败: ${e.message}")
            null
        }
    }

    private fun deleteMediaUri(uri: Uri): Boolean {
        // 1) 直接删:本应用文件 / API 29 legacy / 用户已勾选「不再询问」后放行
        try {
            if (contentResolver.delete(uri, null, null) > 0) {
                Log.d("MainActivity", "截图已直接删除: $uri")
                return true
            }
            // 返回 0 行说明行已不存在(可能上次确认后已被系统删掉,MediaStore
            // 有延迟) — 视为已删除。
            Log.w("MainActivity", "MediaStore 删除返回 0 行(视为已删): $uri")
            return true
        } catch (e: SecurityException) {
            // 2) API 30+:统一删除确认框(带「不再询问」选项),用户确认后由
            //    系统删除。RecoverableSecurityException 是 SecurityException
            //    的子类,一并落在此处;不单独处理它的 userAction —— API 36 起
            //    getUserAction() 返回 RemoteAction,与 API 29 的 UserAction
            //    类型不同,编译期写死某一版会崩另一版。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val pendingIntent =
                    MediaStore.createDeleteRequest(contentResolver, listOf(uri))
                dispatchDeleteConfirm(pendingIntent.intentSender)
                return true
            }
            // API 29:legacy storage + WRITE_EXTERNAL_STORAGE 通常可直删;
            // 仍被系统拒绝时保留截图(不弹单文件确认框,避免跨版本类型问题)。
            throw e
        }
    }

    private fun dispatchDeleteConfirm(intentSender: IntentSender?) {
        if (intentSender == null) return
        try {
            startIntentSenderForResult(
                intentSender, DELETE_SCREENSHOT_REQUEST, null, 0, 0, 0, null
            )
        } catch (e: Exception) {
            Log.e("MainActivity", "发起截图删除确认失败", e)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DELETE_SCREENSHOT_REQUEST) {
            // 闭环日志:vivo 等 ROM 的确认框不一定带「不再询问」,用户每次
            // 确认/取消都记录,便于区分「没授权」与「删了但查不到」。
            Log.d(
                "MainActivity",
                "截图删除确认框结果: resultCode=$resultCode " +
                    "(RESULT_OK=-1 用户确认, RESULT_CANCELED=0 用户取消)"
            )
        }
    }

    private fun startScreenshotObserver(flutterEngine: FlutterEngine) {
        try {
            android.util.Log.d("MainActivity", "========== 开始启动截图监听服务 ==========")
            LoggerPlugin.info("MainActivity", "开始启动截图监听服务")

            // 先停止旧的监听(如果有)
            stopScreenshotObserver()

            // 使用 ContentObserver 监听媒体库变化
            android.util.Log.d("MainActivity", "启动 ContentObserver 模式")
            LoggerPlugin.info("MainActivity", "截图监听模式: ContentObserver (监听媒体库变化)")
            startContentObserverMonitor(flutterEngine)

            android.util.Log.d("MainActivity", "========== 截图监听服务启动完成 ==========")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "❌ 启动截图监听失败", e)
            LoggerPlugin.error("MainActivity", "启动截图监听失败: ${e.message}")
        }
    }

    /**
     * 启动 ContentObserver 截图监听
     * 监听媒体库变化，检测新增的截图文件
     */
    private fun startContentObserverMonitor(flutterEngine: FlutterEngine) {
        android.util.Log.d("MainActivity", "📸 配置 ContentObserver 模式...")
        LoggerPlugin.info("MainActivity", "开始配置 ContentObserver 截图监听")

        // 创建ContentObserver
        screenshotObserver = ScreenshotObserver(this) { screenshotPath ->
            android.util.Log.d("MainActivity", "✅ ContentObserver 检测到截图: $screenshotPath")
            LoggerPlugin.info("MainActivity", "ContentObserver 检测到截图，路径: ${screenshotPath.substringAfterLast('/')}")

            // 通知 Flutter 端
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREENSHOT_CHANNEL)
                .invokeMethod("onScreenshotDetected", screenshotPath)
        }

        // 注册ContentObserver
        val uri = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            android.provider.MediaStore.Images.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL)
        } else {
            android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        android.util.Log.d("MainActivity", "   监听URI: $uri")
        contentResolver.registerContentObserver(uri, true, screenshotObserver!!)
        android.util.Log.d("MainActivity", "✅ ContentObserver 已注册到 MediaStore")
        LoggerPlugin.info("MainActivity", "ContentObserver 已注册到 MediaStore")
    }

    private fun stopScreenshotObserver() {
        try {
            // 停止ContentObserver
            screenshotObserver?.let {
                contentResolver.unregisterContentObserver(it)
                screenshotObserver = null
                android.util.Log.d("MainActivity", "✅ ContentObserver已注销")
            }

            android.util.Log.d("MainActivity", "✅ 截图监听已停止")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "❌ 停止截图监听失败", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScreenshotObserver()
        unregisterSmsBridge()
        unregisterNotifyBridge()
        unregisterScreenTextBridge()
    }

    /**
     * 屏幕文本桥接:与 [registerSmsBridge] 完全同构(见其注释),
     * 只是 action / Flutter 方法名不同。
     */
    private fun registerScreenTextBridge(flutterEngine: FlutterEngine) {
        try {
            unregisterScreenTextBridge()
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != ScreenTextWatcher.BRIDGE_ACTION) return
                    try {
                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_TEXT_CHANNEL)
                            .invokeMethod("onScreenTextCaptured", null)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "转发屏幕文本桥接失败(队列仍保留,启动时会补处理): ${e.message}")
                    }
                }
            }
            ContextCompat.registerReceiver(
                this, receiver, IntentFilter(ScreenTextWatcher.BRIDGE_ACTION),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            screenTextBridgeReceiver = receiver
            Log.d("MainActivity", "✅ 屏幕文本桥接接收器已注册")
        } catch (e: Exception) {
            Log.e("MainActivity", "注册屏幕文本桥接接收器失败", e)
        }
    }

    private fun unregisterScreenTextBridge() {
        try {
            val bridge = screenTextBridgeReceiver
            if (bridge != null) {
                unregisterReceiver(bridge)
                screenTextBridgeReceiver = null
                Log.d("MainActivity", "✅ 屏幕文本桥接接收器已注销")
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "注销屏幕文本桥接接收器失败", e)
        }
    }

    /**
     * 通知桥接:与 [registerSmsBridge] 完全同构(见其注释),
     * 只是 action / Flutter 方法名不同。
     */
    private fun registerNotifyBridge(flutterEngine: FlutterEngine) {
        try {
            unregisterNotifyBridge()
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != NotificationWatcher.BRIDGE_ACTION) return
                    try {
                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFY_CHANNEL)
                            .invokeMethod("onNotifyCaptured", null)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "转发通知桥接失败(队列仍保留,启动时会补处理): ${e.message}")
                    }
                }
            }
            ContextCompat.registerReceiver(
                this, receiver, IntentFilter(NotificationWatcher.BRIDGE_ACTION),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            notifyBridgeReceiver = receiver
            Log.d("MainActivity", "✅ 通知桥接接收器已注册")
        } catch (e: Exception) {
            Log.e("MainActivity", "注册通知桥接接收器失败", e)
        }
    }

    private fun unregisterNotifyBridge() {
        try {
            val bridge = notifyBridgeReceiver
            if (bridge != null) {
                unregisterReceiver(bridge)
                notifyBridgeReceiver = null
                Log.d("MainActivity", "✅ 通知桥接接收器已注销")
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "注销通知桥接接收器失败", e)
        }
    }

    /**
     * 注册 SMS 桥接:接收 [SmsReceiver] 发来的本地广播,转发给 Flutter 端
     * (SmsMonitorService 只需"有新短信,请 drain"信号;处理数据从持久化
     * 队列取,与启动恢复路径共用一条 drain 逻辑)。
     *
     * 只在 Activity 存活期间注册 —— 进程被杀死时短信只入队,下次启动 drain。
     */
    private fun registerSmsBridge(flutterEngine: FlutterEngine) {
        try {
            unregisterSmsBridge()
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != SmsReceiver.BRIDGE_ACTION) return
                    try {
                        // Dart 侧 setMethodCallHandler 可能尚未注册(冷启动竞态):
                        // invokeMethod 会走 pending 队列?不会 —— 直接失败,静默
                        // 忽略即可,积压会在启动时 drain。
                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
                            .invokeMethod("onSmsCaptured", null)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "转发短信桥接失败(队列仍保留,启动时会补处理): ${e.message}")
                    }
                }
            }
            ContextCompat.registerReceiver(
                this, receiver, IntentFilter(SmsReceiver.BRIDGE_ACTION),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            smsBridgeReceiver = receiver
            Log.d("MainActivity", "✅ SMS 桥接接收器已注册")
        } catch (e: Exception) {
            Log.e("MainActivity", "注册 SMS 桥接接收器失败", e)
        }
    }

    private fun unregisterSmsBridge() {
        try {
            val bridge = smsBridgeReceiver
            if (bridge != null) {
                unregisterReceiver(bridge)
                smsBridgeReceiver = null
                Log.d("MainActivity", "✅ SMS 桥接接收器已注销")
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "注销 SMS 桥接接收器失败", e)
        }
    }

    private fun installApkWithIntent(filePath: String): Boolean {
        return try {
            android.util.Log.d("MainActivity", "UPDATE_CRASH: 开始原生Intent安装APK: $filePath")

            val sourceFile = File(filePath)
            if (!sourceFile.exists()) {
                android.util.Log.e("MainActivity", "UPDATE_CRASH: APK文件不存在: $filePath")
                return false
            }

            android.util.Log.d("MainActivity", "UPDATE_CRASH: APK文件大小: ${sourceFile.length()} 字节")

            // 直接在缓存根目录创建APK，避免子目录配置问题
            android.util.Log.d("MainActivity", "UPDATE_CRASH: 复制APK到缓存根目录")
            val cachedApk = File(cacheDir, "install.apk")
            sourceFile.copyTo(cachedApk, overwrite = true)
            android.util.Log.d("MainActivity", "UPDATE_CRASH: APK已复制到: ${cachedApk.absolutePath}")

            val intent = Intent(Intent.ACTION_VIEW)

            android.util.Log.d("MainActivity", "UPDATE_CRASH: 使用FileProvider创建URI")
            try {
                android.util.Log.d("MainActivity", "UPDATE_CRASH: 包名: $packageName")
                android.util.Log.d("MainActivity", "UPDATE_CRASH: Authority: $packageName.fileprovider")
                android.util.Log.d("MainActivity", "UPDATE_CRASH: 缓存APK路径: ${cachedApk.absolutePath}")
                android.util.Log.d("MainActivity", "UPDATE_CRASH: 调试 - applicationId: $packageName")
                android.util.Log.d("MainActivity", "UPDATE_CRASH: 调试 - Authority完整: $packageName.fileprovider")

                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    cachedApk
                )
                android.util.Log.d("MainActivity", "UPDATE_CRASH: ✅ FileProvider URI创建成功: $uri")

                intent.setDataAndType(uri, "application/vnd.android.package-archive")
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                android.util.Log.d("MainActivity", "UPDATE_CRASH: URI权限已设置")

            } catch (e: IllegalArgumentException) {
                android.util.Log.e("MainActivity", "UPDATE_CRASH: ❌ FileProvider路径配置错误", e)
                return false
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "UPDATE_CRASH: ❌ FileProvider创建URI失败", e)
                return false
            }

            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

            android.util.Log.d("MainActivity", "UPDATE_CRASH: 启动APK安装Intent")

            // 检查是否有应用可以处理该Intent
            if (intent.resolveActivity(packageManager) != null) {
                android.util.Log.d("MainActivity", "UPDATE_CRASH: 找到可处理APK安装的应用")
                startActivity(intent)
                android.util.Log.d("MainActivity", "UPDATE_CRASH: ✅ APK安装Intent启动成功")
                return true
            } else {
                android.util.Log.e("MainActivity", "UPDATE_CRASH: ❌ 没有应用可以处理APK安装")
                return false
            }

        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "UPDATE_CRASH: ❌ 原生Intent安装失败: $e")
            return false
        }
    }
}
