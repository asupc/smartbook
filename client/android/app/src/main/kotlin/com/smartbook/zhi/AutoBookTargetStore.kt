package com.smartbook.zhi

import android.content.Context
import org.json.JSONObject

/**
 * B2:自动记账目标的**原生只读缓存**。
 *
 * Dart 侧在配置保存成功后写入(先落 Dart prefs,再同步这里,B0 §3.1 的
 * 版本检查顺序);四路捕获入队时读它,把目标快照**冻结进队列项** ——
 * 之后用户改设置、切浏览账本,都不改变已捕获事件的目标。
 *
 * 约定:
 * - 缓存缺失(从未配置/新装/写入失败)→ [enqueueFields] 返回空 map,
 *   队列项不带目标字段,Dart 侧按**当前配置**解析,绝不回退到浏览账本;
 * - peek 回吐的是**该队列项自己的**冻结字段,不是当前缓存。
 */
object AutoBookTargetStore {
    const val PREFS_NAME = "auto_book_target_prefs"
    const val KEY_TARGET_REF = "target_ref"
    const val KEY_TARGET_STATE = "target_state"
    const val KEY_CONFIG_VERSION = "config_version"

    /** 稳定引用 `syncId:<v>` / `localId:<v>` + 状态 + 配置版本。 */
    data class Snapshot(
        val ref: String?,
        val state: String?,
        val version: Int,
    )

    @Synchronized
    fun read(context: Context): Snapshot {
        return try {
            val prefs =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val ref = prefs.getString(KEY_TARGET_REF, null)?.trim().orEmpty()
            val state = prefs.getString(KEY_TARGET_STATE, null)?.trim().orEmpty()
            val version = prefs.getInt(KEY_CONFIG_VERSION, -1)
            if (ref.isEmpty() || version < 0) {
                Snapshot(null, null, -1)
            } else {
                Snapshot(ref, state.ifEmpty { "resolved" }, version)
            }
        } catch (e: Exception) {
            Snapshot(null, null, -1)
        }
    }

    /** Dart 配置保存后同步写入;ref 为空 = 清空缓存。 */
    @Synchronized
    fun write(context: Context, ref: String?, state: String, configVersion: Int) {
        try {
            val prefs =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val editor = prefs.edit()
            if (ref.isNullOrEmpty()) {
                editor.remove(KEY_TARGET_REF)
                    .remove(KEY_TARGET_STATE)
                    .remove(KEY_CONFIG_VERSION)
            } else {
                editor.putString(KEY_TARGET_REF, ref)
                    .putString(KEY_TARGET_STATE, state)
                    .putInt(KEY_CONFIG_VERSION, configVersion)
            }
            editor.apply()
        } catch (e: Exception) {
            // 缓存写失败只影响「捕获时冻结」,Dart 仍会按当前配置解析。
        }
    }

    /**
     * 入队时要冻结进队列项的目标字段。缓存缺失返回空 map ——
     * 队列项不带目标字段,由 Dart 回落当前配置解析(不是浏览账本)。
     */
    fun enqueueFields(context: Context): Map<String, Any> {
        val snapshot = read(context)
        val ref = snapshot.ref ?: return emptyMap()
        return mapOf(
            "targetRef" to ref,
            "targetState" to (snapshot.state ?: "resolved"),
            "targetVersion" to snapshot.version,
        )
    }

    /** peek 时回吐队列项**自己的**冻结字段(旧队列无字段 → 空 map)。 */
    fun itemFields(obj: JSONObject): Map<String, String> {
        val ref = obj.optString("targetRef")
        if (ref.isNullOrEmpty()) return emptyMap()
        val state = obj.optString("targetState")
        val version = obj.optString("targetVersion")
        return mapOf(
            "targetRef" to ref,
            "targetState" to state.ifEmpty { "resolved" },
            "targetVersion" to version,
        )
    }
}
