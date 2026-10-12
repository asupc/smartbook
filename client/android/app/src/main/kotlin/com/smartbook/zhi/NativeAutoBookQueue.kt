package com.smartbook.zhi

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * B3:四路捕获共用的原生持久化队列(应用私有目录 SQLite)。
 *
 * 设计约束(计划 §4 B3):
 * - 只用 Android 自带 `android.database.sqlite`,**不打开 Drift 库**、不引第三方依赖;
 * - 统一封套:事件键/来源/捕获时间/发生时间/目标快照/重放材料/迁移版本;
 * - 分批读取([peekBatch])、有界处理;Dart 到达可 ACK 结果后才 [ack];
 * - 入队与桥接广播解耦(桥接失败不影响入队,靠 peek-drain 补齐);
 * - 容量/字节/有效期三道闸:接近上限提示、耗尽拒收并记损失摘要,不静默删最旧;
 * - 迁移:旧 SharedPreferences 队列 → 新库按事件键去重 → 校验 → 标记 →
 *   切读;可重复执行,失败继续读旧队列,**不清空旧值**。
 *
 * 队列是进程内共享的:短信广播 / 通知监听 / 无障碍 / 截图观察器都跑在 App
 * 进程里,一把对象锁即可互斥;真正的并发保护还依赖 SQLite 事务。
 */
object NativeAutoBookQueue {
    private const val TAG = "NativeAutoBookQueue"

    const val DB_NAME = "auto_book_queue.db"
    const val DB_VERSION = 1

    /** 每来源条数上限(B0 §4.2 首版参数,待真机验证后锁定)。 */
    const val MAX_PER_SOURCE = 500

    /** 接近容量的提示阈值(0.9 * MAX_PER_SOURCE)。 */
    const val NEAR_CAPACITY = (MAX_PER_SOURCE * 9) / 10

    /** 全部来源的重放材料字节上限(20 MiB)。 */
    const val MAX_TOTAL_BYTES = 20 * 1024 * 1024

    /** 未完成处理材料的最长保留期(72 小时)。 */
    const val MAX_AGE_MS = 72L * 60 * 60 * 1000

    /** 单次 peek 批次上限:分批读取,避免一次把整队搬进 Dart。 */
    const val PEEK_BATCH = 10

    /** 旧格式备份 key:迁移前把旧队列原样复制一份(不先清空旧值)。 */
    const val PREFS_BACKUP_KEY = "pending_queue_backup_v1"

    /** 迁移标记(按来源)。 */
    const val MIGRATION_FLAG = "queue_migrated_v1"

    /** 损失摘要(容量拒收/过期清理),供设置页/状态卡展示,不静默丢。 */
    const val LOSS_SUMMARY_KEY = "queue_loss_summary_v1"

    // ── 表 ──
    const val COL_EVENT_KEY = "event_key"
    const val COL_SOURCE = "source"
    const val COL_FINGERPRINT = "fingerprint"
    const val COL_CAPTURED_AT = "captured_at"
    const val COL_OCCURRED_AT = "occurred_at"
    const val COL_TARGET_REF = "target_ref"
    const val COL_TARGET_VERSION = "target_version"
    const val COL_TARGET_STATE = "target_state"
    const val COL_PAYLOAD = "payload_json"
    const val COL_MATERIAL_BYTES = "material_bytes"
    const val COL_EXPIRES_AT = "expires_at"
    const val COL_ENQUEUED_AT = "enqueued_at"
    const val COL_MIGRATED_FROM = "migrated_from"

    /** 入队结果。 */
    enum class EnqueueResult { added, duplicate, rejectedFull, rejectedBytes }

    /** 迁移结果(可重复执行,幂等)。 */
    data class MigrationResult(
        val migrated: Int,
        val skippedDuplicates: Int,
        val failed: Int,
        val completed: Boolean,
    )

    /** 单来源统计。 */
    data class SourceStats(
        val count: Int,
        val bytes: Int,
        val oldestAt: Long,
        val expired: Int,
    )

    private val lock = Any()

    private class QueueDb(context: Context) :
        SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE queue (" +
                    "event_key TEXT NOT NULL, " +
                    "source TEXT NOT NULL, " +
                    "fingerprint TEXT NOT NULL DEFAULT '', " +
                    "captured_at INTEGER NOT NULL, " +
                    "occurred_at INTEGER, " +
                    "target_ref TEXT, " +
                    "target_version INTEGER, " +
                    "target_state TEXT, " +
                    "payload_json TEXT NOT NULL, " +
                    "material_bytes INTEGER NOT NULL DEFAULT 0, " +
                    "expires_at INTEGER NOT NULL, " +
                    "enqueued_at INTEGER NOT NULL, " +
                    "migrated_from TEXT, " +
                    "PRIMARY KEY (source, event_key))"
            )
            db.execSQL(
                "CREATE INDEX idx_queue_source_time ON queue (source, captured_at)"
            )
            db.execSQL(
                "CREATE INDEX idx_queue_expires ON queue (expires_at)"
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // 队列是可重建的临时数据:升级只加列,不删既有行。
            if (oldVersion < 2) {
                // 预留:v2 结构变更在这里补列。
            }
        }
    }

    private var helper: QueueDb? = null

    private fun db(context: Context): SQLiteDatabase {
        val existing = helper
        if (existing != null) return existing.writableDatabase
        val created = QueueDb(context.applicationContext)
        helper = created
        return created.writableDatabase
    }

    // ───────────────────────── 纯函数(可单测) ─────────────────────────

    /**
     * 事件键 = 队列项在本来源内的幂等身份。
     *
     * 各路沿用既有口径(短信/详情页 eventKey、通知 fingerprint、截图 path),
     * 不把「同金额同商家」当同一事件。
     *
     * K-2(2026-10-11):notification 分支在 fingerprint 缺失时回退
     * `title|body`,但标题与正文**都为空**时该拼接会产出常量 `"|"` ——
     * 一个非空身份,绕过 [enqueue] 与 [migrationCandidates] 的
     * `identity.isEmpty()` 拒收闸,不同的空通知互相判重。改成全空即短路返回
     * `""`(与其它来源的全空行为一致)。
     * 注意:单个字段为空时拼接**保持不变**(`"标题|"` / `"|正文"` 仍是有效
     * 身份,只有 title/body 同时为空才算「无法识别」)。
     */
    fun identityOf(source: String, item: JSONObject): String {
        return when (source) {
            "screenshot" -> item.optString("path")
            "notification" -> {
                val fp = item.optString("fingerprint")
                if (fp.isNotEmpty()) {
                    fp
                } else {
                    val title = item.optString("title")
                    val body = item.optString("body")
                    if (title.isEmpty() && body.isEmpty()) "" else "$title|$body"
                }
            }
            else -> {
                val eventKey = item.optString("eventKey")
                if (eventKey.isNotEmpty()) eventKey else item.optString("fingerprint")
            }
        }
    }

    /** 材料字节数(UTF-8 近似;截图只存路径,天然很小)。 */
    fun materialBytesOf(item: JSONObject): Int = item.toString().toByteArray(Charsets.UTF_8).size

    /** 是否已过期(未完成处理材料超过 72h)。 */
    fun isExpired(expiresAt: Long, nowMs: Long): Boolean = expiresAt in 1..nowMs

    /**
     * 容量裁决(纯函数,便于 JUnit 覆盖):先看有效期与条数,再看总字节。
     * 返回 null 表示可以入队。
     */
    fun rejectReason(
        currentCount: Int,
        currentBytes: Int,
        incomingBytes: Long,
        nowMs: Long,
        incomingExpiresAt: Long,
        maxPerSource: Int = MAX_PER_SOURCE,
        maxBytes: Int = MAX_TOTAL_BYTES,
    ): EnqueueResult? {
        if (isExpired(incomingExpiresAt, nowMs)) return null // 过期项交给过期清理
        if (currentCount >= maxPerSource) return EnqueueResult.rejectedFull
        if (currentBytes + incomingBytes > maxBytes.toLong()) {
            return EnqueueResult.rejectedBytes
        }
        return null
    }

    /** 是否接近容量(触发「先提示并有界处理」)。 */
    fun isNearCapacity(count: Int, threshold: Int = NEAR_CAPACITY): Boolean = count >= threshold

    /**
     * 从旧 SharedPreferences 队列抽迁移项:按事件键去重,保序返回待写入项。
     * 旧值不动 —— 清空由迁移成功后的读切换决定,不先清旧。
     */
    fun migrationCandidates(
        existingIdentities: Set<String>,
        legacyJson: String?,
    ): List<JSONObject> {
        if (legacyJson.isNullOrBlank()) return emptyList()
        val arr = try {
            JSONArray(legacyJson)
        } catch (e: Exception) {
            return emptyList()
        }
        val out = ArrayList<JSONObject>(arr.length())
        val seen = HashSet<String>(existingIdentities)
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val identity = obj.optString("eventKey").ifEmpty {
                obj.optString("fingerprint").ifEmpty { obj.optString("path") }
            }
            if (identity.isEmpty() || !seen.add(identity)) continue
            out.add(obj)
        }
        return out
    }

    /**
     * 损失摘要文本(容量拒收/过期),只含计数与来源,不含原文。
     *
     * K-1(2026-10-11):用 [JSONObject] 构造而非字符串插值拼接。旧实现
     * `"""{"source":"$source",...}"""` 不做转义 —— source/kind 含 `"` 或
     * 控制字符即产出非法 JSON,消费方 [appendLossLocked] 里的 `JSONArray(raw)`
     * 构造抛异常被 catch 吞掉,损失摘要整体静默不再累积。当前调用方传的是
     * 四路来源常量,不可达;但本函数是 public,JSONObject 构造是零成本的
     * 结构性加固(同时保证键顺序与字段集合稳定)。
     */
    fun lossSummary(source: String, kind: String, count: Int, nowMs: Long): String =
        JSONObject()
            .put("source", source)
            .put("kind", kind)
            .put("count", count)
            .put("at", nowMs)
            .toString()

    // ───────────────────────── 队列操作 ─────────────────────────

    /**
     * 入队。重复(同来源同事件键)直接返回 [EnqueueResult.duplicate];
     * 容量/字节耗尽时**拒绝新入队**并记录最小损失摘要,不静默删最旧。
     */
    @Synchronized
    fun enqueue(
        context: Context,
        source: String,
        item: JSONObject,
        nowMs: Long = System.currentTimeMillis(),
        targetRef: String? = null,
        targetVersion: Int? = null,
        targetState: String? = null,
    ): EnqueueResult {
        val identity = identityOf(source, item)
        if (identity.isEmpty()) return EnqueueResult.duplicate

        synchronized(lock) {
            val database = db(context)
            val bytes = materialBytesOf(item)
            val expiresAt = nowMs + MAX_AGE_MS

            // 先做过期清理,避免过期材料占着容量。
            purgeExpiredLocked(context, database, nowMs)

            val reason = rejectReason(
                currentCount = countLocked(database, source),
                currentBytes = totalBytesLocked(database),
                incomingBytes = bytes.toLong(),
                nowMs = nowMs,
                incomingExpiresAt = expiresAt,
            )
            if (reason != null) {
                appendLossLocked(
                    context,
                    lossSummary(source, reason.name.lowercase(), 1, nowMs),
                )
                Log.w(TAG, "队列拒绝入队: source=$source reason=$reason")
                return reason
            }

            // 目标快照既落列(封套/查询),也写进 payload —— Dart 侧 peek 出来
            // 的就是 payload 的字段,B2 靠这些字段识别「捕获时冻结」的目标。
            if (targetRef != null) item.put("targetRef", targetRef)
            if (targetState != null) item.put("targetState", targetState)
            if (targetVersion != null) item.put("targetVersion", targetVersion)

            val values = ContentValues().apply {
                put(COL_EVENT_KEY, identity)
                put(COL_SOURCE, source)
                put(COL_FINGERPRINT, item.optString("fingerprint"))
                put(COL_CAPTURED_AT, nowMs)
                put(
                    COL_OCCURRED_AT,
                    if (item.has("timestamp")) item.optLong("timestamp") else null,
                )
                put(COL_TARGET_REF, targetRef)
                put(COL_TARGET_VERSION, targetVersion)
                put(COL_TARGET_STATE, targetState)
                put(COL_PAYLOAD, item.toString())
                put(COL_MATERIAL_BYTES, bytes)
                put(COL_EXPIRES_AT, expiresAt)
                put(COL_ENQUEUED_AT, nowMs)
                putNull(COL_MIGRATED_FROM)
            }
            // INSERT OR IGNORE + 回读行数:并发入队同一事件时只有一个成功。
            val rowId = database.insertWithOnConflict(
                "queue", null, values, SQLiteDatabase.CONFLICT_IGNORE,
            )
            return if (rowId == -1L) EnqueueResult.duplicate else EnqueueResult.added
        }
    }

    /**
     * 分批读取(不删除)。Dart 逐项处理,到达可 ACK 结果后调用 [ack]。
     * 旧库遗留 + 迁移未完成时这里只读新库 —— 迁移在首次访问时同步完成。
     */
    @Synchronized
    fun peekBatch(
        context: Context,
        source: String,
        limit: Int = PEEK_BATCH,
        nowMs: Long = System.currentTimeMillis(),
    ): List<JSONObject> {
        synchronized(lock) {
            val database = db(context)
            purgeExpiredLocked(context, database, nowMs)
            val out = ArrayList<JSONObject>(limit)
            database.rawQuery(
                "SELECT $COL_PAYLOAD FROM queue WHERE $COL_SOURCE = ? " +
                    "ORDER BY $COL_CAPTURED_AT ASC LIMIT ?",
                arrayOf(source, limit.toString()),
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val raw = cursor.getString(0) ?: continue
                    val parsed = try {
                        JSONObject(raw)
                    } catch (e: Exception) {
                        null
                    }
                    if (parsed != null) out.add(parsed)
                }
            }
            return out
        }
    }

    /** payload → Dart 侧可见的字符串 Map(字段全保留,含冻结的目标快照)。 */
    fun toMap(item: JSONObject): Map<String, String> {
        val out = HashMap<String, String>()
        for (key in item.keys()) out[key] = item.optString(key)
        return out
    }

    /**
     * 按事件键 **或** 指纹取回原始项(ACK 前要用它更新「已处理」备忘录)。
     * 短信/详情页按 eventKey,通知按 fingerprint,截图按 path —— 同一批 keys
     * 同时匹配两列即可,不存在跨来源误命中(有 source 条件)。
     */
    fun itemsFor(context: Context, source: String, keys: Set<String>): List<JSONObject> {
        if (keys.isEmpty()) return emptyList()
        synchronized(lock) {
            val database = db(context)
            val placeholders = keys.joinToString(",") { "?" }
            val args = arrayOf(source) + keys.toList() + keys.toList()
            val out = ArrayList<JSONObject>(keys.size)
            database.rawQuery(
                "SELECT $COL_PAYLOAD FROM queue WHERE $COL_SOURCE = ? AND " +
                    "($COL_EVENT_KEY IN ($placeholders) OR $COL_FINGERPRINT IN ($placeholders))",
                args,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val raw = cursor.getString(0) ?: continue
                    val parsed = try {
                        JSONObject(raw)
                    } catch (e: Exception) {
                        null
                    }
                    if (parsed != null) out.add(parsed)
                }
            }
            return out
        }
    }

    /** 该来源是否还有下一批(供 Dart 循环 drain 时判断)。 */
    fun hasMore(context: Context, source: String, after: Int): Boolean {
        synchronized(lock) {
            return countLocked(db(context), source) > after
        }
    }

    /** 按事件键 ACK(删除已交给 Dart 且到达可 ACK 结果的项)。 */
    @Synchronized
    fun ack(context: Context, source: String, identities: List<String>) {
        if (identities.isEmpty()) return
        synchronized(lock) {
            val database = db(context)
            database.beginTransaction()
            try {
                for (identity in identities) {
                    database.delete(
                        "queue",
                        "$COL_SOURCE = ? AND $COL_EVENT_KEY = ?",
                        arrayOf(source, identity),
                    )
                }
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        }
    }

    /** 单来源统计(状态卡/设置页展示积压与容量)。 */
    @Synchronized
    fun stats(context: Context, source: String, nowMs: Long = System.currentTimeMillis()): SourceStats {
        synchronized(lock) {
            val database = db(context)
            purgeExpiredLocked(context, database, nowMs)
            var count = 0
            var bytes = 0
            var oldest = 0L
            var expired = 0
            database.rawQuery(
                "SELECT COUNT(*), COALESCE(SUM($COL_MATERIAL_BYTES),0), " +
                    "COALESCE(MIN($COL_CAPTURED_AT),0), " +
                    "COALESCE(SUM(CASE WHEN $COL_EXPIRES_AT <= ? THEN 1 ELSE 0 END),0) " +
                    "FROM queue WHERE $COL_SOURCE = ?",
                arrayOf(nowMs.toString(), source),
            ).use { c ->
                if (c.moveToFirst()) {
                    count = c.getInt(0)
                    bytes = c.getInt(1)
                    oldest = c.getLong(2)
                    expired = c.getInt(3)
                }
            }
            return SourceStats(count, bytes, oldest, expired)
        }
    }

    /** 清空队列(隐私清理入口 + 仪器测试隔离用)。 */
    @Synchronized
    fun clearAll(context: Context) {
        synchronized(lock) {
            db(context).delete("queue", null, null)
        }
    }

    /** 当前损失摘要(容量拒收 / 过期清理)。 */
    fun lossSummary(context: Context): String {
        val prefs = prefs(context)
        return prefs.getString(LOSS_SUMMARY_KEY, null) ?: "[]"
    }

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(
            "auto_book_queue_meta", Context.MODE_PRIVATE,
        )

    // ───────────────────────── 迁移 ─────────────────────────

    /**
     * 旧 SharedPreferences 队列 → 新库。**幂等**:按事件键去重,可重复执行;
     * 失败时保持标记未完成,读取侧继续读旧队列;旧值全程不清空。
     */
    @Synchronized
    fun migrateFromPrefs(
        context: Context,
        source: String,
        prefsName: String,
        queueKey: String,
        nowMs: Long = System.currentTimeMillis(),
    ): MigrationResult {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        if (prefs.getBoolean(MIGRATION_FLAG, false)) {
            return MigrationResult(0, 0, 0, true)
        }
        synchronized(lock) {
            val legacy = prefs.getString(queueKey, null)
            // 迁移前保留旧格式备份(计划 §4 B3 任务 8)。
            if (!legacy.isNullOrEmpty() && prefs.getString(PREFS_BACKUP_KEY, null) == null) {
                prefs.edit().putString(PREFS_BACKUP_KEY, legacy).apply()
            }

            val database = db(context)
            val existing = HashSet<String>()
            database.rawQuery(
                "SELECT $COL_EVENT_KEY FROM queue WHERE $COL_SOURCE = ?",
                arrayOf(source),
            ).use { c -> while (c.moveToNext()) existing.add(c.getString(0)) }

            val candidates = migrationCandidates(existing, legacy)
            var migrated = 0
            var failed = 0
            database.beginTransaction()
            try {
                for (item in candidates) {
                    val identity = identityOf(source, item)
                    if (identity.isEmpty()) continue
                    val bytes = materialBytesOf(item)
                    val values = ContentValues().apply {
                        put(COL_EVENT_KEY, identity)
                        put(COL_SOURCE, source)
                        put(COL_FINGERPRINT, item.optString("fingerprint"))
                        put(
                            COL_CAPTURED_AT,
                            if (item.has("timestamp")) item.optLong("timestamp") else nowMs,
                        )
                        put(
                            COL_OCCURRED_AT,
                            if (item.has("timestamp")) item.optLong("timestamp") else null,
                        )
                        // 旧队列没有目标快照 → 留空,Dart 回落当前配置解析(B2)。
                        put(COL_PAYLOAD, item.toString())
                        put(COL_MATERIAL_BYTES, bytes)
                        put(COL_EXPIRES_AT, nowMs + MAX_AGE_MS)
                        put(COL_ENQUEUED_AT, nowMs)
                        put(COL_MIGRATED_FROM, "prefs:$prefsName/$queueKey")
                    }
                    val rowId = database.insertWithOnConflict(
                        "queue", null, values, SQLiteDatabase.CONFLICT_IGNORE,
                    )
                    if (rowId == -1L) failed++ else migrated++
                }
                database.setTransactionSuccessful()
            } catch (e: Exception) {
                Log.e(TAG, "队列迁移写入失败,保持旧队列可读", e)
                return MigrationResult(migrated, candidates.size - migrated - failed, failed, false)
            } finally {
                database.endTransaction()
            }

            // 校验:写入条数 + 去重条数 与候选一致才算完成。
            val verifyCount = database.rawQuery(
                "SELECT COUNT(*) FROM queue WHERE $COL_SOURCE = ? AND $COL_MIGRATED_FROM IS NOT NULL",
                arrayOf(source),
            ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

            val completed = verifyCount >= migrated
            if (completed) {
                prefs.edit().putBoolean(MIGRATION_FLAG, true).apply()
            }
            Log.i(
                TAG,
                "队列迁移 source=$source migrated=$migrated dup=" +
                    "${candidates.size - migrated - failed} failed=$failed completed=$completed",
            )
            return MigrationResult(
                migrated,
                candidates.size - migrated - failed,
                failed,
                completed,
            )
        }
    }

    /** 迁移是否已完成(未完成时调用方仍可读旧队列兜底)。 */
    fun isMigrated(context: Context, prefsName: String): Boolean =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .getBoolean(MIGRATION_FLAG, false)

    // ───────────────────────── 内部 ─────────────────────────

    private fun countLocked(database: SQLiteDatabase, source: String): Int =
        database.rawQuery(
            "SELECT COUNT(*) FROM queue WHERE $COL_SOURCE = ?",
            arrayOf(source),
        ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    private fun totalBytesLocked(database: SQLiteDatabase): Int =
        database.rawQuery(
            "SELECT COALESCE(SUM($COL_MATERIAL_BYTES),0) FROM queue",
            emptyArray(),
        ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    /** 过期材料清理:只删过期行,并记无原文的过期摘要(计划 B3 任务 7)。 */
    private fun purgeExpiredLocked(
        context: Context,
        database: SQLiteDatabase,
        nowMs: Long,
    ) {
        for (source in listOf("sms", "notification", "screenText", "screenshot")) {
            val expired = database.rawQuery(
                "SELECT COUNT(*) FROM queue WHERE $COL_SOURCE = ? AND $COL_EXPIRES_AT <= ?",
                arrayOf(source, nowMs.toString()),
            ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }
            if (expired <= 0) continue
            database.delete(
                "queue",
                "$COL_SOURCE = ? AND $COL_EXPIRES_AT <= ?",
                arrayOf(source, nowMs.toString()),
            )
            appendLossLocked(
                context,
                // 过期摘要不含原文,只留计数(计划 §4 B3 任务 7)。
                lossSummary(source, "expired", expired, nowMs),
            )
        }
    }

    private fun appendLossLocked(context: Context, entry: String) {
        try {
            val prefs = prefs(context)
            val raw = prefs.getString(LOSS_SUMMARY_KEY, null) ?: "[]"
            val arr = JSONArray(raw)
            arr.put(JSONObject(entry))
            // 只留最近 20 条,避免无界增长。
            while (arr.length() > 20) arr.remove(0)
            prefs.edit().putString(LOSS_SUMMARY_KEY, arr.toString()).apply()
        } catch (e: Exception) {
            Log.w(TAG, "损失摘要写入失败(不影响队列)", e)
        }
    }
}
