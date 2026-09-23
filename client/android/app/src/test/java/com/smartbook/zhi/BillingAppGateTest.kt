package com.smartbook.zhi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 截图来源 App 门禁纯函数单测(2026-09-18 策略调整):
 * 分类器(金融/电商白名单)与前台跟踪(记录/新鲜窗/SystemUI 排除)。
 * 与 ScreenTextWatcherTest 同策略:只测不依赖 Android 运行时的部分;
 * UsageStatsProbe 需要 Context/UsageStatsManager,不在 JVM 侧覆盖。
 */
class BillingAppGateTest {

    @Before
    fun resetTracker() {
        ForegroundAppTracker.resetForTest()
    }

    // ---- BillingAppClassifier ----

    @Test
    fun `支付与微信账单场景包名放行`() {
        assertTrue(BillingAppClassifier.isBillingApp("com.eg.android.AlipayGphone"))
        assertTrue(BillingAppClassifier.isBillingApp("com.tencent.mm"))
        // 微信小程序子进程(支付结果页跑在 appbrand0)
        assertTrue(BillingAppClassifier.isBillingApp("com.tencent.mm:appbrand0"))
        assertTrue(BillingAppClassifier.isBillingApp("com.unionpay"))
    }

    @Test
    fun `银行包名放行(与通知白名单同名单)`() {
        assertTrue(BillingAppClassifier.isBillingApp("com.icbc"))                    // 工行
        assertTrue(BillingAppClassifier.isBillingApp("com.chinamworld.main"))        // 建行
        assertTrue(BillingAppClassifier.isBillingApp("cmb.pb"))                      // 招行
        assertTrue(BillingAppClassifier.isBillingApp("com.mybank.android.phone"))    // 网商
    }

    @Test
    fun `电商与本地生活包名放行`() {
        assertTrue(BillingAppClassifier.isBillingApp("com.taobao.taobao"))
        assertTrue(BillingAppClassifier.isBillingApp("com.jingdong.app.mall"))
        assertTrue(BillingAppClassifier.isBillingApp("com.xunmeng.pinduoduo"))
        assertTrue(BillingAppClassifier.isBillingApp("com.sankuai.meituan"))
        assertTrue(BillingAppClassifier.isBillingApp("me.ele"))
        // 抖音极速版(子串覆盖 lite)
        assertTrue(BillingAppClassifier.isBillingApp("com.ss.android.ugc.aweme.lite"))
    }

    @Test
    fun `非消费类App不通过`() {
        assertFalse(BillingAppClassifier.isBillingApp("com.android.systemui"))
        assertFalse(BillingAppClassifier.isBillingApp("com.bbk.launcher2"))
        assertFalse(BillingAppClassifier.isBillingApp("com.smartbook.zhi"))
        assertFalse(BillingAppClassifier.isBillingApp("com.tencent.mobileqq"))
        assertFalse(BillingAppClassifier.isBillingApp("com.baidu.searchbox"))
        assertFalse(BillingAppClassifier.isBillingApp(""))
    }

    // ---- ForegroundAppTracker ----

    @Test
    fun `记录后新鲜窗内可查询`() {
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        assertEquals(
            "com.eg.android.AlipayGphone",
            ForegroundAppTracker.recentForeground(60_000L)
        )
    }

    @Test
    fun `超过新鲜窗返回null`() {
        // 记录时间戳取"现在-2分钟",1 分钟窗应视为过期
        ForegroundAppTracker.recordForeground(
            "com.eg.android.AlipayGphone",
            System.currentTimeMillis() - 120_000L
        )
        assertNull(ForegroundAppTracker.recentForeground(60_000L))
    }

    @Test
    fun `systemui浮窗不污染记录`() {
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        // 截图后 SystemUI 预览浮窗产生的事件不应覆盖真前台 App
        ForegroundAppTracker.recordForeground("com.android.systemui")
        assertEquals(
            "com.eg.android.AlipayGphone",
            ForegroundAppTracker.recentForeground(60_000L)
        )
    }

    @Test
    fun `vivo截图编辑浮窗不污染记录`() {
        // vivo 真机 2026-09-22:截图后必弹 com.vivo.smartshot 编辑浮窗,
        // 覆盖真前台导致门禁全拦成 smartshot —— 必须与 SystemUI 同等透传
        ForegroundAppTracker.recordForeground("com.tencent.mm")
        ForegroundAppTracker.recordForeground("com.vivo.smartshot")
        assertEquals(
            "com.tencent.mm",
            ForegroundAppTracker.recentForeground(60_000L)
        )
        // 诊断字段:被排除的浮窗包名要留痕,供门禁拦截 detail 带出
        assertEquals("com.vivo.smartshot", ForegroundAppTracker.lastSkippedOverlay)
    }

    @Test
    fun `systemui子进程截图事件不污染记录`() {
        ForegroundAppTracker.recordForeground("com.tencent.mm")
        ForegroundAppTracker.recordForeground("com.android.systemui:screenshot")
        assertEquals(
            "com.tencent.mm",
            ForegroundAppTracker.recentForeground(60_000L)
        )
    }

    @Test
    fun `系统预装浮层经skipExtra透传回溯到真实前台`() {
        // vivo 真机 2026-09-23:截屏瞬间除 smartshot 外,upslide 等系统
        // 浮层也会插窗口事件;skipExtra 注入"系统预装透传",回溯到浮层
        // 弹出前的真实三方 App(京东,白名单)作为判定对象
        ForegroundAppTracker.recordForeground("com.jingdong.app.mall")
        ForegroundAppTracker.recordForeground("com.vivo.upslide")
        assertEquals(
            "com.jingdong.app.mall",
            ForegroundAppTracker.recentForeground(60_000L) { it == "com.vivo.upslide" }
        )
    }

    @Test
    fun `回溯不到真实前台时返回null`() {
        ForegroundAppTracker.recordForeground("com.vivo.upslide")
        assertNull(
            ForegroundAppTracker.recentForeground(60_000L) { it == "com.vivo.upslide" }
        )
    }

    @Test
    fun `白名单包回溯时优先命中`() {
        // 回溯遇白名单立即返回:即使更近处有系统浮层,白名单 App 就是判定对象
        ForegroundAppTracker.recordForeground("com.tencent.mm")
        ForegroundAppTracker.recordForeground("com.vivo.upslide")
        assertEquals(
            "com.tencent.mm",
            ForegroundAppTracker.recentForeground(60_000L) { it == "com.vivo.upslide" }
        )
    }

    @Test
    fun `环形队列只保留最近8条`() {
        ForegroundAppTracker.recordForeground("com.tencent.mm")
        repeat(10) { ForegroundAppTracker.recordForeground("com.third.app$it") }
        // 微信已被挤出队列;回溯从 app9 开始,无 skipExtra 时 app9 即判定对象
        assertEquals(
            "com.third.app9",
            ForegroundAppTracker.recentForeground(60_000L)
        )
        // 跳过 app9/app8 后回溯到 app7
        assertEquals(
            "com.third.app7",
            ForegroundAppTracker.recentForeground(60_000L) {
                it == "com.third.app9" || it == "com.third.app8"
            }
        )
    }

    @Test
    fun `切换App后记录被覆盖`() {
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        ForegroundAppTracker.recordForeground("com.tencent.mobileqq")
        assertEquals(
            "com.tencent.mobileqq",
            ForegroundAppTracker.recentForeground(60_000L)
        )
    }

    @Test
    fun `空包名不记录`() {
        ForegroundAppTracker.recordForeground(null)
        ForegroundAppTracker.recordForeground("")
        assertNull(ForegroundAppTracker.recentForeground(60_000L))
    }
}
