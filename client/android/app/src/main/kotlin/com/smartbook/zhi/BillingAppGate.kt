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
 * 两个数据源都排除 com.android.systemui:截图瞬间 SystemUI 的预览浮窗/
 * 保存通知会产生窗口事件与 Activity 记录,不排除会把真前台 App 覆盖掉。
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
 * 前台 App 跟踪:无障碍服务把每次窗口切换事件(TYPE_WINDOW_STATE_CHANGED,
 * 语义 = 前台 App 变化)的包名+时间戳记到这个进程级单例,截图门禁查询。
 *
 * 记录语义是「最近一次前台切换的 App」:任何切 App 都必然产生窗口切换事件,
 * 所以新鲜窗口可以放得宽(默认 10 分钟)—— 静态账单页久看无事件不会把记录
 * 变"陈旧";窗口内记录即当前前台 App。探测不到前台(无障碍未开启/服务被
 * ROM 杀掉且记录超窗)时门禁按 fail-closed 处理,由 UsageStatsProbe 兜底。
 *
 * 线程模型:无障碍回调在主线程写,门禁在 MediaStore 延迟检查(主线程)或
 * 文件兜底线程读,@Volatile 单字段写读即可,无需加锁。
 */
object ForegroundAppTracker {

    /** 截图预览浮窗/保存通知等系统覆盖层的包名 —— 记录时排除。 */
    private const val EXCLUDED_PKG = "com.android.systemui"

    @Volatile
    private var lastPkg: String? = null

    @Volatile
    private var lastTs = 0L

    /** 无障碍事件到达时记录前台包名;空包名与 SystemUI 不记(见类注释)。 */
    fun recordForeground(pkg: String?, ts: Long = System.currentTimeMillis()) {
        if (pkg.isNullOrEmpty() || pkg == EXCLUDED_PKG) return
        lastPkg = pkg
        lastTs = ts
    }

    /** 最近 [maxAgeMs] 内的前台包名;无记录或超窗返回 null。 */
    fun recentForeground(maxAgeMs: Long): String? {
        val pkg = lastPkg ?: return null
        return if (System.currentTimeMillis() - lastTs <= maxAgeMs) pkg else null
    }

    /** 仅供单测重置状态。 */
    fun resetForTest() {
        lastPkg = null
        lastTs = 0L
    }
}

/**
 * 使用情况访问兜底:无障碍服务未开启时,经 UsageStatsManager 查询最近窗口内
 * 最后一次前台切换。PACKAGE_USAGE_STATS 是 AppOps 特殊权限(声明在
 * AndroidManifest,用户需在系统「使用情况访问」页授权),未授权时
 * queryEvents 返回空列表 —— 这里统一以 null 表达"探测不到",不区分原因。
 */
object UsageStatsProbe {

    /** 查询窗口内最后一次前台包名(SystemUI 除外);未授权/无事件返回 null。 */
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
                if (p == "com.android.systemui") continue
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
