import '../../ai/core/bill_info.dart';
import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import 'auto_book_event.dart';
import 'auto_book_event_store.dart';

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
}

/// 自动入口的交易级去重匹配器。
///
/// 这是“证据是否指向同一交易”的业务规则，不负责原始事件去重。弱匹配
/// 只返回 possible，调用方必须把它放入待确认，不能静默丢弃。
class SemanticDedupMatcher {
  static const strongThreshold = 0.92;
  static const possibleThreshold = 0.72;

  const SemanticDedupMatcher();

  /// 生成与来源无关的业务 key。存在 externalId 时优先使用；否则只在
  /// 商户/备注和时间等信息足够时生成，避免“空备注+同金额+同日”误合并。
  static String? semanticKey(BillInfo bill) {
    final external = _normalize(bill.externalId);
    if (external != null) {
      return 'external:v1:${autoBookHash('${bill.currency ?? ''}|$external')}';
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

  /// 从本账本近 90 天交易中找最高匹配项。
  Future<SemanticDedupMatch?> findBest({
    required BaseRepository repository,
    required int ledgerId,
    required BillInfo bill,
    AutoBookEventStore? eventStore,
    String? sourceChannel,
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

    final rows = await repository.getTransactionsByDateRange(
      ledgerId: ledgerId,
      startDate: time.subtract(const Duration(days: 90)),
      endDate: time.add(const Duration(days: 2)),
    );
    SemanticDedupMatch? best;
    for (final row in rows) {
      final candidate = _score(bill, row.t);
      if (candidate == null) continue;
      if (best == null || candidate.score > best.score) best = candidate;
    }
    return best;
  }

  SemanticDedupMatch? _score(BillInfo bill, Transaction tx) {
    final expectedType = _typeValue(bill.type);
    if (expectedType != tx.type) return null;

    final billAmount = bill.amount!.abs();
    final amountDiff = (billAmount - tx.amount.abs()).abs();
    final amountTolerance = (billAmount * 0.01).clamp(0.01, 10.0).toDouble();
    if (amountDiff > amountTolerance) return null;

    var score = 0.0;
    final reasons = <String>[];
    if (amountDiff <= 0.01) {
      score += 0.40;
      reasons.add('amount_exact');
    } else {
      score += 0.22;
      reasons.add('amount_close');
    }

    final currency = bill.currency?.trim().toUpperCase();
    final txCurrency = tx.currencyCode?.trim().toUpperCase();
    if (currency != null && txCurrency != null) {
      if (currency != txCurrency) return null;
      score += 0.15;
      reasons.add('currency');
    }

    final diff = bill.time!.difference(tx.happenedAt).abs();
    if (diff <= const Duration(minutes: 5)) {
      score += 0.25;
      reasons.add('time_5m');
    } else if (diff <= const Duration(hours: 24)) {
      score += 0.14;
      reasons.add('time_24h');
    } else if (diff <= const Duration(days: 3)) {
      score += 0.05;
      reasons.add('time_3d');
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
      // 没有商户/备注时，金额+时间最多只能作为候选，绝不强判重复。
      score = score.clamp(0.0, 0.68).toDouble();
      reasons.add('merchant_missing');
    }

    return SemanticDedupMatch(
      transactionId: tx.id,
      score: score.clamp(0.0, 1.0).toDouble(),
      reason: reasons.join(','),
    );
  }

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

  static bool _tokenOverlap(String a, String b) {
    final left =
        a.split(RegExp(r'[\s\-_]+')).where((e) => e.isNotEmpty).toSet();
    final right =
        b.split(RegExp(r'[\s\-_]+')).where((e) => e.isNotEmpty).toSet();
    if (left.isEmpty || right.isEmpty) return false;
    return left.intersection(right).isNotEmpty;
  }
}
