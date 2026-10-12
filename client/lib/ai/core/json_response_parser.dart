import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../services/system/logger_service.dart';
import 'bill_info.dart';

/// AI 响应 JSON 解析器。
///
/// 容错策略(应对 AI 实际吐出的各种花样):
/// - **JSON 数组**:`[{...}, {...}]` 是默认 prompt 期望的格式
/// - **单 JSON 对象**:`{...}` 兼容老用户自定义 prompt
/// - **Markdown 包裹**:` ```json ... ``` ` 通过 balanced-block 提取自动跳过
/// - **trailing comma**:`{,}` / `[,]` AI 偶发生成 JSON5 风格,清理后再 parse
/// - **统一 sanitize**:amount 缺失/为 0 的丢弃;time 缺失/不可解析的兜底当前时间
///
/// 渠道层信任 `parse` 的输出 —— 返回的 list 已经做过 amount 校验和 time 兜底,
/// 可直接逐笔入库,**不需要**再做 `where((b) => b.amount != null && ...)` 之类
/// 的二次过滤。
class JsonResponseParser {
  static const String _tag = 'JsonResponseParser';

  const JsonResponseParser();

  /// 解析 AI 响应文本为 `List<BillInfo>`。返回空 list 表示无有效账单。
  ///
  /// [captureTime] 事件捕获时刻(通知 postTime)。AI 未从正文识别出交易
  /// 时间、或给出了推测时间时,改用它(分钟精度、不标记推测)—— 通知到达
  /// ≈ 交易时刻。null = 走旧兜底(now() + 推测标记),时间缺失的账单由
  /// 策略层决定丢弃与否。
  List<BillInfo> parse(String response, {DateTime? captureTime}) {
    final responseHash =
        sha256.convert(utf8.encode(response)).toString().substring(0, 12);
    logger.debug(
        _tag, '解析 AI 响应', 'length=${response.length}, hash=$responseHash');

    // 结构位上的 BOM / 零宽字符先剥掉(逐段加 BOM 的网关/代理会让
    // `[<BOM>{...}]` 直接过不了 jsonDecode;`{` 前逐个带 BOM 时更会
    // 只救回第一笔)。只剥**字符串字面量之外**的字符 —— 文本内容不动。
    final structural = _stripStructuralInvisibles(response);

    // 数组路径优先 —— 新默认 prompt 期望此格式
    final arrayBlock = _extractBalancedBlock(structural, '[', ']');
    if (arrayBlock != null) {
      try {
        final decoded = jsonDecode(_cleanupJson(arrayBlock));
        if (decoded is List) {
          final bills = _billsFromDecodedList(decoded, captureTime);
          if (bills.isNotEmpty) {
            logger.info(_tag, '账单提取成功(数组): ${bills.length} 笔');
            return bills;
          }
          logger.warning(_tag, '数组中没有有效账单项');
          // 不直接 return,fallback 到单对象路径(防 AI 把单笔写成 `[]` 又附 `{...}`)
        }
      } catch (e) {
        logger.warning(_tag, '数组 JSON 解析失败,尝试逐对象抢救: $e');
        // 数组整体解析失败时先**逐对象重试**:块内每个完整 `{...}` 单独
        // jsonDecode —— 比直接退化到单对象路径只救回第一笔强得多
        // (缺失逗号 / 混入注释 / 局部脏字符的批次都能救回多笔)。
        final salvaged = _salvageObjectsInBlock(arrayBlock, captureTime);
        if (salvaged.isNotEmpty) {
          logger.info(_tag, '账单提取成功(数组逐对象抢救): ${salvaged.length} 笔');
          return salvaged;
        }
        logger.warning(_tag, '逐对象抢救无结果,尝试单对象 fallback');
      }
    }

    // Fallback: 单对象(旧格式 / 用户自定义老 prompt)
    final objectBlock = _extractBalancedBlock(structural, '{', '}');
    if (objectBlock == null) {
      logger.warning(_tag, '响应中没有找到 JSON');
      return const [];
    }
    try {
      final json =
          jsonDecode(_cleanupJson(objectBlock)) as Map<String, dynamic>;
      final raw = BillInfo.fromJson(json);
      _warnIfCurrencyDropped(json, raw);
      final sanitized = _sanitize(raw, captureTime);
      if (sanitized == null) {
        logger.warning(_tag, '单对象金额无效');
        return const [];
      }
      logger.info(_tag, '账单提取成功(单对象)');
      return [sanitized];
    } catch (e) {
      logger.warning(_tag, '单对象 JSON 解析失败: $e');
      return const [];
    }
  }

  /// 把 jsonDecode 出来的数组逐项转成有效账单(单笔异常不拖累整批)。
  List<BillInfo> _billsFromDecodedList(
      List<dynamic> decoded, DateTime? captureTime) {
    final bills = <BillInfo>[];
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map<String, dynamic>) {
        logger.warning(_tag, '数组第 ${i + 1} 项不是对象,跳过');
        continue;
      }
      try {
        final raw = BillInfo.fromJson(item);
        _warnIfCurrencyDropped(item, raw);
        final sanitized = _sanitize(raw, captureTime);
        if (sanitized == null) {
          logger.warning(_tag, '数组第 ${i + 1} 项金额无效,跳过');
          continue;
        }
        bills.add(sanitized);
      } catch (e) {
        logger.warning(_tag, '数组第 ${i + 1} 项解析失败,跳过: $e');
      }
    }
    return bills;
  }

  /// 数组块整体解析失败时,逐个提取块内的**顶层完整对象**并单独解析。
  ///
  /// 用于 `[{...},{...}]` 因局部脏字符(注释、缺逗号、BOM 残留)整体不可解析
  /// 但每个对象自身完好的场景 —— 逐对象抢救能保住多笔,而不是退化到
  /// 单对象路径只救回第一笔。
  List<BillInfo> _salvageObjectsInBlock(
      String block, DateTime? captureTime) {
    final bills = <BillInfo>[];
    final objects = _extractAllTopLevelBlocks(block, '{', '}');
    for (final objectText in objects) {
      try {
        final json =
            jsonDecode(_cleanupJson(objectText)) as Map<String, dynamic>;
        final raw = BillInfo.fromJson(json);
        _warnIfCurrencyDropped(json, raw);
        final sanitized = _sanitize(raw, captureTime);
        if (sanitized == null) {
          logger.warning(_tag, '抢救对象金额无效,跳过');
          continue;
        }
        bills.add(sanitized);
      } catch (e) {
        logger.warning(_tag, '抢救对象解析失败,跳过: $e');
      }
    }
    return bills;
  }

  /// AI 给了币种但解析不出来时留一条 warning。
  ///
  /// 这条日志的价值:币种解析失败是**静默降级**成账本本位币的(A5 不阻断),
  /// 用户只会看到「1200 日元被记成 1200 元」这种结果,没有日志根本没法判断
  /// 是模型没填、还是填了个我们不认的写法(实测「美元」失效就卡在这一步:
  /// 模型回的是 `"$"`,被歧义保护丢掉了)。
  void _warnIfCurrencyDropped(Map<String, dynamic> json, BillInfo bill) {
    if (bill.currency != null) return;
    final raw =
        json['currency'] ?? json['currency_code'] ?? json['currencyCode'];
    if (raw == null || (raw is String && raw.trim().isEmpty)) return;
    logger.warning(_tag, '币种「$raw」无法解析成 ISO 代码,本笔按账本本位币入账');
  }

  /// 单笔统一校验 + 兜底。
  ///
  /// 返回 null = 该笔应丢弃(amount 缺失/为 0/非有限);
  /// 返回非 null = 已修正,可直接入库。
  ///
  /// 时间规则(2026-10-09 用户裁决):
  /// - 通知路径([captureTime] 非空):正文无时间、或时间为模型推测 →
  ///   一律改用通知时间(分钟精度、非推测),不让猜测时间入账;
  /// - 其它路径:维持旧兜底(缺失填 now() + 推测标记),时间不可信的账单
  ///   交给策略层丢弃/分流。
  BillInfo? _sanitize(BillInfo bill, DateTime? captureTime) {
    final amt = bill.amount;
    // A6/A11(2026-10-11):非有限金额(JSON `1e999` 溢出为 Infinity,
    // 或字符串 "NaN"/"Infinity" 被 double.tryParse 接受)必须在解析入口
    // 丢弃。`NaN.abs() <= 0` 与 `Infinity.abs() <= 0` 恒为 false,旧判定挡
    // 不住,非有限值会一路落库污染统计/判重索引。本类是下游信任的
    // 「统一 sanitize」关口(见类注释),守卫必须在此生效。
    if (amt == null || !amt.isFinite || amt.abs() <= 0) return null;
    if (captureTime != null) {
      if (bill.time == null || bill.timeInferred) {
        return bill.copyWith(
          time: captureTime,
          timeInferred: false,
          timePrecision: BillTimePrecision.minute,
        );
      }
      return bill;
    }
    if (bill.time == null) {
      return bill.copyWith(
        time: DateTime.now(),
        timeInferred: true,
        timePrecision: BillTimePrecision.inferred,
      );
    }
    return bill;
  }

  /// JSON5 容错清理 —— 去除引号外的 trailing comma(如 `{,}` / `[,]`)。
  ///
  /// 简单状态机:进入引号内的字符全部原样保留(避免误删 note 字段里用户输入
  /// 的「苹果, 香蕉」这类合法逗号),引号外的 `,` 如果其后跟 `}` 或 `]`
  /// (空白容忍)则丢弃。
  String _cleanupJson(String input) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        continue;
      }
      if (c == ',') {
        var j = i + 1;
        while (j < input.length &&
            (input[j] == ' ' ||
                input[j] == '\t' ||
                input[j] == '\n' ||
                input[j] == '\r')) {
          j++;
        }
        if (j < input.length && (input[j] == '}' || input[j] == ']')) {
          continue;
        }
      }
      out.write(c);
    }
    return out.toString();
  }

  /// 从文本中提取首个**配对完整**的 `[...]` 或 `{...}` 块。
  ///
  /// brace-balance 计数 + 字符串字面量识别,可以穿过 markdown 包裹
  /// (\`\`\`json ... \`\`\`) 和前后多余的解释文字。
  String? _extractBalancedBlock(String text, String open, String close) {
    final start = text.indexOf(open);
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final c = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  /// 剥离**字符串字面量之外**的 BOM / 零宽字符。
  ///
  /// 诱因:部分 AI 网关/代理会逐段加 BOM,于是响应长成
  /// `[<BOM>{"amount":-30},<BOM>{"amount":-88}]` —— 这些字符在结构位上
  /// 会让 `jsonDecode` 直接抛 FormatException,数组路径整体失败后只剩
  /// 单对象 fallback(只救回第一笔)。字符串内容里的同类字符**保留**
  /// (那是用户数据,不能改)。
  String _stripStructuralInvisibles(String text) {
    final invisibles = RegExp('[\uFEFF\u200B\u200C\u200D\u2060]');
    if (!invisibles.hasMatch(text)) return text;

    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        continue;
      }
      if (invisibles.hasMatch(c)) continue;
      out.write(c);
    }
    return out.toString();
  }

  /// 提取 [text] 内**全部顶层** `{...}` 块(嵌套对象不单列)。
  ///
  /// 供数组路径整体解析失败时的"逐对象抢救"用:每个块单独 jsonDecode,
  /// 脏字符只毁掉它所在的那一笔,不会像整体 parse 那样一笔连坐整批。
  List<String> _extractAllTopLevelBlocks(String text, String open, String close) {
    final blocks = <String>[];
    var depth = 0;
    var start = -1;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == open) {
        if (depth == 0) start = i;
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0 && start >= 0) {
          blocks.add(text.substring(start, i + 1));
          start = -1;
        }
      }
    }
    return blocks;
  }
}
