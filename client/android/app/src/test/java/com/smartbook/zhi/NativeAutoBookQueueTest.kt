package com.smartbook.zhi

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * B3:统一队列的**纯逻辑**测试(JVM 可跑,不依赖 Android 运行时)。
 *
 * 依赖 SQLite 的部分(入队事务、迁移中断、并发 ACK、崩溃重放)属于
 * instrumentation 测试,见 R01 决定:`app/src/androidTest/…/NativeAutoBookQueueTest`。
 */
class NativeAutoBookQueueTest {

    private fun item(vararg pairs: Pair<String, Any?>): JSONObject {
        val json = JSONObject()
        for ((k, v) in pairs) json.put(k, v ?: org.json.JSONObject.NULL)
        return json
    }

    // ── 事件键:保持各路既有身份口径,不把同金额同商家当同一事件 ──

    @Test
    fun identityOfSmsPrefersEventKey() {
        val json = item("eventKey" to "abc", "fingerprint" to "fp", "sender" to "10086")
        assertEquals("abc", NativeAutoBookQueue.identityOf("sms", json))
    }

    @Test
    fun identityOfSmsFallsBackToFingerprint() {
        val json = item("eventKey" to "", "fingerprint" to "fp1")
        assertEquals("fp1", NativeAutoBookQueue.identityOf("sms", json))
    }

    @Test
    fun identityOfNotificationUsesFingerprint() {
        val json = item("fingerprint" to "nfp", "title" to "支付成功")
        assertEquals("nfp", NativeAutoBookQueue.identityOf("notification", json))
    }

    @Test
    fun identityOfScreenshotUsesPath() {
        val json = item("path" to "/sdcard/Pictures/a.png", "timestamp" to 1L)
        assertEquals("/sdcard/Pictures/a.png",
            NativeAutoBookQueue.identityOf("screenshot", json))
    }

    @Test
    fun identityDiffersBetweenSourcesAndEvents() {
        val a = item("eventKey" to "k1", "fingerprint" to "f1")
        val b = item("eventKey" to "k2", "fingerprint" to "f2")
        assertFalse(
            NativeAutoBookQueue.identityOf("sms", a) ==
                NativeAutoBookQueue.identityOf("sms", b),
        )
    }

    // ── 容量/字节/有效期三道闸 ──

    @Test
    fun rejectReasonUnderLimitsAllowsEnqueue() {
        assertNull(
            NativeAutoBookQueue.rejectReason(
                currentCount = 10,
                currentBytes = 1024,
                incomingBytes = 64,
                nowMs = 1_000L,
                incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
            ),
        )
    }

    @Test
    fun rejectReasonFullQueueRejectsNew() {
        val result = NativeAutoBookQueue.rejectReason(
            currentCount = NativeAutoBookQueue.MAX_PER_SOURCE,
            currentBytes = 10,
            incomingBytes = 10,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedFull, result)
    }

    @Test
    fun rejectReasonByteBudgetExhaustedRejectsNew() {
        val result = NativeAutoBookQueue.rejectReason(
            currentCount = 1,
            currentBytes = NativeAutoBookQueue.MAX_TOTAL_BYTES - 10,
            incomingBytes = 64,
            nowMs = 1_000L,
            incomingExpiresAt = 1_000L + NativeAutoBookQueue.MAX_AGE_MS,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedBytes, result)
    }

    @Test
    fun nearCapacityThresholdMatchesNinetyPercent() {
        assertFalse(NativeAutoBookQueue.isNearCapacity(
            NativeAutoBookQueue.NEAR_CAPACITY - 1))
        assertTrue(NativeAutoBookQueue.isNearCapacity(
            NativeAutoBookQueue.NEAR_CAPACITY))
        assertEquals(
            (NativeAutoBookQueue.MAX_PER_SOURCE * 9) / 10,
            NativeAutoBookQueue.NEAR_CAPACITY,
        )
    }

    @Test
    fun expiryUsesSeventyTwoHours() {
        val now = 10_000L
        val expiresAt = now + NativeAutoBookQueue.MAX_AGE_MS
        assertFalse(NativeAutoBookQueue.isExpired(expiresAt, now))
        assertFalse(NativeAutoBookQueue.isExpired(expiresAt, expiresAt - 1))
        assertTrue(NativeAutoBookQueue.isExpired(expiresAt, expiresAt))
        assertTrue(NativeAutoBookQueue.isExpired(expiresAt, expiresAt + 1))
        // 未到期(将来时间)不当过期
        assertFalse(NativeAutoBookQueue.isExpired(now + 1, now))
    }

    @Test
    fun materialBytesGrowsWithPayload() {
        val small = NativeAutoBookQueue.materialBytesOf(item("a" to "1"))
        val large = NativeAutoBookQueue.materialBytesOf(item("body" to "x".repeat(500)))
        assertTrue(large > small)
        assertTrue(small > 0)
    }

    // ── 旧队列迁移:按事件键去重、幂等、坏数据不炸 ──

    @Test
    fun migrationSkipsExistingIdentities() {
        val legacy = """[{"eventKey":"k1","fingerprint":"f1"},{"eventKey":"k2","fingerprint":"f2"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(
            existingIdentities = setOf("k1"),
            legacyJson = legacy,
        )
        assertEquals(1, candidates.size)
        assertEquals("k2", candidates[0].optString("eventKey"))
    }

    @Test
    fun migrationIsIdempotent() {
        val legacy = """[{"eventKey":"k1"},{"eventKey":"k2"}]"""
        val first = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(2, first.size)
        // 第二次执行时已迁移项进入 existing → 0 条
        val second = NativeAutoBookQueue.migrationCandidates(
            first.map { NativeAutoBookQueue.identityOf("sms", it) }.toSet(),
            legacy,
        )
        assertTrue(second.isEmpty())
    }

    @Test
    fun migrationDedupsInsideLegacyQueueToo() {
        val legacy = """[{"eventKey":"k1"},{"eventKey":"k1"},{"eventKey":"k2"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(2, candidates.size)
    }

    @Test
    fun migrationToleratesCorruptLegacyJson() {
        assertTrue(NativeAutoBookQueue.migrationCandidates(emptySet(), null).isEmpty())
        assertTrue(NativeAutoBookQueue.migrationCandidates(emptySet(), "").isEmpty())
        assertTrue(
            NativeAutoBookQueue.migrationCandidates(emptySet(), "not a json").isEmpty(),
        )
    }

    @Test
    fun migrationFallsBackToIdentityForItemsWithoutEventKey() {
        val legacy = """[{"fingerprint":"fpA"},{"path":"/a/b.png"}]"""
        val candidates = NativeAutoBookQueue.migrationCandidates(emptySet(), legacy)
        assertEquals(2, candidates.size)
        assertEquals(
            "fpA",
            NativeAutoBookQueue.identityOf("notification", candidates[0]),
        )
    }

    // ── 损失摘要:只有计数与来源,不含原文 ──

    @Test
    fun lossSummaryContainsNoRawContent() {
        val text = NativeAutoBookQueue.lossSummary("sms", "rejectedfull", 3, 42L)
        val json = JSONObject(text)
        assertEquals("sms", json.getString("source"))
        assertEquals(3, json.getInt("count"))
        assertEquals(42L, json.getLong("at"))
        assertFalse(text.contains("body"))
    }
}
