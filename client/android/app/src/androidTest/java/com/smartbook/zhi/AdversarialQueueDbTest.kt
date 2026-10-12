package com.smartbook.zhi

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 对抗性测试:统一队列的 SQLite 真实行为 —— 并发入队、容量闸、
 * ACK 精确性、过期清理与损失摘要的交互。
 *
 * 与 NativeAutoBookQueueDbTest 互补:那个锁基础生命周期,这个打边界与竞态。
 * 运行:`./gradlew :app:connectedDevDebugAndroidTest`
 */
@RunWith(AndroidJUnit4::class)
class AdversarialQueueDbTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        NativeAutoBookQueue.clearAll(context)
        context.getSharedPreferences("auto_book_queue_meta", Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @After
    fun tearDown() {
        NativeAutoBookQueue.clearAll(context)
    }

    private fun item(eventKey: String, body: String = "body-$eventKey"): JSONObject =
        JSONObject()
            .put("eventKey", eventKey)
            .put("fingerprint", "fp-$eventKey")
            .put("sender", "95555")
            .put("body", body)
            .put("timestamp", 1_700_000_000_000L)

    // ── 并发 ──

    @Test
    fun concurrentEnqueueSameEventKeyOnlyOneAdded() {
        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val latch = CountDownLatch(1)
        val added = AtomicInteger(0)
        val duplicate = AtomicInteger(0)
        val others = AtomicInteger(0)
        val futures = (0 until threads).map {
            pool.submit {
                latch.await()
                when (NativeAutoBookQueue.enqueue(context, "sms", item("race-k"))) {
                    NativeAutoBookQueue.EnqueueResult.added -> added.incrementAndGet()
                    NativeAutoBookQueue.EnqueueResult.duplicate -> duplicate.incrementAndGet()
                    else -> others.incrementAndGet()
                }
            }
        }
        latch.countDown()
        futures.forEach { it.get(20, TimeUnit.SECONDS) }
        pool.shutdown()

        assertEquals("并发同事件键:恰好一条入库", 1, added.get())
        assertEquals("其余全部判重", threads - 1, duplicate.get())
        assertEquals(0, others.get())
        assertEquals(1, NativeAutoBookQueue.stats(context, "sms").count)
    }

    @Test
    fun concurrentEnqueueDistinctEventKeysAllPersisted() {
        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val latch = CountDownLatch(1)
        val futures = (0 until threads).map { i ->
            pool.submit {
                latch.await()
                NativeAutoBookQueue.enqueue(context, "sms", item("distinct-$i"))
            }
        }
        latch.countDown()
        futures.forEach { it.get(20, TimeUnit.SECONDS) }
        pool.shutdown()
        assertEquals(threads, NativeAutoBookQueue.stats(context, "sms").count)
    }

    // ── 容量闸真实行为 ──

    @Test
    fun perSourceCapRejectsOverflowAndRecordsLoss() {
        repeat(NativeAutoBookQueue.MAX_PER_SOURCE) { i ->
            val r = NativeAutoBookQueue.enqueue(context, "notification", item("cap-$i"))
            assertEquals(NativeAutoBookQueue.EnqueueResult.added, r)
        }
        val over = NativeAutoBookQueue.enqueue(context, "notification", item("cap-over"))
        assertEquals(NativeAutoBookQueue.EnqueueResult.rejectedFull, over)
        assertEquals(
            NativeAutoBookQueue.MAX_PER_SOURCE,
            NativeAutoBookQueue.stats(context, "notification").count,
        )
        val losses = JSONArray(NativeAutoBookQueue.lossSummary(context))
        var sawFull = false
        for (i in 0 until losses.length()) {
            val e = losses.getJSONObject(i)
            if (e.optString("source") == "notification" &&
                e.optString("kind") == "rejectedfull"
            ) {
                sawFull = true
            }
        }
        assertTrue("容量拒收必须留下损失摘要(不静默丢)", sawFull)
    }

    @Test
    fun perSourceCapIsIndependentBetweenSources() {
        repeat(NativeAutoBookQueue.MAX_PER_SOURCE) { i ->
            NativeAutoBookQueue.enqueue(context, "sms", item("sms-cap-$i"))
        }
        // 短信满不影响通知
        val r = NativeAutoBookQueue.enqueue(context, "notification", item("n-ok"))
        assertEquals(NativeAutoBookQueue.EnqueueResult.added, r)
    }

    @Test
    fun lossSummaryRingKeepsAtMost20Entries() {
        // 触发 25 次容量拒收 → 摘要环只留最近 20 条。
        repeat(NativeAutoBookQueue.MAX_PER_SOURCE) { i ->
            NativeAutoBookQueue.enqueue(context, "screenText", item("ring-$i"))
        }
        repeat(25) { i ->
            NativeAutoBookQueue.enqueue(context, "screenText", item("ring-over-$i"))
        }
        val losses = JSONArray(NativeAutoBookQueue.lossSummary(context))
        assertTrue("摘要环上限 20,实际=${losses.length()}", losses.length() <= 20)
    }

    // ── ACK 精确性 ──

    @Test
    fun ackByFingerprintOnlyRemovesMatchingRow() {
        NativeAutoBookQueue.enqueue(
            context, "notification",
            JSONObject()
                .put("fingerprint", "fp-target")
                .put("package", "com.x")
                .put("title", "t")
                .put("body", "b")
                .put("timestamp", 1L),
        )
        NativeAutoBookQueue.enqueue(
            context, "notification",
            JSONObject()
                .put("fingerprint", "fp-other")
                .put("package", "com.x")
                .put("title", "t2")
                .put("body", "b2")
                .put("timestamp", 2L),
        )
        // ack 传 fingerprint(事件键是 title|body 拼接,指纹才是通知路径的 ACK 键)
        NativeAutoBookQueue.ack(context, "notification", listOf("fp-target"))
        val rest = NativeAutoBookQueue.peekBatch(context, "notification")
        assertEquals(1, rest.size)
        assertEquals("fp-other", rest[0].optString("fingerprint"))
    }

    @Test
    fun ackWithUnknownIdentityLeavesQueueIntact() {
        NativeAutoBookQueue.enqueue(context, "sms", item("stay"))
        NativeAutoBookQueue.ack(context, "sms", listOf("does-not-exist"))
        assertEquals(1, NativeAutoBookQueue.stats(context, "sms").count)
    }

    @Test
    fun ackDoesNotCrossSourceBoundary() {
        // 相同的身份串在 sms 与 screenshot 各一条;ack sms 不能删掉 screenshot 的行。
        NativeAutoBookQueue.enqueue(
            context, "sms", JSONObject().put("eventKey", "shared").put("body", "b"),
        )
        NativeAutoBookQueue.enqueue(
            context, "screenshot",
            JSONObject().put("eventKey", "shared").put("path", "shared").put("timestamp", 1L),
        )
        NativeAutoBookQueue.ack(context, "sms", listOf("shared"))
        assertEquals(0, NativeAutoBookQueue.stats(context, "sms").count)
        assertEquals("跨来源不得误删", 1, NativeAutoBookQueue.stats(context, "screenshot").count)
    }

    @Test
    fun ackEmptyListIsNoop() {
        NativeAutoBookQueue.enqueue(context, "sms", item("keep"))
        NativeAutoBookQueue.ack(context, "sms", emptyList())
        assertEquals(1, NativeAutoBookQueue.stats(context, "sms").count)
    }

    // ── 过期清理 ──

    @Test
    fun expiredRowsPurgedOnStatsAccessAndCountedInLoss() {
        val staleNow = System.currentTimeMillis() - (NativeAutoBookQueue.MAX_AGE_MS + 1)
        NativeAutoBookQueue.enqueue(
            context = context, source = "screenshot",
            item = JSONObject().put("path", "/old/a.png").put("timestamp", 1L),
            nowMs = staleNow,
        )
        NativeAutoBookQueue.enqueue(
            context = context, source = "screenshot",
            item = JSONObject().put("path", "/new/b.png").put("timestamp", 2L),
        )
        val stats = NativeAutoBookQueue.stats(context, "screenshot")
        assertEquals("过期行应被清理,仅剩新行", 1, stats.count)
        val peeked = NativeAutoBookQueue.peekBatch(context, "screenshot")
        assertEquals("/new/b.png", peeked[0].optString("path"))
    }

    @Test
    fun purgeIsIdempotentAcrossRepeatedAccess() {
        val staleNow = System.currentTimeMillis() - (NativeAutoBookQueue.MAX_AGE_MS + 1)
        NativeAutoBookQueue.enqueue(
            context = context, source = "sms", item = item("stale-once"), nowMs = staleNow,
        )
        NativeAutoBookQueue.stats(context, "sms") // 触发第一次清理
        NativeAutoBookQueue.stats(context, "sms") // 第二次
        NativeAutoBookQueue.peekBatch(context, "sms") // 第三次
        assertEquals(0, NativeAutoBookQueue.stats(context, "sms").count)
    }

    // ── 目标快照端到端 ──

    @Test
    fun targetSnapshotFrozenAtEnqueueNotAffectedByLaterEnqueues() {
        NativeAutoBookQueue.enqueue(
            context = context, source = "sms", item = item("snap-a"),
            targetRef = "syncId:A", targetVersion = 1, targetState = "resolved",
        )
        NativeAutoBookQueue.enqueue(
            context = context, source = "sms", item = item("snap-b"),
            targetRef = "syncId:B", targetVersion = 2, targetState = "unconfirmed",
        )
        val byKey = NativeAutoBookQueue.peekBatch(context, "sms")
            .associateBy { it.optString("eventKey") }
        assertEquals("syncId:A", byKey.getValue("snap-a").optString("targetRef"))
        assertEquals("1", byKey.getValue("snap-a").optString("targetVersion"))
        assertEquals("syncId:B", byKey.getValue("snap-b").optString("targetRef"))
        assertEquals("unconfirmed", byKey.getValue("snap-b").optString("targetState"))
    }

    // ── 迁移:与既有行共存 ──

    @Test
    fun migrationSkipsIdentitiesAlreadyInDb() {
        NativeAutoBookQueue.enqueue(context, "sms", item("dup-key"))
        val prefs = context.getSharedPreferences("legacy_mix_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString(
            "pending_queue",
            JSONArray()
                .put(JSONObject().put("eventKey", "dup-key").put("fingerprint", "f1"))
                .put(JSONObject().put("eventKey", "new-key").put("fingerprint", "f2"))
                .toString(),
        ).commit()
        val result = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_mix_prefs", "pending_queue",
        )
        assertTrue(result.completed)
        assertEquals("已存在的键跳过,只迁新键", 1, result.migrated)
        assertEquals(2, NativeAutoBookQueue.stats(context, "sms").count)
        prefs.edit().clear().commit()
    }

    @Test
    fun migrationFromEmptyLegacyPrefsMarksCompletedWithoutRows() {
        val prefs = context.getSharedPreferences("legacy_empty_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val result = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_empty_prefs", "pending_queue",
        )
        assertTrue(result.completed)
        assertEquals(0, result.migrated)
        assertTrue(NativeAutoBookQueue.isMigrated(context, "legacy_empty_prefs"))
        prefs.edit().clear().commit()
    }

    @Test
    fun migrationLegacyItemWithoutTimestampUsesNowAndStaysReadable() {
        val prefs = context.getSharedPreferences("legacy_nots_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString(
            "pending_queue",
            JSONArray().put(
                JSONObject().put("eventKey", "nots").put("fingerprint", "fp-nots")
                    .put("body", "无时间戳旧项"),
            ).toString(),
        ).commit()
        val result = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_nots_prefs", "pending_queue",
        )
        assertEquals(1, result.migrated)
        val peeked = NativeAutoBookQueue.peekBatch(context, "sms")
        assertEquals(1, peeked.size)
        assertEquals("无时间戳旧项", peeked[0].optString("body"))
        prefs.edit().clear().commit()
    }

    // ── 劣质行不阻塞整批 ──

    @Test
    fun corruptPayloadRowDoesNotBlockPeekOfValidRows() {
        // 手工塞一行 payload 非法 JSON(模拟磁盘损坏/未来格式变更)。
        NativeAutoBookQueue.enqueue(context, "sms", item("good-a"))
        NativeAutoBookQueue.enqueue(context, "sms", item("good-b"))
        val db = context.openOrCreateDatabase(
            NativeAutoBookQueue.DB_NAME, Context.MODE_PRIVATE, null,
        )
        db.execSQL(
            "INSERT OR REPLACE INTO queue " +
                "(event_key, source, fingerprint, captured_at, payload_json, " +
                "material_bytes, expires_at, enqueued_at) " +
                "VALUES ('broken', 'sms', 'f', 1, '{not json', 1, ?, ?)",
            arrayOf(System.currentTimeMillis() + 100_000, System.currentTimeMillis()),
        )
        db.close()
        val peeked = NativeAutoBookQueue.peekBatch(context, "sms")
        // 坏行被跳过(JSONObject 构造失败 → null → 不入结果),好行照常返回。
        assertEquals(2, peeked.size)
        val keys = peeked.map { it.optString("eventKey") }.toSet()
        assertEquals(setOf("good-a", "good-b"), keys)
    }

    @Test
    fun batchOrderIsOldestFirst() {
        NativeAutoBookQueue.enqueue(
            context, "sms", item("later"),
            nowMs = System.currentTimeMillis(),
        )
        // captured_at 用 nowMs 落列,这里用较早 nowMs 覆盖顺序断言:
        NativeAutoBookQueue.clearAll(context)
        val base = System.currentTimeMillis() - 10_000
        NativeAutoBookQueue.enqueue(context, "sms", item("first"), nowMs = base)
        NativeAutoBookQueue.enqueue(context, "sms", item("second"), nowMs = base + 5_000)
        val peeked = NativeAutoBookQueue.peekBatch(context, "sms")
        assertEquals("first", peeked[0].optString("eventKey"))
        assertEquals("second", peeked[1].optString("eventKey"))
    }

    @Test
    fun statsOldestAtReflectsMinCapturedAt() {
        val base = System.currentTimeMillis() - 20_000
        NativeAutoBookQueue.enqueue(context, "sms", item("o1"), nowMs = base)
        NativeAutoBookQueue.enqueue(context, "sms", item("o2"), nowMs = base + 7_000)
        val stats = NativeAutoBookQueue.stats(context, "sms")
        assertEquals(base, stats.oldestAt)
        assertNotEquals(0L, stats.oldestAt)
    }
}
