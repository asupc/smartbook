// EntitySerializer 纯函数级对抗性测试。
//
// 攻击面:把"不可能的输入"直接喂给序列化层(绕过 UI 校验),看 payload 是否
// 被毒化。因为 EntitySerializer 是纯静态类,不需要 db/engine。
//
// 覆盖:serializeTransaction(金额 NaN/Infinity/负数/极大、时区幂等、note
// emoji/超长、空 syncId)、serializeCategory(level 越界、parentSyncId 悬空)、
// serializeExchangeRateOverride(rate 0/负/NaN、updatedAt null)、
// serializeAccount / Tag / Budget / Ledger / AccountAdjustment 的边界、
// toJsonString / fromJsonString 的非法输入。
//
// 源码:`lib/cloud/sync/entity_serializer.dart`

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/cloud/sync/entity_serializer.dart';
import 'package:smartbook/data/db.dart';

Transaction tx({
  int id = 1,
  int ledgerId = 1,
  String type = 'expense',
  double amount = 12.5,
  DateTime? happenedAt,
  String? note,
  String? syncId = 'tx-1',
  String? currencyCode,
  double? nativeAmount,
  bool excludeFromStats = false,
  bool excludeFromBudget = false,
}) {
  return Transaction(
    id: id,
    ledgerId: ledgerId,
    type: type,
    amount: amount,
    happenedAt: happenedAt ?? DateTime(2026, 5, 1, 10, 0),
    note: note,
    syncId: syncId,
    excludeFromStats: excludeFromStats,
    excludeFromBudget: excludeFromBudget,
    currencyCode: currencyCode,
    nativeAmount: nativeAmount,
  );
}

Transaction txWithHappenedAt(DateTime at) => tx(happenedAt: at);

Category cat({
  int id = 1,
  String name = 'Food',
  String kind = 'expense',
  int level = 1,
  int sortOrder = 0,
  int? parentId,
  String? syncId = 'cat-1',
  String iconType = 'material',
  String? customIconPath,
}) {
  return Category(
    id: id,
    name: name,
    kind: kind,
    level: level,
    sortOrder: sortOrder,
    parentId: parentId,
    syncId: syncId,
    iconType: iconType,
    customIconPath: customIconPath,
  );
}

Ledger ledger({
  int id = 1,
  String name = 'L',
  String currency = 'CNY',
  String? syncId = 'l1',
  int monthStartDay = 1,
}) {
  return Ledger(
    id: id,
    name: name,
    currency: currency,
    type: 'personal',
    createdAt: DateTime(2026),
    syncId: syncId,
    myRole: 'owner',
    memberCount: 1,
    isShared: false,
    monthStartDay: monthStartDay,
  );
}

Budget budget({
  int id = 1,
  String? syncId = 'b1',
  String type = 'total',
  double amount = 100.0,
}) {
  return Budget(
    id: id,
    syncId: syncId,
    ledgerId: 1,
    type: type,
    amount: amount,
    period: 'monthly',
    startDay: 1,
    enabled: true,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

Tag tag({int id = 1, String name = '', String? syncId = 't1'}) {
  return Tag(
    id: id,
    name: name,
    sortOrder: 0,
    createdAt: DateTime(2026),
    syncId: syncId,
  );
}

Account account({
  int id = 1,
  String name = 'A',
  double initialBalance = 0.0,
  String? syncId = 'a1',
}) {
  return Account(
    id: id,
    ledgerId: 1,
    name: name,
    type: 'cash',
    currency: 'CNY',
    initialBalance: initialBalance,
    sortOrder: 0,
    hidden: false,
    syncId: syncId,
  );
}

AccountAdjustment adjustment({
  int id = 1,
  int accountId = 5,
  double amount = 100.0,
  String? syncId = 'adj-1',
}) {
  return AccountAdjustment(
    id: id,
    syncId: syncId,
    ledgerId: 1,
    accountId: accountId,
    amount: amount,
    happenedAt: DateTime(2026, 5, 1),
    createdAt: DateTime(2026, 5, 1),
    updatedAt: DateTime(2026, 5, 1),
  );
}

ExchangeRateOverride rateOverride({
  int id = 1,
  String base = 'CNY',
  String quote = 'USD',
  String rate = '7.1',
  String? syncId = 'ero-1',
  DateTime? updatedAt,
}) {
  return ExchangeRateOverride(
    id: id,
    baseCurrency: base,
    quoteCurrency: quote,
    rate: rate,
    syncId: syncId,
    updatedAt: updatedAt,
  );
}

void main() {
  // ==================================================================
  group('serializeTransaction 金额边界', () {
    test('ADVERSE FINDING: amount=Infinity → payload 含非有限数值,jsonEncode 抛错',
        () {
      // ADVERSE FINDING(高):serializeTransaction 对 amount 不做有限性校验,
      // 直接把 double.infinity 写进 payload。EntitySerializer.toJsonString
      // 走 jsonEncode → `JsonUnsupportedObjectError`。
      //
      // 可达性:server pull 的 payload 由 `(payload['amount'] as num?)
      // ?.toDouble()` 解析,而 JSON 字面量 `1e400` 在 dart:convert 里解出的
      // 就是 `double.infinity`(已实测)。apply 直接把它写进 transactions.amount
      // (SQLite REAL 允许 Infinity)。此后该行任何 push 都会在序列化后
      // jsonEncode 阶段抛错 —— 一条远端脏数据可以永久毒化本设备的整个 push
      // 批次(pushChanges 之前的 buildSyncChange 就抛,整批不发)。
      final payload = EntitySerializer.serializeTransaction(
          tx(amount: double.infinity));

      expect(payload['amount'], double.infinity,
          reason: 'ADVERSE FINDING: Infinity 被原样写进 payload,无 isFinite 守卫');
      expect(() => EntitySerializer.toJsonString(payload),
          throwsA(isA<JsonUnsupportedObjectError>()),
          reason: 'ADVERSE FINDING: payload 无法编码 → push 整批失败');
    });

    test('ADVERSE FINDING: payload {amount: Infinity} 无法编码,毒化整个 push 批',
        () {
      // 同上但强调"批"效应:一个坏实体让同批 N 条 change 全部发不出去。
      final good = EntitySerializer.serializeTransaction(tx(syncId: 'ok'));
      final bad =
          EntitySerializer.serializeTransaction(tx(syncId: 'bad', amount: double.infinity));
      final batch = [good, bad];

      expect(
        () => jsonEncode(batch),
        throwsA(isA<JsonUnsupportedObjectError>()),
        reason: 'ADVERSE FINDING: 同批一条坏 amount → 整批 jsonEncode 失败'
            '(PushChanges 的 body 构造在 engine 之外,engine 无法逐条隔离)',
      );
    });

    test('ADVERSE: amount=NaN 无法编码(同样毒化批次)', () {
      final payload = EntitySerializer.serializeTransaction(tx(amount: double.nan));
      expect(() => EntitySerializer.toJsonString(payload),
          throwsA(isA<JsonUnsupportedObjectError>()));
    });

    test('负数 amount 原样进 payload(合法:退款 / 调整)', () {
      final payload = EntitySerializer.serializeTransaction(tx(amount: -88.5));
      expect(payload['amount'], -88.5,
          reason: '负数金额是合法语义(退款),serializer 不做绝对值化');
    });

    test('极大 amount(1e308)可编码', () {
      final payload =
          EntitySerializer.serializeTransaction(tx(amount: 1e308));
      expect(payload['amount'], 1e308);
      expect(() => EntitySerializer.toJsonString(payload), returnsNormally,
          reason: '1e308 仍是有限 double,可编码');
    });

    test('ADVERSE: 超长数字串解析溢出 → Infinity(SQLite TEXT→REAL 转换路径)',
        () {
      // 若某处把用户输入的字符串直接 `double.tryParse`,超出 double 范围的
      // 数字会得到 Infinity 而不是 null。验证该语言级行为,作为上面
      // "Infinity 从哪来"的可达性证据。
      final huge = double.tryParse('1${'0' * 400}');
      expect(huge, double.infinity,
          reason: 'ADVERSE: tryParse 不返 null 而是 Infinity —— 校验必须用 isFinite');
    });

    test('amount=0 合法', () {
      final payload = EntitySerializer.serializeTransaction(tx(amount: 0.0));
      expect(payload['amount'], 0.0);
    });

    test('amount=-0.0 保留符号(编码为 -0.0)', () {
      final payload = EntitySerializer.serializeTransaction(tx(amount: -0.0));
      expect((payload['amount'] as double).isNegative, isTrue,
          reason: 'HARDENING: -0.0 会被 JSON 编码为 -0.0,server/对端解析后仍是 -0.0');
    });
  });

  // ==================================================================
  group('serializeTransaction happenedAt / 时区', () {
    test('happenedAt 转 UTC 序列化,往返幂等', () {
      final local = DateTime(2026, 5, 1, 10, 30, 45);
      final p1 = EntitySerializer.serializeTransaction(tx(happenedAt: local));
      final s1 = p1['happenedAt'] as String;
      expect(s1.endsWith('Z'), isTrue, reason: '必须统一 UTC ISO8601');

      final reparsed = DateTime.parse(s1);
      // 再次序列化同一时刻
      final p2 = EntitySerializer.serializeTransaction(
          tx(happenedAt: reparsed.toLocal()));
      expect(p2['happenedAt'], s1, reason: 'utc 转换幂等(同一时刻 → 同一字符串)');
    });

    test('已经是 UTC 的 happenedAt 不重复偏移', () {
      final utc = DateTime.utc(2026, 5, 1, 2, 30, 45);
      final p = EntitySerializer.serializeTransaction(tx(happenedAt: utc));
      expect(p['happenedAt'], '2026-05-01T02:30:45.000Z');
    });

    test('HARDENING: 毫秒被保留在 ISO 字符串里', () {
      final withMs = DateTime(2026, 5, 1, 10, 0, 0, 123);
      final p = EntitySerializer.serializeTransaction(tx(happenedAt: withMs));
      expect(p['happenedAt'], contains('.123'),
          reason: 'toIso8601String 保留毫秒;但本地 drift 存 DateTime 是**秒**'
              '精度 → 时区/毫秒信息在 DB 往返后丢(见 pull 套件)');
    });
  });

  // ==================================================================
  group('serializeTransaction note / syncId 边界', () {
    test('note 含 emoji / CJK 可正常编码', () {
      final payload = EntitySerializer.serializeTransaction(
          tx(note: '午餐 🍜 ￥38.50 ✅ 测试'));
      final json = EntitySerializer.toJsonString(payload);
      final back = EntitySerializer.fromJsonString(json);
      expect(back['note'], '午餐 🍜 ￥38.50 ✅ 测试');
    });

    test('超长 note(1MB)可编码,不截断', () {
      final long = 'x' * 1000000;
      final payload = EntitySerializer.serializeTransaction(tx(note: long));
      final json = EntitySerializer.toJsonString(payload);
      expect((EntitySerializer.fromJsonString(json)['note'] as String).length,
          1000000,
          reason: 'HARDENING: serializer 不截断 note —— 超长 note 会撑大 POST body');
    });

    test("note 含 NUL / 控制字符原样保留(JSON 转义)", () {
      final payload =
          EntitySerializer.serializeTransaction(tx(note: 'a\u0000b\nc'));
      final back =
          EntitySerializer.fromJsonString(EntitySerializer.toJsonString(payload));
      expect(back['note'], 'a\u0000b\nc');
    });

    test('syncId 为空串 → payload.syncId 是空串(毒数据未拦截)', () {
      final payload = EntitySerializer.serializeTransaction(tx(syncId: ''));
      expect(payload['syncId'], '',
          reason: 'HARDENING: serializer 不校验 syncId 非空;'
              'server 的 entity_sync_id 是 required str(可为空串)→ 会写出一条'
              '无法被任何本地实体匹配的 change');
    });

    test('syncId 为 null → payload.syncId 是 null', () {
      final payload = EntitySerializer.serializeTransaction(tx(syncId: null));
      expect(payload['syncId'], isNull,
          reason: 'HARDENING: null syncId 原样进 payload;'
              'engine push 时 entity_sync_id 取 change.entitySyncId 而不是'
              'payload.syncId,所以两者可能不一致');
    });
  });

  // ==================================================================
  group('serializeTransaction 账号/分类字段语义', () {
    test('accountName/accountId 为 null → 发空串(显式"清空账户")', () {
      final payload = EntitySerializer.serializeTransaction(tx());
      expect(payload['accountName'], '');
      expect(payload['accountId'], '');
      expect(payload['fromAccountName'], '');
      expect(payload['fromAccountId'], '');
      expect(payload['toAccountName'], '');
      expect(payload['toAccountId'], '');
    });

    test('categorySyncId 为空串 → 省略 categoryId 键', () {
      final payload = EntitySerializer.serializeTransaction(
          tx(), categorySyncId: '');
      expect(payload.containsKey('categoryId'), isFalse,
          reason: 'contract: 空串不写键(server 按"缺键=不更新"处理)');
    });

    test('attachments=[] 必须写出键(空数组 ≠ 缺键)', () {
      final payload =
          EntitySerializer.serializeTransaction(tx(), attachments: const []);
      expect(payload.containsKey('attachments'), isTrue,
          reason: 'contract: [] 表示"远端权威列表为空"(全删),缺键表示"不带信息"');
      expect(payload['attachments'], isEmpty);
    });

    test('attachments=null → 不写键(legacy 语义)', () {
      final payload = EntitySerializer.serializeTransaction(tx());
      expect(payload.containsKey('attachments'), isFalse);
    });

    test('tagNames 空列表 → 不写 tags 键', () {
      final payload =
          EntitySerializer.serializeTransaction(tx(), tagNames: const []);
      expect(payload.containsKey('tags'), isFalse);
    });

    test('tagNames 含逗号 → 拼接后歧义(逗号作分隔符)', () {
      final payload = EntitySerializer.serializeTransaction(tx(),
          tagNames: const ['a,b', 'c']);
      expect(payload['tags'], 'a,b,c',
          reason: 'ADVERSE-CANDIDATE: 标签名含逗号时 joined 字符串有歧义;'
              '对端 name-split fallback 会解析出 3 个标签。'
              'tagIds 存在时不受影响(优先按 id 匹配)');
    });

    test('ledgerSyncId 空串 → 不写键', () {
      final payload =
          EntitySerializer.serializeTransaction(tx(), ledgerSyncId: '');
      expect(payload.containsKey('ledgerSyncId'), isFalse);
    });

    test('currencyCode/nativeAmount 缺省 → 不写键(D7 缺键保留语义)', () {
      final payload = EntitySerializer.serializeTransaction(tx());
      expect(payload.containsKey('currencyCode'), isFalse);
      expect(payload.containsKey('nativeAmount'), isFalse);
    });

    test('currencyCode 有值 / nativeAmount 为 null → 只写 currencyCode', () {
      final payload = EntitySerializer.serializeTransaction(
          tx(currencyCode: 'USD')); // nativeAmount 仍 null
      expect(payload['currencyCode'], 'USD');
      expect(payload.containsKey('nativeAmount'), isFalse,
          reason: 'HARDENING: 两键独立判断,可出现"只有币种没有折算值"的 payload');
    });

    test('nativeAmount=0 会被写出(0 不是 null)', () {
      final payload =
          EntitySerializer.serializeTransaction(tx(nativeAmount: 0.0));
      expect(payload['nativeAmount'], 0.0);
    });

    test('excludeFromStats / excludeFromBudget 无条件写出', () {
      final payload = EntitySerializer.serializeTransaction(tx());
      expect(payload['excludeFromStats'], isFalse);
      expect(payload['excludeFromBudget'], isFalse);
    });
  });

  // ==================================================================
  group('serializeCategory 边界', () {
    test('level 越界(0 / 3 / -1)原样进 payload', () {
      for (final lvl in [0, 3, -1, 99]) {
        final payload = EntitySerializer.serializeCategory(cat(level: lvl));
        expect(payload['level'], lvl,
            reason: 'HARDENING: serializer 不 clamp level;'
                'apply 端也不校验 → 非法 level 会落库');
      }
    });

    test('parentSyncId 指向不存在的实体 → 原样写出(悬空引用)', () {
      final payload = EntitySerializer.serializeCategory(
          cat(parentId: 42), parentSyncId: 'ghost-parent');
      expect(payload['parentSyncId'], 'ghost-parent',
          reason: 'HARDENING: 悬空 parentSyncId 无校验;'
              '对端 apply 用 name+kind 反查(见 sync_engine_apply 的 parentName 分支),'
              'parentSyncId 当前未被消费');
    });

    test('name 空串原样写出', () {
      final payload = EntitySerializer.serializeCategory(cat(name: ''));
      expect(payload['name'], '');
    });

    test('customIconPath 有值 → 写出(本地路径泄漏风险)', () {
      final payload = EntitySerializer.serializeCategory(
          cat(iconType: 'custom', customIconPath: 'custom_icons/a_1.png'));
      expect(payload['customIconPath'], 'custom_icons/a_1.png',
          reason: 'HARDENING: payload 带 A 端本地相对路径;'
              'B 端 apply 明确不写这列(见 _applyCategoryChange 注释),所以安全');
    });

    test('iconCloudFileId / sha256 null → 不写键', () {
      final payload = EntitySerializer.serializeCategory(cat());
      expect(payload.containsKey('iconCloudFileId'), isFalse);
      expect(payload.containsKey('iconCloudSha256'), isFalse);
    });
  });

  // ==================================================================
  group('serializeExchangeRateOverride 边界', () {
    test('rate 是 TEXT,原样保留 "0" / 负数 / 非数字串', () {
      for (final r in ['0', '-1.5', 'abc', '', '1e999', 'NaN', 'Infinity']) {
        final payload = EntitySerializer.serializeExchangeRateOverride(
            rateOverride(rate: r));
        expect(payload['rate'], r,
            reason: 'HARDENING: rate 无校验;apply 端只判 null/空串,'
                '"abc" 会落库,消费方 double.tryParse 返 null → 退化成无汇率');
      }
    });

    test('updatedAt=null → 兜底成 now(不写 null)', () {
      final before = DateTime.now().toUtc();
      final payload = EntitySerializer.serializeExchangeRateOverride(
          rateOverride()); // updatedAt 缺省 null
      final parsed = DateTime.parse(payload['updatedAt'] as String);
      expect(parsed.isBefore(before.subtract(const Duration(seconds: 5))), isFalse,
          reason: 'updatedAt 缺省兜底 now');
    });

    test('ADVERSE-CANDIDATE: updatedAt=null 兜底 now 会让 push 时间戳每次漂移',
        () async {
      // 序列化两次(模拟同一行 push 两次)。语义上 updatedAt=null 表示"本地
      // 从未写入过时间戳",但每次序列化都取新的 now → server LWW 的
      // (updated_at, device_id) 元组每次都变。
      final o = rateOverride(); // updatedAt null
      final p1 = EntitySerializer.serializeExchangeRateOverride(o);
      await Future.delayed(const Duration(milliseconds: 5));
      final p2 = EntitySerializer.serializeExchangeRateOverride(o);
      expect(p1['updatedAt'], isA<String>());
      expect(p2['updatedAt'], isA<String>(),
          reason: 'ADVERSE-CANDIDATE: updatedAt=null → 每次序列化取新 now;'
              '本地 override 行的 updatedAt 只在 setOverride / apply 写入,'
              '若为 null 则 push 的时间戳不稳定');
    });

    test('baseCurrency / quoteCurrency 大小写原样保留(不 uppercase)', () {
      final payload = EntitySerializer.serializeExchangeRateOverride(
          rateOverride(base: 'cny', quote: ' usd '));
      expect(payload['baseCurrency'], 'cny',
          reason: 'HARDENING: serializer 不做大小写/trim 归一;'
              'apply 端有 toUpperCase —— 但本地 repo 写入时已 uppercase,'
              '所以本地正常路径不受影响');
      expect(payload['quoteCurrency'], ' usd ');
    });
  });

  // ==================================================================
  group('serializeAccount / Tag / Budget / Ledger / Adjustment 边界', () {
    test('serializeAccount 空名 / 空 syncId 原样写出', () {
      final payload = EntitySerializer.serializeAccount(
          account(name: '', syncId: ''));
      expect(payload['name'], '');
      expect(payload['syncId'], '');
      expect(payload['hidden'], isFalse, reason: 'hidden 无条件写出(#240 契约)');
    });

    test('serializeAccount initialBalance=Infinity → payload 已毒(同 amount)', () {
      final payload = EntitySerializer.serializeAccount(
          account(initialBalance: double.infinity));
      expect(payload['initialBalance'], double.infinity,
          reason: 'ADVERSE: 账户初始余额同样无有限性校验');
    });

    test('serializeTag 空名 / 无 color → 不写 color 键', () {
      final payload = EntitySerializer.serializeTag(tag(name: ''));
      expect(payload['name'], '');
      expect(payload.containsKey('color'), isFalse);
    });

    test('serializeBudget categorySyncId 空串 → 不写 categoryId 键', () {
      final payload = EntitySerializer.serializeBudget(
        budget(type: 'category'),
        categorySyncId: '',
      );
      expect(payload.containsKey('categoryId'), isFalse,
          reason: '分类预算 categoryId 缺失 → server 侧无法定位分类');
    });

    test('serializeBudget amount=Infinity → 毒 payload', () {
      final payload = EntitySerializer.serializeBudget(
          budget(amount: double.infinity));
      expect(payload['amount'], double.infinity);
    });

    test('serializeLedger monthStartDay 越界原样写出(无 clamp)', () {
      final payload =
          EntitySerializer.serializeLedger(ledger(monthStartDay: 999));
      expect(payload['monthStartDay'], 999,
          reason: 'HARDENING: serializer 不 clamp;'
              'apply 端 clamp(1,28) 挡住了落到本地,但 server 侧拿到 999');
    });

    test('serializeLedger 空名 / 空 syncId', () {
      final payload =
          EntitySerializer.serializeLedger(ledger(name: '', currency: '', syncId: ''));
      expect(payload['ledgerName'], '');
      expect(payload['currency'], '');
      expect(payload['syncId'], '');
    });

    test('serializeAccountAdjustment amount 带符号 / accountId 空串兜底', () {
      final payload = EntitySerializer.serializeAccountAdjustment(
          adjustment(amount: -123.45));
      expect(payload['amount'], -123.45);
      expect(payload['accountId'], '',
          reason: 'contract: accountSyncId 未传 → 空串(显式无账户语义)');
      expect(payload.containsKey('accountName'), isFalse,
          reason: 'accountName null → 不写键');
    });

    test('serializeAccountAdjustment amount=Infinity → 毒 payload', () {
      final payload = EntitySerializer.serializeAccountAdjustment(
          adjustment(amount: double.infinity));
      expect(payload['amount'], double.infinity);
    });
  });

  // ==================================================================
  group('toJsonString / fromJsonString 健壮性', () {
    test('fromJsonString("5") → TypeError(顶层非 Map)', () {
      expect(() => EntitySerializer.fromJsonString('5'),
          throwsA(isA<TypeError>()),
          reason: 'HARDENING: 裸 cast `as Map<String, dynamic>` → TypeError;'
              '调用方若以为是 FormatException 会漏 catch');
    });

    test('fromJsonString("null") → TypeError', () {
      expect(() => EntitySerializer.fromJsonString('null'),
          throwsA(isA<TypeError>()));
    });

    test('fromJsonString("[1,2]") → TypeError(顶层 List)', () {
      expect(() => EntitySerializer.fromJsonString('[1,2]'),
          throwsA(isA<TypeError>()));
    });

    test('fromJsonString("{") → FormatException(非法 JSON)', () {
      expect(() => EntitySerializer.fromJsonString('{'),
          throwsA(isA<FormatException>()));
    });

    test('fromJsonString 对 Map<String,Object?> 的嵌套 List 不做深拷贝', () {
      final decoded = EntitySerializer.fromJsonString('{"a":[1,2,3]}');
      expect(decoded['a'], isA<List<dynamic>>(),
          reason: 'HARDENING: 返回的是 jsonDecode 的原始 Map,'
              '顶层 cast 成功但嵌套值类型是 List<dynamic> 而非 List<String>;'
              'apply 端到处 `as List` + whereType 兜住');
    });

    test('toJsonString ↔ fromJsonString 往返保真(含 Unicode / 嵌套)', () {
      final original = <String, dynamic>{
        'note': '中文 🎉 \u0000 \n\t',
        'amount': 1.23456789012345,
        'nested': {'list': [1, 'two', null, true]},
        'nullValue': null,
      };
      final back =
          EntitySerializer.fromJsonString(EntitySerializer.toJsonString(original));
      expect(back, equals(original));
    });

    test('ADVERSE: 若 payload 含 Infinity,toJsonString 抛 JsonUnsupportedObjectError',
        () {
      expect(() => EntitySerializer.toJsonString({'amount': double.infinity}),
          throwsA(isA<JsonUnsupportedObjectError>()));
      expect(() => EntitySerializer.toJsonString({'amount': double.nan}),
          throwsA(isA<JsonUnsupportedObjectError>()));
    });

    test('HARDENING: 顶层 Map<dynamic,dynamic> cast 到 Map<String,dynamic> 会抛',
        () {
      // jsonDecode 对对象字面量返的确实是 Map<String, dynamic>,所以正常路径 OK;
      // 但若有人手工构造 Map<int,int>,cast 会抛。记下来(非缺陷,只是脆弱点)。
      final raw = <dynamic, dynamic>{'a': 1};
      expect(() => raw as Map<String, dynamic>, throwsA(isA<TypeError>()));
    });
  });
}
