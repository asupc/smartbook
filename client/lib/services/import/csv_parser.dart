/// CSV 解析工具类
class CsvParser {
  /// 解析 CSV 文本为二维数组
  ///
  /// 行切分是**引号感知的状态机**(RFC 4180):双引号内的 `\n` / `\r\n`
  /// 属于字段内容,不切行 —— 否则「备注/商品名含换行」的一行会被拆成两行,
  /// 其后整份文件列错位。
  static List<List<String>> parse(String input) {
    // 规范化换行并移除 UTF-8 BOM
    var text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }

    final lines = _splitLogicalLines(text)
        .where((l) => !_isBlankLine(l))
        .toList(growable: false);
    if (lines.isEmpty) return const [];

    // 1. 先尝试自动检测常规分隔符（逗号/制表符/分号/竖线）
    final delimiter = _detectDelimiter(lines);

    List<List<String>> parsed;
    if (delimiter == 'space') {
      parsed = lines.map((l) => _splitSpaceSeparatedLine(l)).toList();
    } else {
      parsed = lines.map((l) => _splitDelimitedLine(l, delimiter)).toList();
    }

    // 2. 如果仍然全部只有 1 列（说明可能不是上述分隔符），且文本出现了连续双空格/制表符，再次尝试空白分隔
    final multiColumn = parsed.any((r) => r.length > 1);
    if (!multiColumn) {
      final hasMultiSpaces = RegExp(r' {2,}').hasMatch(text);
      final hasTab = text.contains('\t');
      if (hasTab) {
        final tabParsed =
            lines.map((l) => _splitDelimitedLine(l, '\t')).toList();
        if (tabParsed.any((r) => r.length > 1)) return tabParsed;
      }
      if (hasMultiSpaces) {
        final spaceParsed = lines.map(_splitSpaceSeparatedLine).toList();
        if (spaceParsed.any((r) => r.length > 1)) return spaceParsed;
      }
    }

    return parsed;
  }

  /// 引号感知的逻辑行切分:引号内的换行并入当前行。
  ///
  /// 输入已规范化成 `\n`(CRLF/CR 都转成 `\n`),所以只需认 `\n`。
  /// 未闭合引号的方向仍是"吞并后续"(既有容错口径,不改成报错)。
  static List<String> _splitLogicalLines(String text) {
    final lines = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        // 转义的双引号 "" 不成对切换状态
        if (inQuotes && i + 1 < text.length && text[i + 1] == '"') {
          buf.write('""');
          i++;
          continue;
        }
        inQuotes = !inQuotes;
        buf.write(ch);
        continue;
      }
      if (ch == '\n' && !inQuotes) {
        lines.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    lines.add(buf.toString());
    return lines;
  }

  /// 纯空白行(不含引号状态)判空 —— 与旧 `.where((l) => l.trim().isNotEmpty)` 等价。
  static bool _isBlankLine(String line) => line.trim().isEmpty;

  /// 自动检测分隔符（不进入引号内部）
  ///
  /// 判据从「出现次数最多」改成「**列数一致性**评分」:候选分隔符对同一批行
  /// 切出的列数越稳定、且表头列数 > 1,得分越高。
  ///
  /// 计数法在「tab 文件 + 备注含较多逗号」时会把逗号选成分隔符(随后 tab 被删、
  /// 表头塌成 1 列),列数一致性判据天然免疫 —— 真实分隔符切出的列数在整份
  /// 文件里是一致的,错误分隔符切出的列数会随备注里的逗号数波动。
  static String _detectDelimiter(List<String> lines) {
    // 扩大到前50行，以覆盖支付宝CSV前面的描述行（表头在第25行左右）
    final maxLines = lines.length < 50 ? lines.length : 50;
    final sample = lines.take(maxLines).toList(growable: false);

    const candidates = [',', '\t', ';', '|'];
    String? best;
    var bestScore = -1.0;

    for (final delimiter in candidates) {
      final columnCounts = <int>[];
      for (final line in sample) {
        // 空行在切列前已剔除,但仍防御一下:跳过切不出列的候选
        columnCounts.add(_splitDelimitedLine(line, delimiter).length);
      }
      if (columnCounts.isEmpty) continue;

      final headerCols = columnCounts.first;
      // 表头必须真的被这个分隔符切成多列,否则它不可能是本文件的分隔符
      if (headerCols <= 1) continue;

      // 一致性 = 与「众数列数」相同的行占比;众数列数用出现最多者近似
      final freq = <int, int>{};
      for (final c in columnCounts) {
        freq[c] = (freq[c] ?? 0) + 1;
      }
      var modeCount = 0;
      var modeCols = headerCols;
      freq.forEach((cols, count) {
        if (count > modeCount || (count == modeCount && cols > modeCols)) {
          modeCount = count;
          modeCols = cols;
        }
      });

      // 表头列数与众数列数一致时给最高分(表头属于数据的一部分)
      final consistency = modeCount / columnCounts.length;
      final headerBonus = modeCols == headerCols ? 1.0 : 0.0;
      final score = consistency + headerBonus + modeCols * 1e-6;
      if (score > bestScore) {
        bestScore = score;
        best = delimiter;
      }
    }

    if (best != null) return best;

    // 检查是否存在连续多空格用于分隔
    final hasMultiSpaces =
        sample.any((l) => RegExp(r' {2,}').hasMatch(l));
    if (hasMultiSpaces) return 'space';
    // 默认回退逗号（保持与以前行为兼容）
    return ',';
  }

  /// 拆分一行：适用于明确单字符分隔符（逗号/制表符/分号/竖线），支持双引号转义
  static List<String> _splitDelimitedLine(String line, String delimiter) {
    final out = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }
      if (!inQuotes && ch == delimiter) {
        out.add(_cleanCsvField(buf.toString()));
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    out.add(_cleanCsvField(buf.toString()));
    return out;
  }

  /// 空格（或多个空格）分隔的行拆分：忽略引号内空格
  ///
  /// 单空格同样算分隔符(既有口径),但**空格千分位**要先合并:
  /// `1 234.56` 是一个金额而不是「1」+「234.56」—— 否则整行从金额列起右移。
  static List<String> _splitSpaceSeparatedLine(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    int spaceRun = 0;
    void pushBuf() {
      out.add(_cleanCsvField(buf.toString()));
      buf.clear();
    }

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        spaceRun = 0;
        continue;
      }
      if (!inQuotes && ch == ' ') {
        spaceRun++;
        continue;
      }
      // 碰到非空格字符
      if (!inQuotes && spaceRun > 0) {
        // 空格千分位:buf 的末段是 1~3 位数字、下一段是 3 位数字(可带小数)时,
        // 该空格不是分隔符,原样并入当前字段。
        if (spaceRun == 1 &&
            buf.isNotEmpty &&
            _looksLikeThousandsGroupStart(buf.toString(), line, i)) {
          buf.write(' ');
          spaceRun = 0;
          buf.write(ch);
          continue;
        }
        // 之前累积的空格作为分隔符（忽略行首空格）
        if (buf.isNotEmpty) {
          pushBuf();
        }
        spaceRun = 0;
      }
      buf.write(ch);
    }
    // 行尾 push
    if (buf.isNotEmpty) {
      pushBuf();
    }
    return out;
  }

  /// 判断 `buf + ' ' + line[i..]` 是否构成空格千分位金额的中间态。
  ///
  /// 条件(保守,只在明显是千分位时合并):
  /// - 已累积内容以 1~3 位数字结尾(千分位组的左侧)
  /// - 空格后紧随恰好 3 位数字,且该 3 位数字之后是行尾 / 小数点 / 空格
  ///   (即 `234.56` / `234` 这种千分位组,而不是 `1 23` 这种普通分词)
  static bool _looksLikeThousandsGroupStart(
      String buf, String line, int start) {
    final trimmed = buf.trimRight();
    final tail = RegExp(r'(\d{1,3})$').firstMatch(trimmed);
    if (tail == null) return false;

    var j = start;
    var digits = 0;
    while (j < line.length &&
        digits < 4 &&
        line[j].codeUnitAt(0) >= 0x30 &&
        line[j].codeUnitAt(0) <= 0x39) {
      digits++;
      j++;
    }
    if (digits != 3) return false;
    // 组后必须是行尾 / 小数点 / 空格(下一组或列分隔)
    if (j >= line.length) return true;
    final next = line[j];
    return next == '.' || next == ' ';
  }

  /// 清理 CSV 字段：去除首尾空格和引号转义
  static String _cleanCsvField(String raw) {
    var s = raw.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1).replaceAll('""', '"').trim();
    }
    return s;
  }
}
