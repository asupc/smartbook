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
