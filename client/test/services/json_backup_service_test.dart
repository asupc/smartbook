import 'dart:convert';

import 'package:smartbook/services/export/json_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// M5 JSON 结构化导出测试:结构键、条件字段省略、可回读(jsonDecode 往返)。
void main() {
  test('buildBackupJson:结构完整且可回读', () {
    final json = buildBackupJson(
      ledger: (id: 1, name: '生活账', currency: 'CNY'),
      accounts: [
        (id: 10, name: '招行卡', type: 'bank', currency: 'CNY'),
        (id: 11, name: '微信零钱', type: 'wechat', currency: 'CNY'),
      ],
      categories: [
        (id: 1, name: '餐饮', kind: 'expense', parentId: null, level: 1),
        (id: 5, name: '咖啡', kind: 'expense', parentId: 1, level: 2),
      ],
      transactions: [
        BackupTx(
          id: 100,
          type: 'expense',
          amount: -45.5,
          categoryId: 5,
          accountId: 11,
          happenedAt: DateTime(2026, 9, 2, 12, 30),
          note: '星巴克',
          tags: ['自动记账'],
          attachments: ['a1b2c.png'],
        ),
        BackupTx(
          id: 101,
          type: 'expense',
          amount: -200,
          happenedAt: DateTime(2026, 9, 1),
        ),
      ],
      exportedAt: '2026-09-02T12:00:00',
    );

    expect(json['format'], 'smartbook-backup');
    expect(json['version'], 1);
    expect(json['ledger']['name'], '生活账');
    expect(json['accounts'], hasLength(2));
    expect(json['categories'], hasLength(2));
    expect(json['transactions'], hasLength(2));

    final tx = json['transactions'][0] as Map<String, dynamic>;
    expect(tx['note'], '星巴克');
    expect(tx['tags'], ['自动记账']);
    expect(tx['attachments'], ['a1b2c.png']);
    expect(tx['happenedAt'], DateTime(2026, 9, 2, 12, 30).toIso8601String());

    // 空值字段省略(可回读的最小结构)
    final tx2 = json['transactions'][1] as Map<String, dynamic>;
    expect(tx2.containsKey('note'), isFalse);
    expect(tx2.containsKey('categoryId'), isFalse);
    expect(tx2.containsKey('accountId'), isFalse);

    // jsonEncode → jsonDecode 往返无损(结构可回读)
    final roundTrip =
        Map<String, dynamic>.from(jsonDecode(jsonEncode(json)) as Map);
    expect(roundTrip['format'], 'smartbook-backup');
    expect((roundTrip['transactions'] as List).length, 2);
  });
}
