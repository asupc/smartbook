import 'package:smartbook/services/billing/anomaly_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 异常检测(M3)纯数学测试:median / MAD / 判定阈值 / 防误报边界。
void main() {
  group('AnomalyDetector median/mad', () {
    test('中位数:奇数取中间', () {
      expect(AnomalyDetector.median([1, 3, 2]), 2);
    });

    test('中位数:偶数取两中位平均', () {
      expect(AnomalyDetector.median([1, 2, 3, 4]), 2.5);
    });

    test('空列表为 0', () {
      expect(AnomalyDetector.median([]), 0);
    });

    test('MAD:各元素与中位数绝对差的中位数', () {
      expect(AnomalyDetector.mad([1, 3, 5, 7, 9], 5), 2);
    });
  });

  group('AnomalyDetector.detect', () {
    /// 历史基线:med 50,mad 8;threshold = max(20, 50+3*8) = 74。
    /// 序列 [40,60,45,55,42,58,50,50,38,62]:排序后 med=50,
    /// 与中位数差 [10,10,5,5,8,8,0,0,12,12] → mad=8。
    List<double> history() => [40, 60, 45, 55, 42, 58, 50, 50, 38, 62];

    test('明显超额(90 >> 74)→ 判定异常并给出基线/幅度', () {
      final v = AnomalyDetector.detect(history: history(), current: 90);
      expect(v, isNotNull);
      expect(v!.median, 50);
      expect(v.excessRatio, closeTo((90 - 74) / 74, 1e-9));
      expect(v.ratio, closeTo(90 / 50, 1e-9));
    });

    test('未超阈值(70 < 74)→ 不报', () {
      expect(AnomalyDetector.detect(history: history(), current: 70), isNull);
    });

    test('历史样本不足 < 7 → 不报(冷启动)', () {
      expect(
        AnomalyDetector.detect(history: [50, 51, 49, 52, 50, 50], current: 99),
        isNull,
      );
    });

    test('基线过低(<15 元)→ 不报', () {
      final small = <double>[5, 6, 5, 7, 5, 6, 5, 6, 5, 7]; // med 5.5 < 15
      expect(AnomalyDetector.detect(history: small, current: 60), isNull);
    });

    test('基线完全一致(mad=0)但当日明显偏高 → 报', () {
      final flat = List.filled(10, 100.0); // med 100, mad 0
      final v = AnomalyDetector.detect(history: flat, current: 160);
      expect(v, isNotNull);
      expect(v!.median, 100);
      expect(v.ratio, closeTo(1.6, 1e-9));
    });

    test('空历史 → 不报', () {
      expect(AnomalyDetector.detect(history: const [], current: 999), isNull);
    });

    test('current 为 0 → 不报', () {
      expect(AnomalyDetector.detect(history: history(), current: 0), isNull);
    });
  });
}
