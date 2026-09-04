package com.smartbook.zhi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SmsReceiver 纯函数过滤逻辑的 JVM 单测(M1 短信自动记账)。
 *
 * 只测不依赖 Android 运行时的方法(白名单/垃圾过滤/金额动作特征/指纹);
 * onReceive 依赖 Telephony 等 Android 类,交给真机冒烟。
 *
 * 验收映射(development-plan.md M1):
 * - "验证码/营销短信不误入账" → shouldReject 用例
 * - "能收到银行/支付短信并自动生成交易" → isTrustedSender + hasAmountOrAction 用例
 * - "同一笔交易不重复" → fingerprint 用例
 */
class SmsReceiverTest {

    private val receiver = SmsReceiver()

    // ---------------- 发送者白名单 ----------------

    @Test
    fun `银行短号与银行名可信`() {
        assertTrue(receiver.isTrustedSender("95555"))
        assertTrue(receiver.isTrustedSender("招商银行"))
        assertTrue(receiver.isTrustedSender("中国建设银行"))
        assertTrue(receiver.isTrustedSender("湖北农商行"))
    }

    @Test
    fun `支付宝与微信支付可信`() {
        assertTrue(receiver.isTrustedSender("支付宝"))
        assertTrue(receiver.isTrustedSender("微信支付"))
    }

    @Test
    fun `未知号码不可信`() {
        assertFalse(receiver.isTrustedSender("13812345678"))
        assertFalse(receiver.isTrustedSender("9530"))
    }

    // ---------------- 垃圾/非交易短信 ----------------

    @Test
    fun `验证码短信被拒`() {
        assertTrue(receiver.shouldReject("您正在登录招商银行APP,验证码123456,请勿泄露"))
        assertTrue(receiver.shouldReject("【建设银行】您的动态验证码为2345,有效期5分钟"))
        assertTrue(receiver.shouldReject("验证码1234用于重置密码,任何人不得告知。"))
    }

    @Test
    fun `营销短信被拒`() {
        assertTrue(receiver.shouldReject("【招商银行】6.18消费满减活动,回复TD退订"))
        assertTrue(receiver.shouldReject("【微信支付】夏日福利,领券享立减"))
    }

    @Test
    fun `纯余额提醒被拒(有余额词但无收支动作)`() {
        assertTrue(receiver.isPureBalanceReminder("您尾号1234的储蓄卡当前余额为1,234.56元"))
        assertTrue(receiver.isPureBalanceReminder("【招商银行】您的账户可用金额为5,000.00元"))
        // 含收支动作的短信即使带余额词也不算纯提醒
        assertFalse(receiver.isPureBalanceReminder("您尾号1234账户消费100.00元,余额10,000.00元"))
    }

    @Test
    fun `账单提醒有动作词放行,由AI侧billGuard兜底`() {
        // "还款"命中动作词 → 放行;是否可记由 AI(billGuardForSms)判定,不误杀
        assertTrue(receiver.hasAmountOrAction("您持有的信用卡3月账单已出,请在还款日前还款,点击查看详情"))
    }

    // ---------------- 交易短信识别 ----------------

    @Test
    fun `银行消费短信识别为交易`() {
        assertFalse(receiver.shouldReject("您尾号1234的储蓄卡账户于03月28日14时32分消费人民币(卡内)1,234.56元,当前余额10,000.00元,收款商户:星巴克咖啡,交易摘要:消费"))
        assertTrue(receiver.hasAmountOrAction("您尾号1234的储蓄卡账户于03月28日14时32分消费人民币(卡内)1,234.56元,当前余额10,000.00元,收款商户:星巴克咖啡,交易摘要:消费"))
    }

    @Test
    fun `转账入账短信识别为交易`() {
        assertTrue(receiver.hasAmountOrAction("【招商银行】您光大银行账户于06月08日收到张三转账500.00元,余额5,000.00元"))
        assertFalse(receiver.shouldReject("【招商银行】您光大银行账户于06月08日收到张三转账500.00元,余额5,000.00元"))
    }

    @Test
    fun `支付消费只有金额符号也能识别`() {
        assertTrue(receiver.hasAmountOrAction("您的账户付款¥230.00,交易成功"))
        assertTrue(receiver.hasAmountOrAction("消费￥88元"))
    }

    // ---------------- 指纹 ----------------

    @Test
    fun `指纹确定性且为16位hex`() {
        val fp = receiver.fingerprint("95555", "消费123.45元")
        assertEquals(16, fp.length)
        assertTrue(Regex("^[0-9a-f]{16}$").matches(fp))
        assertEquals(fp, receiver.fingerprint("95555", "消费123.45元"))
    }

    @Test
    fun `内容不同指纹不同`() {
        assertFalse(
            receiver.fingerprint("95555", "消费123.45元")
                == receiver.fingerprint("95555", "消费124.00元")
        )
    }
}
