package com.smartbook.zhi

import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * 日志插件 - 将 Android 原生日志发送到 Flutter
 */
object LoggerPlugin {
    private const val TAG = "LoggerPlugin"
    private var channel: MethodChannel? = null

    // 日志队列，用于在 Flutter 端未就绪时缓存日志
    private val logQueue = mutableListOf<Map<String, Any>>()
    private const val MAX_QUEUE_SIZE = 100

    fun setup(channel: MethodChannel) {
        Log.d(TAG, "========== LoggerPlugin setup START ==========")
        this.channel = channel
        Log.d(TAG, "Channel assigned: $channel")
        Log.d(TAG, "Queue size: ${logQueue.size}")

        try {
            // 发送队列中的日志
            flushQueue()
            Log.d(TAG, "========== LoggerPlugin setup SUCCESS ==========")
        } catch (e: Exception) {
            Log.e(TAG, "========== LoggerPlugin setup FAILED ==========", e)
        }
    }

    /**
     * 发送日志到 Flutter
     */
    fun log(level: String, tag: String, message: String) {
        // 先打印到 Android logcat，确保至少能看到
        Log.d(TAG, "[$level] [$tag] $message")

        val logData = mapOf(
            "platform" to "android",
            "level" to level,
            "tag" to tag,
            "message" to message,
            "timestamp" to System.currentTimeMillis()
        )

        if (channel != null) {
            try {
                Log.d(TAG, "Sending to Flutter: $logData")
                channel?.invokeMethod("onNativeLog", logData)
                Log.d(TAG, "Sent successfully")
            } catch (e: Exception) {
                Log.e(TAG, "发送日志到Flutter失败: $e", e)
                // 失败时加入队列
                addToQueue(logData)
            }
        } else {
            Log.w(TAG, "Channel is null, adding to queue: $message")
            // Channel 未就绪，加入队列
            addToQueue(logData)
        }
    }

    private fun addToQueue(logData: Map<String, Any>) {
        synchronized(logQueue) {
            if (logQueue.size >= MAX_QUEUE_SIZE) {
                logQueue.removeAt(0) // 移除最旧的
            }
            logQueue.add(logData)
        }
    }

    private fun flushQueue() {
        synchronized(logQueue) {
            if (logQueue.isNotEmpty()) {
                Log.d(TAG, "Flushing ${logQueue.size} queued logs")
                logQueue.forEach { logData ->
                    try {
                        channel?.invokeMethod("onNativeLog", logData)
                    } catch (e: Exception) {
                        Log.e(TAG, "发送队列日志失败: $e")
                    }
                }
                logQueue.clear()
            }
        }
    }

    // 便捷方法
    fun debug(tag: String, message: String) = log("DEBUG", tag, message)
    fun info(tag: String, message: String) = log("INFO", tag, message)
    fun warning(tag: String, message: String) = log("WARNING", tag, message)
    fun error(tag: String, message: String) = log("ERROR", tag, message)
}
