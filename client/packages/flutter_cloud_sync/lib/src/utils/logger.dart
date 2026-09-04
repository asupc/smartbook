/// Log level enumeration
enum LogLevel {
  /// Debug level - verbose information
  debug,

  /// Info level - general information
  info,

  /// Warning level - potential issues
  warning,

  /// Error level - errors and exceptions
  error,
}

/// Cloud sync logger
///
/// Provides a simple logging interface that can be connected
/// to any logging framework (like logger, firebase_crashlytics, etc.)
class CloudSyncLogger {
  /// Log callback function
  final void Function(LogLevel level, String message) onLog;

  const CloudSyncLogger({required this.onLog});

  /// Log debug message
  void debug(String message) => onLog(LogLevel.debug, message);

  /// Log info message
  void info(String message) => onLog(LogLevel.info, message);

  /// Log warning message
  void warning(String message) => onLog(LogLevel.warning, message);

  /// Log error message
  void error(String message) => onLog(LogLevel.error, message);
}
