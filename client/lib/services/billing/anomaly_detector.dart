import 'dart:math' as math;

/// 异常消费检测(自动记账 M3,文档 plan §M3 任务 2)。
///
/// 检测器本身不关心数据从哪来 —— 上层把「历史基线序列」聚合好传进来,
/// 这里是纯数学判定:中位数 + MAD(绝对中位差)判离群点,并生成
/// 解释性文案所需的数值(当前值 / 基线 / 幅度)。
///
/// 防误报(文档:冷启动历史数据不足时不误报):
/// - 历史样本不足 [minSamples] 个 → 不判定(返回 null);
/// - 基线中位数低于 [minBaseline](如日均 10 元)→ 不判定,无统计意义;
/// - 判定阈值取下限 [minThreshold]:即便 median + k*mad 很小,
///   当前值也要超过 ≥20 元的绝对差距才算异常,避免噪声基数过度敏感。
class AnomalyDetector {
  /// 历史基线最少样本数(不足不报)。
  static const int minSamples = 7;

  /// 离群判定系数: |x - median| >= k * MAD。
  static const double kMadd = 3.0;

  /// 最小判定基线差:D 档幅度过小时一律不报(如 median 5 元时 ±5 元不算异常)。
  static const double minThreshold = 20.0;
  static const double minBaseline = 15.0;

  /// 中位数(奇数取中间,偶数取两中位平均)。
  static double median(List<double> xs) {
    if (xs.isEmpty) return 0;
    final sorted = [...xs]..sort();
    final n = sorted.length;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// MAD:各元素与中位数绝对差的单位数。
  static double mad(List<double> xs, double med) {
    return median(xs.map((x) => (x - med).abs()).toList());
  }

  /// 判定当前值是否相对历史显著异常。
  ///
  /// [history] 历史基线(如近 30 天逐日消费),[current] 当前累计值;
  /// [minSamples] 允许按窗口调整(日 7 / 周 5 / 月 3 / 分类 5)。
  /// 返回 [AnomalyVerdict];数据不足或基线过低返回 null(不报)。
  static AnomalyVerdict? detect({
    required List<double> history,
    required double current,
    int minSamples = AnomalyDetector.minSamples,
  }) {
    if (history.length < minSamples) return null;
    final med = median(history);
    // 基线本身过低(阈值下界 15 元)时无统计意义,不报
    if (med < minBaseline) return null;
    final d = mad(history, med);
    final threshold = math.max(minThreshold, med + kMadd * d);
    if (current <= threshold) return null;
    return AnomalyVerdict(
      median: med,
      mad: d,
      threshold: threshold,
      current: current,
      ratio: current / med,
      excessRatio: (current - threshold) / threshold,
    );
  }
}

/// 一次判定的完整结果,供 UI/提醒文案使用。
class AnomalyVerdict {
  final double median; // 基线(历史中位数)
  final double mad; // 波动幅度
  final double threshold; // 判定阈值 median + k*mad(含下限)
  final double current; // 当前值
  final double ratio; // 当前值 / 基线
  final double excessRatio; // 超出阈值比例

  const AnomalyVerdict({
    required this.median,
    required this.mad,
    required this.threshold,
    required this.current,
    required this.ratio,
    required this.excessRatio,
  });
}
