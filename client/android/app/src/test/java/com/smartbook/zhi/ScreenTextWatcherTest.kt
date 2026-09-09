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
        assertTrue(watcher.hasBookableHint(text))
    }

    @Test
    fun `支付宝账单详情`() {
        val text = "账单详情\n交易时间:2026-09-03 12:00\n支付金额:30.00元\n对方:美团外卖"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
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
        assertTrue(watcher.hasBookableHint(text))
        assertFalse(watcher.shouldReject(text))
        assertFalse(watcher.isNonBookableStatus(text))
        assertFalse(watcher.isListPage(text))
    }

    @Test
    fun `裸数字无小数尾不算金额`() {
        // 订单号/流水号这类长整数不是金额,页面只有它们时仍应被丢弃
        val text = "账单详情\n订单编号 3612495000067592\n商户单号 14084282609052028410461797623"
        assertFalse(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
    }

    @Test
    fun `纯口语聊天无金额被跳过`() {
        val text = "今晚吃火锅吗?不见不散\n呵呵"
        assertFalse(watcher.hasAmount(text))
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `商品浏览页无交易关键词被跳过`() {
        val text = "棒球帽\n¥ 19.90\n加入购物车\n立即购买\n包邮"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `聊天口语提到支付退款不再命中交易特征`() {
        // 2026-09 收紧:单词「支付/退款/转账」不再算交易特征,防止聊天文本送 AI
        val text = "我支付了50元\n你退款了吗\n他转账给你了吗\nAA收款30"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `聊天内容出现转账气泡有金额有特征词但被类名黑名单拒识`() {
        // 聊天里收到「微信转账」消息:气泡文本同时含金额和「转账单号」样式文案,
        // 内容粗筛挡不住,靠页面类名黑名单兜底
        val text = "微信转账\n¥ 200.00\n已收款\n转账单号 1000050001234501234567"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
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
        assertTrue(watcher.hasBookableHint(text))
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
        assertTrue(watcher.hasBookableHint(text))
        assertFalse(watcher.isListPage(text))
        assertFalse(watcher.isNonBookableStatus(text))
    }

    @Test
    fun `转账详情页屏幕外金额顶过阈值不误判列表页`() {
        // 2026-09-09 真机漏记根因:支付宝转账详情可见金额仅 3 个
        // (-4,997.00/5000.00/-3.00),H5 屏幕外节点(推荐流价格)把计数顶到 5,
        // 旧的一刀切阈值按列表页整页丢弃(真列表页是几十个金额)。阈值区间
        // 内改按日期行数区分:详情页只有创建时间 1 个日期,列表页每行带日期。
        val text = "账单详情\n杨靖(*靖)\n-4,997.00\n交易成功\n" +
            "订单金额 5000.00\n中国银行立减金 -3.00\n" +
            "创建时间 2026-03-28 18:53:41\n" +
            "付款方式 中国银行储蓄卡(3822)\n" +
            "转账备注 转账\n对方账户 杨靖(*靖) 186******80\n" +
            "账单管理\n账单分类 转账红包\n计入收支\n再转一笔\n" +
            "¥12.90\n¥29.90"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
        assertEquals(1, watcher.countDates(text))
        assertFalse(watcher.isListPage(text))
    }

    @Test
    fun `金额数达到硬阈值无条件判列表页`() {
        // 整页几十条流水:详情页再叠优惠行/屏幕外推荐流也到不了的量级
        val rows = (1..12).joinToString("\n") { "9-$it 商户消费 ${it * 11}.00" }
        assertTrue(watcher.isListPage(rows))
    }

    @Test
    fun `金额过阈值且日期行多仍判列表页`() {
        // 阈值区间内:每行流水带一个日期 → 真列表页
        val text = "账单\n9-01 商户消费 30.00\n9-02 早餐 12.00\n9-03 地铁 4.00\n" +
            "9-05 外卖 28.50\n9-08 超市 96.40"
        assertTrue(watcher.isListPage(text))
    }

    @Test
    fun `日期正则不命中时刻卡尾与订单号`() {
        // 「2026-03-28」只命中「03-28」一段;时刻/卡尾/手机号/无分隔订单号不命中
        assertEquals(1, watcher.countDates("创建时间 2026-03-28 18:53:41"))
        assertEquals(0, watcher.countDates("付款方式 中国银行储蓄卡(3822)\n对方账户 186******80"))
        assertEquals(1, watcher.countDates("收款时间 9月8日 20:15"))
    }

    @Test
    fun `有交易特征的营销活动页不整页拒识由后续闸门兜底`() {
        // 京东订单详情常见「促销 -¥x」抵扣行:有强交易特征,营销词让位,
        // 是否入账交给列表页/状态闸与 AI 判定
        val text = "订单详情\n促销 -¥10.00\n优惠券 -¥5.00\n实付款 ¥89.00\n交易成功"
        assertFalse(watcher.isMarketingPage(text))
        assertTrue(watcher.hasBookableHint(text))
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

    @Test
    fun `同内容不同捕获时间指纹稳定事件键变化`() {
        // 2026-09-07 修复:同一账单详情页文本在两次进入时完全一致,指纹必须
        // 相同;事件键含时间戳必然不同。判重必须以指纹为准,否则重复进详情页
        // 会被当成新事件反复送 AI 记账。
        val text = "账单详情\n交易成功\n实付金额:¥45.00\n商户:星巴克咖啡(万通中心店)"
        val fpA = watcher.fingerprint("com.eg.android.AlipayGphone", text)
        val fpB = watcher.fingerprint("com.eg.android.AlipayGphone", text)
        assertEquals(fpA, fpB)
        val keyA = watcher.eventKey("com.eg.android.AlipayGphone", fpA, 1_757_000_000_000L)
        val keyB = watcher.eventKey("com.eg.android.AlipayGphone", fpB, 1_757_000_001_000L)
        assertFalse(keyA == keyB)
    }

    @Test
    fun `不同内容指纹不同避免误判`() {
        // 不同账单文本(金额/商户不同)指纹不同,按指纹判重不会误杀新账单。
        val a = watcher.fingerprint("com.eg.android.AlipayGphone", "账单详情 实付45.00元 美团外卖")
        val b = watcher.fingerprint("com.eg.android.AlipayGphone", "账单详情 实付30.00元 星巴克")
        assertFalse(a == b)
    }

    @Test
    fun `单一弱锚点不构成交易特征需两个以上`() {
        // 2026-09 锚点分级:单个字段词+金额的订单确认/售后页不再通过粗筛,
        // 弱锚点需 ≥2 个不同词同时命中
        val text = "订单编号 1234567890\n¥ 30.00"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `两个弱锚点组合放行`() {
        val text = "订单编号 1234567890\n商户单号 9876543210\n¥ 30.00"
        assertTrue(watcher.hasBookableHint(text))
    }

    @Test
    fun `收款方向强锚点被识别`() {
        // 收入方向补全:微信收款/转账存入零钱的详情页此前只有支出视角词表
        val text = "微信支付凭证\n已存入零钱\n¥ 200.00\n转账单号 1000050001234501234567"
        assertTrue(watcher.hasBookableHint(text))
        assertTrue(watcher.hasBookableHint("已收款\n收款方:某商户\n¥ 45.00"))
    }

    @Test
    fun `AA收款等聊天口语仍不命中收入锚点`() {
        // 「已收款/已收钱」带「已」字前缀,「AA收款」这类口语不擦边
        val text = "AA收款30\n快转给我"
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `支付结果页类名命中快速通道`() {
        assertTrue(
            watcher.isFastPathPage(
                "com.eg.android.AlipayGphone",
                "com.alipay.android.msp.ui.views.MspContainerActivity"
            )
        )
        assertTrue(
            watcher.isFastPathPage(
                "com.eg.android.AlipayGphone",
                "com.alipay.android.phone.businesscommon.ucdp.nfc.activity.NResPageActivity"
            )
        )
        // 小程序支付跑在 com.tencent.mm:appbrand0 子进程,contains 匹配要覆盖
        assertTrue(
            watcher.isFastPathPage(
                "com.tencent.mm:appbrand0",
                "com.tencent.mm.plugin.lite.ui.WxaLiteAppLiteUI"
            )
        )
        assertTrue(
            watcher.isFastPathPage(
                "com.tencent.mm",
                "com.tencent.mm.plugin.remittance.ui.RemittanceDetailUI"
            )
        )
        // 承载页面过多的通用容器与普通页面不进快速通道
        assertFalse(
            watcher.isFastPathPage(
                "com.tencent.mm",
                "com.tencent.mm.framework.app.UIPageFragmentActivity"
            )
        )
        assertFalse(
            watcher.isFastPathPage(
                "com.jingdong.app.mall",
                "com.jingdong.app.mall.main.MainActivity"
            )
        )
        assertFalse(watcher.isFastPathPage("com.tencent.mm", "com.tencent.mm.ui.LauncherUI"))
    }

    @Test
    fun `微信支付结果页desc按钮词作为弱锚点`() {
        // GKD 微信支付规则同款锚点:「返回商家」是支付结果页完成按钮的
        // contentDescription,配合字段词一起构成弱锚点组合
        val text = "支付金额 ¥ 88.00\n返回商家"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
    }

    @Test
    fun `抖音月付订单详情页被识别`() {
        // 2026-09-09 真机漏记:抖音月付订单详情宿主是 LiveDummyActivity/
        // BulletContainerActivity 通用容器,状态「确认收货后付款」原先不命中
        // 任何强锚点,预筛直接丢弃;月付订单不走支付宝/微信,只在此页可见。
        // 文本取自真机截图(鲜铺子猕猴桃 -19.80,抖音支付立减 ¥5.00)。
        val text = "鲜铺子猕猴桃\n-19.80\n确认收货后付款\n" +
            "支付积分领取 22\n抖音支付立减 ¥ 5.00\n" +
            "支付时间 2026-09-06 16:40:29\n支付方式 抖音月付\n商品订单 共1件\n" +
            "【鲜铺子】陕西周至徐香猕猴桃奇异果当季水果礼盒装净重4.5-5斤 单果70-90g\n" +
            "19.80 数量1"
        assertFalse(watcher.shouldReject(text))
        // 「立减」命中营销词,但页面有强锚点,营销闸让位
        assertFalse(watcher.isMarketingPage(text))
        assertTrue(watcher.hasAmount(text))
        // 强:确认收货后付款;弱兜底:支付方式+支付时间+商品订单
        assertTrue(watcher.hasBookableHint(text))
        // 金额 3 次(-19.80/¥5.00/19.80)、日期 1 行(09-06),详情页规模
        assertFalse(watcher.isListPage(text))
        // 「确认收货后付款」不含「待付款/待确认」子串,不落不可入账闸
        assertFalse(watcher.isNonBookableStatus(text))
    }

    @Test
    fun `抖音订单详情状态行不可见时字段词弱锚点组合放行`() {
        // 部分真机上订单详情的状态级强词不在无障碍文本树里,只剩字段行;
        // 预筛组合词(支付方式+支付时间)与粗筛弱锚点(≥2)同口径放行
        val text = "鲜铺子猕猴桃\n-19.80\n" +
            "支付时间 2026-09-06 16:40:29\n支付方式 抖音月付\n商品订单 共1件"
        assertTrue(watcher.hasAmount(text))
        assertTrue(watcher.hasBookableHint(text))
        assertFalse(watcher.isListPage(text))
    }

    @Test
    fun `支付方式与支付时间只出现一个不构成弱锚点组合`() {
        // 单独一个字段词太泛(支付设置页也有「支付方式」),不能放行
        val text = "支付方式\n免密支付\n¥ 0.01"
        assertTrue(watcher.hasAmount(text))
        assertFalse(watcher.hasBookableHint(text))
    }

    @Test
    fun `我的订单列表页标题一票判列表页`() {
        // 单订单的列表页金额只有 1~2 个且无日期行,计数法失效;订单卡片的
        // 状态词会通过锚点预筛,标题兜底防止随后进详情页同一单双发
        val text = "我的订单\n全部 待付款 待收货 已完成\n鲜铺子猕猴桃\n" +
            "确认收货后付款\n¥19.8 ×1\n查看物流 确认收货"
        assertTrue(watcher.isListPage(text))
        // 详情页不含列表标题,不受影响
        assertFalse(watcher.isListPage("订单详情\n鲜铺子猕猴桃\n-19.80\n交易成功"))
    }
}
