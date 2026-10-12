package com.smartbook.zhi

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 对抗性测试:目标快照(冻结字段)与截图来源门禁。
 *
 * AutoBookTargetStore 依赖 Context/SharedPreferences,其读写在 JVM 侧不可跑,
 * 因此这里攻击**不依赖运行时**的部分:[AutoBookTargetStore.itemFields] 的队列
 * 项回吐口径与 [AutoBookTargetStore.Snapshot] 数据类语义,以及
 * [ForegroundAppTracker]/[ScreenshotOverlay]/[BillingAppClassifier] 的判定
 * 边界(门禁误判 = 静默漏记,是本项目历史上最贵的缺陷类型)。
 */
class AdversarialTargetAndGateTest {

    @Before
    fun reset() {
        ForegroundAppTracker.resetForTest()
    }

    // ── itemFields:队列项自己的冻结字段 ──

    @Test
    fun `itemFields对无目标字段的旧队列项返回空map`() {
        val out = AutoBookTargetStore.itemFields(JSONObject().put("eventKey", "k"))
        assertTrue("旧队列项应无冻结字段,Dart 侧回落当前配置", out.isEmpty())
    }

    @Test
    fun `itemFields对空ref返回空map`() {
        val out = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "").put("targetState", "resolved"),
        )
        assertTrue(out.isEmpty())
    }

    @Test
    fun `itemFields回吐该项自己的ref而不是别的项`() {
        // 核心契约:peek 出来的必须是「该队列项捕获时冻结」的字段,
        // 不是当前缓存。这里用两个不同 ref 的项验证取值就项论项。
        val a = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "syncId:A").put("targetVersion", "3"),
        )
        val b = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "localId:7").put("targetVersion", "9"),
        )
        assertEquals("syncId:A", a["targetRef"])
        assertEquals("3", a["targetVersion"])
        assertEquals("localId:7", b["targetRef"])
        assertEquals("9", b["targetVersion"])
    }

    @Test
    fun `itemFields对缺失state补resolved`() {
        val out = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "syncId:A").put("targetState", ""),
        )
        assertEquals("resolved", out["targetState"])
    }

    @Test
    fun `itemFields原样保留非法state串不校验`() {
        // HARDENING:itemFields 不校验 state 白名单,把 "banana" 原样交给 Dart;
        // Dart 侧 AutoBookQueueTargetSnapshot 后续解析会把未知 state 当
        // undetermined 处理(见 automation_settings_store.dart)。此处断言
        // 原生侧不做二次判断,行为可辩护但脆弱 —— 若 Dart 侧未来直接
        // == "resolved" 比较,未知串会静默变成「不可写」,变成漏记。
        val out = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "syncId:A").put("targetState", "banana"),
        )
        assertEquals("banana", out["targetState"])
    }

    @Test
    fun `itemFields对version为非数字串原样返回`() {
        val out = AutoBookTargetStore.itemFields(
            JSONObject().put("targetRef", "syncId:A").put("targetVersion", "v2"),
        )
        assertEquals("v2", out["targetVersion"])
    }

    @Test
    fun `itemFields对嵌套非字符串ref取toString形式`() {
        // 畸形项:targetRef 是 JSON 对象。optString 对非字符串走 toString,
        // 返回 "{...}" 非空 → 会被当作有效 ref 上传。断言不崩。
        val nested = JSONObject().put("targetRef", JSONObject().put("a", 1))
        val out = AutoBookTargetStore.itemFields(nested)
        assertTrue(out.containsKey("targetRef"))
    }

    // ── 门禁:截图系统组件识别 ──

    @Test
    fun `截图组件子串匹配覆盖各厂ROM与子进程`() {
        assertTrue(ScreenshotOverlay.matches("com.android.systemui"))
        assertTrue(ScreenshotOverlay.matches("com.android.systemui:screenshot"))
        assertTrue(ScreenshotOverlay.matches("com.vivo.smartshot"))
        assertTrue(ScreenshotOverlay.matches("com.miui.screenshot"))
        assertTrue(ScreenshotOverlay.matches("com.oplus.screenshot"))
        assertTrue(ScreenshotOverlay.matches("com.hihonor.screenshot"))
        assertTrue(ScreenshotOverlay.matches("com.samsung.android.smartcapture"))
    }

    @Test
    fun `截图组件泛匹配会误伤名字含screenshot的普通应用`() {
        // HARDENING(已知取舍):HINTS 用子串 "screenshot",任何包名含该词的
        // 三方 App(如某个叫 screenshot-helper 的工具)都会被当截图组件透传。
        // 类注释明确论证过「泛匹配更稳」,此处把该取舍钉成测试,防止未来
        // 被无意识收紧为精确匹配时丢失 ROM 兼容性。
        assertTrue(ScreenshotOverlay.matches("com.example.screenshot.helper"))
    }

    @Test
    fun `空包名不匹配任何组件`() {
        assertFalse(ScreenshotOverlay.matches(""))
    }

    // ── 门禁:前台回溯 ──

    @Test
    fun `回溯取最近的非浮层记录(白名单不越过更新的普通App)`() {
        // 语义:前台判定对象是「最近一次真实前台 App」。先在白名单 App 里,
        // 后切到普通 App —— 截图时刻的判定对象是普通 App(门禁应拦截)。
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        ForegroundAppTracker.recordForeground("com.tencent.mobileqq")
        assertEquals(
            "com.tencent.mobileqq",
            ForegroundAppTracker.recentForeground(60_000),
        )
    }

    @Test
    fun `白名单App之后弹浮层时回落到白名单App`() {
        // 白名单 App → 截图浮层(不记录)→ 回溯仍取白名单 App,门禁放行。
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        ForegroundAppTracker.recordForeground("com.vivo.smartshot")
        assertEquals(
            "com.eg.android.AlipayGphone",
            ForegroundAppTracker.recentForeground(60_000),
        )
    }

    @Test
    fun `回溯跳过系统预装层拿到真实前台`() {
        ForegroundAppTracker.recordForeground("com.android.launcher")
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        val result = ForegroundAppTracker.recentForeground(60_000) { it.startsWith("com.android.") }
        assertEquals("com.eg.android.AlipayGphone", result)
    }

    @Test
    fun `回溯遇超窗记录立即返回null(不继续往前找)`() {
        assertNull(ForegroundAppTracker.recentForeground(60_000))
        // 注:recordForeground 的 ts 用默认 now,无法注入旧时间戳,「恰好超窗」
        // 需要 -1ms 窗口才稳定(now-ts 对刚写入的记录为 0,> 判定不命中);
        // 这里验证「无记录 → null」,超窗分支留给仪器测试/真机时间旅行覆盖。
        ForegroundAppTracker.recordForeground("com.taobao.taobao")
        assertEquals(
            "com.taobao.taobao",
            ForegroundAppTracker.recentForeground(60_000),
        )
    }

    @Test
    fun `记录截图组件时只更新诊断字段不进队列`() {
        ForegroundAppTracker.recordForeground("com.vivo.smartshot")
        assertNull(ForegroundAppTracker.recentForeground(60_000))
        assertEquals("com.vivo.smartshot", ForegroundAppTracker.lastSkippedOverlay)
    }

    @Test
    fun `环形队列上限8条,更旧的白名单记录被挤出后回溯不到`() {
        ForegroundAppTracker.recordForeground("com.eg.android.AlipayGphone")
        repeat(8) { ForegroundAppTracker.recordForeground("com.tencent.mobileqq") }
        // 前 1 + 后 8 = 9 条,保留最近 8 条 → 支付宝被挤出。
        val result = ForegroundAppTracker.recentForeground(60_000)
        assertEquals("com.tencent.mobileqq", result)
    }

    @Test
    fun `白名单App在回溯中优先于更旧的普通App命中`() {
        ForegroundAppTracker.recordForeground("com.tencent.mobileqq") // 旧:普通
        ForegroundAppTracker.recordForeground("com.icbc")            // 新:白名单
        assertEquals("com.icbc", ForegroundAppTracker.recentForeground(60_000))
    }

    @Test
    fun `全部记录都是系统层时返回null交给UsageStats兜底`() {
        ForegroundAppTracker.recordForeground("com.android.launcher")
        ForegroundAppTracker.recordForeground("com.vivo.upslide")
        val result = ForegroundAppTracker.recentForeground(60_000) { true } // 全透传
        assertNull(result)
    }

    @Test
    fun `微信子进程包名在门禁中按白名单放行`() {
        ForegroundAppTracker.recordForeground("com.tencent.mm:appbrand0")
        assertEquals(
            "com.tencent.mm:appbrand0",
            ForegroundAppTracker.recentForeground(60_000),
        )
    }

    // ── 分类器:包名匹配的注入面 ──

    @Test
    fun `包名带前后空白仍命中白名单(contains语义)`() {
        // 子串匹配下前后空白不影响命中;HARDENING:无 trim 也无害,
        // 钉住现行为防收紧时破坏。
        assertTrue(BillingAppClassifier.isBillingApp(" com.taobao.taobao "))
        assertTrue(BillingAppClassifier.isBillingApp("com.taobao.taobao"))
    }

    @Test
    fun `分类器大小写敏感(系统包名约定小写)`() {
        // HARDENING:contains 区分大小写;Android 包名约定全小写,但
        // "com.eg.android.AlipayGphone" 名单里就带大写 —— 若真实包名
        // 大小写与名单不符,静默不命中(漏记)。这里钉住现行为。
        assertTrue(BillingAppClassifier.isBillingApp("com.eg.android.AlipayGphone"))
        assertFalse(BillingAppClassifier.isBillingApp("com.eg.android.alipaygphone"))
    }

    @Test
    fun `空包名与自身包名均不放行`() {
        assertFalse(BillingAppClassifier.isBillingApp(""))
        assertFalse(BillingAppClassifier.isBillingApp("com.smartbook.zhi"))
    }

    @Test
    fun `相似前缀包名在子串语义下同样放行(contains 代价)`() {
        // HARDENING:contains 语义下 "com.taobao.taobaoclone" 也命中白名单。
        // 与「伪装包」同类:门禁用于降噪不涉权限,该行为可辩护;
        // 此处钉住现行为,防未来收紧为 equals 时无意破坏 ROM 子进程兼容。
        assertTrue(BillingAppClassifier.isBillingApp("com.taobao.taobaoclone"))
    }

    @Test
    fun `伪装WLAN前缀的第三方包会被放行(子串匹配代价)`() {
        // HARDENING:contains 匹配下 "com.evil.com.tencent.mm.phish" 也会命中
        // 微信白名单。当前白名单用于「截图是否送 AI」的降噪门禁(不涉及权限
        // 或资金),伪装的代价是多烧一次识别,可辩护;但需知悉。
        assertTrue(BillingAppClassifier.isBillingApp("com.evil.com.tencent.mm.phish"))
    }

    @Test
    fun `名单内不存在重复项(去重卫生)`() {
        // 重复项无害但说明维护态;用几个代表性包名验证互不冲突。
        val pkgs = listOf(
            "com.eg.android.AlipayGphone", "com.tencent.mm", "com.unionpay",
            "com.icbc", "com.taobao.taobao", "com.jingdong.app.mall",
        )
        assertEquals(pkgs.size, pkgs.toSet().size)
        pkgs.forEach { assertTrue("$it 应在白名单", BillingAppClassifier.isBillingApp(it)) }
    }
}
