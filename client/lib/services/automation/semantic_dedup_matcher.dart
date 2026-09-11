import '../../ai/core/bill_info.dart';
import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import 'auto_book_event.dart';
import 'auto_book_event_store.dart';
import 'dedup_exempt_store.dart';

/// 与某一笔已有交易的相似度结果。
class SemanticDedupMatch {
  final int transactionId;
  final double score;
  final String reason;

  const SemanticDedupMatch({
    required this.transactionId,
    required this.score,
    required this.reason,
  });

  bool get isStrong => score >= SemanticDedupMatcher.strongThreshold;
  bool get isPossible => score >= SemanticDedupMatcher.possibleThreshold;

  /// 跨渠道强判重命中:同一笔支付被多个事件来源(短信/通知/页面/账单)
  /// 重复上报,合并由 A2 富化路径接管(后到的信息补进已有交易)。
  bool get isCrossChannel => reason.contains('cross_channel_strong');
}

/// 自动入口的交易级去重匹配器。
///
/// 「同一笔消费」的硬性定义:金额完全一致(无容差)且消费时间相差
/// 1 分钟以内——金额不同不可能是同一笔,时间差超过 1 分钟视为两笔独立消费。
/// 在硬闸门之内,时间精确到秒完全一致且秒值可信时直接强判重(自动通道
/// 对同一笔消费反复上报的指纹特征),商户/备注缺失或不一致也不再进待确认。
/// 其余情况商户/备注与币种只决定分数高低(能否达到强判自动合并),不放宽
/// 硬闸门。弱匹配只返回 possible,调用方必须把它放入待确认,不能静默丢弃。
///
/// 跨渠道强判重:硬闸门已过的前提下,若当前捕获的事件来源与已有交易的
/// 全部事件来源**都不同**,直接强判重。同一笔支付的 4 路上报(账单页/
/// 电商通知/银行通知/短信)商户名天然对不上(银行报收款方、电商报商户、
/// 账单报全称),商户一致性对跨渠道对是结构性失真的判据;而「两笔真实消费
/// 同分钟同金额到分、恰好被两个不同渠道捕获」的概率远低于重复上报。
/// 误合并兜底:决策日志 reason=cross_channel_strong 可回溯,撤销合并/
/// 豁免表照常生效。
class SemanticDedupMatcher {
  static const strongThreshold = 0.92;

  /// 疑似重复线:低于 strong 的相似对(如同金额同分钟但商户对不上)也要
  /// 进待确认让用户裁决,因此该线必须低于硬闸门通过后的最低分 0.65。
  static const possibleThreshold = 0.60;

  const SemanticDedupMatcher();

  /// externalId 维度的查重 key(与 semanticKey 的 external 分支同公式)。
  /// 单独抽出供查询侧复用 —— EventStore.findTransactionByExternalId 用它
  /// 点查 auto_book_event_items.semantic_key 索引,避免公式漂移。
  static String? externalKey(String? externalId, {String? currency}) {
    final external = _normalize(externalId);
    if (external == null) return null;
    return 'external:v1:${autoBookHash('${currency ?? ''}|$external')}';
  }

  /// 生成与来源无关的业务 key。存在 externalId 时优先使用；否则只在
  /// 商户/备注和时间等信息足够时生成，避免“空备注+同金额+同日”误合并。
  static String? semanticKey(BillInfo bill) {
    final external = externalKey(bill.externalId, currency: bill.currency);
    if (external != null) {
      return external;
    }

    final merchant = _normalize(bill.merchant) ?? _normalize(bill.note);
    final time = bill.time;
    final amount = bill.amount;
    if (merchant == null ||
        time == null ||
        amount == null ||
        amount.abs() <= 0) {
      return null;
    }
    final type = _typeValue(bill.type);
    final currency = (bill.currency ?? '').trim().toUpperCase();
    // 保留分钟而不是仅保留日期，允许同日多笔同金额交易共存。
    final minute = '${time.year.toString().padLeft(4, '0')}-'
        '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}T'
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    return 'semantic:v1:${autoBookHash('$type|${amount.abs().toStringAsFixed(2)}|$currency|$merchant|$minute')}';
  }

  /// 在本账本中找与 bill 同金额(完全相等)、时间相差 1 分钟以内的最高匹配项。
  /// 窗口收紧到硬闸门口径后,候选集就是「可能通过 _score 硬闸门」的那一批。
  ///
  /// [sourceKey] 当前捕获的事件来源键(AutoBookSourceValue.sourceKey 口径)。
  /// [transactionSourceKeys] 反查一笔交易被哪些事件来源记录过(事件表
  /// transactionId 关联);为 null 或返回空集 = 该交易无自动事件来源,
  /// 跨渠道强判重不生效,按原有打分口径。
  Future<SemanticDedupMatch?> findBest({
    required BaseRepository repository,
    required int ledgerId,
    required BillInfo bill,
    AutoBookEventStore? eventStore,
    String? sourceChannel,
    String? sourceKey,
    Future<Set<String>> Function(int transactionId)? transactionSourceKeys,
  }) async {
    final externalId = _normalize(bill.externalId);
    if (externalId != null && eventStore != null) {
      final transactionId = await eventStore.findTransactionByExternalId(
        externalId,
        ledgerId: ledgerId,
        sourceChannel: sourceChannel,
      );
      if (transactionId != null) {
        return SemanticDedupMatch(
          transactionId: transactionId,
          score: 1.0,
          reason: 'external_id_exact',
        );
      }
    }

    final amount = bill.amount;
    final time = bill.time;
    if (amount == null || amount.abs() <= 0 || time == null) return null;

    // 豁免表(P1-1):用户「仍记一笔」裁定过的(商户/备注关键词,金额段)
    // 不再参与判重 —— 同类误判不复发。命中即跳过该对(等价于把这对的
    // score 压到阈值之下)。豁免表是增强能力,读取失败照常判重不阻断。
    List<DedupExemptRule> exemptRules = const [];
    try {
      exemptRules = await DedupExemptStore().list();
    } catch (_) {}
    final billNoteNormalized =
        _normalize(bill.merchant) ?? _normalize(bill.note);

    // M3-2:判重只用得到纯 Transaction 行,过滤条件(账本 / 类型 / 时间窗 /
    // 金额区间)全部下推到 SQL。金额与时间窗和 _score 的硬闸门同源
    // (金额完全相等、时间 ±1 分钟),因此候选集就是「可能打出非 null 分数」
    // 的那批,匹配结果与全量扫描等价。
    final billAmount = amount.abs();
    final rows = await repository.getDedupCandidates(
      ledgerId: ledgerId,
      type: _typeValue(bill.type),
      start: time.subtract(const Duration(minutes: 1)),
      end: time.add(const Duration(minutes: 1)),
      minAmount: billAmount,
      maxAmount: billAmount,
    );
    SemanticDedupMatch? best;
    for (final tx in rows) {
      if (DedupExemptStore.isExempt(
        exemptRules,
        billAmount: amount,
        billNoteNormalized: billNoteNormalized,
        txAmount: tx.amount,
        txNoteNormalized: _normalize(tx.note),
      )) {
        continue;
      }
      final candidate = _score(bill, tx);
      if (candidate == null) continue;
      // 跨渠道强判重:硬闸门(同类型+金额全等+±1min)已过,且当前来源与
      // 该交易已有来源都不同时,直接按强匹配合并(见类注释)。反查失败/
      // 无来源信号不放宽也不收紧,按原打分继续。
      if (sourceKey != null && transactionSourceKeys != null) {
        try {
          final existing = await transactionSourceKeys(tx.id);
          if (existing.isNotEmpty && !existing.contains(sourceKey)) {
            best = SemanticDedupMatch(
              transactionId: tx.id,
              score: 1.0,
              reason:
                  '${candidate.reason},cross_channel_strong:${existing.length + 1}',
            );
            break;
          }
        } catch (_) {
          // 来源反查失败不阻断判重,退回语义打分。
        }
      }
      if (best == null || candidate.score > best.score) best = candidate;
    }
    return best;
  }

  /// 账单与一批账单(如待确认候选)之间是否存在秒级指纹完全命中:
  /// 同类型 + 金额完全一致 + 时间截断到秒一致 + 双方秒值可信 + 币种一致。
  /// 供自动入口在候选维度去重——同一笔消费的重复上报不再往待确认清单
  /// 堆第二条候选。
  static bool hasSecondExactDuplicate(BillInfo bill, Iterable<BillInfo> others) {
    final amount = bill.amount;
    final time = bill.time;
    if (amount == null || amount.abs() <= 0 || time == null) return false;
    final type = _typeValue(bill.type);
    final currency = bill.currency?.trim().toUpperCase();
    for (final other in others) {
      final otherAmount = other.amount;
      final otherTime = other.time;
      if (otherAmount == null ||
          otherAmount.abs() <= 0 ||
          otherTime == null ||
          other.ledgerId != bill.ledgerId ||
          _typeValue(other.type) != type ||
          otherAmount.abs() != amount.abs()) {
        continue;
      }
      if (currency != null) {
        final otherCurrency = other.currency?.trim().toUpperCase();
        if (otherCurrency != null && otherCurrency != currency) continue;
      }
      if (_truncateToSecond(otherTime) != _truncateToSecond(time)) continue;
      if (!_secondsTrustworthy(time, bill.timePrecision)) continue;
      if (!_secondsTrustworthy(otherTime, other.timePrecision)) continue;
      return true;
    }
    return false;
  }

  /// 相似 = 同一笔消费。两条硬闸门(不过即返回 null):
  /// 1. 金额完全一致(无容差)——金额不同绝不可能是重复消费;
  /// 2. 消费时间相差 1 分钟以内——同一笔支付的多通道重复上报几乎同时发生。
  /// 商户/备注与币种只在闸门之内决定分数高低(能否强判自动合并)。
  SemanticDedupMatch? _score(BillInfo bill, Transaction tx) {
    final expectedType = _typeValue(bill.type);
    if (expectedType != tx.type) return null;

    final billAmount = bill.amount!.abs();
    if (billAmount != tx.amount.abs()) return null;

    var score = 0.40;
    final reasons = <String>['amount_exact'];

    final currency = bill.currency?.trim().toUpperCase();
    final txCurrency = tx.currencyCode?.trim().toUpperCase();
    if (currency != null && txCurrency != null) {
      if (currency != txCurrency) return null;
      score += 0.15;
      reasons.add('currency');
    }

    final diff = bill.time!.difference(tx.happenedAt).abs();
    if (diff > const Duration(minutes: 1)) return null;
    score += 0.25;
    reasons.add('time_1m');

    // 秒级指纹:金额完全一致且消费时间精确到秒完全一致,且两边的秒值
    // 都可信时,直接强判重。这是自动通道对同一笔消费反复上报的确定性
    // 指纹,商户/备注对不上也不进待确认。秒值可信 = 账单侧显式标注
    // exact(或未标注但秒/毫秒位非零),交易侧落库时没有精度列,只用
    // 「秒/毫秒非零」启发式。比较按截断到整秒:Drift 以 epoch 秒存
    // DateTime,毫秒位落库即丢失,直接比 Duration.zero 永远不成立。
    // minute/date 精度的时间秒位是截断补零出来的,同日同金额的两笔真实
    // 消费会伪造成「秒级一致」,绝不能用它静默合并。
    final secondExact =
        _truncateToSecond(bill.time!) == _truncateToSecond(tx.happenedAt) &&
            _secondsTrustworthy(bill.time!, bill.timePrecision) &&
            _secondsTrustworthy(tx.happenedAt, null);
    if (secondExact) {
      return SemanticDedupMatch(
        transactionId: tx.id,
        score: 1.0,
        reason: 'amount_exact,time_second_exact',
      );
    }

    final billMerchant = _normalize(bill.merchant) ?? _normalize(bill.note);
    final txNote = _normalize(tx.note);
    final hasMerchantSignal = billMerchant != null && txNote != null;
    if (hasMerchantSignal && billMerchant == txNote) {
      score += 0.25;
      reasons.add('merchant_exact');
    } else if (hasMerchantSignal && _tokenOverlap(billMerchant, txNote)) {
      score += 0.12;
      reasons.add('merchant_overlap');
    }

    if (!hasMerchantSignal) {
      // 没有商户/备注时:金额+时间两条硬闸门已过,按疑似重复(possible)
      // 进待确认由用户裁决,但固定在 strong 阈值之下,绝不静默合并。
      score = 0.75;
      reasons.add('merchant_missing');
    }

    return SemanticDedupMatch(
      transactionId: tx.id,
      score: score.clamp(0.0, 1.0).toDouble(),
      reason: reasons.join(','),
    );
  }

  /// 时间秒值是否可信(非补零)。exact 精度直接可信;未标注精度时用
  /// 「秒或毫秒非零」启发式——补零时间(00 秒 000 毫秒)天然不可信。
  static bool _secondsTrustworthy(
    DateTime time,
    BillTimePrecision? precision,
  ) {
    switch (precision) {
      case BillTimePrecision.exact:
        return true;
      case BillTimePrecision.minute:
      case BillTimePrecision.date:
      case BillTimePrecision.inferred:
      case BillTimePrecision.unknown:
        return false;
      case null:
        return time.second != 0 || time.millisecond != 0;
    }
  }

  /// 截断到整秒(Drift 以 epoch 秒存 DateTime,毫秒落库即丢)。
  static DateTime _truncateToSecond(DateTime time) =>
      DateTime.fromMillisecondsSinceEpoch(
        time.millisecondsSinceEpoch ~/ 1000 * 1000,
      );

  static String _typeValue(BillType? type) => switch (type) {
        BillType.income => 'income',
        BillType.transfer => 'transfer',
        BillType.expense || null => 'expense',
      };

  static String? _normalize(String? value) {
    if (value == null) return null;
    final normalized = normalizeAutoBookText(value)
        .replaceAll(RegExp(r'商户|有限公司|有限责任公司|支付|收款'), '')
        .trim();
    return normalized.isEmpty ? null : normalized;
  }

  /// 提取豁免规则关键字(P1-1):与判重同一套规范化口径,保证「仍记一笔」
  /// 时落的关键字能命中后续判重的比对文本。
  static String? exemptKeyword(BillInfo bill) =>
      _normalize(bill.merchant) ?? _normalize(bill.note);

  static bool _tokenOverlap(String a, String b) {
    final left =
        a.split(RegExp(r'[\s\-_]+')).where((e) => e.isNotEmpty).toSet();
    final right =
        b.split(RegExp(r'[\s\-_]+')).where((e) => e.isNotEmpty).toSet();
    if (left.isEmpty || right.isEmpty) return false;
    return left.intersection(right).isNotEmpty;
  }
}
