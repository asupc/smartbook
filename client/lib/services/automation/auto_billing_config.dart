/// 自动记账配置参数
/// 统一管理超时、重试、缓存等配置
class AutoBillingConfig {
  /// 文件等待超时时间 (毫秒)
  /// 统一设置为3秒，覆盖以下场景：
  /// - AutoBillingService 等待文件写入
  /// - ContentObserver 查询最近图片的时间窗口
  /// - 无障碍服务等待文件就绪
  static const int fileWaitTimeout = 3000;

  /// 防重复处理时间窗口 (毫秒)
  /// 在此时间内相同路径的截图只处理一次
  static const int duplicateCheckWindow = 5000;

  /// 已处理截图缓存大小
  /// 防止内存占用过大
  static const int maxProcessedCache = 100;

  /// 无障碍服务防重复触发间隔 (毫秒)
  /// 避免截图动画/编辑界面重复触发
  static const int accessibilityDuplicateWindow = 3000;

  /// ContentObserver 查询时间窗口 (秒)
  /// 查询最近N秒内添加的图片
  static const int contentObserverQueryWindow = 3;

  /// 最新截图文件的有效期 (毫秒)
  /// 超过此时间的截图视为过旧，不处理
  static const int latestScreenshotMaxAge = 5000;

  /// 无障碍服务文件等待延迟 (毫秒)
  /// Android 10及以下等待文件写入的延迟时间
  static const int accessibilityFileWaitDelay = 1500;

  /// 无障碍服务 API 截图延迟 (毫秒)
  /// Android 11+ 使用 takeScreenshot API 前的延迟，等待截图动画完成
  static const int accessibilityApiDelay = 200;

  /// 每次文件检查的间隔 (毫秒)
  /// 循环等待文件时的检查间隔
  static const int fileCheckInterval = 100;
}
