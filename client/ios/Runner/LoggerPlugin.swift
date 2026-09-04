import Flutter
import Foundation

/// 日志插件 - 将 iOS 原生日志发送到 Flutter
/// 可以被任何 iOS 模块使用
public class LoggerPlugin {
    public static var channel: FlutterMethodChannel?

    /// 设置通道
    public static func setup(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    /// 发送日志到 Flutter
    public static func log(level: String, tag: String, message: String) {
        // 同时打印到控制台
        print("[\(tag)] \(message)")

        let args: [String: Any] = [
            "platform": "ios",
            "level": level,
            "tag": tag,
            "message": message,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]

        DispatchQueue.main.async {
            channel?.invokeMethod("onNativeLog", arguments: args)
        }
    }

    // 便捷方法
    public static func debug(tag: String, message: String) {
        log(level: "DEBUG", tag: tag, message: message)
    }

    public static func info(tag: String, message: String) {
        log(level: "INFO", tag: tag, message: message)
    }

    public static func warning(tag: String, message: String) {
        log(level: "WARNING", tag: tag, message: message)
    }

    public static func error(tag: String, message: String) {
        log(level: "ERROR", tag: tag, message: message)
    }
}
