// 对抗性测试 — CSV 解析 / 文件编码域。
//
// 攻击面:`lib/services/import/csv_parser.dart`, `lib/services/import/file_reader.dart`,
// `lib/utils/xlsx_reader.dart`(转出的 CSV 约定), 以及它们与
// `import_confirm_page.dart` 列映射的交互。
//
// 红绿纪律:
// - 确认缺陷 → 断言当前错误行为并失败,行内标 `// ADVERSE FINDING: <标题>`。
// - 行为可辩护但脆弱 → 断言当前行为并通过,行内标 `// HARDENING: <说明>`。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';

import 'package:smartbook/services/import/csv_parser.dart';
import 'package:smartbook/services/import/file_reader.dart';
import 'package:smartbook/services/import/parsers/generic_parser.dart';

void main() {
  group('CSV:引号内换行(合法 CSV 字段)', () {
    // ADVERSE FINDING: 带引号的内嵌换行是 RFC 4180 合法 CSV,但 `parse` 开头
    // 就 `text.split('\n')` 把行切开,**先切行再拆列** ——
    // 引号内的换行被当成行尾,一行被拆成两行,列数错位。
    // 后果:商品名/备注含换行的行,金额与日期会被推到"下一行的开头",
    // 整份账单从该行起全部错位(且不报错)。
    // 源码:`lib/services/import/csv_parser.dart:11-14`(先按 \n 切行)。
    test('引号内的换行把一行拆成两行', () {
      const csv = '商家,备注,金额\n盒马,"多行\n备注",88.00\n';
      final rows = CsvParser.parse(csv);
      expect(rows, hasLength(2),
          reason: 'ADVERSE FINDING: 期望 2 行(表头+1条数据),实际 ${rows.length} 行'
              ' —— 内嵌换行被当行尾,数据被拆成 [盒马, 多行] 与 [备注,88.00]');
    });

    test('拆行后数据行列数少于表头(列错位)', () {
      const csv = '商家,备注,金额\n盒马,"多行\n备注",88.00\n';
      final rows = CsvParser.parse(csv);
      final header = rows.first;
      final second = rows[1];
      expect(second.length, header.length,
          reason: 'ADVERSE FINDING: 表头 ${header.length} 列,第二行只有 '
              '${second.length} 列 —— 金额/日期列落到后续行里');
    });

    test('CRLF 形式的内嵌换行同样被拆(且保留 \\r 语义破坏)', () {
      const csv = 'a,b\n"x\r\ny",2\n';
      final rows = CsvParser.parse(csv);
      expect(rows, hasLength(2),
          reason: 'ADVERSE FINDING: \\r\\n 已被规范化成 \\n,内嵌换行照样拆行');
    });

    // HARDENING: 未闭合引号("1,\"2,3")把后续所有内容吞进同一字段,
    // 行尾引号缺失时不会报错。当前行为锁在这里。
    test('未闭合引号吞掉行内后续内容(不报错)', () {
      final rows = CsvParser.parse('a,b,c\n1,"2,3\n');
      expect(rows.last, ['1', '2,3'],
          reason: 'HARDENING 标记:未闭合引号的容错方向是"吞并"而非"报错"');
    });
  });

  group('CSV:分隔符自动检测(计数法)', () {
    // ADVERSE FINDING: `_detectDelimiter` 用「谁的字符出现次数最多」选分隔符,
    // 完全不看**每行列数一致性**。制表符文件里若备注列含较多逗号,
    // 逗号计数超过制表符计数 → 选逗号 → 随后
    // `processedLines = lines.map((l) => l.replaceAll('\t', ''))`
    // 把所有制表符删掉 → 表头塌成 1 列、数据行按逗号切成 4 列,整个文件崩。
    // 源码:`lib/services/import/csv_parser.dart:57-95`(计数选择)、
    // `:23-27`(非 tab 分隔符时删除所有 tab)。
    test('tab 文件 + 备注含逗号 → 分隔符误判为逗号,表头塌成 1 列', () {
      const csv = '日期\t金额\t备注\n'
          '2026-01-01\t1.00\t买,买,买,买\n'
          '2026-01-02\t2.00\t吃,吃,吃,吃\n'
          '2026-01-03\t3.00\t喝,喝,喝,喝\n';
      final rows = CsvParser.parse(csv);
      expect(rows.first.length, 3,
          reason: 'ADVERSE FINDING: 表头期望 3 列(日期/金额/备注),'
              '实际 ${rows.first.length} 列 —— 制表符被删、表头粘成「日期金额备注」');
    });

    test('同一份 tab 文件的数据行列数 ≠ 表头列数(整份错位)', () {
      const csv = '日期\t金额\t备注\n'
          '2026-01-01\t1.00\t买,买,买,买\n'
          '2026-01-02\t2.00\t吃,吃,吃,吃\n'
          '2026-01-03\t3.00\t喝,喝,喝,喝\n';
      final rows = CsvParser.parse(csv);
      expect(rows[1].length, rows.first.length,
          reason: 'ADVERSE FINDING: 表头 ${rows.first.length} 列 vs 数据行 '
              '${rows[1].length} 列 —— 列映射全部失效');
    });

    // HARDENING: 备注逗号较少时计数法恰好选对 tab,行为正常。
    // 说明缺陷依赖"逗号数量 > 制表符数量"这一脆弱阈值。
    test('对照:备注逗号较少时 tab 检测正确', () {
      const csv = '日期\t金额\t备注\n'
          '2026-01-01\t1.00\t买,买\n'
          '2026-01-02\t2.00\t吃,吃\n';
      final rows = CsvParser.parse(csv);
      expect(rows.first, ['日期', '金额', '备注']);
      expect(rows[1], ['2026-01-01', '1.00', '买,买']);
    });

    // 修复后(2026-10-11,批次 C2):不再对非选中分隔符做全局
    // `replaceAll('\t', '')` —— 字段内的 tab 属于数据,原样保留。
    // (原断言 `['xy','2']` 锁的是"数据静默丢失"这一缺陷行为,按正确行为改写。)
    test('逗号文件里字段内的 tab 原样保留(不再被全局删除)', () {
      final rows = CsvParser.parse('a,b\n"x\t\t\ty",2\n');
      expect(rows[1], ['x\t\t\ty', '2'],
          reason: '字段内 tab 是数据(tab 文件里两条 tab 甚至可能是分隔符),'
              '不能因"选中的是逗号"就全局删除');
    });

    test('分号/竖线文件里的逗号不受干扰(计数仍偏向真实分隔符)', () {
      final semi = CsvParser.parse('日期;金额;备注\n2026-01-01;1.00;a,b\n2026-01-02;2.00;c,d\n');
      expect(semi.first, ['日期', '金额', '备注']);
      expect(semi[1], ['2026-01-01', '1.00', 'a,b']);

      final pipe = CsvParser.parse('日期|金额|备注\n2026-01-01|1.00|a,b,c\n2026-01-02|2.00|d,e,f\n');
      expect(pipe.first, ['日期', '金额', '备注']);
      expect(pipe[1], ['2026-01-01', '1.00', 'a,b,c']);
    });

    // HARDENING: 全角逗号「，」不是分隔符 —— 中文用户从网页/聊天复制出来的
    // "日期，金额" 表头会整行塌成 1 列。金额清洗里有全角逗号处理,
    // 分隔符检测里没有。
    test('全角逗号不作分隔符(整行 1 列)', () {
      final rows = CsvParser.parse('日期，金额\n2026-01-01，1.00\n');
      expect(rows.first, ['日期，金额'],
          reason: 'HARDENING 标记:，不被识别为分隔符');
    });

    // HARDENING: 全角空格 U+3000 不匹配 RegExp(r' {2,}'),整行 1 列。
    test('全角空格(U+3000)不作空白分隔', () {
      final rows = CsvParser.parse('日期\u3000金额\u3000备注\n2026-01-01\u30001.00\u3000早餐\n');
      expect(rows.first.length, 1,
          reason: 'HARDENING 标记:U+3000 不是 ASCII 空格');
    });
  });

  group('CSV:空白分隔模式的金额陷阱', () {
    // ADVERSE FINDING: 空白分隔模式下,`_splitSpaceSeparatedLine` 把
    // **单个空格**也当分隔符,于是金额里的空格千分位 "1 234.56"
    // 被切成两列 → 该行从金额列起整体右移一列,金额变 1、备注变 234.56。
    // 源码:`lib/services/import/csv_parser.dart:148-163`(spaceRun==1 即分隔)。
    test('空格千分位金额 "1 234.56" 被切成两列(整行右移)', () {
      const csv = '日期  金额  备注\n2026-01-01  1 234.56  早餐\n';
      final rows = CsvParser.parse(csv);
      expect(rows[1].length, rows.first.length,
          reason: 'ADVERSE FINDING: 表头 ${rows.first.length} 列,数据行 '
              '${rows[1].length} 列 —— 金额被拆成 "1" 与 "234.56"');
    });

    test('单空格分隔在空白模式下也被当分隔符', () {
      final rows = CsvParser.parse('a  b c\n1 2 3\n');
      expect(rows.first, ['a', 'b', 'c'],
          reason: 'HARDENING 标记:单空格也是分隔符(与注释"多个连续空格"不符)');
      expect(rows[1], ['1', '2', '3']);
    });
  });

  group('CSV:转义、BOM、行尾、空行', () {
    test('双引号转义 "" → "', () {
      expect(CsvParser.parse('a,b\n"x""y",2\n')[1], ['x"y', '2']);
    });

    test('空值 vs 引号空串都归一为空字符串', () {
      expect(CsvParser.parse('a,b,c\n"",x,""\n')[1], ['', 'x', '']);
    });

    test('UTF-8 BOM 被剥离(表头首字段不带 \\uFEFF)', () {
      final rows = CsvParser.parse('\uFEFFa,b\n1,2\n');
      expect(rows.first.first, 'a');
      expect(rows.first.first.codeUnitAt(0) == 0xFEFF, isFalse);
    });

    // HARDENING: BOM 只在文件开头剥离;字段内的 BOM 由字段 trim 顺带吃掉
    // (Dart `String.trim()` 视 U+FEFF 为空白),所以引号里的 BOM 也消失 ——
    // 这是"数据静默变化"而非崩溃,锁当前行为。
    test('字段内 BOM 被 trim 顺带剥掉', () {
      final rows = CsvParser.parse('a,b\n"\uFEFFx",2\n');
      expect(rows[1].first, 'x',
          reason: 'HARDENING 标记:字段内 BOM 被 trim 吃掉,数据静默变化');
    });

    test('CRLF 与 CR 都归一为一行一行', () {
      expect(CsvParser.parse('a,b\r\n1,2\r\n'), [
        ['a', 'b'],
        ['1', '2']
      ]);
      expect(CsvParser.parse('a,b\r1,2\r'), [
        ['a', 'b'],
        ['1', '2']
      ]);
    });

    test('混合 CR/LF/CRLF 逐个切分', () {
      expect(CsvParser.parse('a,b\r\n1,2\n3,4\r5,6'), [
        ['a', 'b'],
        ['1', '2'],
        ['3', '4'],
        ['5', '6']
      ]);
    });

    // HARDENING: 空行(纯空白)被整行丢弃,数据行中的空行不留占位 ——
    // 用户无法从解析结果看出文件里原有空行。不产生错误行,只是信息丢失。
    test('纯空白行被丢弃(只剩非空行)', () {
      final rows = CsvParser.parse('a,b\n\n   \n1,2\n');
      expect(rows, hasLength(2), reason: 'HARDENING 标记:两个空白行被静默丢弃');
      expect(rows[1], ['1', '2']);
    });

    test('只有表头 / 空输入 / 纯空白输入', () {
      expect(CsvParser.parse('a,b,c\n'), hasLength(1));
      expect(CsvParser.parse(''), isEmpty);
      expect(CsvParser.parse('   \n\t\n'), isEmpty);
    });

    test('重复表头作为普通数据行保留(不特殊处理)', () {
      final rows = CsvParser.parse('a,b\n1,2\na,b\n');
      expect(rows, hasLength(3));
      expect(rows[2], ['a', 'b']);
    });

    // HARDENING: 垂直制表符 \x0b / 换页符 \x0c 不被当行分隔符,
    // 含它们的行会粘成一行。
    test('垂直制表符/换页符不切行', () {
      final rows = CsvParser.parse('a,b\x0b1,2\x0c3,4\n');
      expect(rows, hasLength(1),
          reason: 'HARDENING 标记:\\x0b/\\x0c 非行分隔符');
    });
  });

  group('CSV:公式注入与超长输入', () {
    // HARDENING: 以 = / @ / + / - 开头的字段(CSV 公式注入载荷)原样保留。
    // 本 App 不做 CSV 再导出,风险落在"值被当作数据展示"而非执行;
    // 若未来加导出功能需补转义。
    test('= 与 @ 前缀字段原样保留(不转义)', () {
      final rows = CsvParser.parse('a,b\n=1+1,@SUM(A1)\n');
      expect(rows[1], ['=1+1', '@SUM(A1)'],
          reason: 'HARDENING 标记:公式注入载荷不转义(当前无 CSV 导出路径)');
    });

    test('100KB 单字段不崩', () {
      final rows = CsvParser.parse('x' * 100000);
      expect(rows, hasLength(1));
      expect(rows.first.first, hasLength(100000));
    });

    test('100KB 引号字段不崩', () {
      final rows = CsvParser.parse('"${'x' * 100000}"');
      expect(rows.first.first, hasLength(100000));
    });

    test('5000 列不崩', () {
      final row = List.generate(5000, (i) => '$i').join(',');
      final rows = CsvParser.parse('$row\n$row\n');
      expect(rows.first, hasLength(5000));
    });

    test('生成 4000 行账单后仍可被 GenericBillParser 找到表头', () {
      final big = List.generate(4000, (i) => '2026-01-01,测试$i,1.00').join('\n');
      final rows = CsvParser.parse(big);
      expect(rows, hasLength(4000));
      expect(GenericBillParser().findHeaderRow(rows), 0);
    });
  });

  group('文件编码:decodeBytes', () {
    test('合法 UTF-8 中文/emoji 正常解码', () {
      expect(FileReaderService.decodeBytes(utf8.encode('交易时间,金额')), '交易时间,金额');
      expect(FileReaderService.decodeBytes(utf8.encode('早餐🍜')), '早餐🍜');
    });

    test('UTF-8 BOM 被跳过', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('账单')];
      expect(FileReaderService.decodeBytes(bytes), '账单');
    });

    test('UTF-16 LE / BE BOM 各自正确解码', () {
      final le = <int>[0xFF, 0xFE];
      for (final cu in '账单'.codeUnits) {
        le..add(cu & 0xFF)..add(cu >> 8);
      }
      expect(FileReaderService.decodeBytes(le), '账单');

      final be = <int>[0xFE, 0xFF];
      for (final cu in '账单'.codeUnits) {
        be..add(cu >> 8)..add(cu & 0xFF);
      }
      expect(FileReaderService.decodeBytes(be), '账单');
    });

    // HARDENING: UTF-16 分支要求 BOM;无 BOM 的 UTF-16 文件会走 UTF-8/GBK
    // 路径产出乱码。且 BOM 后落单的尾字节被 pair 循环丢弃(i+1 < length)。
    test('UTF-16 无 BOM → 乱码;奇数尾字节被丢弃', () {
      final noBom = <int>[];
      for (final cu in '账单'.codeUnits) {
        noBom..add(cu & 0xFF)..add(cu >> 8);
      }
      expect(FileReaderService.decodeBytes(noBom), isNot('账单'),
          reason: 'HARDENING 标记:无 BOM 的 UTF-16 不被识别');
      expect(FileReaderService.decodeBytes([0xFF, 0xFE, 0x41]), '',
          reason: 'HARDENING 标记:0xFF 0xFE 的 0x41 尾字节被 pair 循环丢弃');
      expect(FileReaderService.decodeBytes([0xFF, 0xFE]), '');
    });

    test('GBK 字节被正确解码(支付宝旧版 Windows 导出)', () {
      // '备注' GBK = B1 B8 D7 A2
      expect(FileReaderService.decodeBytes([0xB1, 0xB8, 0xD7, 0xA2]), '备注');
      // '交易时间' GBK = BD BB D2 D7 CA B1 BC E4
      expect(
          FileReaderService.decodeBytes(
              [0xBD, 0xBB, 0xD2, 0xD7, 0xCA, 0xB1, 0xBC, 0xE4]),
          '交易时间');
    });

    // ADVERSE FINDING: 只要 UTF-8 解码出的文本里含 **任意一个** U+FFFD,整个
    // 文件就被判定"不是 UTF-8"并改走 GBK 解码;而 U+FFFD 的 UTF-8 字节
    // EF BF BD 恰好是合法 GBK,GBK 结果又必然含汉字 → `_containsChineseCharacters`
    // 通过 → 返回**全文件乱码**。
    // 后果:一份 99.9% 正常的 UTF-8 账单,只要有一个坏字节(或用户备注里
    // 真有 U+FFFD),整份文件变乱码;且乱码仍含汉字,不会被上层察觉。
    // 源码:`lib/services/import/file_reader.dart:137-157`。
    test('单个坏字节使整个 UTF-8 文件变 GBK 乱码', () {
      final good = utf8.encode('交易');
      final good2 = utf8.encode('时间');
      final bytes = <int>[...good, 0xFF, ...good2];
      final decoded = FileReaderService.decodeBytes(bytes);
      expect(decoded, contains('交易'),
          reason: 'ADVERSE FINDING: 期望"交易�时间"(单点损坏),'
              '实际整串变乱码「{$decoded}」');
    });

    test('合法含 U+FFFD 的 UTF-8 文本也变乱码', () {
      final bytes = utf8.encode('备注\uFFFD测试');
      final decoded = FileReaderService.decodeBytes(bytes);
      expect(decoded, '备注\uFFFD测试',
          reason: 'ADVERSE FINDING: 含真 U+FFFD 的合法 UTF-8 被判为非 UTF-8,'
              '实际输出「{$decoded}」');
    });

    // 修复后(2026-10-11,批次 C2):UTF-8 严格解码失败时看**损坏程度** ——
    // 只有尾部 1 个替换字符(单点损坏)→ 保留 UTF-8 宽容解码结果,不再整份
    // 回退 GBK 乱码。原断言 `startsWith('交易时间')` 本身不可满足
    // (被截断的正是"间"字的最后一个字节,不可能产出完整的"间";其 reason
    // 字符串写的期望也是"交易时�"),已改为与 reason 一致的断言。
    test('UTF-8 被截断的多字节序列 → 单点替换字符(不回退 GBK)', () {
      final bytes = utf8.encode('交易时间');
      final truncated = bytes.sublist(0, bytes.length - 1);
      final decoded = FileReaderService.decodeBytes(truncated);
      expect(decoded, startsWith('交易时'),
          reason: '前缀必须保真(不被 GBK 重解码成乱码)');
      expect(decoded, contains('\uFFFD'),
          reason: '截断处用替换字符标记,而不是整份乱码');
    });

    test('空/单字节输入不抛异常', () {
      expect(FileReaderService.decodeBytes([]), '');
      expect(FileReaderService.decodeBytes([0x80]), isNotNull);
    });

    // HARDENING: latin1 兜底只在"GBK 也不含汉字"时触发;UTF-8 allowMalformed
    // 兜底先于 latin1,所以 0xC3 0x28 这类输入产出替换字符而非 latin1 重解码。
    test('非法单字节序列走 allowMalformed(替换字符)而非 latin1', () {
      final decoded = FileReaderService.decodeBytes([0xC3, 0x28]);
      expect(decoded.contains('\uFFFD'), isTrue,
          reason: 'HARDENING 标记:latin1 兜底实际不可达(注释与实现不符)');
    });
  });

  group('与列映射的交互:引号内换行修复后的整链行为', () {
    // 修复后(2026-10-11,批次 C2):引号感知状态机把内嵌换行并入同一行,
    // 数据行与表头列数一致 → 列映射正常、金额不再缺失。
    // (原断言 `rows[1].length < 3` 锁的是"拆行导致列错位"这一缺陷,已改写。)
    test('引号换行后 GenericBillParser 的表头探测与列映射都正确', () {
      const csv = '商家,备注,金额\n盒马,"多行\n备注",88.00\n';
      final rows = CsvParser.parse(csv);
      expect(rows, hasLength(2), reason: '内嵌换行不再拆行');
      expect(GenericBillParser().findHeaderRow(rows), 0);
      final mapping = GenericBillParser().mapColumns(rows.first);
      expect(mapping['amount'], 2);
      expect(rows[1], hasLength(3),
          reason: '数据行与表头列数一致 → amount 列索引 2 可取到金额');
      expect(rows[1][mapping['amount']!], '88.00');
      expect(rows[1][1], '多行\n备注', reason: '内嵌换行作为字段内容保留');
    });
  });
}
