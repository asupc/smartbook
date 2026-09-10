package com.smartbook.zhi

import android.content.Context
import android.content.SharedPreferences
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 截图监听器
 * 监听 MediaStore 的 Screenshots 目录变化,检测新截图
 */
class ScreenshotObserver(
    private val context: Context,
    private val onScreenshotDetected: (String) -> Unit
) : ContentObserver(Handler(Looper.getMainLooper())) {

    companion object {
        private const val TAG = "ScreenshotObserver"

        // 截图关键词
        private val SCREENSHOT_KEYWORDS = listOf(
            "screenshot",
            "截屏",
            "截图",
            "screen_shot",
            "screen shot"
        )

        // 只处理最近30秒内的截图（防止处理历史图片）
        private const val MAX_SCREENSHOT_AGE_SECONDS = 30L

        // 两段写入:MediaStore 事件后延迟统一检查的窗口(等 rename 完成)
        private const val DRAIN_DELAY_MS = 1000L
        // 单个 uri 遇到 .pending- 中间态的最大重查次数(每次间隔 DRAIN_DELAY_MS)
        private const val MAX_PENDING_RETRIES = 2

        // SharedPreferences相关
        private const val PREFS_NAME = "screenshot_monitor_prefs"
        private const val KEY_PROCESSED_PATHS = "processed_paths"
        private const val MAX_STORED_PATHS = 200 // 最多存储200条记录
        private const val KEY_PENDING_QUEUE = "pending_queue"
        private const val MAX_PENDING_QUEUE = 30

        /** 读取待处理截图，读取不删除，处理完成由 Flutter ACK。 */
        @Synchronized
        fun peekQueue(context: Context): ArrayList<Map<String, String>> {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString(KEY_PENDING_QUEUE, null) ?: "[]")
            val result = ArrayList<Map<String, String>>(arr.length())
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                result.add(
                    mapOf(
                        "path" to obj.optString("path"),
                        "timestamp" to obj.optString("timestamp"),
                    )
                )
            }
            return result
        }

        /** 终态 ACK：删除队列项并写入已完成路径缓存。 */
        @Synchronized
        fun ackQueue(context: Context, paths: List<String>) {
            if (paths.isEmpty()) return
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val wanted = paths.toSet()
            val arr = JSONArray(prefs.getString(KEY_PENDING_QUEUE, null) ?: "[]")
            val remaining = JSONArray()
            val acked = mutableSetOf<String>()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val path = obj.optString("path")
                if (wanted.contains(path)) acked.add(path) else remaining.put(obj)
            }
            if (acked.isEmpty()) return
            val processed = prefs.getString(KEY_PROCESSED_PATHS, null)
                ?.split("|")?.filter { it.isNotEmpty() }?.toMutableList()
                ?: mutableListOf()
            processed.addAll(acked)
            val trimmed = processed.takeLast(MAX_STORED_PATHS)
            prefs.edit()
                .putString(KEY_PENDING_QUEUE, remaining.toString())
                .putString(KEY_PROCESSED_PATHS, trimmed.joinToString("|"))
                .apply()
        }
    }

    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private var lastCheckTime = System.currentTimeMillis()
    private val processedPaths = mutableSetOf<String>()

    // 两段写入兼容(2026-09 修复):很多厂商截图先写 `.pending-` 临时文件、
    // 写完再 rename 成正式名,MediaStore 会触发两次事件。旧实现 onChange 开头
    // 的 500ms 防抖会把「第一个事件(.pending-,被过滤)之后的 rename 事件」
    // 整个跳过 → 截图不触发,用户只能手动编辑保存(独立操作,间隔超窗口)才
    // 触发。这里改为:收集待查 uri → 延迟 1s 一次性检查(rename 已完成),
    // 集合天然去重,不再有全局防抖窗口。
    private val pendingUris = mutableSetOf<Uri?>()
    private var pendingScheduled = false
    private val retryCounts = mutableMapOf<Uri, Int>()

    init {
        // 从SharedPreferences加载已处理的路径
        loadProcessedPaths()
        LoggerPlugin.info(TAG, "ScreenshotObserver初始化完成，已加载${processedPaths.size}条历史记录")
    }

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)

        val startTime = System.currentTimeMillis()
        try {
            Log.d(TAG, "⏱️ [性能] onChange触发: uri=$uri, 时间=${startTime}")
            LoggerPlugin.info(TAG, "ContentObserver检测到媒体库变化: uri=$uri")

            // 先收集后统一延迟检查:两段写入(见类注释)的 rename 事件与首次
            // insert 间隔通常 <1s,延迟后行已是最终状态;null 代表走全量兜底。
            pendingUris.add(uri)
            scheduleDrain()

            val elapsed = System.currentTimeMillis() - startTime
            Log.d(TAG, "⏱️ [性能] onChange处理完成, 耗时=${elapsed}ms")
            LoggerPlugin.debug(TAG, "ContentObserver处理完成, 耗时=${elapsed}ms")
        } catch (e: Exception) {
            Log.e(TAG, "处理媒体库变化失败", e)
            LoggerPlugin.error(TAG, "处理媒体库变化失败: ${e.message}")
        }
    }

    /// 调度一次延迟检查。窗口内有新事件只并集,不重复调度。
    private fun scheduleDrain() {
        if (pendingScheduled) return
        pendingScheduled = true
        Handler(Looper.getMainLooper()).postDelayed({
            pendingScheduled = false
            drainPending()
        }, DRAIN_DELAY_MS)
    }

    private fun drainPending() {
        val uris = pendingUris.toList()
        pendingUris.clear()
        for (u in uris) {
            if (u == null) {
                checkForNewScreenshot()
                continue
            }
            val retry = checkImageUri(u) // true = 疑似两段写入中间态,需重查
            val attempts = retryCounts.getOrDefault(u, 0)
            if (retry && attempts < MAX_PENDING_RETRIES) {
                retryCounts[u] = attempts + 1
                pendingUris.add(u)
                scheduleDrain()
            } else {
                retryCounts.remove(u)
            }
        }
    }

    /**
     * 直接检查特定URI的图片（新优化方法）
     *
     * 返回 true 表示「疑似两段写入中间态」(文件名仍是 `.pending-`),调用方
     * 稍后重查 —— 1s 后 rename 完成,行就是最终状态。
     */
    private fun checkImageUri(uri: Uri): Boolean {
        val queryStartTime = System.currentTimeMillis()
        try {
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.DISPLAY_NAME
            )

            Log.d(TAG, "⏱️ [性能] 开始查询单个URI: $uri")
            val cursor: Cursor? = context.contentResolver.query(
                uri,
                projection,
                null,
                null,
                null
            )
            val queryElapsed = System.currentTimeMillis() - queryStartTime
            Log.d(TAG, "⏱️ [性能] URI查询完成, 耗时=${queryElapsed}ms")

            val processStartTime = System.currentTimeMillis()
            var retry = false
            cursor?.use {
                LoggerPlugin.debug(TAG, "媒体查询结果: rows=${it.count}")
                if (it.moveToFirst()) {
                    val nameIndex = it.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
                    val dateIndex = it.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
                    val dataIndex = it.getColumnIndex(MediaStore.Images.Media.DATA)
                    val relIndex = it.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)

                    // 2026-09-10 真机定位(vivo OriginOS):ROM 对非属主 App 可能
                    // 不回 `_data` 列(路径隐私),旧代码该列缺失时整段静默跳过,
                    // 截图链路表现为「onChange 有事件、查询有耗时、之后零日志」。
                    // 路径兜底:relative_path 是 API 29+ 对所有有媒体权限的 App
                    // 可见的列,拼出物理路径供 OCR 读取。
                    val imageName = if (nameIndex >= 0) it.getString(nameIndex) ?: "" else ""
                    var resolvedPath = if (dataIndex >= 0) it.getString(dataIndex) else null
                    if (resolvedPath.isNullOrEmpty() && relIndex >= 0 && imageName.isNotEmpty()) {
                        val rel = it.getString(relIndex) ?: ""
                        if (rel.isNotEmpty()) {
                            resolvedPath = "${Environment.getExternalStorageDirectory().absolutePath}/$rel$imageName"
                            LoggerPlugin.debug(TAG, "_data 列缺失,按 relative_path 还原路径: $resolvedPath")
                        }
                    }
                    val imagePath = resolvedPath

                    if (!imagePath.isNullOrEmpty() && dateIndex >= 0) {

                        // 两段写入中间态:等 rename(MAX_PENDING_RETRIES 次重试后放弃)
                        if (isPendingTmp(imagePath, imageName)) {
                            Log.d(TAG, "⏳ 疑似写入中临时文件，延迟重查: $imageName")
                            LoggerPlugin.debug(TAG, "疑似写入中临时文件,延迟重查: $imageName")
                            retry = true
                            return@use
                        }

                        val dateAdded = it.getLong(dateIndex)

                        // 检查图片年龄（防止处理历史图片）
                        val currentTimeSeconds = System.currentTimeMillis() / 1000
                        val imageAge = currentTimeSeconds - dateAdded
                        if (imageAge > MAX_SCREENSHOT_AGE_SECONDS) {
                            Log.d(TAG, "⏭️ 跳过旧图片: $imageName (年龄=${imageAge}秒)")
                            LoggerPlugin.debug(TAG, "跳过旧图片: $imageName (年龄=${imageAge}秒，超过${MAX_SCREENSHOT_AGE_SECONDS}秒阈值)")
                            return@use
                        }

                        // 检查是否是截图
                        if (isScreenshot(imagePath, imageName) &&
                            enqueuePending(imagePath, System.currentTimeMillis())) {
                            Log.d(TAG, "✅ 检测到新截图: $imagePath")
                            Log.d(TAG, "文件名: $imageName, 年龄=${imageAge}秒")
                            LoggerPlugin.info(TAG, "检测到新截图: $imageName")
                            ScreenTextWatcher.recordDecision(
                                context, "app", "enqueued",
                                "name=$imageName",
                                ScreenTextWatcher.DECISION_SOURCE_SCREENSHOT,
                            )

                            // 先写入持久化队列，再通知 Flutter。进程在 AI/DB
                            // 处理前被杀时，启动 drain 仍能恢复；只有 Flutter ACK
                            // 后才进入 completed path cache。
                            val callbackStartTime = System.currentTimeMillis()
                            onScreenshotDetected(imagePath)
                            val callbackElapsed = System.currentTimeMillis() - callbackStartTime
                            Log.d(TAG, "⏱️ [性能] 回调执行完成, 耗时=${callbackElapsed}ms")
                            LoggerPlugin.debug(TAG, "截图回调执行完成, 耗时=${callbackElapsed}ms")
                        }
                    }
                } else if (isPartialPhotoAccess()) {
                    // 2026-09-10 真机定位:onChange 仍通知但查询游标为空,几乎
                    // 必然是「仅允许选中的照片」部分授权 —— 显式警告,不再静默
                    LoggerPlugin.warning(
                        TAG,
                        "照片权限为「仅选中的照片」,MediaStore 看不到新截图;请到系统设置把智记的照片权限改为「允许所有照片」"
                    )
                    ScreenTextWatcher.recordDecision(
                        context, "app", "partial_access",
                        "照片权限=仅选中的照片,MediaStore 看不到新截图",
                        ScreenTextWatcher.DECISION_SOURCE_SCREENSHOT,
                    )
                }
                if (!retry) {
                    val fallbackPath = findRecentScreenshotFile()
                    if (fallbackPath != null &&
                        enqueuePending(fallbackPath, System.currentTimeMillis())
                    ) {
                        // MediaStore 行不可见的文件系统兜底(vivo 真机 2026-09-10:
                        // 权限全量、is_pending=0,provider 查询仍恒 0 行;而
                        // targetSdk 32 + legacy storage 的 FUSE 直读不受影响)
                        LoggerPlugin.info(
                            TAG,
                            "检测到新截图(MediaStore 0 行,文件系统兜底): ${File(fallbackPath).name}"
                        )
                        ScreenTextWatcher.recordDecision(
                            context, "app", "enqueued",
                            "name=${File(fallbackPath).name}(文件兜底)",
                            ScreenTextWatcher.DECISION_SOURCE_SCREENSHOT,
                        )
                        val callbackStartTime = System.currentTimeMillis()
                        onScreenshotDetected(fallbackPath)
                        LoggerPlugin.debug(
                            TAG,
                            "截图回调执行完成(文件系统兜底), 耗时=${System.currentTimeMillis() - callbackStartTime}ms"
                        )
                    }
                }
                val processElapsed = System.currentTimeMillis() - processStartTime
                Log.d(TAG, "⏱️ [性能] 处理完成, 耗时=${processElapsed}ms")
            }
            return retry
        } catch (e: Exception) {
            Log.e(TAG, "检查URI失败: $uri", e)
            return false
        }
    }

    /**
     * 检查是否有新截图（兜底方案）
     */
    private fun checkForNewScreenshot() {
        val currentTime = System.currentTimeMillis()
        val queryStartTime = System.currentTimeMillis()

        try {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }

            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.DISPLAY_NAME
            )

            // 查询最近添加的图片，但会通过时间检查过滤掉旧图片
            val currentTimeSeconds = System.currentTimeMillis() / 1000
            val selection = "${MediaStore.Images.Media.DATE_ADDED} > ?"
            val selectionArgs = arrayOf((currentTimeSeconds - MAX_SCREENSHOT_AGE_SECONDS).toString())
            val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

            Log.d(TAG, "⏱️ [性能] 开始查询MediaStore（兜底）")
            val cursor: Cursor? = context.contentResolver.query(
                uri,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )
            val queryElapsed = System.currentTimeMillis() - queryStartTime
            Log.d(TAG, "⏱️ [性能] MediaStore查询完成, 耗时=${queryElapsed}ms")

            val processStartTime = System.currentTimeMillis()
            cursor?.use {
                var foundCount = 0
                while (it.moveToNext()) {
                    foundCount++
                    val nameIndex = it.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
                    val dateIndex = it.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
                    val dataIndex = it.getColumnIndex(MediaStore.Images.Media.DATA)
                    val relIndex = it.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)

                    // 与 checkImageUri 同款路径兜底:_data 列可能被 ROM 对非属主隐藏
                    val imageName = if (nameIndex >= 0) it.getString(nameIndex) ?: "" else ""
                    var resolvedPath = if (dataIndex >= 0) it.getString(dataIndex) else null
                    if (resolvedPath.isNullOrEmpty() && relIndex >= 0 && imageName.isNotEmpty()) {
                        val rel = it.getString(relIndex) ?: ""
                        if (rel.isNotEmpty()) {
                            resolvedPath = "${Environment.getExternalStorageDirectory().absolutePath}/$rel$imageName"
                        }
                    }
                    val imagePath = resolvedPath

                    if (!imagePath.isNullOrEmpty() && dateIndex >= 0) {
                        val dateAdded = it.getLong(dateIndex)

                        // 检查图片年龄（防止处理历史图片）
                        val imageAge = currentTimeSeconds - dateAdded
                        if (imageAge > MAX_SCREENSHOT_AGE_SECONDS) {
                            Log.d(TAG, "⏭️ 跳过旧图片(兜底): $imageName (年龄=${imageAge}秒)")
                            LoggerPlugin.debug(TAG, "跳过旧图片(兜底): $imageName (年龄=${imageAge}秒，超过${MAX_SCREENSHOT_AGE_SECONDS}秒阈值)")
                            continue
                        }

                        // 检查是否是截图
                        if (isScreenshot(imagePath, imageName) &&
                            enqueuePending(imagePath, System.currentTimeMillis())) {
                            Log.d(TAG, "✅ 检测到新截图: $imagePath")
                            Log.d(TAG, "文件名: $imageName, 年龄=${imageAge}秒")
                            LoggerPlugin.info(TAG, "检测到新截图(兜底): $imageName")

                            val callbackStartTime = System.currentTimeMillis()
                            onScreenshotDetected(imagePath)
                            val callbackElapsed = System.currentTimeMillis() - callbackStartTime
                            Log.d(TAG, "⏱️ [性能] 回调执行完成, 耗时=${callbackElapsed}ms")
                            LoggerPlugin.debug(TAG, "截图回调执行完成(兜底), 耗时=${callbackElapsed}ms")
                        }
                    }
                }
                val processElapsed = System.currentTimeMillis() - processStartTime
                Log.d(TAG, "⏱️ [性能] 处理${foundCount}条记录, 耗时=${processElapsed}ms")
            }

            lastCheckTime = currentTime
        } catch (e: Exception) {
            Log.e(TAG, "检查新截图失败", e)
        }
    }

    /**
     * 文件系统兜底:MediaStore 查询不到行时,直接扫系统截图目录找
     * [MAX_SCREENSHOT_AGE_SECONDS] 内的新截图(见 checkImageUri 内注释)。
     * 只扫截图专属目录,列表小、主线程开销可忽略;enqueuePending 按路径幂等。
     */
    private fun findRecentScreenshotFile(): String? {
        val roots = listOfNotNull(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
        ).flatMap { listOfNotNull(it, File(it, "Screenshots")) }
            .filter { it.isDirectory }
        val cutoff = System.currentTimeMillis() - MAX_SCREENSHOT_AGE_SECONDS * 1000
        var best: File? = null
        var bestTime = 0L
        for (dir in roots) {
            val files = dir.listFiles()
            LoggerPlugin.debug(TAG, "兜底扫描 ${dir.absolutePath}: ${files?.size ?: -1}")
            if (files == null) continue
            for (f in files) {
                if (!f.isFile) continue
                val nameLower = f.name.lowercase()
                if (SCREENSHOT_KEYWORDS.none { nameLower.contains(it) }) continue
                if (isPendingTmp(f.absolutePath, f.name)) continue
                val mtime = resolveCaptureTime(f)
                if (mtime < cutoff) continue
                if (best == null || mtime > bestTime) {
                    best = f
                    bestTime = mtime
                }
            }
        }
        return best?.absolutePath
    }

    /**
     * 截图捕获时间:vivo FUSE 对其他 App 新建的文件可能回 lastModified=0(真机
     * 2026-09-10 兜底扫描不命中的根因),而系统截图的标准文件名内嵌拍摄时间
     * (Screenshot_20260910_101242.jpg),优先解析文件名,异常再退 lastModified。
     */
    private fun resolveCaptureTime(f: File): Long {
        Regex("(\\d{8})_(\\d{6})").find(f.name)?.let { m ->
            val (d, t) = m.destructured
            try {
                val cal = java.util.Calendar.getInstance().apply {
                    set(
                        d.substring(0, 4).toInt(), d.substring(4, 6).toInt() - 1,
                        d.substring(6, 8).toInt(), t.substring(0, 2).toInt(),
                        t.substring(2, 4).toInt(), t.substring(4, 6).toInt()
                    )
                    set(java.util.Calendar.MILLISECOND, 0)
                }
                return cal.timeInMillis
            } catch (_: Exception) {
            }
        }
        return f.lastModified()
    }

    /** 将截图路径写入待处理队列，队列项本身作为事件级幂等兜底。 */
    @Synchronized
    private fun enqueuePending(path: String, ts: Long): Boolean {
        val processed = prefs.getString(KEY_PROCESSED_PATHS, null)
            ?.split("|")?.filter { it.isNotEmpty() }?.toSet() ?: emptySet()
        if (processed.contains(path)) return false
        val arr = JSONArray(prefs.getString(KEY_PENDING_QUEUE, null) ?: "[]")
        for (i in 0 until arr.length()) {
            if (arr.optJSONObject(i)?.optString("path") == path) return false
        }
        arr.put(JSONObject().put("path", path).put("timestamp", ts))
        while (arr.length() > MAX_PENDING_QUEUE) arr.remove(0)
        prefs.edit().putString(KEY_PENDING_QUEUE, arr.toString()).apply()
        return true
    }

    /**
     * 是否「仅允许选中的照片」部分授权(Android 14+)。判定必须是**组合**条件:
     * USER_SELECTED 授权 且 READ_MEDIA_IMAGES 未授权 —— 部分 ROM(vivo 实测
     * 2026-09-10)在「允许全部」时也会附带授出 USER_SELECTED,只看它会把
     * 完全访问误判成部分授权,反复弹「仅选中的照片」提示。
     */
    private fun isPartialPhotoAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val userSelectedGranted = context.checkSelfPermission(
            android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val imagesGranted = context.checkSelfPermission(
            android.Manifest.permission.READ_MEDIA_IMAGES
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        return userSelectedGranted && !imagesGranted
    }

    /**
     * 是否是系统写入中的临时文件(.pending- 前缀是小米等厂商两段写入的
     * 中间态,rename 完成后才是正式文件名)。
     */
    private fun isPendingTmp(path: String, name: String): Boolean {
        return name.startsWith(".pending-") || path.contains("/.pending-")
    }

    /**
     * 判断是否是截图
     */
    private fun isScreenshot(path: String, name: String): Boolean {
        val lowerPath = path.lowercase()
        val lowerName = name.lowercase()

        // 过滤掉临时文件(两段写入中间态,rename 后重新触发)
        if (isPendingTmp(lowerPath, lowerName)) {
            Log.d(TAG, "⏭️ 跳过临时文件: $name")
            LoggerPlugin.debug(TAG, "跳过临时文件: $name")
            return false
        }

        return SCREENSHOT_KEYWORDS.any { keyword ->
            lowerPath.contains(keyword) || lowerName.contains(keyword)
        }
    }

    /**
     * 从SharedPreferences加载已处理的路径
     */
    private fun loadProcessedPaths() {
        try {
            val pathsString = prefs.getString(KEY_PROCESSED_PATHS, null)
            if (pathsString != null) {
                val paths = pathsString.split("|").filter { it.isNotEmpty() }
                processedPaths.addAll(paths)
                LoggerPlugin.info(TAG, "从SharedPreferences加载了 ${paths.size} 条已处理路径")
            }
        } catch (e: Exception) {
            Log.e(TAG, "加载已处理路径失败", e)
            LoggerPlugin.error(TAG, "加载已处理路径失败: ${e.message}")
        }
    }

    /**
     * 保存已处理的路径到SharedPreferences
     */
    private fun saveProcessedPaths() {
        try {
            // 只保存最近的 MAX_STORED_PATHS 条记录
            val pathsList = processedPaths.toList()
            val pathsToSave = if (pathsList.size > MAX_STORED_PATHS) {
                pathsList.takeLast(MAX_STORED_PATHS)
            } else {
                pathsList
            }

            val pathsString = pathsToSave.joinToString("|")
            prefs.edit().putString(KEY_PROCESSED_PATHS, pathsString).apply()
            LoggerPlugin.debug(TAG, "已保存 ${pathsToSave.size} 条已处理路径到SharedPreferences")
        } catch (e: Exception) {
            Log.e(TAG, "保存已处理路径失败", e)
            LoggerPlugin.error(TAG, "保存已处理路径失败: ${e.message}")
        }
    }

    /**
     * 清理已处理的路径缓存
     */
    fun clear() {
        processedPaths.clear()
        prefs.edit().remove(KEY_PROCESSED_PATHS).apply()
        LoggerPlugin.info(TAG, "已清空所有已处理路径缓存")
    }
}
