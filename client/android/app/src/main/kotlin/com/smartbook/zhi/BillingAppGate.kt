package com.smartbook.zhi

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.Process

/**
 * 截图来源 App 门禁(2026-09-18 策略调整):截图自动记账触发前,先探查截图
 * 时刻的前台 App 是否属于金融/电商类消费 App;非此类 App 内的截图不入队、
 * 不送 OCR/AI,避免任意截图(聊天/表情包/风景)都烧一次识别与 AI 中转。
 *
 * 前台 App 的两个数据源(见 ScreenshotObserver.sourceAppGateBlocking):
 *  1. [ForegroundAppTracker] —— 无障碍服务(ScreenTextWatcher)在可信包过滤
 *     **之前**记录的最近一次前台切换包名。零新增权限,但依赖无障碍服务开启
 *     (四路自动记账互相独立,截图路不能硬依赖它,所以有数据源 2);
 *  2. [UsageStatsProbe] —— UsageStatsManager 查询最近窗口内最后一次
 *     MOVE_TO_FOREGROUND。需用户在系统设置授予「使用情况访问」特殊权限
 *     (AppOps),未授权时查询恒空、静默返回 null。
 *
 * 两个数据源都排除截图系统组件([ScreenshotOverlay],含 SystemUI 与各厂商
 * 截屏/编辑浮窗):截图瞬间这些组件的浮窗会产生窗口事件与 Activity 记录,
 * 不排除会把真前台 App 覆盖掉 —— vivo 真机 2026-09-22 实测,截图后必弹
 * com.vivo.smartshot 编辑浮窗,门禁全部误拦成 smartshot。
 * 自身包名**不**排除 —— 用户在智记内的截图本就不该自动记账。
 */
object BillingAppClassifier {

    /**
     * 金融/电商类消费 App 包名表。contains 子串匹配,与
     * ScreenTextWatcher.TRUSTED_PACKAGES 同风格(覆盖子进程包名如
     * com.tencent.mm:appbrand0、com.ss.android.ugc.aweme.lite)。
     *
     * 银行段与 NotificationWatcher.TRUSTED_PACKAGES 保持一致(该名单已逐家
     * 经应用商店核验);电商/本地生活段按各厂官网包名收录,不确定的(如苏宁)
     * 宁缺勿滥 —— 漏的 App 只是不触发截图自动记账,用户仍可手动分享图片记账;
     * 收错包名则永远不会命中,等价于静默失效。名单外的新 App 用识别记录页的
     * skipped_non_billing_app 决策(detail 含包名)定位后按需增补。
     */
    private val PACKAGES = listOf(
        // ---- 支付/金融 ----
        "com.eg.android.AlipayGphone", // 支付宝
        "com.tencent.mm",              // 微信(支付/账单页;聊天截图由 AI 判非账单兜底)
        "com.unionpay",                // 云闪付
        // ---- 银行(与 NotificationWatcher.TRUSTED_PACKAGES 同名单) ----
        "com.icbc",                    // 中国工商银行
        "com.chinamworld.main",        // 中国建设银行
        "android.bankabc",             // 中国农业银行
        "com.chinamworld.bocmbci",     // 中国银行
        "com.bankcomm.Bankcomm",       // 交通银行
        "cmb.pb",                      // 招商银行
        "com.yitong.mbank.psbc",       // 邮储银行
        "cn.com.cmbc.newmbank",        // 民生银行
        "com.ecitic.bank.mobile",      // 中信银行
        "cn.com.spdb.mobilebank.per",  // 浦发银行
        "com.cib.cibmb",               // 兴业银行
        "com.cgbchina.xpt",            // 广发银行
        "com.hxb.mobile.client",       // 华夏银行
        "com.pingan.paces.ccms",       // 平安口袋银行
        "com.webank.wemoney",          // 微众银行
        "com.mybank.android.phone",    // 网商银行
        // ---- 电商/本地生活 ----
        "com.taobao.taobao",           // 淘宝
        "com.taobao.idlefish",         // 闲鱼
        "com.tmall.wireless",          // 天猫
        "com.jingdong.app.mall",       // 京东
        "com.xunmeng.pinduoduo",       // 拼多多
        "com.ss.android.ugc.aweme",    // 抖音(含极速版)
        "com.sankuai.meituan",         // 美团(含美团外卖)
        "me.ele",                      // 饿了么
        "com.achievo.vipshop",         // 唯品会
        "com.xingin.xhs"               // 小红书
    )

    /** 截图来源包名是否属于金融/电商类消费 App(可触发截图自动记账)。 */
    fun isBillingApp(pkg: String): Boolean {
        return PACKAGES.any { pkg.contains(it) }
    }
}

/**
 * 截图系统组件(厂商截屏/编辑浮窗)识别:截图瞬间 SystemUI 预览浮窗、vivo
 * smartshot 编辑浮窗等会弹到前台,把真前台 App 的窗口事件/Activity 记录
 * 覆盖掉 —— 两个探测数据源([ForegroundAppTracker] 不记录、[UsageStatsProbe]
 * 查询时跳过)都按"透传"处理,探测结果停留在浮窗弹出前的真实前台 App。
 * **命中本表 ≠ 拦截**:排除后取到的前一个前台才是门禁判定对象。
 *
 * 用通用子串而非逐家精确包名:厂商截图组件包名随 ROM 版本变(小米
 * com.miui.screenshot、OPPO/一加 com.oplus.screenshot、荣耀
 * com.hihonor.screenshot…),漏收录的表现是"门禁全拦成该组件包名"
 * (vivo smartshot 真机 2026-09-22 事故),错收录的代价只是"在该 App 里
 * 截图归到上一个前台"且这些组件必非白名单金融 App —— 泛匹配更稳。
 */
object ScreenshotOverlay {

    private val HINTS = listOf(
        "com.android.systemui",           // 截图预览/保存通知(含 :screenshot 子进程)
        "screenshot",                     // MIUI/OPPO/华为/荣耀等 *screenshot* 组件
        "smartshot",                      // vivo/iQOO 截图编辑浮窗 com.vivo.smartshot
        "longshot",                       // 各厂商长截屏组件
        "com.samsung.android.smartcapture" // 三星截屏编辑器(包名不含 screenshot)
    )

    /** 包名是否属于截图系统组件(子串匹配,覆盖 :子进程 后缀)。 */
    fun matches(pkg: String): Boolean {
        return HINTS.any { pkg.contains(it) }
    }
}

/**
 * 前台 App 跟踪:无障碍服务把每次窗口切换事件(TYPE_WINDOW_STATE_CHANGED,
 * 语义 = 前台 App 变化)的包名+时间戳记到这个进程级单例,截图门禁查询。
 *
 * **记录语义是环形队列 + 查询回溯**(vivo 真机 2026-09-23 教训):截屏瞬间
 * 除了 smartshot 编辑浮窗,还会弹 upslide 等多个**系统浮层组件**的窗口事件,
 * 逐个加排除名单是打地鼠 —— 改为「最近 8 条」队列,查询时从新到旧回溯:
 * 白名单 App 命中即判定;系统预装 App(浮层必是系统组件,由查询方经
 * [skipExtra] 注入 PackageManager 判定)透传跳过;第一个真实三方 App 即
 * 判定对象。回溯到底没有 → null → UsageStatsProbe 兜底。
 *
 * 任何切 App 都必然产生窗口切换事件,所以新鲜窗口可以放得宽(默认 10 分钟)
 * —— 静态账单页久看无事件不会把记录变"陈旧"。
 *
 * 线程模型:无障碍回调在主线程写,门禁在 MediaStore 延迟检查(主线程)或
 * 文件兜底线程读,synchronized 保护队列即可。
 */
object ForegroundAppTracker {

    private const val MAX_ENTRIES = 8

    private val entries = ArrayDeque<Pair<String, Long>>()

    /**
     * 最近被排除的截图系统组件包名(诊断字段):正常情况下它被透传、判定对象
     * 是排除前的真实前台;若门禁仍拦成截图组件本身,说明有未覆盖的新组件
     * ——识别记录页 detail 会带出这个字段,直接看到 ROM 实际弹的浮窗包名。
     */
    @Volatile
    var lastSkippedOverlay: String? = null
        private set

    /** 无障碍事件到达时记录前台包名;空包名与截图系统组件不记(见类注释)。 */
    fun recordForeground(pkg: String?, ts: Long = System.currentTimeMillis()) {
        if (pkg.isNullOrEmpty()) return
        if (ScreenshotOverlay.matches(pkg)) {
            lastSkippedOverlay = pkg
            return
        }
        synchronized(entries) {
            entries.addLast(pkg to ts)
            while (entries.size > MAX_ENTRIES) entries.removeFirst()
        }
    }

    /**
     * 回溯查询最近 [maxAgeMs] 内的前台包名:白名单 App 命中立即返回;
     * 截图组件与 [skipExtra](查询方注入的"系统预装透传")跳过;第一个
     * 真实三方 App 作为判定对象返回。无记录/全部超窗/全部被透传 → null。
     */
    fun recentForeground(
        maxAgeMs: Long,
        skipExtra: (String) -> Boolean = { false },
    ): String? {
        val now = System.currentTimeMillis()
        synchronized(entries) {
            for ((pkg, ts) in entries.reversed()) {
                if (now - ts > maxAgeMs) return null // 队列按时间有序,更旧的必超窗
                if (BillingAppClassifier.isBillingApp(pkg)) return pkg
                if (ScreenshotOverlay.matches(pkg) || skipExtra(pkg)) continue
                return pkg
            }
        }
        return null
    }

    /** 仅供单测重置状态。 */
    fun resetForTest() {
        synchronized(entries) { entries.clear() }
        lastSkippedOverlay = null
    }

    /** 仅供排查日志输出队列快照。 */
    fun queueForLog(): String {
        return synchronized(entries) { entries.joinToString(" → ") { it.first } }
    }
}

/**
 * 使用情况访问兜底:无障碍服务未开启时,经 UsageStatsManager 查询最近窗口内
 * 最后一次前台切换。PACKAGE_USAGE_STATS 是 AppOps 特殊权限(声明在
 * AndroidManifest,用户需在系统「使用情况访问」页授权),未授权时
 * queryEvents 返回空列表 —— 这里统一以 null 表达"探测不到",不区分原因。
 */
object UsageStatsProbe {

    /** 查询窗口内最后一次前台包名(截图系统组件除外);未授权/无事件返回 null。 */
    fun lastForegroundPackage(context: Context, windowMs: Long): String? {
        return try {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as? UsageStatsManager ?: return null
            val now = System.currentTimeMillis()
            val events = usm.queryEvents(now - windowMs, now)
            var pkg: String? = null
            val event = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                // MOVE_TO_FOREGROUND 与 ACTIVITY_RESUMED(API 29+)同值(=1),
                // targetSdk 32 直接用旧常量,新旧系统都覆盖。
                if (event.eventType != UsageEvents.Event.MOVE_TO_FOREGROUND) continue
                val p = event.packageName ?: continue
                // 截图组件的浮窗 Activity 记录同样会覆盖真前台,跳过后取的
                // 是浮窗弹出前最后一个真实 App(如 vivo smartshot 场景)。
                if (ScreenshotOverlay.matches(p)) continue
                pkg = p
            }
            pkg
        } catch (_: Exception) {
            null
        }
    }

    /** 「使用情况访问」是否已授权(AppOps,供设置页展示/引导)。 */
    fun isGranted(context: Context): Boolean {
        return try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
    }
}
