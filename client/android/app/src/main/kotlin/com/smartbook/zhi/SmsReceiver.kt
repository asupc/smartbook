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
        if (!enqueue(prefs, eventKey, fingerprint, sender, body, sourceTimestamp)) {
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

    /** 垃圾短信:验证码/安全校验类、营销推广类,命中即拒。 */
    fun shouldReject(body: String): Boolean {
        return REJECT_KEYWORDS.any { body.contains(it) } ||
            MARKETING_KEYWORDS.any { body.contains(it) }
    }

    /** 至少一个"交易证据":金额模式,或收支动作词。 */
    fun hasAmountOrAction(body: String): Boolean {
        return AMOUNT_PATTERN.containsMatchIn(body) ||
            ACTION_KEYWORDS.any { body.contains(it) }
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

    /** sha256(sender|body) 前 16 位 hex,作为兼容用内容指纹。 */
    fun fingerprint(sender: String, body: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest("$sender|$body".toByteArray())
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

    // ------------------------------------------------------------
    // 持久化队列(JSON,cap MAX_QUEUE)。drain 后即清,原文不长期保留。
    // ------------------------------------------------------------

    @Synchronized
    private fun enqueue(
        prefs: SharedPreferences,
        eventKey: String,
        fingerprint: String,
        sender: String,
        body: String,
        ts: Long,
    ): Boolean {
        val processed = loadFingerprints(prefs)
        // 新事件按 eventKey 去重，不能把内容 fingerprint 当永久幂等键，
        // 否则两条正文完全相同但时间不同的真实短信会互相覆盖。
        if (processed.contains(PROCESSED_EVENT_PREFIX + eventKey)) return false
        val arr = JSONArray(prefs.getString(KEY_QUEUE, null) ?: "[]")
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            if (obj.optString("eventKey") == eventKey ||
                (obj.optString("eventKey").isEmpty() &&
                    obj.optString("fingerprint") == fingerprint)
            ) {
                return false
            }
        }
        arr.put(
            JSONObject()
                .put("eventKey", eventKey)
                .put("fingerprint", fingerprint)
                .put("sender", sender)
                .put("body", body)
                .put("timestamp", ts)
        )
        // 超出容量:删最旧(0 是队头,最先入队)。未 ACK 的项不写入 processed,
        // 避免容量淘汰造成静默丢失后永久阻断重放。
        while (arr.length() > MAX_QUEUE) arr.remove(0)
        prefs.edit().putString(KEY_QUEUE, arr.toString()).apply()
        return true
    }

    /**
     * 读取全部积压短信(读取不移除 —— 移除由 Flutter 侧逐项 ack)。
     *
     * 设计:drain-then-delete 会在"读取后、处理完前"被进程杀死时丢掉
     * 未处理的短信;peek-then-ack 只会丢"正在处理的那一条"(ack 语义
     * 与处理完成原子写入),未开始的项下次启动继续处理。
     */
    @Synchronized
    fun peekQueue(context: Context): ArrayList<Map<String, String>> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_QUEUE, null) ?: return ArrayList()
        val arr = JSONArray(raw)
        val result = ArrayList<Map<String, String>>(arr.length())
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            result.add(
                mapOf(
                    "eventKey" to obj.optString("eventKey"),
                    "fingerprint" to obj.optString("fingerprint"),
                    "sender" to obj.optString("sender"),
                    "body" to obj.optString("body"),
                    "timestamp" to obj.optString("timestamp")
                )
            )
        }
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
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_QUEUE, null) ?: return
        val wanted = (fingerprints + eventKeys).toSet()
        val arr = JSONArray(raw)
        val remaining = JSONArray()
        val acked = mutableSetOf<String>()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val fp = obj.optString("fingerprint")
            val key = obj.optString("eventKey")
            if (wanted.contains(fp) || (key.isNotEmpty() && wanted.contains(key))) {
                // 新格式只持久化带前缀的 eventKey；没有 eventKey 的旧队列
                // 才回退到内容 fingerprint。
                if (key.isNotEmpty()) {
                    acked.add(PROCESSED_EVENT_PREFIX + key)
                } else if (fp.isNotEmpty()) {
                    acked.add(fp)
                }
            } else {
                remaining.put(obj)
            }
        }
        if (acked.isEmpty()) return
        val processed = loadFingerprints(prefs)
        processed.addAll(acked)
        saveFingerprints(prefs, processed)
        prefs.edit().putString(KEY_QUEUE, remaining.toString()).apply()
    }

    @Synchronized
    fun queueSize(context: Context): Int {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return JSONArray(prefs.getString(KEY_QUEUE, null) ?: "[]").length()
    }

    companion object {
        private const val TAG = "SmsReceiver"
        const val BRIDGE_ACTION = "com.smartbook.zhi.SMS_CAPTURED"

        const val PREFS_NAME = "sms_monitor_prefs"
        const val KEY_ENABLED = "enabled"
        const val KEY_FINGERPRINTS = "processed_fingerprints"
        const val KEY_QUEUE = "pending_queue"

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

        /** 营销推广类:命中即拒。 */
        private val MARKETING_KEYWORDS = listOf(
            "退订", "回复TD", "优惠券", "满减", "秒杀", "邀请码", "购物节",
            "双11", "双十一", "618", "促销", "特惠", "会员日", "立减",
            "抽奖", "问卷", "红包雨", "有奖", "限时", "领券", "福利",
            "直降", "特价", "折扣"
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

        /** 明确的账单/订单非结算状态，不能直接生成消费。 */
        private val NON_BOOKABLE_KEYWORDS = listOf(
            "本期账单", "账单已出", "账单出账", "最低还款", "还款日前",
            "还款日", "待付款", "待支付", "待确认", "订单确认",
            "交易关闭", "支付失败", "交易失败", "支付未成功", "订单已关闭",
            "可用额度", "积分余额", "积分到账"
        )

        /** 金额证据:带 ¥/￥ 符号,或数字紧邻 元/块。 */
        private val AMOUNT_PATTERN = Regex("[¥￥]\\s*\\d|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*元|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*块")

        private fun log(msg: String) {
            // vivo OriginOS 会过滤 Log.d(debug 级),用 Log.i 保证诊断日志可见
            Log.i(TAG, msg)
        }
    }
}
