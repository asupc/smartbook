package com.smartbook.zhi

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * 屏幕文本监听服务(账单详情页自动记账,无障碍)。
 *
 * 与 NotificationWatcher 的分工:通知监听覆盖「支付成功瞬间」(App 发出
 * 支付通知时),本服务覆盖「打开账单/订单详情页」场景(抖音、京东等不发
 * 支付通知的 App 以及历史账单回看)。系统无障碍服务读取前台页面文本树,
 * 检测到金额+交易特征后持久化入队,Flutter 侧经 AI 记账。流程与
 * NotificationWatcher 完全同构:
 *   1. 白名单包名(支付宝/抖音/京东/微信/招商银行) + 事件防抖(支付结果页
 *      类名命中快速通道时防抖缩短,见 FAST_PATH_PAGES);
 *   2. 聊天页类名拒识 → fastQuery 式锚点预筛(不展开整树) → 垃圾特征剔除 +
 *      强/弱锚点分级与金额粗筛(宁缺勿滥);
 *   3. 指纹去重 + 持久化队列与短信/通知队列相互独立;
 *   4. Flutter 进程存活时经桥接广播即时取走,否则下次启动 drain。
 *
 * 页面识别思路(2026-09 参考 GKD 广告跳过订阅的支付类规则规律并适配,非照搬):
 * GKD 对支付规则一律「activityIds 锁页面 + 文本锚点组合确认」,本服务借鉴为
 * 三点 —— 已知结果页类名走快速通道(缩短防抖抢抓取)、交易特征词分强/弱两级
 * (弱词需 ≥2 个同时命中)、整树采集前先做廉价锚点探测。类名表只收录短时
 * 停留的支付结果页,历史账单回看(H5 容器页等)仍由内容启发式覆盖。
 *
 * 隐私:抓取文本**不入日志**(只打长度摘要)、不落盘,队列项处理完即删;
 * 与短信/通知一致,文本仅在 AI 已配置时发送到用户配置的 AI 服务商做记账。
 * 说明:抖音/京东部分页面是 WebView/自研引擎,无障碍文本树可能拿不到,
 * 拿不到时宁可漏记也不误记 —— 由 AI 判定兜底。
 */
open class ScreenTextWatcher : AccessibilityService() {

    // lazy:纯 JVM 单测无 Android Looper,实例化过滤测试时不能初始化 Handler
    private val handler: Handler by lazy { Handler(Looper.getMainLooper()) }

    // 生命周期日志:用于排查「无障碍开关被系统秒关」—— logcat 里
    // 没有「连接成功」说明绑定被拒(受限设置/ROM 拦截),有「连接成功」
    // 后紧接着进程消亡才说明是崩溃/被杀。
    override fun onServiceConnected() {
        super.onServiceConnected()
        log("无障碍服务连接成功,开始监听白名单 App 事件")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        Log.d(TAG, "无障碍服务被解绑")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        Log.d(TAG, "无障碍服务销毁")
        super.onDestroy()
    }
    private var grabScheduled = false
    private var retryCount = 0
    private var lastEventAt = 0L
    private var lastEventPkg = ""
    private var lastPageClass = ""
    private var lastDisabledRecordAt = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        try {
            if (e.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
                e.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
            ) return
            val pkg = e.packageName?.toString() ?: return
            if (!TRUSTED_PACKAGES.any { pkg.contains(it) }) return

            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_ENABLED, false)) {
                log("白名单包可见但开关关闭,跳过: $pkg")
                // 决策记录节流:事件风暴下 5s 一条,够设置页定位「开关没开」
                val now = System.currentTimeMillis()
                if (now - lastDisabledRecordAt > 5_000) {
                    lastDisabledRecordAt = now
                    recordDecision(this, pkg, "skipped_disabled", "监听开关未开启")
                }
                return
            }

            // 只有窗口切换事件携带页面(Activity)类名;内容变化事件携带的是
            // 控件类名,不能覆盖。据此维护「当前页面类名」供聊天页黑名单判定。
            if (e.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                lastPageClass = e.className?.toString() ?: ""
            }

            // 事件到达只记时间戳,保证只有一个待执行的抓取任务。
            lastEventAt = System.currentTimeMillis()
            lastEventPkg = pkg
            scheduleGrab()
        } catch (ex: Exception) {
            Log.e(TAG, "处理无障碍事件失败", ex)
        }
    }

    /**
     * 防抖:页面停止变化 GRAB_IDLE_MS 后再抓取(参考 ScreenshotObserver
     * 两段写入「收集后延迟统一检查」思路)。期间有滚动/加载等持续事件则重排,
     * 重试次数上限防止滚动流无限后延。
     */
    private fun scheduleGrab() {
        if (grabScheduled) return
        grabScheduled = true
        val idleMs = grabIdleMs()
        handler.postDelayed({
            grabScheduled = false
            if (System.currentTimeMillis() - lastEventAt < idleMs &&
                retryCount < MAX_GRAB_RETRIES
            ) {
                retryCount++
                scheduleGrab()
                return@postDelayed
            }
            retryCount = 0
            grabAndProcess()
        }, idleMs)
    }

    /**
     * 防抖时长按页面身份动态取值:支付结果页(快速通道)停留常只有几秒且
     * 可能自动跳转,800ms 全额防抖容易抢不到内容,缩到 300ms。参考 GKD 对
     * 支付完成页规则的紧时效处理(activityIds 先锁页再立即动作)适配而来,
     * 只调防抖,不引入强制抓取。
     */
    private fun grabIdleMs(): Long {
        return if (isFastPathPage(lastEventPkg, lastPageClass)) FAST_GRAB_IDLE_MS else GRAB_IDLE_MS
    }

    private fun grabAndProcess() {
        try {
            val pkg = lastEventPkg
            if (pkg.isEmpty()) return
            val fastPath = isFastPathPage(pkg, lastPageClass)

            // 聊天页拒识只依赖类名,提到最前:聊天页连锚点探测与整树采集都
            // 不做(此前在采集之后才判,白白读了整树文本)。
            if (isChatPage(pkg, lastPageClass)) {
                log("页面类名命中聊天页黑名单,丢弃: $pkg/$lastPageClass")
                recordDecision(this, pkg, "chat_page", "cls=$lastPageClass")
                return
            }

            val root = rootInActiveWindow
            if (root == null) {
                recordDecision(this, pkg, "no_anchor", "rootInActiveWindow=null(窗口未就绪)")
                return
            }

            // 窗口归属校验:防抖结束的瞬间窗口可能已切换(快速通道 300ms 更
            // 明显),根节点包名与事件包名对不上说明读到的不是来源 App 的页面,
            // 丢弃本次抓取,等后续事件重新触发。contains 双向是覆盖微信
            // 「com.tencent.mm:appbrand0」这类子进程包名。
            val rootPkg = root.packageName?.toString() ?: ""
            if (rootPkg.isNotEmpty() && !pkg.contains(rootPkg) && !rootPkg.contains(pkg)) {
                log("窗口归属不符,丢弃: 事件=$pkg 根=$rootPkg")
                recordDecision(this, pkg, "pkg_mismatch", "root包名=$rootPkg cls=$lastPageClass")
                return
            }

            // fastQuery 式锚点预筛(GKD fastQuery 规律适配):先用框架原生的
            // 文本查找探测强锚点,全部落空就不展开整树 —— 白名单 App 的绝大
            // 多数页面(聊天流/商品流/信息流)没有强锚点,整树采集的逐节点
            // binder 往返与字符串拼接都省下,页面文本也不进入本进程(隐私同
            // 向)。探测词表 ⊆ 强锚点表,只会提前放弃、不会漏掉本应入队的页
            // 面:弱锚点 ≥2 的页面仍会走完整采集与判定。
            if (!hasAnchorNode(root)) {
                log("锚点预筛未命中,跳过整树采集: $pkg/$lastPageClass")
                recordDecision(this, pkg, "no_anchor", "预筛未命中锚点(cls=$lastPageClass)")
                return
            }

            val text = collectWindowText()
            val logLen = text.length
            if (text.length < MIN_TEXT_LENGTH) {
                log("页面文本 < $MIN_TEXT_LENGTH 字符,丢弃过短页面: $pkg len=$logLen")
                recordDecision(this, pkg, "too_short", "len=$logLen(<$MIN_TEXT_LENGTH,页面可能未加载完/无障碍树为空)")
                return
            }
            val rejectHit = REJECT_KEYWORDS.firstOrNull { text.contains(it) }
            if (rejectHit != null) {
                log("页面内容命中垃圾特征,丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "rejected", "命中垃圾词=$rejectHit")
                return
            }
            val marketingHit = MARKETING_KEYWORDS.firstOrNull { text.contains(it) }
            if (marketingHit != null && !hasBookableHint(text)) {
                log("页面内容命中营销特征且无交易特征,丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "marketing_no_hint", "命中营销词=$marketingHit")
                return
            }
            val amountCount = AMOUNT_PATTERN.findAll(text).count()
            if (!hasAmount(text) || !hasBookableHint(text)) {
                val why = if (!hasAmount(text)) "无金额" else "无交易特征"
                log("无金额或无交易特征,丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "no_amount_or_hint", "$why amounts=$amountCount")
                return
            }
            // 列表页(整页几十条流水)金额会命中几十次,详情页单条账单只有 1~3 个
            // 金额。不挡列表页会把历史流水批量送 AI,重复/错误入账。
            if (isListPage(text)) {
                log("命中列表页特征(金额出现 ${AMOUNT_PATTERN.findAll(text).count()} 次),丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "list_page", "amounts=$amountCount(≥$MAX_DETAIL_AMOUNTS,整页流水/推荐流?)")
                return
            }
            val nonBookableHit = NON_BOOKABLE_KEYWORDS.firstOrNull { text.contains(it) }
            if (nonBookableHit != null) {
                log("命中账单汇总/待支付/失败状态,丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "non_bookable", "命中状态词=$nonBookableHit")
                return
            }

            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val fingerprint = fingerprint(pkg, text)
            val timestamp = System.currentTimeMillis()
            val eventKey = eventKey(pkg, fingerprint, timestamp)
            if (!enqueue(prefs, eventKey, fingerprint, pkg, text, timestamp)) {
                log("页面已在已处理记录或待处理队列中,丢弃: $pkg len=$logLen")
                recordDecision(this, pkg, "duplicate", "同页面已在队列/已处理")
                return
            }
            log("已入队详情页文本: $pkg len=$logLen fast=$fastPath")
            recordDecision(
                this, pkg, "enqueued",
                "len=$logLen amounts=$amountCount fast=$fastPath hint=" +
                    (STRONG_TRADE_KEYWORDS.firstOrNull { text.contains(it) }
                        ?: WEAK_TRADE_KEYWORDS.filter { text.contains(it) }.joinToString("+"))
            )

            try {
                sendBroadcast(Intent(BRIDGE_ACTION).setPackage(packageName))
            } catch (e: Exception) {
                Log.e(TAG, "发送桥接广播失败(不影响入队)", e)
            }
        } catch (e: Exception) {
            Log.e(TAG, "抓取/入队屏幕文本失败", e)
        }
    }

    // ------------------------------------------------------------
    // 文本树收集
    // ------------------------------------------------------------

    /** 递归收集当前窗口可见文本(text + contentDescription),限深限量限字数。 */
    private fun collectWindowText(): String {
        val root = rootInActiveWindow ?: return ""
        try {
            val sb = StringBuilder()
            collectText(root, sb, 0, NodeStats())
            return sb.toString().trim()
        } finally {
            // API 33+ 的 node 不再需要 recycle
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                root.recycle()
            }
        }
    }

    private class NodeStats {
        var nodes = 0
        var chars = 0
    }

    private fun collectText(
        node: AccessibilityNodeInfo,
        sb: StringBuilder,
        depth: Int,
        stats: NodeStats,
    ) {
        if (depth > MAX_DEPTH || stats.nodes > MAX_NODES || stats.chars >= MAX_CHARS) return
        stats.nodes++

        val text = node.text?.toString()?.trim() ?: ""
        val desc = node.contentDescription?.toString()?.trim() ?: ""
        val joined = listOf(text, desc)
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        if (joined.isNotEmpty()) {
            if (sb.isNotEmpty()) sb.append('\n')
            val remaining = MAX_CHARS - stats.chars
            sb.append(if (joined.length > remaining) joined.substring(0, remaining) else joined)
            stats.chars += joined.length
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectText(child, sb, depth + 1, stats)
        }
    }

    /**
     * 锚点预筛(GKD fastQuery 规律适配):在整树采集前用框架原生的文本查找
     * 探测强锚点是否存在。findAccessibilityNodeInfosByText 对节点的
     * text/contentDescription 做不区分大小写的包含匹配,与 collectWindowText
     * 的「text+desc 拼接」口径一致;每次调用是单次进程间往返,树遍历由宿主
     * App 侧完成,比逐节点 getChild 的多轮往返便宜。任一强锚点命中即值得
     * 整树采集;全部落空则大概率不是账单页。API<33 的返回节点按惯例回收。
     */
    private fun hasAnchorNode(root: AccessibilityNodeInfo): Boolean {
        fun hit(word: String): Boolean {
            val found = root.findAccessibilityNodeInfosByText(word) ?: return false
            val exists = found.isNotEmpty()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                found.forEach { it.recycle() }
            }
            return exists
        }
        return STRONG_TRADE_KEYWORDS.any { hit(it) }
    }

    // ------------------------------------------------------------
    // 过滤规则(与 SmsReceiver/NotificationWatcher 同策略,可单测)
    // ------------------------------------------------------------

    fun shouldReject(text: String): Boolean {
        return REJECT_KEYWORDS.any { text.contains(it) }
    }

    /**
     * 营销页拒识:营销词命中 **且** 页面没有详情页强交易特征时才整页丢弃。
     * 真实账单详情页会把「立减/满减/优惠券」作为抵扣行内嵌(如支付宝账单
     * 详情的「碰一下立减 -0.44」),营销词整页子串一票否决会把真账单当
     * 营销页丢弃(2026-09-06 真机漏记根因);而纯营销/活动页(领券中心、
     * 秒杀频道)不会带「账单详情/交易成功/订单金额」这类强特征,仍在此被
     * 挡 —— 就算漏过,后面还有列表页/不可入账状态两道闸和 AI 最终判定兜底。
     */
    fun isMarketingPage(text: String): Boolean {
        return MARKETING_KEYWORDS.any { text.contains(it) } && !hasBookableHint(text)
    }

    /** 页面文本中是否出现金额(¥/￥ 前缀或 x元/x块 写法)。 */
    fun hasAmount(text: String): Boolean {
        return AMOUNT_PATTERN.containsMatchIn(text)
    }

    /**
     * 聊天页拒识:微信聊天列表/单聊页面十年未变(LauncherUI 承载聊天列表与
     * 单聊;微信支付/账单页是独立页面),按页面类名黑名单直接丢弃 —— 聊天
     * 文本既不是账单,送 AI 还有隐私风险。类名比内容特征可靠:聊天里出现
     * 「转账/支付成功 ¥xx」的消息气泡会绕过内容粗筛,却绕不过类名。
     * 覆盖子进程包名(如 com.tencent.mm:tools)用 contains 匹配。
     */
    fun isChatPage(pkg: String, pageClass: String): Boolean {
        if (pkg.contains("com.tencent.mm") &&
            (pageClass.contains("LauncherUI") || pageClass.contains("ChatUI"))
        ) return true
        return false
    }

    /**
     * 列表页判定:单条账单详情页金额通常出现 1~3 次(实付/原价/优惠/退款),
     * 账单/流水列表页则一条流水一个金额,整页几十个。金额命中次数达到阈值
     * 即视为列表页,丢弃 —— 避免把整页历史流水批量送 AI 造成重复/错误入账。
     */
    fun isListPage(text: String): Boolean {
        return AMOUNT_PATTERN.findAll(text).count() >= MAX_DETAIL_AMOUNTS
    }

    /** 明确不是已完成交易的状态，避免详情页把待付款/汇总页送入 AI。 */
    fun isNonBookableStatus(text: String): Boolean {
        return NON_BOOKABLE_KEYWORDS.any { text.contains(it) }
    }

    /**
     * 页面文本是否有账单/订单**详情页**特征(粗筛,精确判定交给 AI)。
     * 强/弱锚点分级(2026-09 参考 GKD 支付规则的「状态词+按钮词组合确认」
     * 适配):强锚点(页面标题/交易状态)单独命中即可;弱锚点(字段名/
     * 按钮文案)聊天与商品页擦边风险高,需 ≥2 个不同词同时命中 —— 原
     * 「任意单词命中即可」会让「订单号+金额」的订单确认/售后页通过粗筛。
     */
    fun hasBookableHint(text: String): Boolean {
        if (STRONG_TRADE_KEYWORDS.any { text.contains(it) }) return true
        return WEAK_TRADE_KEYWORDS.count { text.contains(it) } >= 2
    }

    /**
     * 支付结果页快速通道(仅影响防抖时长,不做放行)。匹配用 contains 子串,
     * 与 TRUSTED_PACKAGES 同风格;包名同样用 contains,覆盖微信小程序跑在
     * com.tencent.mm:appbrand0 这类子进程的场景。
     */
    fun isFastPathPage(pkg: String, pageClass: String): Boolean {
        return FAST_PATH_PAGES.any { (target, pages) ->
            pkg.contains(target) && pages.any { pageClass.contains(it) }
        }
    }

    /** 同一页面内容在不同捕获时刻可区分的原始事件键。 */
    fun eventKey(pkg: String, fingerprint: String, timestamp: Long): String {
        return MessageDigest.getInstance("SHA-256")
            .digest("$pkg|$timestamp|$fingerprint".toByteArray())
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /**
     * 页面指纹:sha256(pkg|text) 前 16 位 hex。与短信/通知指纹不共用命名空间
     * (pkg ≠ sender 并不会冲突,但独立 key 更清晰);Dart 侧同口径。
     */
    fun fingerprint(pkg: String, text: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest("$pkg|$text".toByteArray())
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
    // 持久化队列(独立 prefs,结构同通知/短信:peek + 逐项 ack)
    // ------------------------------------------------------------

    @Synchronized
    private fun enqueue(
        prefs: SharedPreferences,
        eventKey: String,
        fingerprint: String,
        pkg: String,
        text: String,
        ts: Long,
    ): Boolean {
        // 内容指纹优先判重:同一账单详情页文本完全一致,指纹稳定;事件键含
        // 捕获时间戳,每次进入详情页都会变化,不能作为去重依据(2026-09-07
        // 修复:重复进入被当成新事件,导致文本反复送 AI 记账)。已处理与队列
        // 里都按 fingerprint 判重,eventKey 仅作队列项标识。
        val processed = loadFingerprints(prefs)
        if (processed.contains(fingerprint) ||
            processed.contains(PROCESSED_EVENT_PREFIX + eventKey)
        ) return false
        val arr = JSONArray(prefs.getString(KEY_QUEUE, null) ?: "[]")
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val queuedFp = obj.optString("fingerprint")
            if (queuedFp == fingerprint || queuedFp.isEmpty() &&
                obj.optString("eventKey") == eventKey
            ) {
                return false
            }
        }
        arr.put(
            JSONObject()
                .put("eventKey", eventKey)
                .put("fingerprint", fingerprint)
                .put("package", pkg)
                .put("text", text)
                .put("timestamp", ts)
        )
        while (arr.length() > MAX_QUEUE) arr.remove(0)
        prefs.edit().putString(KEY_QUEUE, arr.toString()).apply()
        return true
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
                    "eventKey" to obj.optString("eventKey"),
                    "fingerprint" to obj.optString("fingerprint"),
                    "package" to obj.optString("package"),
                    "text" to obj.optString("text"),
                    "timestamp" to obj.optString("timestamp")
                )
            )
        }
        return result
    }

    @Synchronized
    fun ackQueue(
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
                // 已处理记录同时写指纹与事件键:指纹作为去重主依据(同内容不再
                // 记),事件键保留作兜底(2026-09-07)。之前只写 event:eventKey,
                // 而 eventKey 含时间戳每次变化,漏记了指纹导致重复入账。
                if (fp.isNotEmpty()) acked.add(fp)
                if (key.isNotEmpty()) acked.add(PROCESSED_EVENT_PREFIX + key)
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

    override fun onInterrupt() {
        // 无障碍服务被系统打断(如权限被撤销),无需处理
    }

    companion object {
        private const val TAG = "ScreenTextWatcher"
        const val BRIDGE_ACTION = "com.smartbook.zhi.SCREEN_TEXT_CAPTURED"

        const val PREFS_NAME = "screen_text_monitor_prefs"
        const val KEY_ENABLED = "enabled"
        const val KEY_FINGERPRINTS = "processed_fingerprints"
        const val KEY_QUEUE = "pending_queue"

        const val MAX_FINGERPRINTS = 200
        const val MAX_QUEUE = 30
        private const val PROCESSED_EVENT_PREFIX = "event:"

        // ---- 识别决策环形队列(设置页「最近识别记录」,排查真机漏记用) ----
        // 隐私:只存决策码/命中关键词/长度与计数,**绝不存页面文本** —— 文本仍
        // 遵守「不入日志、不落盘,仅在 AI 已配置时发往用户配置的服务商」约定。
        const val KEY_DECISIONS = "recent_decisions"
        const val MAX_DECISIONS = 20
        private const val MAX_DECISION_DETAIL = 120

        /** 记录一条识别决策。任何线程可调;失败静默(诊断能力不能反噬主流程)。 */
        fun recordDecision(context: Context, pkg: String, decision: String, detail: String) {
            try {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val arr = JSONArray(prefs.getString(KEY_DECISIONS, null) ?: "[]")
                arr.put(
                    JSONObject()
                        .put("ts", System.currentTimeMillis())
                        .put("pkg", pkg)
                        .put("decision", decision)
                        .put("detail", detail.take(MAX_DECISION_DETAIL))
                )
                while (arr.length() > MAX_DECISIONS) arr.remove(0)
                prefs.edit().putString(KEY_DECISIONS, arr.toString()).apply()
            } catch (_: Exception) {
            }
        }

        /** 读取决策记录(时间正序),供设置页展示。 */
        fun loadDecisions(context: Context): ArrayList<Map<String, String>> {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_DECISIONS, null) ?: return ArrayList()
            return try {
                val arr = JSONArray(raw)
                val result = ArrayList<Map<String, String>>(arr.length())
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    result.add(
                        mapOf(
                            "ts" to obj.optLong("ts").toString(),
                            "pkg" to obj.optString("pkg"),
                            "decision" to obj.optString("decision"),
                            "detail" to obj.optString("detail")
                        )
                    )
                }
                result
            } catch (_: Exception) {
                ArrayList()
            }
        }

        /** 详情页自动记账白名单包名(完整的包名;此处用 contains 子串匹配,
            与 NotificationWatcher 同风格,与 accessibility_service_config.xml
            的精确匹配等效 —— XML 必须写完整包名,见该文件注释)。
            招商银行 2026-09 已在真机核对补充;其余银行包名 2026-09 已逐家经
            应用商店核验(同 NotificationWatcher.TRUSTED_PACKAGES 注释)。
            注意:无障碍抓全页文本,银行 App 页面噪声大,故银行只开通知路、
            不进本白名单 —— 只有「详情页文本可判读」的 App 才值得无障碍抓。 */
        private val TRUSTED_PACKAGES = listOf(
            "com.eg.android.AlipayGphone",    // 支付宝
            "com.ss.android.ugc.aweme",       // 抖音(含极速版,子串覆盖 lite)
            "com.jingdong.app.mall",          // 京东
            "com.tencent.mm",                 // 微信
            "cmb.pb"                          // 招商银行
        )

        /** 事件防抖:页面静默多久后抓取 (ms) */
        private const val GRAB_IDLE_MS = 800L
        /** 快速通道页面(支付结果页)的防抖:短停留/可能自动跳转,抢抓取 */
        private const val FAST_GRAB_IDLE_MS = 300L
        /** 连续重排最大次数(防滚动类事件无限后延) */
        private const val MAX_GRAB_RETRIES = 2

        private const val MAX_DEPTH = 30
        private const val MAX_NODES = 400
        private const val MAX_CHARS = 2000
        private const val MIN_TEXT_LENGTH = 8

        /** 详情页允许的最大金额出现次数;达到即判定为列表页(整页流水),丢弃。 */
        private const val MAX_DETAIL_AMOUNTS = 5

        private val REJECT_KEYWORDS = listOf(
            "验证码", "校验码", "动态码", "动态口令", "授权码", "识别码",
            "短信验证码", "手机验证码", "登录", "注册", "重置密码", "绑定",
            "解绑", "安全验证", "人机验证", "异常登录", "异地登录", "新设备",
            "身份验证", "考试", "取件码", "网页链接", "点击链接", "查看链接"
        )

        /** 营销特征词:本路径不做一票否决,只在页面无详情页交易特征时拒识
            (见 isMarketingPage —— 真实账单详情常内嵌「立减/满减」抵扣行)。 */
        private val MARKETING_KEYWORDS = listOf(
            "退订", "回复TD", "优惠券", "消费券", "满减", "秒杀", "邀请码", "购物节",
            "双11", "双十一", "618", "促销", "特惠", "会员日", "立减",
            "抽奖", "问卷", "红包雨", "有奖", "限时", "领券", "福利",
            "直降", "特价", "折扣"
        )

        /**
         * 支付结果页快速通道类名表(2026-09,参考 GKD 订阅支付类规则的
         * activityIds 适配;类名是 GKD 订阅在真机长期验证过的映射):
         *  - MspContainerActivity:支付宝收银台/支付结果页
         *  - NResPageActivity:支付宝碰一碰/NFC 支付结果页
         *  - WxaLiteAppLiteUI / WxaLiteAppTransparentLiteUI:微信小程序支付结果
         *  - RemittanceDetailUI:微信收款详情(「已收款」页)
         * 微信 UIPageFragmentActivity 承载页面过多,支付宝账单详情是 H5 容器页,
         * 都不适合按类名放行 —— 历史账单回看仍由内容启发式覆盖。此表只决定
         * 防抖时长,是否入队仍走完整过滤链。
         */
        private val FAST_PATH_PAGES = mapOf(
            "com.eg.android.AlipayGphone" to listOf(
                "MspContainerActivity", "NResPageActivity"
            ),
            "com.tencent.mm" to listOf(
                "WxaLiteAppLiteUI", "WxaLiteAppTransparentLiteUI", "RemittanceDetailUI"
            )
        )

        /**
         * 强锚点:页面标题/交易状态级短语,单独命中(配合金额闸)即可放行。
         * 聊天口语里的单词(「我支付了」「退款了吗」「转账给你」)不会命中。
         */
        private val STRONG_TRADE_KEYWORDS = listOf(
            // 页面标题
            "订单详情", "账单详情", "交易详情", "支付详情", "退款详情",
            "订单结算", "支付结果", "微信支付凭证", "红包详情",
            // 支出状态
            "支付成功", "付款成功", "交易成功", "已支付", "已付款",
            "退款成功", "支付完成",
            // 收入状态(2026-09 补全:原词表只有支出视角,收款/转账存入
            // 零钱的详情页此前进不了粗筛)
            "已收款", "收款成功", "已收钱", "已存入零钱"
        )

        /**
         * 弱锚点:字段名/按钮级短语,需 ≥2 个不同词同时命中才放行 —— 单个
         * 字段词+金额的订单确认/售后页不再通过粗筛。「返回商家」为微信支付
         * 结果页完成按钮的 contentDescription(GKD 微信支付规则同款锚点)。
         */
        private val WEAK_TRADE_KEYWORDS = listOf(
            "订单编号", "订单号", "交易单号", "转账单号", "商户单号",
            "商家订单", "交易流水", "实付款", "实付金额", "付款金额",
            "支付金额", "订单金额", "交易金额", "合计金额", "退款金额",
            "返回商家"
        )

        private val NON_BOOKABLE_KEYWORDS = listOf(
            "本期账单", "账单已出", "最低还款", "还款日", "待付款", "待支付",
            "待确认", "订单确认", "交易关闭", "支付失败", "交易失败",
            "支付未成功", "订单已关闭", "可用额度", "积分余额"
        )
        /** 金额写法:¥/￥ 前缀、x元、x块,以及**裸两位小数**(微信/京东账单详情
            的大字金额是「-529.00」式裸数字,无货币符号 —— 2026-09 真机走查漏记
            根因)。订单号/时间戳/手机号都不会带 .xx 小数尾,负 lookahead 再挡掉
            「1.234」这类截断串,误判风险低;后面仍有交易特征/列表页/不可入账
            状态三道闸兜底。 */
        private val AMOUNT_PATTERN = Regex(
            "[¥￥]\\s*\\d" +
                "|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*元" +
                "|\\d[\\d,]*(\\.[\\d]{1,2})?\\s*块" +
                "|\\d[\\d,]*\\.\\d{2}(?!\\d)"
        )

        private fun log(msg: String) {
            // vivo OriginOS 会过滤 Log.d(debug 级),用 Log.i 保证诊断日志可见
            Log.i(TAG, msg)
        }
    }
}
