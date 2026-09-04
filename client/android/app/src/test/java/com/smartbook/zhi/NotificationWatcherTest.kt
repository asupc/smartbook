package com.smartbook.zhi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NotificationWatcher 纯函数过滤逻辑的 JVM 单测(支付通知监听)。
 * 与 SmsReceiverTest 同策略:只测不依赖 Android 运行时的过滤/指纹方法。
 */
class NotificationWatcherTest {

    private val watcher = NotificationWatcher()

    @Test
    fun `支付类通知正文识别为交易`() {
        val body = "已支付45.00元 商家:星巴克咖啡(万通中心店)"
        assertFalse(watcher.shouldReject(body))
        assertTrue(watcher.hasAmountAndAction(body))
    }

    @Test
    fun `微信聊天消息无金额被剔除`() {
        val body = "今晚吃火锅吗?不见不散"
        assertFalse(watcher.hasAmountAndAction(body))
    }

    @Test
    fun `仅动作词无金额被拒`() {
        // 有"支付/付款"动作词但无金额,不应触发自动记账
        assertFalse(watcher.hasAmountAndAction("您有一笔待付款订单,请尽快支付"))
    }

    @Test
    fun `仅金额无动作词被拒`() {
        assertFalse(watcher.hasAmountAndAction("45.00元"))
    }

    @Test
    fun `到账通知金额与动作词同时命中放行`() {
        assertTrue(watcher.hasAmountAndAction("您收到一笔转账到账500.00元"))
    }

    @Test
    fun `验证码通知被拒`() {
        assertTrue(watcher.shouldReject("验证码123456用于登录支付宝,请勿泄露"))
    }

    @Test
    fun `营销通知被拒`() {
        assertTrue(watcher.shouldReject("618大促,满减优惠券,领券立减100"))
    }

    @Test
    fun `纯余额提醒被拒`() {
        assertTrue(watcher.isPureBalanceReminder("您账户当前余额为5,000.00元"))
        assertFalse(watcher.isPureBalanceReminder("您账户消费100.00元,余额5,000.00元"))
    }

    @Test
    fun `指纹确定性且16位hex`() {
        val fp = watcher.fingerprint("com.tencent.mm", "微信支付", "已支付45元")
        assertEquals(16, fp.length)
        assertTrue(Regex("^[0-9a-f]{16}$").matches(fp))
        assertEquals(fp, watcher.fingerprint("com.tencent.mm", "微信支付", "已支付45元"))
    }
}
