package com.smartbook.zhi

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * 支付通知监听服务(自动记账)。
 *
 * SmartBook 原版实际没有通知捕获(文档标注"已内置"的 NotificationReceiver
 * 只是闹钟提醒),本服务补上真实能力:
 *   1. 监听微信/支付宝/银行 App 的支付通知(包名白名单);
 *   2. 剔除验证码/营销类;金额与收支动作词须**同时命中**才放行(缺一即弃,
 *      比短信更严,因为通知文本噪声更多,只有动作词或只有金额都不足以确定是支付通知);
 *   3. 指纹去重 + 持久化队列(与短信队列相互独立);
 *   4. Flutter 进程存活时经桥接广播即时取走,否则下次启动 drain。
 *
 * 隐私:通知 title/text 不入日志;处理完即从队列删除。
 * 与短信一样:"宁缺勿滥"——模糊内容交给 AI(billGuard)判定,这里只管确定过滤。
 */
class NotificationWatcher : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        try {
            val s = sbn ?: return
            // 只处理 group summary 之外的普通通知(微信服务号/银行 App 支付通知)
            if (s.notification?.flags?.and(android.app.Notification.FLAG_GROUP_SUMMARY) != 0) return

            val pkg = s.packageName
            if (!TRUSTED_PACKAGES.any { pkg.contains(it) }) {
                log("包名未命中白名单,丢弃: $pkg")
                return
            }
            // 定时闹钟/媒体类通知不取大文本 —— 用 extra_text 与 extra_big_text
            val extras = s.notification?.extras ?: return
            val title = extras.getString("android.title") ?: ""
            val text = buildString {
                append(extras.getString("android.text") ?: "")
                val bigText = extras.getCharSequence("android.bigText")?.toString()
                if (bigText != null) append("\n").append(bigText)
            }.trim()
            if (text.isEmpty()) return

            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_ENABLED, false)) {
                log("开关关闭,丢弃通知")
                return
            }
            if (shouldReject(text)) {
                log("内容命中垃圾特征,丢弃")
                return
            }
            if (isPureBalanceReminder(text)) {
                log("纯余额/结余提醒,丢弃")
                return
            }
            if (!hasAmountAndAction(text)) {
                log("无金额或无收支动作特征,丢弃")
                return
            }

            val fingerprint = fingerprint(pkg, title, text)
            val memo = loadFingerprints(prefs)
            if (memo.contains(fingerprint)) {
                log("指纹已处理过,丢弃")
                return
            }
            memo.add(fingerprint)
            saveFingerprints(prefs, memo)

            enqueue(prefs, fingerprint, pkg, title, text, System.currentTimeMillis())

            try {
                sendBroadcast(Intent(BRIDGE_ACTION).setPackage(packageName))
            } catch (e: Exception) {
                Log.e(TAG, "发送桥接广播失败(不影响入队)", e)
            }
        } catch (e: Exception) {
            Log.e(TAG, "处理通知失败", e)
        }
    }

    // ------------------------------------------------------------
    // 过滤规则(与 SmsReceiver 同策略,可单测)
    // ------------------------------------------------------------

    fun shouldReject(text: String): Boolean {
        return REJECT_KEYWORDS.any { text.contains(it) } ||
            MARKETING_KEYWORDS.any { text.contains(it) }
    }

    /** 金额与收支动作词须**同时命中**(缺一视为非交易)。
     *  通知文本噪声多,只有动作词(如"请及时支付")或只有金额都不足以确定
     *  是支付通知,两者都要有才能交给 AI 做精细判定。 */
    fun hasAmountAndAction(text: String): Boolean {
        return AMOUNT_PATTERN.containsMatchIn(text) &&
            ACTION_KEYWORDS.any { text.contains(it) }
    }

    fun isPureBalanceReminder(text: String): Boolean {
        return BALANCE_TRIGGER.any { text.contains(it) } &&
            !ACTION_KEYWORDS.any { text.contains(it) }
    }

    /**
     * 通知指纹:sha256(pkg|title|text) 前 16 位 hex。
     * 与短信指纹不共用命名空间(pkg ≠ sender 并不会冲突,但独立 key 更清晰)。
     */
    fun fingerprint(pkg: String, title: String, text: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest("$pkg|$title|$text".toByteArray())
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun loadFingerprints(prefs: SharedPreferences): MutableSet<String> {
        return prefs.getString(KEY_FINGERPRINTS, null)
            ?.split("|")?.filter { it.isNotEmpty() }?.toMutableSet()
            ?: mutableSetOf()
    }

    fun saveFingerprints(prefs: SharedPreferences, memo: MutableSet<String>) {
        val trimmed = memo.toList().takeLast(MAX_FINGERPRINTS)
        prefs.edit().putString(KEY_FINGERPRINTS, trimmed.joinToString("|")).apply()
    }

    // ------------------------------------------------------------
    // 持久化队列(独立 prefs,结构同短信队列:peek + 逐项 ack)
    // ------------------------------------------------------------

    @Synchronized
    private fun enqueue(prefs: SharedPreferences, fingerprint: String, pkg: String, title: String, text: String, ts: Long) {
        val arr = JSONArray(prefs.getString(KEY_QUEUE, null) ?: "[]")
        arr.put(
            JSONObject()
                .put("fingerprint", fingerprint)
                .put("package", pkg)
                .put("title", title)
                .put("body", text)
                .put("timestamp", ts)
        )
        while (arr.length() > MAX_QUEUE) arr.remove(0)
        prefs.edit().putString(KEY_QUEUE, arr.toString()).apply()
    }

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
                    "fingerprint" to obj.optString("fingerprint"),
                    "package" to obj.optString("package"),
                    "title" to obj.optString("title"),
                    "body" to obj.optString("body"),
                    "timestamp" to obj.optString("timestamp")
                )
            )
        }
        return result
    }

    @Synchronized
    fun ackQueue(context: Context, fingerprints: List<String>) {
        if (fingerprints.isEmpty()) return
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_QUEUE, null) ?: return
        val arr = JSONArray(raw)
        val remaining = JSONArray()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            if (fingerprints.contains(obj.optString("fingerprint"))) continue
            remaining.put(obj)
        }
        prefs.edit().putString(KEY_QUEUE, remaining.toString()).apply()
    }

    companion object {
        private const val TAG = "NotificationWatcher"
        const val BRIDGE_ACTION = "com.smartbook.zhi.NOTIFY_CAPTURED"

        const val PREFS_NAME = "notify_monitor_prefs"
        const val KEY_ENABLED = "enabled"
        const val KEY_FINGERPRINTS = "processed_fingerprints"
        const val KEY_QUEUE = "pending_queue"

        const val MAX_FINGERPRINTS = 200
        const val MAX_QUEUE = 50

        /** 支付/银行 App 包名白名单(子串匹配)。自用可在此扩展。
         *  京东/抖音包名 2026-09 已在真机核对补充。 */
        private val TRUSTED_PACKAGES = listOf(
            "eg.android.AlipayGphone",        // 支付宝
            "tencent.mm",                     // 微信(含微信支付)
            "com.unionpay",                   // 云闪付
            "com.tencent.mm.biz",             // 微信支付服务号(兜底)
            "com.jingdong.app.mall",          // 京东
            "com.ss.android.ugc.aweme",       // 抖音(含极速版,子串覆盖 lite)
            // 六大行(包名按常见值,若有出入请在真机核对后增补)
            "com.icbc",                       // 中国工商银行
            "com.chinamworld.main",           // 中国建设银行
            "android.bankabc",                // 中国农业银行
            "com.chinabank.mobilebank",       // 中国银行(实际包名待核对)
            "com.bankcomm.Bankcomm",          // 交通银行(实际包名待核对)
            "cmb.pb",                         // 招商银行
            "cn.pay.youjian",                 // 邮储银行(实际包名待核对)
            "lianlian.trust"                  // 连连支付(商户通知,可选)
        )

        private val REJECT_KEYWORDS = listOf(
            "验证码", "校验码", "动态码", "动态口令", "授权码", "识别码",
            "短信验证码", "手机验证码", "登录", "注册", "重置密码", "绑定",
            "解绑", "安全验证", "人机验证", "异常登录", "异地登录", "新设备",
            "身份验证", "考试", "取件码", "网页链接", "点击链接", "查看链接"
        )

        private val MARKETING_KEYWORDS = listOf(
            "退订", "回复TD", "优惠券", "满减", "秒杀", "邀请码", "购物节",
            "双11", "双十一", "618", "促销", "特惠", "会员日", "立减",
            "抽奖", "问卷", "红包雨", "有奖", "限时", "领券", "福利",
            "直降", "特价", "折扣"
        )

        private val BALANCE_TRIGGER = listOf(
            "余额", "结余", "可用金额", "可用额度", "当前余额", "账户余额"
        )

        private val ACTION_KEYWORDS = listOf(
            "消费", "支出", "扣款", "扣费", "转账", "转入", "转出", "收款",
            "入账", "到账", "充值", "退款", "还款", "支付", "付款", "扫码", "刷卡",
            "提现", "红包", "汇入", "汇出", "购买", "代扣", "扣缴",
            "利息", "存现", "存入", "取现", "取款", "汇兑", "购汇", "费"
        )

        private val AMOUNT_PATTERN = Regex("[¥￥]\\s*\\d|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*元|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*块|人民币\\s*\\d")

        private fun log(msg: String) {
            // vivo OriginOS 会过滤 Log.d(debug 级),用 Log.i 保证诊断日志可见
            Log.i(TAG, msg)
        }
    }
}
