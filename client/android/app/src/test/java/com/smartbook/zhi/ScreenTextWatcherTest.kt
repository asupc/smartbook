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
    fun `商品浏览页无交易关键词被跳过`() {
        val text = "棒球帽\n¥ 19.90\n加入购物车\n立即购买\n包邮"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasTradeHint(text))
    }

    @Test
    fun `微信聊天页无金额被跳过`() {
        val text = "今晚吃火锅吗?不见不散\n呵呵"
        assertFalse(watcher.hasAmount(text))
        assertFalse(watcher.hasTradeHint(text))
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
}
