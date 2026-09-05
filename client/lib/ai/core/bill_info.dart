import '../../utils/currency_aliases.dart';

/// 账单类型
///
/// AI 多模态记账底座 · 数据模型。底座 (Layer 1) 把 text/image/audio 输入
/// 转换成 `List<BillInfo>` 后,应用层 (Layer 2 `AiBookkeeper`) 逐笔落库。
/// 字段全部可空,反映 AI 提取的实际不确定性;校验/兜底统一在
/// `JsonResponseParser._sanitize` 里完成。
enum BillType {
  /// 收入
  income,

  /// 支出
  expense,

  /// 转账
  transfer,
}

/// 账单证据的业务语义。
///
/// [BillType] 描述最终账务方向；[BillEventKind] 描述来源内容是什么。两者
/// 必须分开，否则「本期账单」「充值」「退款」都可能被模型粗略写成 expense。
enum BillEventKind {
  purchase,
  income,
  refund,
  transfer,
  repayment,
  recharge,
  fee,
  statement,
  balanceReminder,
  pendingOrder,
  unknown,
}

/// 来源证据中的结算状态。
enum BillSettlementStatus {
  settled,
  pending,
  failed,
  cancelled,
  reversed,
  summary,
  unknown,
}

BillEventKind? billEventKindFromValue(dynamic value) {
  if (value == null) return null;
  final raw = value.toString().trim().toLowerCase();
  if (raw.isEmpty) return null;
  if (raw.contains('purchase') || raw.contains('消费') || raw.contains('购买')) {
    return BillEventKind.purchase;
  }
  if (raw.contains('income') || raw.contains('收入')) return BillEventKind.income;
  if (raw.contains('refund') || raw.contains('退款') || raw.contains('退费')) {
    return BillEventKind.refund;
  }
  if (raw.contains('repayment') || raw.contains('还款')) {
    return BillEventKind.repayment;
  }
  if (raw.contains('recharge') || raw.contains('充值')) {
    return BillEventKind.recharge;
  }
  if (raw.contains('transfer') || raw.contains('转账') || raw.contains('轉帳')) {
    return BillEventKind.transfer;
  }
  if (raw.contains('fee') || raw.contains('手续费') || raw.contains('利息')) {
    return BillEventKind.fee;
  }
  if (raw.contains('statement') ||
      raw.contains('账单汇总') ||
      raw.contains('本期账单')) {
    return BillEventKind.statement;
  }
  if (raw.contains('balance') || raw.contains('余额') || raw.contains('额度')) {
    return BillEventKind.balanceReminder;
  }
  if (raw.contains('pending') || raw.contains('待支付') || raw.contains('待付款')) {
    return BillEventKind.pendingOrder;
  }
  if (raw == 'unknown' || raw.contains('未知')) return BillEventKind.unknown;
  return null;
}

enum BillTimePrecision {
  exact,
  minute,
  date,
  inferred,
  unknown,
}

BillTimePrecision? billTimePrecisionFromValue(dynamic value) {
  if (value == null) return null;
  final raw = value.toString().trim().toLowerCase();
  if (raw.isEmpty) return null;
  if (raw.contains('exact') || raw.contains('秒') || raw.contains('精确')) {
    return BillTimePrecision.exact;
  }
  if (raw.contains('minute') || raw.contains('分钟')) {
    return BillTimePrecision.minute;
  }
  if (raw == 'date' || raw.contains('日期') || raw.contains('仅日')) {
    return BillTimePrecision.date;
  }
  if (raw.contains('inferred') || raw.contains('推断') || raw.contains('估算')) {
    return BillTimePrecision.inferred;
  }
  if (raw == 'unknown' || raw.contains('未知')) return BillTimePrecision.unknown;
  return null;
}

BillSettlementStatus? billSettlementStatusFromValue(dynamic value) {
  if (value == null) return null;
  final raw = value.toString().trim().toLowerCase();
  if (raw.isEmpty) return null;
  // 失败/取消/冲正优先于“已支付/成功”等正向子串，避免
  // “已支付失败”“支付成功后冲正”被误放行。汇总也不能被“完成”覆盖。
  if (raw.contains('failed') || raw.contains('失败')) {
    return BillSettlementStatus.failed;
  }
  if (raw.contains('cancel') || raw.contains('关闭') || raw.contains('取消')) {
    return BillSettlementStatus.cancelled;
  }
  if (raw.contains('reversed') || raw.contains('冲正') || raw.contains('撤销')) {
    return BillSettlementStatus.reversed;
  }
  if (raw.contains('summary') || raw.contains('汇总') || raw.contains('本期账单')) {
    return BillSettlementStatus.summary;
  }
  if (raw.contains('pending') ||
      raw.contains('待支付') ||
      raw.contains('待付款') ||
      raw.contains('处理中')) {
    return BillSettlementStatus.pending;
  }
  if (raw.contains('settled') ||
      raw.contains('success') ||
      raw.contains('完成') ||
      raw.contains('成功') ||
      raw.contains('已支付') ||
      raw.contains('已付款')) {
    return BillSettlementStatus.settled;
  }
  if (raw == 'unknown' || raw.contains('未知')) {
    return BillSettlementStatus.unknown;
  }
  return null;
}

/// 账单信息
class BillInfo {
  /// 金额(支出为负、收入为正、转账为正)
  final double? amount;

  /// 发生时间
  final DateTime? time;

  /// 备注(注意 ≤15 字,prompt 已要求 AI 自行精简长标题)
  final String? note;

  /// 分类名称(从用户分类列表中匹配,或 AI 自行命名)
  final String? category;

  /// 收入/支出/转账
  final BillType? type;

  /// 支付账户(收入/支出场景)
  final String? account;

  /// 转出账户(转账场景)
  final String? fromAccount;

  /// 转入账户(转账场景)
  final String? toAccount;

  /// 标签列表
  final List<String>? tags;

  /// 交易币种(ISO 4217 大写)。`null` = AI 未识别 → 落库时回落账本本位币
  /// (.docs/multi-currency-ai A1)。解析/兜底见 [_parseCurrency]。
  final String? currency;

  /// 账本 ID(由应用层注入,AI 不感知)
  final int? ledgerId;

  /// 置信度 0.0 - 1.0。
  /// 缺省 1.0 语义:"AI/规则未给出置信度时按高置信处理"(旧模型不输出
  /// confidence 时保持直入账行为;低置信分流由 M2 规则引擎按阈值判定)。
  final double confidence;

  /// 来源内容语义；旧模型未返回时为 null，由自动策略保守推断。
  final BillEventKind? eventKind;

  /// 是否已结算；旧模型未返回时为 null。
  final BillSettlementStatus? settlementStatus;

  /// 支付平台订单号/交易号/流水号。
  final String? externalId;

  /// 规范化商户名称（AI 可从长文本中提取）。
  final String? merchant;

  /// 卡号后四位（可选，仅用于本地匹配，不写原始敏感内容）。
  final String? cardLast4;

  /// 模型是否显式提供 confidence。自动路径不能把缺失值无条件当成高置信。
  final bool confidenceProvided;

  /// 时间是否由 parser 兜底/模型推断，而不是来源明确给出。
  final bool timeInferred;

  /// 来源时间精度，自动路径用于判断时间是否足以做强去重。
  final BillTimePrecision? timePrecision;

  const BillInfo({
    this.amount,
    this.time,
    this.note,
    this.category,
    this.type,
    this.account,
    this.fromAccount,
    this.toAccount,
    this.tags,
    this.currency,
    this.ledgerId,
    this.confidence = 1.0,
    this.eventKind,
    this.settlementStatus,
    this.externalId,
    this.merchant,
    this.cardLast4,
    this.confidenceProvided = true,
    this.timeInferred = false,
    this.timePrecision,
  });

  /// 信息完整度:amount + time 都有。
  ///
  /// 注意:经过 [JsonResponseParser._sanitize] 之后,time 字段一定非空
  /// (parser 内部已 fallback 到 `DateTime.now()`),所以此 getter 主要用于
  /// 测试或边界排查,业务代码不需要再判 `isComplete`。
  bool get isComplete => amount != null && time != null;

  /// 派生新实例,缺省沿用原值。
  BillInfo copyWith({
    double? amount,
    DateTime? time,
    String? note,
    String? category,
    BillType? type,
    String? account,
    String? fromAccount,
    String? toAccount,
    List<String>? tags,
    String? currency,
    int? ledgerId,
    double? confidence,
    BillEventKind? eventKind,
    BillSettlementStatus? settlementStatus,
    String? externalId,
    String? merchant,
    String? cardLast4,
    bool? confidenceProvided,
    bool? timeInferred,
    BillTimePrecision? timePrecision,
  }) {
    return BillInfo(
      amount: amount ?? this.amount,
      time: time ?? this.time,
      note: note ?? this.note,
      category: category ?? this.category,
      type: type ?? this.type,
      account: account ?? this.account,
      fromAccount: fromAccount ?? this.fromAccount,
      toAccount: toAccount ?? this.toAccount,
      tags: tags ?? this.tags,
      currency: currency ?? this.currency,
      ledgerId: ledgerId ?? this.ledgerId,
      confidence: confidence ?? this.confidence,
      eventKind: eventKind ?? this.eventKind,
      settlementStatus: settlementStatus ?? this.settlementStatus,
      externalId: externalId ?? this.externalId,
      merchant: merchant ?? this.merchant,
      cardLast4: cardLast4 ?? this.cardLast4,
      confidenceProvided: confidenceProvided ?? this.confidenceProvided,
      timeInferred: timeInferred ?? this.timeInferred,
      timePrecision: timePrecision ?? this.timePrecision,
    );
  }

  /// 从 AI 返回的 JSON 对象构造。
  ///
  /// 容错:
  /// - `amount` / `confidence` 兼容字符串数值(部分模型吐 `"-800.00"`,
  ///   甚至带千分位 `"1,234.50"`),无法解析时按缺失处理
  /// - `note` 兼容老字段名 `merchant`
  /// - `from_account` / `to_account` 兼容 camelCase
  /// - `tag` / `tags` 兼容单字符串和字符串数组
  /// - `time` 字符串内嵌空格会自动 strip 再 parse(应对 AI 偶发吐
  ///   `"2222 2-1-26T18:08:00"` 这类格式),并支持中文格式
  ///   `"2026年5月29日 23:35:16"`;仍不可解析时返回 null,
  ///   由 [JsonResponseParser._sanitize] 兜底成当前时间。
  factory BillInfo.fromJson(Map<String, dynamic> json) {
    return BillInfo(
      amount: _parseDouble(json['amount']),
      time: _parseTime(json['time']),
      note: json['note'] as String? ?? json['merchant'] as String?,
      merchant: json['merchant'] as String? ??
          json['merchant_name'] as String? ??
          json['merchantName'] as String?,
      category: json['category'] as String?,
      type: _parseBillType(json['type']),
      account: json['account'] as String?,
      fromAccount:
          json['from_account'] as String? ?? json['fromAccount'] as String?,
      toAccount: json['to_account'] as String? ?? json['toAccount'] as String?,
      tags: _parseTags(json['tags'] ?? json['tag']),
      currency: _parseCurrency(
          json['currency'] ?? json['currency_code'] ?? json['currencyCode']),
      ledgerId: json['ledgerId'] as int?,
      // confidence 缺失(旧模型)视同高置信,避免全量进待确认
      confidence: _parseDouble(json['confidence']) ?? 1.0,
      eventKind: billEventKindFromValue(
          json['event_kind'] ?? json['eventKind'] ?? json['kind']),
      settlementStatus: billSettlementStatusFromValue(
          json['settlement_status'] ??
              json['settlementStatus'] ??
              json['status']),
      externalId: _firstString([
        json['external_id'],
        json['externalId'],
        json['transaction_id'],
        json['transactionId'],
        json['order_id'],
        json['orderId'],
      ]),
      cardLast4: _firstString([
        json['card_last4'],
        json['cardLast4'],
        json['card_last_four'],
      ]),
      confidenceProvided:
          json.containsKey('confidence') && json['confidence'] != null,
      timeInferred: json['time_inferred'] == true ||
          json['timeInferred'] == true ||
          json['time_precision']?.toString().toLowerCase() == 'inferred',
      timePrecision: billTimePrecisionFromValue(
            json['time_precision'] ?? json['timePrecision'],
          ) ??
          ((json['time_inferred'] == true || json['timeInferred'] == true)
              ? BillTimePrecision.inferred
              : null),
    );
  }

  Map<String, dynamic> toJson() => {
        'amount': amount,
        'time': time?.toIso8601String(),
        'note': note,
        'category': category,
        'type': type?.name,
        'account': account,
        'from_account': fromAccount,
        'to_account': toAccount,
        'tags': tags,
        'currency': currency,
        'ledgerId': ledgerId,
        'confidence': confidence,
        'event_kind': eventKind?.name,
        'settlement_status': settlementStatus?.name,
        'external_id': externalId,
        'merchant': merchant,
        'card_last4': cardLast4,
        'confidence_provided': confidenceProvided,
        'time_inferred': timeInferred,
        'time_precision': timePrecision?.name,
      };

  /// 解析数值字段,兼容 `num` 与字符串(部分模型把 amount 输出成 `"-800.00"`,
  /// 甚至带千分位 `"1,234.50"`)。无法解析返回 null,交由上层兜底/丢弃。
  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) {
      // 去掉千分位逗号(半/全角)与空白;负号、小数点保留交给 tryParse。
      final cleaned = value.replaceAll(RegExp(r'[,，\s]'), '');
      if (cleaned.isEmpty) return null;
      return double.tryParse(cleaned);
    }
    return null;
  }

  static DateTime? _parseTime(dynamic value) {
    if (value is! String) return null;
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct;
    // AI 偶发会在 ISO8601 里夹空格(如 `"2222 2-1-26T18:08:00"`),strip 重试
    final stripped = DateTime.tryParse(raw.replaceAll(RegExp(r'\s+'), ''));
    if (stripped != null) return stripped;
    // 本地化 / 中文格式(如 `"2026年5月29日 23:35:16"`):正则提取年月日时分秒。
    final m = RegExp(
      r'(\d{4})\s*[年./-]\s*(\d{1,2})\s*[月./-]\s*(\d{1,2})\s*日?'
      r'(?:[\sT]+(\d{1,2})\s*[:时点]\s*(\d{1,2})(?:\s*[:分]\s*(\d{1,2}))?)?',
    ).firstMatch(raw);
    if (m == null) return null;
    int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
    final month = g(2);
    final day = g(3);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(g(1), month, day, g(4), g(5), g(6));
  }

  /// 币种解析(.docs/multi-currency-ai A4):ISO 码直通 → 口语/符号别名兜底。
  ///
  /// 无法唯一确定(未知码、歧义符号 `$`/`¥` 无上下文)一律返回 null 按缺失
  /// 处理,落库时回落账本本位币 —— **绝不猜**,记错币种比不识别代价大得多。
  /// 这里拿不到账本/账户上下文,所以不传 `disambiguateWith`;需要消歧的场景
  /// 由 [BillCreationService] 在有账本上下文时再判。
  static String? _parseCurrency(dynamic value) {
    if (value is! String) return null;
    return currencyCodeFromAlias(value);
  }

  static String? _firstString(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static BillType? _parseBillType(dynamic value) {
    if (value == null) return null;
    final str = value.toString().toLowerCase();
    if (str.contains('income') || str == '收入') return BillType.income;
    if (str.contains('expense') || str == '支出') return BillType.expense;
    if (str.contains('transfer') || str == '转账' || str == '轉帳') {
      return BillType.transfer;
    }
    return null;
  }

  static List<String>? _parseTags(dynamic value) {
    if (value == null) return null;
    final tags = <String>[];
    if (value is String) {
      tags.addAll(value
          .split(RegExp(r'[,\n，、;；|]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty));
    } else if (value is List) {
      tags.addAll(value
          .map((item) => item.toString().trim())
          .where((s) => s.isNotEmpty));
    }
    return tags.isEmpty ? null : tags;
  }

  @override
  String toString() {
    return 'BillInfo(amount: $amount, time: $time, note: $note, category: $category, '
        'type: $type, account: $account, fromAccount: $fromAccount, '
        'toAccount: $toAccount, tags: $tags, currency: $currency, '
        'eventKind: $eventKind, settlementStatus: $settlementStatus)';
  }
}
