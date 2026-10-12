package com.smartbook.zhi

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.provider.Telephony
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * 短信监听接收器(自动记账 M1)。
 *
 * 与截图监听不同,短信广播在 App 进程被杀死时也能到达,而 Flutter 代码此时
 * 不存在 —— 所以本接收器把"确定性工作"全部做完并**持久化入队**,Flutter 侧
 * 只负责两件事:
 *   1. 进程存活时经桥接广播即时处理([BRIDGE_ACTION] → MainActivity);
 *   2. 下次启动时经 SmsMonitorService.drain 处理积压队列。
 *
 * 确定性过滤(只拒绝明确不是交易的短信,业务判断交给 AI 兜底):
 *   1. 发送者白名单:银行/支付服务号(M1 文档:"只处理可信发送者");
 *   2. 剔除验证码/安全校验类、营销推广类;
 *   3. 无金额模式且无收支动作词 → 剔除(含纯余额提醒/账单通知);
 *   4. 指纹去重(sha256 前 16 位,持久化,cap 200)。
 *
 * 隐私(M1 文档 5 条):短信原文只短暂驻留队列,处理/入队超限即删;
 * 本类**绝不**把正文写进 Log/LoggerPlugin。
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val smsMessages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        val sender = smsMessages.firstOrNull()?.originatingAddress ?: return
        val body = smsMessages.joinToString("") { it.messageBody ?: "" }
        if (body.isEmpty()) return

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        // 开关:由 Flutter 侧经 MethodChannel setEnabled 同步(独立文件,与
        // shared_preferences 的 "flutter." 前缀空间隔离)。关闭时直接丢弃 ——
        // 不进队列、不残留隐私数据。
        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            log("开关关闭,丢弃短信")
            return
        }

        if (!isTrustedSender(sender)) {
            log("发送者未命中白名单,丢弃")
            return
        }
        if (shouldReject(body)) {
            log("内容命中垃圾/非交易特征,丢弃")
            return
        }
        if (isMarketingSms(body)) {
            log("内容命中营销特征且无已结算交易词,丢弃")
            return
        }
        if (isPureBalanceReminder(body)) {
            log("纯余额/结余提醒(有余额词但无收支动作),丢弃")
            return
        }
        if (isNonBookableStatus(body)) {
            log("内容命中账单汇总/待支付/失败状态,丢弃")
            return
        }
        if (!hasAmountOrAction(body)) {
            log("无金额且无收支动作特征,丢弃")
            return
        }

        val fingerprint = fingerprint(sender, body)
        val sourceTimestamp = smsMessages
            .map { it.timestampMillis }
            .filter { it > 0L }
            .minOrNull() ?: System.currentTimeMillis()
        val eventKey = eventKey(sender, fingerprint, sourceTimestamp)
        if (!enqueue(context, prefs, eventKey, fingerprint, sender, body, sourceTimestamp)) {
            log("短信已在已处理记录或待处理队列中,丢弃")
            return
        }

        // 通知 Flutter 活实例;进程已死则自然无人接收,队列留待下次启动处理。
        try {
            val bridge = Intent(BRIDGE_ACTION).setPackage(context.packageName)
            context.sendBroadcast(bridge)
        } catch (e: Exception) {
            Log.e(TAG, "发送桥接广播失败(不影响入队)", e)
        }
    }

    // ------------------------------------------------------------
    // 过滤规则(纯函数,便于以后迁移到测试)
    // ------------------------------------------------------------

    /** 发送者白名单:命中任意关键词(子串,忽略大小写)视为可信。 */
    fun isTrustedSender(sender: String): Boolean {
        val s = sender.uppercase()
        return TRUSTED_SENDER_KEYWORDS.any { s.contains(it) }
    }

    /** 垃圾短信:验证码/安全校验类命中即拒(银行也会用这些文案,与金额无关)。 */
    fun shouldReject(body: String): Boolean {
        return REJECT_KEYWORDS.any { body.contains(it) }
    }

    /** 至少一个"交易证据":金额模式,或收支动作词。 */
    fun hasAmountOrAction(body: String): Boolean {
        return AMOUNT_PATTERN.containsMatchIn(body) ||
            ACTION_KEYWORDS.any { body.contains(it) }
    }

    /**
     * 营销页拒识(与 ScreenTextWatcher.isMarketingPage 同规则,2026-09-10
     * 回移):营销词命中 **且** 无已结算交易词时才拒。真实消费/账单详情短信
     * 常把「立减/满减/优惠券」作为抵扣行内嵌,营销词一票否决会把真实交易
     * 静默丢弃(屏幕看护路 2026-09-06 真机漏记根因,同根因补齐到短信路)。
     */
    fun isMarketingSms(body: String): Boolean {
        return MARKETING_KEYWORDS.any { body.contains(it) } &&
            !SETTLED_KEYWORDS.any { body.contains(it) }
    }

    /** 纯余额/结余提醒:出现余额类关键词但无任何收支动作词,按文档剔除。 */
    fun isPureBalanceReminder(body: String): Boolean {
        return BALANCE_TRIGGER.any { body.contains(it) } &&
            !ACTION_KEYWORDS.any { body.contains(it) }
    }

    /** 明确不是已完成交易的状态，交给上层前先挡住高频误记账来源。 */
    fun isNonBookableStatus(body: String): Boolean {
        return NON_BOOKABLE_KEYWORDS.any { body.contains(it) }
    }

    /**
     * 指纹字段编码:每个字段写成 `${长度}:${内容}`,再以 `|` 拼接。
     * 长度前缀让字段边界自描述 —— 内容里的 `|` 无法再与相邻字段互换
     * 构造同一指纹(2026-10-11 批次 C2)。Dart 侧
     * `AutoBillingService.smsFingerprint` 同口径(两侧都是 UTF-16 计数)。
     */
    private fun fieldEncoded(fields: List<String>): String =
        fields.joinToString("|") { "${it.length}:$it" }

    /** sha256(长度前缀拼接 sender/body) 前 16 位 hex,作为兼容用内容指纹。 */
    fun fingerprint(sender: String, body: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(fieldEncoded(listOf(sender, body)).toByteArray())
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /** 同一正文在不同接收时间仍可区分的原始事件键。 */
    fun eventKey(sender: String, fingerprint: String, timestamp: Long): String {
        return MessageDigest.getInstance("SHA-256")
            .digest("$sender|$timestamp|$fingerprint".toByteArray())
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    companion object {
        private const val TAG = "SmsReceiver"
        const val BRIDGE_ACTION = "com.smartbook.zhi.SMS_CAPTURED"

        const val PREFS_NAME = "sms_monitor_prefs"
        /** 统一队列里的来源标识(B3)。 */
        const val SOURCE = "sms"
        const val KEY_ENABLED = "enabled"
        const val KEY_FINGERPRINTS = "processed_fingerprints"
        const val KEY_QUEUE = "pending_queue"

        // B1 状态卡「最近捕获时间」:入队时落盘,ACK 清空队列后仍保留 ——
        // 否则长期无新事件时无法区分「没消息」与「监听断了」。
        const val KEY_LAST_CAPTURE_AT = "last_capture_at"

        const val MAX_FINGERPRINTS = 200
        const val MAX_QUEUE = 50
        private const val PROCESSED_EVENT_PREFIX = "event:"

        /** 银行/支付/运营商服务号关键词(子串匹配,已大写)。 */
        private val TRUSTED_SENDER_KEYWORDS = listOf(
            // 银行名
            "银行", "工商", "农行", "农业银行", "建行", "建设银行", "招商", "招行",
            "中国银行", "中行", "交通银行", "交行", "邮储", "邮政储蓄", "中信",
            "光大", "兴业", "民生", "浦发", "华夏", "广发", "平安", "浙商",
            "北京银行", "上海银行", "江苏银行", "宁波银行", "徽商", "农商行",
            "农村商业银行", "银联", "银联商务", "云闪付",
            // 支付平台
            "支付宝", "微信支付", "财付通", "京东支付", "美团支付", "度小满",
            "京东金融", "滴滴", "APPLE PAY",
            // 运营商(缴费/话费短信往往也含消费信息)
            "中国移动", "中国联通", "中国电信", "10086", "10010", "10000",
            // 银行客服短号
            "95588", "95533", "95555", "95599", "95595", "95566", "95501",
            "95559", "95511", "95512", "95586", "95577", "95508", "95568",
            "95561", "95594", "95518", "95516", "95534"
        )

        /** 验证码/安全校验类:命中即拒,与金额无关(银行也会用这些文案)。 */
        private val REJECT_KEYWORDS = listOf(
            "验证码", "校验码", "动态码", "动态口令", "授权码", "识别码",
            "信息码", "验证码有效期", "短信验证码", "手机验证码",
            "登录", "注册", "重置密码", "绑定", "解绑", "安全验证", "人机验证",
            "异常登录", "异地登录", "新设备", "身份验证", "考试", "取件码",
            "网页链接", "点击链接", "查看链接"
        )

        /** 营销推广类:配合 [isMarketingSms] 使用(命中且无已结算词才拒)。 */
        private val MARKETING_KEYWORDS = listOf(
            "退订", "回复TD", "优惠券", "满减", "秒杀", "邀请码", "购物节",
            "双11", "双十一", "618", "促销", "特惠", "会员日", "立减",
            "抽奖", "问卷", "红包雨", "有奖", "限时", "领券", "福利",
            "直降", "特价", "折扣"
        )

        /** 已结算交易词:与 [MARKETING_KEYWORDS] 组合判定(营销词命中但含
         *  已结算词的真实消费放行,交给 AI 精判)。 */
        private val SETTLED_KEYWORDS = listOf(
            "支付成功", "付款成功", "交易成功", "已支付", "已付款", "支付完成",
            "扣款成功", "消费成功", "退款成功", "收款到账", "交易完成",
            "消费", "支出", "扣款", "扣费", "支付", "付款", "退款", "入账", "到账"
        )

        /** 余额/结余类关键词:配合动作词判定"纯余额提醒"。 */
        private val BALANCE_TRIGGER = listOf(
            "余额", "结余", "可用金额", "可用额度", "当前余额", "账户余额"
        )

        /** 收支动作词:任一命中即视为"可能是交易"。 */
        private val ACTION_KEYWORDS = listOf(
            "消费", "支出", "扣款", "扣费", "转账", "转入", "转出", "收款",
            "入账", "充值", "退款", "还款", "支付", "付款", "扫码", "刷卡",
            "提现", "红包", "汇入", "汇出", "购买", "代扣", "扣缴",
            "利息", "存现", "存入", "取现", "取款", "汇兑", "购汇", "费"
        )

        /** 明确的账单/订单非结算状态，不能直接生成消费。
         *  2026-09-10 收窄:「可用额度」从本表移除 —— 信用卡消费短信正文尾部
         *  常带「可用额度 xxxx 元」尾注,一票否决把真实消费静默丢弃;纯额度
         *  提醒(无收支动作词)由 [isPureBalanceReminder] 正确覆盖。
         *  「还款日」同理仅保留强汇总写法(「还款日前」「最低还款」),
         *  单独「还款日」多是已还款通知的一部分。 */
        private val NON_BOOKABLE_KEYWORDS = listOf(
            "本期账单", "账单已出", "账单出账", "最低还款", "还款日前",
            "待付款", "待支付", "待确认", "订单确认",
            "交易关闭", "支付失败", "交易失败", "支付未成功", "订单已关闭",
            "积分余额", "积分到账"
        )

        /** 金额证据:带 ¥/￥ 符号,或数字紧邻 元/块。 */
        private val AMOUNT_PATTERN = Regex("[¥￥]\\s*\\d|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*元|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*块")

        // ------------------------------------------------------------
        // 持久化队列(JSON,cap MAX_QUEUE)。drain 后即清,原文不长期保留。
        // C7(2026-09-15):队列/指纹操作全部是 companion object 静态方法
        // (@Synchronized 锁 companion 实例 = 类级单锁)。旧行为是实例方法,
        // MainActivity 用临时实例(SmsReceiver().peekQueue)调用 —— 锁对象互不
        // 相同,互斥形同虚设;任一侧挪后台线程就会 SharedPreferences 丢更新
        // (丢新短信/复活已 ACK 项)。对照 ScreenshotObserver 的 companion 模式。
        // ------------------------------------------------------------

        /** 读取全部积压短信(读取不移除 —— 移除由 Flutter 侧逐项 ack)。
         *
         * 设计:drain-then-delete 会在"读取后、处理完前"被进程杀死时丢掉
         * 未处理的短信;peek-then-ack 只会丢"正在处理的那一条"(ack 语义
         * 与处理完成原子写入),未开始的项下次启动继续处理。
         */
        /** peek 不删除;处理完成由 [ackSms] 逐项确认(B3 分批读取)。 */
        @Synchronized
        fun peekQueue(context: Context): ArrayList<Map<String, String>> {
            migrate(context)
            val items = NativeAutoBookQueue.peekBatch(
                context, SOURCE, NativeAutoBookQueue.MAX_PER_SOURCE
            )
            val result = ArrayList<Map<String, String>>(items.size)
            for (item in items) result.add(NativeAutoBookQueue.toMap(item))
            return result
        }

        /** 按指纹删除已处理项(处理完成后 ack)。 */
        @Synchronized
        fun ackSms(
            context: Context,
            fingerprints: List<String>,
            eventKeys: List<String> = emptyList(),
        ) {
            if (fingerprints.isEmpty() && eventKeys.isEmpty()) return
            migrate(context)
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val wanted = (fingerprints + eventKeys).filter { it.isNotEmpty() }.toSet()
            if (wanted.isEmpty()) return

            // 先取回原始项:删除后就无法再补「已处理」备忘录。
            val acked = mutableSetOf<String>()
            for (obj in NativeAutoBookQueue.itemsFor(context, SOURCE, wanted)) {
                val fp = obj.optString("fingerprint")
                val key = obj.optString("eventKey")
                // 新格式持久化带前缀的 eventKey;没有 eventKey 的旧项回退指纹。
                if (key.isNotEmpty()) {
                    acked.add(PROCESSED_EVENT_PREFIX + key)
                } else if (fp.isNotEmpty()) {
                    acked.add(fp)
                }
            }
            NativeAutoBookQueue.ack(context, SOURCE, wanted.toList())
            if (acked.isEmpty()) return
            val processed = loadFingerprints(prefs)
            processed.addAll(acked)
            saveFingerprints(prefs, processed)
        }

        @Synchronized
        fun queueSize(context: Context): Int {
            migrate(context)
            return NativeAutoBookQueue.stats(context, SOURCE).count
        }

        /** 最近一次入队时间(0 = 本机从未捕获过)。只读状态查询用。 */
        fun lastCaptureAt(context: Context): Long {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getLong(KEY_LAST_CAPTURE_AT, 0L)
        }

        @Synchronized
        private fun enqueue(
            context: Context,
            prefs: SharedPreferences,
            eventKey: String,
            fingerprint: String,
            sender: String,
            body: String,
            ts: Long,
        ): Boolean {
            migrate(context)
            val processed = loadFingerprints(prefs)
            // 新事件按 eventKey 去重，不能把内容 fingerprint 当永久幂等键，
            // 否则两条正文完全相同但时间不同的真实短信会互相覆盖。
            if (processed.contains(PROCESSED_EVENT_PREFIX + eventKey)) return false
            // 队列内去重交给统一队列(同 source + event_key 主键冲突即重复)。
            val item = JSONObject()
                .put("eventKey", eventKey)
                .put("fingerprint", fingerprint)
                .put("sender", sender)
                .put("body", body)
                .put("timestamp", ts)
            val target = AutoBookTargetStore.enqueueFields(context)
            val result = NativeAutoBookQueue.enqueue(
                context = context,
                source = SOURCE,
                item = item,
                nowMs = System.currentTimeMillis(),
                targetRef = target["targetRef"] as? String,
                targetVersion = target["targetVersion"] as? Int,
                targetState = target["targetState"] as? String,
            )
            if (result != NativeAutoBookQueue.EnqueueResult.added) return false
            prefs.edit().putLong(KEY_LAST_CAPTURE_AT, ts).apply()
            return true
        }

        /** 首次访问时把旧 SharedPreferences 队列迁进统一队列(幂等)。 */
        private fun migrate(context: Context) {
            NativeAutoBookQueue.migrateFromPrefs(context, SOURCE, PREFS_NAME, KEY_QUEUE)
        }

        fun loadFingerprints(prefs: SharedPreferences): MutableSet<String> {
            return prefs.getString(KEY_FINGERPRINTS, null)
                ?.split("|")?.filter { it.isNotEmpty() }?.toMutableSet()
                ?: mutableSetOf()
        }

        fun saveFingerprints(prefs: SharedPreferences, memo: MutableSet<String>) {
            // 只保留最近 MAX_FINGERPRINTS 条(Set 无序,转为 List 后截尾)
            val trimmed = memo.toList().takeLast(MAX_FINGERPRINTS)
            prefs.edit().putString(KEY_FINGERPRINTS, trimmed.joinToString("|")).apply()
        }

        private fun log(msg: String) {
            // vivo OriginOS 会过滤 Log.d(debug 级),用 Log.i 保证诊断日志可见
            Log.i(TAG, msg)
        }
    }
}
