import '../../ai/core/bill_info.dart';
import '../../data/repositories/base_repository.dart';
import 'semantic_dedup_matcher.dart';

/// 手动记账的软重复提示查询。
///
/// 只返回带有商户/备注等有效信号的 possible match；调用方必须让用户
/// 明确选择继续，绝不能把手动输入静默拦截。
class ManualDuplicateChecker {
  static const _matcher = SemanticDedupMatcher();

  static Future<SemanticDedupMatch?> find({
    required BaseRepository repository,
    required int ledgerId,
    required double amount,
    required BillType type,
    required DateTime time,
    String? note,
    String? currency,
  }) {
    return _matcher.findBest(
      repository: repository,
      ledgerId: ledgerId,
      bill: BillInfo(
        amount: type == BillType.expense ? -amount.abs() : amount.abs(),
        time: time,
        note: note,
        merchant: note,
        type: type,
        currency: currency,
        confidenceProvided: true,
      ),
    );
  }
}
