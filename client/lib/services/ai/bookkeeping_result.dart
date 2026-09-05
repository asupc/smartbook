import '../../ai/core/bill_info.dart';

/// AI 记账应用层 · 统一结果。
///
/// 不论单笔还是多笔,5 个调用渠道(chat / image / voice / auto-screenshot /
/// auto-text)的 [AiBookkeeper] 出口都返回这个结构。渠道层只需检查
/// [success] / [isMulti] 然后展示对应 UI(toast / 通知 / 卡片)。
class BookkeepingResult {
  /// 实际保存成功的账单(已附上正确的 ledgerId / 校正后的 category / account)
  final List<BillInfo> savedBills;

  /// 与 [savedBills] 一一对应的交易 ID
  final List<int> transactionIds;

  /// 因创建失败被跳过的笔数(amount 已校验,失败原因通常是 DB 异常)
  final int failedCount;

  /// 自动路径分流到「待确认」的候选笔数(M2 候选制)。
  final int awaitingCount;

  /// 被语义硬闸门判定为非交易/账单汇总而忽略的笔数。
  final int ignoredCount;

  /// 命中已有 canonical transaction、未重复创建的笔数。
  final int duplicateCount;

  /// 强语义判重命中的已有交易 ID，按识别顺序排列。
  final List<int> duplicateTransactionIds;

  /// 影子模式下识别到、但刻意没有写入交易的账单数。
  final int shadowCount;

  /// 本次流程是否发生了可恢复的临时失败。自动入口据此保留事件并重试，
  /// 不能把网络/数据库异常误当成“非账单”。
  final bool retryable;

  /// AI 能力尚未配置。与 retryable 分开，队列应保持 captured 状态而不是
  /// 进入永久 ignored。
  final bool aiNotConfigured;

  /// 本次入库里「拿不到汇率、按 1:1 暂记」的外币币种(去重、已排序)。
  ///
  /// 多币种降级路径(.docs/multi-currency-ai A5):自动通道无人值守,缺汇率
  /// 不能阻断,只能先落 `nativeAmount = amount` 再靠统计页 L11 横幅补折算。
  /// 有 UI 的渠道(对话/语音/选图)据此在结果上补一行提示;自动截图/通知
  /// 渠道忽略它,只打日志。
  final List<String> unconvertedCurrencies;

  const BookkeepingResult({
    this.savedBills = const [],
    this.transactionIds = const [],
    this.failedCount = 0,
    this.unconvertedCurrencies = const [],
    this.awaitingCount = 0,
    this.ignoredCount = 0,
    this.duplicateCount = 0,
    this.duplicateTransactionIds = const [],
    this.shadowCount = 0,
    this.retryable = false,
    this.aiNotConfigured = false,
  });

  /// 至少有一笔成功入库。
  ///
  /// 注意：候选/重复/忽略都是有效的自动处理结果，不应被渠道层一律
  /// 当作“没有识别到账单”；需要查看 [handled] / 各计数。
  bool get success => transactionIds.isNotEmpty;

  /// 本次至少处理了一笔有效账单（入库、候选或判重）。
  bool get handled =>
      transactionIds.isNotEmpty ||
      awaitingCount > 0 ||
      duplicateCount > 0 ||
      ignoredCount > 0 ||
      shadowCount > 0;

  /// 多笔
  bool get isMulti => transactionIds.length > 1;

  /// 入库总笔数
  int get savedCount => transactionIds.length;

  /// 全部账单的金额绝对值之和(用于通知/toast 汇总)
  double get totalAbsAmount =>
      savedBills.fold(0.0, (s, b) => s + (b.amount?.abs() ?? 0));

  /// 首笔账单(用于单笔场景展示)
  BillInfo? get firstBill => savedBills.isEmpty ? null : savedBills.first;

  /// 首笔交易 ID
  int? get firstTransactionId =>
      transactionIds.isEmpty ? null : transactionIds.first;

  /// 首个已存在的 canonical transaction ID。
  int? get firstDuplicateTransactionId =>
      duplicateTransactionIds.isEmpty ? null : duplicateTransactionIds.first;

  /// 失败结果工厂
  static const BookkeepingResult empty = BookkeepingResult();
}
