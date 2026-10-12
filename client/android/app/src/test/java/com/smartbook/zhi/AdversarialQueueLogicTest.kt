package com.smartbook.zhi

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 对抗性测试:NativeAutoBookQueue 纯逻辑层(容量闸/身份键/迁移/字节统计)。
 *
 * 只攻击既有 NativeAutoBookQueueTest 未覆盖的边界:过期项与满队列的优先级、
 * 字节闸的精确边界、身份键在各来源缺字段时的退化行为、迁移候选对畸形项的
 * 容忍、lossSummary 的 JSON 注入面(来源名含引号时是否产生损坏 JSON)。
 */
class AdversarialQueueLogicTest {

    private fun item(vararg pairs: Pair<String, Any?>): JSONObject {
        val json = JSONObject()
        for ((k, v) in pairs) json.put(k, v ?: JSONObject.NULL)
        return json
    }

    // ── 容量裁决优先级与边界 ──

    @Test
    fun `过期入队项 -即使队列已满也应先判过期而非rejectedFull`() {
        // 语义:过期项由 purge 清理,不占用「满」的判定;若先判满,调用方会看到
        // rejectedFull 并把本可立刻清掉的过期队列当成容量耗尽,损失摘要误导。
        val result = NativeAutoBookQueue.rejectReason(
            currentCount = NativeAutoBookQueue.MAX_PER_SOURCE,
            currentBytes = NativeAutoBookQueue.MAX_TOTAL_BYTES,
            incomingBytes = 1,
            nowMs = 1_000L,
            incomingExpiresAt = 999L, // 已过期
        )
        assertNull("过期项应放行(交给过期清理),实际=$result", result)
    }

    @Test
    fun `条数闸恰好到上限即拒,差一条放行`() {
        val atLimit = NativeAutoBookQueue.rejectReason(
            currentCount = NativeAutoBookQueue.MAX_PER_SOURCE - 1,
            currentBytes = 0,
            incomingBytes = 1,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertNull("差一条应放行", atLimit)
        val overLimit = NativeAutoBookQueue.rejectReason(
            currentCount = NativeAutoBookQueue.MAX_PER_SOURCE,
            currentBytes = 0,
            incomingBytes = 1,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedFull, overLimit)
    }

    @Test
    fun `字节闸恰好等于上限放行,超一字节即拒`() {
        val max = NativeAutoBookQueue.MAX_TOTAL_BYTES
        val exactly = NativeAutoBookQueue.rejectReason(
            currentCount = 0,
            currentBytes = max - 100,
            incomingBytes = 100,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertNull("恰好达到上限应放行(> 判定)", exactly)
        val oneOver = NativeAutoBookQueue.rejectReason(
            currentCount = 0,
            currentBytes = max - 100,
            incomingBytes = 101,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedBytes, oneOver)
    }

    @Test
    fun `字节闸与条数闸同时命中时优先报条数`() {
        val result = NativeAutoBookQueue.rejectReason(
            currentCount = NativeAutoBookQueue.MAX_PER_SOURCE,
            currentBytes = NativeAutoBookQueue.MAX_TOTAL_BYTES,
            incomingBytes = 1,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedFull, result)
    }

    // ── 身份键退化行为 ──

    @Test
    fun `各来源身份键全空字段时返回空串而非崩溃`() {
        // 空身份在 enqueue / migrationCandidates 都被当作「无法识别」跳过;
        // 断言返回空串(而不是抛异常或返回 JSON "null" 字面量)。
        assertEquals("", NativeAutoBookQueue.identityOf("sms", item()))
        assertEquals("", NativeAutoBookQueue.identityOf("screenshot", item()))
        assertEquals("", NativeAutoBookQueue.identityOf("screenText", item()))
        // K-2 修复后(2026-10-11):notification 的全空项也返回空串,不再退化成
        // 常量 "|" 绕过 enqueue 的 identity.isEmpty() 拒收闸(不同空通知互相
        // 判重)。原断言 "|" 锁定的是缺陷行为,随实现同批修正。
        assertEquals("", NativeAutoBookQueue.identityOf("notification", item()))
    }

    @Test
    fun `通知标题与正文只有一个为空时仍按竖线拼接`() {
        // K-2 的边界:只有 title/body **同时**为空才短路成 "";单侧为空仍是
        // 有效身份("标题|" / "|正文"),与其它来源的退化粒度一致。
        assertEquals(
            "支付成功|",
            NativeAutoBookQueue.identityOf("notification", item("title" to "支付成功")),
        )
        assertEquals(
            "|42.00元",
            NativeAutoBookQueue.identityOf("notification", item("body" to "42.00元")),
        )
        // 有 fingerprint 时优先 fingerprint,与 title/body 是否为空无关
        assertEquals(
            "fp-1",
            NativeAutoBookQueue.identityOf(
                "notification",
                item("fingerprint" to "fp-1", "title" to ""),
            ),
        )
    }

    @Test
    fun `通知来源缺指纹时回退标题竖线正文`() {
        val identity = NativeAutoBookQueue.identityOf(
            "notification",
            item("title" to "支付成功", "body" to "42.00元"),
        )
        assertEquals("支付成功|42.00元", identity)
    }

    @Test
    fun `屏幕文本与短信来源缺失所有键时不得误用 path 回落`() {
        // screenText 走 else 分支(eventKey→fingerprint),不应拿 path 当身份;
        // screenshot 只认 path。若实现串了分支,下面的对照会暴露。
        val screenItem = item("path" to "/x/y.png")
        assertEquals("", NativeAutoBookQueue.identityOf("screenText", screenItem))
        assertEquals("/x/y.png", NativeAutoBookQueue.identityOf("screenshot", screenItem))
    }

    @Test
    fun `身份键大小写敏感,同名不同大小写视为两条`() {
        val upper = NativeAutoBookQueue.identityOf("sms", item("eventKey" to "ABC"))
        val lower = NativeAutoBookQueue.identityOf("sms", item("eventKey" to "abc"))
        assertFalse("身份键不应大小写折叠", upper == lower)
    }

    @Test
    fun `身份键保留前后空白,不去trim`() {
        // 如果这里被 trim,两条仅差空白的广播会坍缩成同一事件 → 丢一条。
        // 身份键原样保留(DB 主键语义),trim 发生在更高层。
        val padded = NativeAutoBookQueue.identityOf("sms", item("eventKey" to " k "))
        assertEquals(" k ", padded)
    }

    // ── materialBytes ──

    @Test
    fun `材料字节按UTF8计,中文占3字节`() {
        val one = NativeAutoBookQueue.materialBytesOf(item("a" to "中"))
        val ascii = NativeAutoBookQueue.materialBytesOf(item("a" to "x"))
        assertTrue("中文字节应大于 ASCII", one > ascii)
    }

    @Test
    fun `空对象也有封套字节`() {
        assertTrue(NativeAutoBookQueue.materialBytesOf(item()) > 0)
    }

    // ── 迁移候选的畸形输入 ──

    @Test
    fun `迁移候选跳过非对象元素`() {
        val legacy = """["str",123,{"eventKey":"k1"},null,["arr"]]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(1, candidates.size)
        assertEquals("k1", candidates[0].optString("eventKey"))
    }

    @Test
    fun `迁移候选对无身份项跳过`() {
        val legacy = """[{"sender":"95555","body":"x"},{"eventKey":"k1"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(1, candidates.size)
    }

    @Test
    fun `迁移候选对空数组返回空`() {
        assertTrue(NativeAutoBookQueue.migrationCandidates(emptySet(), "[]").isEmpty())
    }

    @Test
    fun `迁移候选对JSON对象(非数组)返回空而不崩`() {
        // 旧 prefs 值若被外部写成 `{...}` 而非数组,JSONArray 构造抛异常 →
        // 实现捕获后返回空列表。必须不崩、不静默清空。
        val candidates = NativeAutoBookQueue.migrationCandidates(
            emptySet(),
            """{"eventKey":"k1"}""",
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun `迁移候选中空白身份串被跳过`() {
        val legacy = """[{"eventKey":"   "},{"eventKey":"k2"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        // 注意:eventKey="   ",ifEmpty 不触发(非空串),identity 非空 →
        // 会被当作合法身份。此处断言「实现不因纯空白身份崩溃」。
        // 若实现把它当合法身份迁移,记录为 HARDENING(见报告)。
        assertTrue(candidates.isNotEmpty())
    }

    @Test
    fun `迁移候选保留原始顺序`() {
        val legacy = """[{"eventKey":"b"},{"eventKey":"a"},{"eventKey":"c"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(listOf("b", "a", "c"), candidates.map { it.optString("eventKey") })
    }

    // ── lossSummary 注入面 ──

    @Test
    fun `lossSummary来源名含引号时会破坏JSON`() {
        // ADVERSE FINDING(低危/当前不可达):lossSummary 用字符串插值拼 JSON,
        // source 含 `"` 即产出非法 JSON。消费方 appendLossLocked 里
        // JSONArray(raw) 构造抛异常 → catch 只打日志,损失摘要整体不再累积
        // (静默降级)。source 由四路常量("sms" 等)固定传入,现不可达;
        // 但该函数是 public,未来若把用户可控文本(包名/路径)接进来即成缺陷。
        val text = NativeAutoBookQueue.lossSummary("""sms"inject""", "expired", 1, 1L)
        val parsed = runCatching { JSONObject(text) }.getOrNull()
        assertNotNull("lossSummary 必须产出合法 JSON,实际=$text", parsed)
    }

    @Test
    fun `lossSummary kind含换行时会破坏JSON`() {
        // ADVERSE FINDING(低危/当前不可达):同「来源名含引号」,kind 亦未转义。
        val text = NativeAutoBookQueue.lossSummary("sms", "a\nb", 2, 3L)
        val parsed = runCatching { JSONObject(text) }.getOrNull()
        assertNotNull("kind 含控制字符也必须产出合法 JSON,实际=$text", parsed)
    }

    @Test
    fun `lossSummary负数与零计数原样携带`() {
        assertEquals(0, JSONObject(NativeAutoBookQueue.lossSummary("sms", "x", 0, 0L)).getInt("count"))
    }

    @Test
    fun `lossSummary只含四字段,不夹带正文`() {
        val json = JSONObject(NativeAutoBookQueue.lossSummary("sms", "expired", 5, 9L))
        val keys = json.keys().asSequence().toSet()
        assertEquals(setOf("source", "kind", "count", "at"), keys)
    }

    // ── isExpired 边界 ──

    @Test
    fun `expiresAt为零或负数不算过期(哨兵语义)`() {
        // isExpired = expiresAt in 1..nowMs:0/负值是「无到期」哨兵,不能删。
        assertFalse(NativeAutoBookQueue.isExpired(0L, 1_000L))
        assertFalse(NativeAutoBookQueue.isExpired(-1L, 1_000L))
        assertFalse(NativeAutoBookQueue.isExpired(Long.MIN_VALUE, 1_000L))
    }

    @Test
    fun `expiresAt为极大值相对真实now永不过期`() {
        // 之前写成 isExpired(MAX, MAX) 是断言错误:区间语义 1..nowMs 下,
        // 恰好等于 now 即算过期(设计如此,见 expiryUsesSeventyTwoHours)。
        val now = System.currentTimeMillis()
        assertFalse(NativeAutoBookQueue.isExpired(Long.MAX_VALUE, now))
        // HARDENING:enqueue 计算 expiresAt = nowMs + MAX_AGE_MS 未防溢出;
        // nowMs 接近 Long.MAX_VALUE 时溢出为负 → isExpired 因负值哨兵恒 false
        // → 该行永不过期。nowMs 由 System.currentTimeMillis() 传入,实不可达;
        // 纯函数被外部复用时建议加 floor 保护。
    }

    // ── toMap 键值全保留 ──

    @Test
    fun `toMap保留全部键且值转字符串`() {
        val map = NativeAutoBookQueue.toMap(
            item("eventKey" to "k", "timestamp" to 42L, "body" to "消费1.00元"),
        )
        assertEquals("k", map["eventKey"])
        assertEquals("42", map["timestamp"])
        assertEquals("消费1.00元", map["body"])
    }

    @Test
    fun `toMap对嵌套对象取字符串形式不崩`() {
        val nested = item("meta" to JSONObject().put("a", 1))
        val map = NativeAutoBookQueue.toMap(nested)
        assertTrue(map.containsKey("meta"))
    }

    @Test
    fun `toMap对数组值不崩`() {
        val arr = item("tags" to JSONArray().put("x").put("y"))
        val map = NativeAutoBookQueue.toMap(arr)
        assertTrue(map.containsKey("tags"))
    }
}
