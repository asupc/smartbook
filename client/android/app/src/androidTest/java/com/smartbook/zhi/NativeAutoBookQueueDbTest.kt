package com.smartbook.zhi

import android.content.Context
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * B3:统一队列的**原生集成测试** —— 覆盖 SQLite 事务、旧队列迁移、ACK 与
 * 过期清理(JVM 单测测不了这些,见 R01 的测试设施决定)。
 *
 * 运行:`cd client/android && ./gradlew :app:connectedDevDebugAndroidTest`
 */
@RunWith(AndroidJUnit4::class)
class NativeAutoBookQueueDbTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        NativeAutoBookQueue.clearAll(context)
        context.getSharedPreferences("legacy_sms_prefs", Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @After
    fun tearDown() {
        NativeAutoBookQueue.clearAll(context)
    }

    private fun smsItem(eventKey: String, fp: String = "fp-$eventKey"): JSONObject =
        JSONObject()
            .put("eventKey", eventKey)
            .put("fingerprint", fp)
            .put("sender", "10086")
            .put("body", "您尾号1234消费45.00元")
            .put("timestamp", 1_700_000_000_000L)

    @Test
    fun enqueuePeekAckRoundtrip() {
        val result = NativeAutoBookQueue.enqueue(context, "sms", smsItem("k1"))
        assertEquals(NativeAutoBookQueue.EnqueueResult.added, result)

        val peeked = NativeAutoBookQueue.peekBatch(context, "sms")
        assertEquals(1, peeked.size)
        assertEquals("k1", peeked[0].optString("eventKey"))
        // peek 不删除
        assertEquals(1, NativeAutoBookQueue.peekBatch(context, "sms").size)

        NativeAutoBookQueue.ack(context, "sms", listOf("k1"))
        assertTrue(NativeAutoBookQueue.peekBatch(context, "sms").isEmpty())
    }

    @Test
    fun duplicateEventKeyRejectedWithoutDuplicatingRow() {
        assertEquals(
            NativeAutoBookQueue.EnqueueResult.added,
            NativeAutoBookQueue.enqueue(context, "sms", smsItem("dup")),
        )
        assertEquals(
            NativeAutoBookQueue.EnqueueResult.duplicate,
            NativeAutoBookQueue.enqueue(context, "sms", smsItem("dup")),
        )
        assertEquals(1, NativeAutoBookQueue.stats(context, "sms").count)
    }

    @Test
    fun ackOnlyRemovesGivenIdentities() {
        NativeAutoBookQueue.enqueue(context, "sms", smsItem("a"))
        NativeAutoBookQueue.enqueue(context, "sms", smsItem("b"))
        NativeAutoBookQueue.ack(context, "sms", listOf("a"))
        val rest = NativeAutoBookQueue.peekBatch(context, "sms")
        assertEquals(1, rest.size)
        assertEquals("b", rest[0].optString("eventKey"))
    }

    @Test
    fun targetSnapshotFrozenIntoItemAndReadableOnPeek() {
        NativeAutoBookQueue.enqueue(
            context = context,
            source = "sms",
            item = smsItem("snap"),
            targetRef = "syncId:abc",
            targetVersion = 7,
            targetState = "resolved",
        )
        val peeked = NativeAutoBookQueue.peekBatch(context, "sms").first()
        val map = NativeAutoBookQueue.toMap(peeked)
        assertEquals("syncId:abc", map["targetRef"])
        assertEquals("7", map["targetVersion"])
        assertEquals("resolved", map["targetState"])
    }

    @Test
    fun migrationFromPrefsIsIdempotentAndKeepsLegacyQueue() {
        val prefs: SharedPreferences =
            context.getSharedPreferences("legacy_sms_prefs", Context.MODE_PRIVATE)
        val legacy = JSONArray()
            .put(JSONObject().put("eventKey", "old1").put("fingerprint", "f1"))
            .put(JSONObject().put("eventKey", "old2").put("fingerprint", "f2"))
            .toString()
        prefs.edit().putString("pending_queue", legacy).commit()

        val first = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_sms_prefs", "pending_queue",
        )
        assertTrue(first.completed)
        assertEquals(2, first.migrated)
        // 旧值不清空(计划 §4 B3 任务 8:失败可继续读旧队列,先保留备份)
        assertEquals(legacy, prefs.getString("pending_queue", null))
        assertEquals(legacy, prefs.getString(NativeAutoBookQueue.PREFS_BACKUP_KEY, null))
        assertEquals(2, NativeAutoBookQueue.stats(context, "sms").count)

        // 第二次执行:按事件键去重 → 0 条,不重复
        val second = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_sms_prefs", "pending_queue",
        )
        assertTrue(second.completed)
        assertEquals(0, second.migrated)
        assertEquals(2, NativeAutoBookQueue.stats(context, "sms").count)
    }

    @Test
    fun migrationToleratesCorruptLegacyQueue() {
        val prefs =
            context.getSharedPreferences("legacy_sms_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString("pending_queue", "{{{ not json").commit()
        val result = NativeAutoBookQueue.migrateFromPrefs(
            context, "sms", "legacy_sms_prefs", "pending_queue",
        )
        // 坏数据不写入,但迁移标记照常置位(旧值仍在,不阻塞读切换)。
        assertTrue(result.completed)
        assertEquals(0, result.migrated)
        assertEquals(0, NativeAutoBookQueue.stats(context, "sms").count)
    }

    @Test
    fun expiredMaterialPurgedWithLossSummary() {
        val staleNow = System.currentTimeMillis() - (NativeAutoBookQueue.MAX_AGE_MS + 60_000L)
        val result = NativeAutoBookQueue.enqueue(
            context = context,
            source = "sms",
            item = smsItem("stale"),
            nowMs = staleNow,
        )
        assertEquals(NativeAutoBookQueue.EnqueueResult.added, result)
        // 入队当下未过期(捕获时刻 + 72h),下一次访问时已过期 → 清理。
        assertTrue(NativeAutoBookQueue.peekBatch(context, "sms").isEmpty())
        assertEquals(0, NativeAutoBookQueue.stats(context, "sms").count)

        val losses = JSONArray(NativeAutoBookQueue.lossSummary(context))
        var sawExpiry = false
        for (i in 0 until losses.length()) {
            val entry = losses.getJSONObject(i)
            if (entry.optString("source") == "sms" &&
                entry.optString("kind") == "expired"
            ) {
                sawExpiry = true
                // 摘要只有计数,不含原文。
                assertFalse(entry.toString().contains("尾号"))
            }
        }
        assertTrue("应记录过期损失摘要", sawExpiry)
    }

    @Test
    fun sourcesAreIsolated() {
        NativeAutoBookQueue.enqueue(context, "sms", smsItem("only-sms"))
        assertTrue(NativeAutoBookQueue.peekBatch(context, "notification").isEmpty())
        assertTrue(NativeAutoBookQueue.peekBatch(context, "screenshot").isEmpty())
        assertEquals(1, NativeAutoBookQueue.stats(context, "sms").count)
        assertEquals(0, NativeAutoBookQueue.stats(context, "notification").count)
    }

    @Test
    fun batchLimitBoundsPeekSize() {
        for (i in 0 until 15) {
            NativeAutoBookQueue.enqueue(context, "notification", JSONObject()
                .put("fingerprint", "n$i")
                .put("package", "com.x")
                .put("title", "t$i")
                .put("body", "b$i")
                .put("timestamp", i.toLong()))
        }
        val batch = NativeAutoBookQueue.peekBatch(context, "notification", limit = 10)
        assertEquals("分批读取:单次只取一批", 10, batch.size)
        assertEquals(15, NativeAutoBookQueue.stats(context, "notification").count)
    }
}
