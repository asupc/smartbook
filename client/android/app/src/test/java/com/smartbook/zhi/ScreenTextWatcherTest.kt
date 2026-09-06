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
    fun `微信京东账单详情裸数字金额被识别`() {
        // 2026-09 真机走查漏记根因:微信支付账单详情(京东商户)的大字金额是
        // 「-529.00」式裸数字,整页无 ¥/元,旧 AMOUNT_PATTERN 匹配不到金额被丢
        val text = "账单详情\n京东平台商户\n-529.00\n交易成功\n" +
            "支付方式 招商银行信用卡 (1467)\n" +
            "创建时间 2026-09-05 20:28:42\n" +
            "总订单编号 3612495000067592\n" +
            "商户单号 14084282609052028410461797623\n" +
            "服务详情 共1笔订单\n" +
            "账单分类 家居家装\n对此账单有疑问"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
        assertFalse(watcher.shouldReject(text))
        assertFalse(watcher.isNonBookableStatus(text))
        assertFalse(watcher.isListPage(text))
    }

    @Test
    fun `裸数字无小数尾不算金额`() {
        // 订单号/流水号这类长整数不是金额,页面只有它们时仍应被丢弃
        val text = "账单详情\n订单编号 3612495000067592\n商户单号 14084282609052028410461797623"
        assertFalse(watcher.hasAmount(text))
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
        // 无详情页交易特征的纯营销页仍被拒(经 isMarketingPage 组合闸)
        val text = "618大促,满减优惠券,领券立减100"
        assertFalse(watcher.shouldReject(text))
        assertTrue(watcher.isMarketingPage(text))
    }

    @Test
    fun `支付宝账单详情含立减抵扣行不再被营销词误杀`() {
        // 2026-09-06 真机漏记根因:支付宝账单详情把优惠写成「碰一下立减 -0.44」,
        // 「立减」命中营销词后整页一票否决。真实详情页有标题/状态级强特征,
        // 营销词只在无交易特征时才拒识。
        val text = "账单详情\n邻哒超市\n-3.56\n交易成功\n" +
            "订单金额 4.00\n碰一下立减 -0.44\n" +
            "支付时间 2026-09-06 17:46:26\n" +
            "付款方式 招商银行信用卡(1467)\n" +
            "商品说明 2000455268711460\n" +
            "收款方全称 *强(个人)\n" +
            "账单管理\n账单分类 日用百货\n计入收支"
        assertFalse(watcher.shouldReject(text))
        assertFalse(watcher.isMarketingPage(text))
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasTradeHint(text))
        assertFalse(watcher.isListPage(text))
        assertFalse(watcher.isNonBookableStatus(text))
    }

    @Test
    fun `有交易特征的营销活动页不整页拒识由后续闸门兜底`() {
        // 京东订单详情常见「促销 -¥x」抵扣行:有强交易特征,营销词让位,
        // 是否入账交给列表页/状态闸与 AI 判定
        val text = "订单详情\n促销 -¥10.00\n优惠券 -¥5.00\n实付款 ¥89.00\n交易成功"
        assertFalse(watcher.isMarketingPage(text))
        assertTrue(watcher.hasTradeHint(text))
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
