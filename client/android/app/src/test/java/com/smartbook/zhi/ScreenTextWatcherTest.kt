package com.smartbook.zhi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ScreenTextWatcher 纯函数过滤逻辑的 JVM 单测(账单详情页自动记账)。
 * 与 NotificationWatcherTest 同策略:只测不依赖 Android 运行时的过滤/指纹方法。
 */
class ScreenTextWatcherTest {

    private val watcher = ScreenTextWatcher()

    @Test
    fun `账单详情页文本被识别为交易页面`() {
        val text = "订单详情\n支付成功\n实付金额:¥ 45.00\n商户:星巴克咖啡(万通中心店)\n订单编号:1234567890"
        assertFalse(watcher.shouldReject(text))
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
    }

    @Test
    fun `支付宝账单详情`() {
        val text = "账单详情\n交易时间:2026-09-03 12:00\n支付金额:30.00元\n对方:美团外卖"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
    }

    @Test
    fun `纯口语聊天无金额被跳过`() {
        val text = "今晚吃火锅吗?不见不散\n呵呵"
        assertFalse(watcher.hasAmount(text))
        assertFalse(watcher.hasTradeHint(text))
    }

    @Test
    fun `商品浏览页无交易关键词被跳过`() {
        val text = "棒球帽\n¥ 19.90\n加入购物车\n立即购买\n包邮"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasTradeHint(text))
    }

    @Test
    fun `聊天口语提到支付退款不再命中交易特征`() {
        // 2026-09 收紧:单词「支付/退款/转账」不再算交易特征,防止聊天文本送 AI
        val text = "我支付了50元\n你退款了吗\n他转账给你了吗\nAA收款30"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasTradeHint(text))
    }

    @Test
    fun `聊天内容出现转账气泡有金额有特征词但被类名黑名单拒识`() {
        // 聊天里收到「微信转账」消息:气泡文本同时含金额和「转账单号」样式文案,
        // 内容粗筛挡不住,靠页面类名黑名单兜底
        val text = "微信转账\n¥ 200.00\n已收款\n转账单号 1000050001234501234567"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
        assertTrue(watcher.isChatPage("com.tencent.mm", "com.tencent.mm.ui.LauncherUI"))
    }

    @Test
    fun `微信聊天页类名黑名单`() {
        assertTrue(watcher.isChatPage("com.tencent.mm", "com.tencent.mm.ui.LauncherUI"))
        assertTrue(watcher.isChatPage("com.tencent.mm:tools", "com.tencent.mm.ui.LauncherUI"))
        assertFalse(watcher.isChatPage("com.eg.android.AlipayGphone", "com.tencent.mm.ui.LauncherUI"))
        assertFalse(watcher.isChatPage("com.tencent.mm", "com.tencent.mm.plugin.wallet.pay.ui.WalletPayUI"))
        assertFalse(watcher.isChatPage("com.tencent.mm", ""))
    }

    @Test
    fun `微信支付页面不受聊天黑名单影响`() {
        val text = "支付详情\n支付金额:¥ 66.00\n转账单号 1000050001234501234567\n当前状态:已支付"
        assertFalse(watcher.isChatPage("com.tencent.mm", "com.tencent.mm.plugin.wallet.pay.ui.WalletPayUI"))
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
    }

    @Test
    fun `登录验证码页面被拒`() {
        assertTrue(watcher.shouldReject("验证码123456用于登录支付宝,请勿泄露"))
    }

    @Test
    fun `营销页面被拒`() {
        assertTrue(watcher.shouldReject("618大促,满减优惠券,领券立减100"))
    }

    @Test
    fun `指纹确定性且16位hex`() {
        val fp = watcher.fingerprint("com.jingdong.app.mall", "订单详情 实付45.00元")
        assertEquals(16, fp.length)
        assertTrue(Regex("^[0-9a-f]{16}$").matches(fp))
        assertEquals(fp, watcher.fingerprint("com.jingdong.app.mall", "订单详情 实付45.00元"))
    }


    @Test
    fun `待付款和失败详情页被挡住`() {
        assertTrue(watcher.isNonBookableStatus("订单确认\n待付款\n实付金额:¥30.00"))
        assertTrue(watcher.isNonBookableStatus("交易失败\n金额:¥30.00"))
        assertFalse(watcher.isNonBookableStatus("支付成功\n实付金额:¥30.00"))
    }

    @Test
    fun `屏幕事件键包含捕获时间且保持确定性`() {
        val fp = watcher.fingerprint("com.eg.android.AlipayGphone", "订单详情 实付30元")
        val first = watcher.eventKey("com.eg.android.AlipayGphone", fp, 1_757_000_000_000L)
        assertEquals(first, watcher.eventKey("com.eg.android.AlipayGphone", fp, 1_757_000_000_000L))
        assertFalse(first == watcher.eventKey("com.eg.android.AlipayGphone", fp, 1_757_000_001_000L))
        assertEquals(16, first.length)
    }
}
