/// 日期解析工具类
/// 支持多种常见日期格式的自动解析
///
/// 口径(与 `test/utils/date_parser_test.dart` 一致):
/// - 除非串里显式带 UTC 标记,一律按**本地墙钟**解析(`parse` 返回本地时间);
/// - 解析失败**不再回落 `DateTime.now()`**(见 [parseOrNull]/[tryParse]);
/// - 显式写出的年月日/时分秒必须是真实存在的日历时刻,否则整体判为不可解析:
///   `2026-02-30`、`2025-02-29`、`2026年13月40日`、`99:99:99` 一律返回 null,
///   而不是让 `DateTime`/`DateFormat` 静默进位到相邻日期。
class DateParser {
  DateParser._();

  /// 歧义写法(`03-04-2026`:日/月都 ≤12)的默认解读。
  ///
  /// `true` = `dd-MM`(日在前,默认 —— 中文账单/欧洲写法常见);
  /// `false` = `MM-dd`(美式)。仅在两个数字都 ≤12 时生效;
  /// 任一侧 >12 时按「唯一合法解读」自动判定,不看此开关。
  static bool preferDayFirstForAmbiguous = true;

  /// 诊断计数:解析中遇到「日/月都 ≤12」的歧义写法时 +1(只记账,不影响结果)。
  ///
  /// 存在的意义:歧义日期一旦解读错,误差是"月/日互换"而不是明显报错,
  /// 需要一个可观察的量供排查(日志/测试)。
  static int ambiguousDateCount = 0;

  /// 尝试解析日期字符串,失败时返回 [fallback](未指定则 `DateTime.now()`)。
  ///
  /// 支持的格式包括:
  /// - ISO 8601: `2024-11-05`、`2024-11-05T12:30:45`、`2024-11-05T00:00:00+08:00`
  /// - 中文格式: `2024年11月5日`、`2024年11月05日 12:30:45`
  /// - 常见格式: `2024/11/05`、`2024-11-05 12:30:45`、`03-04-2026`(dd-MM-yyyy)、
  ///   `05/03/2026`(dd/MM/yyyy)
  ///
  /// 注意:`fallback` 的「未传」与「显式传 null」无法区分 —— 两者都会回落
  /// `DateTime.now()`。需要「解析失败即 null」请用 [parseOrNull]/[tryParse];
  /// 需要「失败即某个明确值」请显式传 [fallback]。
  ///
  /// 返回解析后的 DateTime 对象
  static DateTime parse(String? dateStr, {DateTime? fallback}) {
    if (dateStr == null || dateStr.trim().isEmpty) {
      return fallback ?? DateTime.now();
    }

    return parseOrNull(dateStr) ?? fallback ?? DateTime.now();
  }

  /// 尝试解析日期字符串,**失败时返回 null**(绝不回落 `now()`)。
  ///
  /// 导入等场景依赖「解析失败 = null」来做无效行判定(1970 sentinel),
  /// 不能用 [parse] 的 now() 兜底 —— 那会把垃圾日期伪装成"导入那一刻"。
  static DateTime? parseOrNull(String? dateStr) {
    if (dateStr == null || dateStr.trim().isEmpty) return null;
    final trimmed = dateStr.trim();

    // 1. 标准 ISO 8601(带日历校验)
    final iso = _tryParseIso(trimmed);
    if (iso != null) return iso.toLocal();

    // 2. 中文日期
    final zh = _tryParseChineseDate(trimmed);
    if (zh != null) return zh;

    // 3. 常见日期格式(严格形状 + 日历校验)
    return _tryParseCommonFormats(trimmed);
  }

  /// 尝试解析 ISO 8601 标准格式
  ///
  /// `DateTime.parse` 不校验日历(会把 `2026-02-30` 顺延成 `2026-03-02`),
  /// 所以对「yyyy-MM-dd / yyyyMMdd 显式形状」的输入额外做一次回写校验 ——
  /// 日期分量与时分秒分量都校验,`2026-05-26 99:99:99` 这类越界时间同样拒绝。
  static DateTime? _tryParseIso(String dateStr) {
    final DateTime parsed;
    try {
      parsed = DateTime.parse(dateStr);
    } catch (_) {
      return null;
    }
    final match =
        _isoExtended.firstMatch(dateStr) ?? _isoBasic.firstMatch(dateStr);
    if (match != null) {
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      if (!_isRealDate(year, month, day)) return null;
      // 时间分量(若串里显式写了):0-23 / 0-59 / 0-59,不允许溢出进位。
      // 例外:`24:00:00` 是 ISO 8601 合法的"当日结束"写法(= 次日 00:00),
      // 保留既有行为;`24:00:01` 这类仍拒绝。
      final hour = match.group(4) == null ? 0 : int.parse(match.group(4)!);
      final minute = match.group(5) == null ? 0 : int.parse(match.group(5)!);
      final second = match.group(6) == null ? 0 : int.parse(match.group(6)!);
      if (!_isRealTime(hour, minute, second)) return null;
    }
    return parsed;
  }

  /// ISO 扩展格式:yyyy-MM-dd,后接可选的时间段(与可选时区段)
  static final RegExp _isoExtended = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})'
      r'(?:[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.\d+)?)?'
      r'(?:[Zz]|[+-]\d{2}:?\d{2})?)?$');

  /// ISO 基本格式:yyyyMMdd,后接可选的时间段(与可选时区段)
  static final RegExp _isoBasic = RegExp(
      r'^(\d{4})(\d{2})(\d{2})'
      r'(?:[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.\d+)?)?'
      r'(?:[Zz]|[+-]\d{2}:?\d{2})?)?$');

  /// 尝试解析中文日期格式
  ///
  /// 支持格式:
  /// - 2024年11月5日
  /// - 2024年11月05日
  /// - 2024年11月5日 12:30
  /// - 2024年11月5日 12:30:45
  static DateTime? _tryParseChineseDate(String dateStr) {
    final trimmed = dateStr.trim();

    // 匹配 "YYYY年MM月DD日 [HH:mm[:ss]]" 格式
    final regex = RegExp(
      r'(\d{4})年(\d{1,2})月(\d{1,2})日(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?'
    );

    final match = regex.firstMatch(trimmed);
    if (match == null) return null;

    try {
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      final hour = match.group(4) != null ? int.parse(match.group(4)!) : 0;
      final minute = match.group(5) != null ? int.parse(match.group(5)!) : 0;
      final second = match.group(6) != null ? int.parse(match.group(6)!) : 0;

      return _buildRealDate(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// 尝试使用常见日期格式解析。
  ///
  /// 这些格式都是**无时区信息的裸墙钟时间**(斜杠分隔、单数字月份、MM/dd/yyyy 等,
  /// 过不了 DateTime.parse),按口径一律解析为**本地时间**(`parse` 默认 utc=false)。
  /// 切勿用 `parse(str, /*utc=*/true)` 强标 UTC —— 那会让 CSV 导入的本地时间在
  /// 本地(如 UTC+8)展示时整体 +8 小时(历史 bug)。
  ///
  /// 实现说明:不再依赖 intl `DateFormat` 的宽松匹配 —— 它对**宽度不校验**,
  /// 会让 `yyyy-MM-dd` 抢走 `03-04-2026`(把 2026 当"日"溢出成 0008 年),
  /// 也会把 `2026-02-30` 顺延成 `2026-03-02`。这里改为严格 regex + 回写校验。
  static DateTime? _tryParseCommonFormats(String dateStr) {
    final s = dateStr.trim();
    if (s.isEmpty) return null;

    // 1. 年在前:yyyy-MM-dd / yyyy/MM/dd(月日允许 1~2 位,兼容 2026-6-25)
    final yearFirst = _yearFirstPattern.firstMatch(s);
    if (yearFirst != null) {
      return _buildRealDate(
        int.parse(yearFirst.group(1)!),
        int.parse(yearFirst.group(2)!),
        int.parse(yearFirst.group(3)!),
        _g(yearFirst, 4),
        _g(yearFirst, 5),
        _g(yearFirst, 6),
      );
    }

    // 2. 日/月在前:dd-MM-yyyy / MM/dd/yyyy(dd/MM/yyyy 同形,靠数值判定)
    final dayMonthFirst = _dayMonthFirstPattern.firstMatch(s);
    if (dayMonthFirst != null) {
      final first = int.parse(dayMonthFirst.group(1)!);
      final second = int.parse(dayMonthFirst.group(2)!);
      final year = int.parse(dayMonthFirst.group(3)!);

      final int day;
      final int month;
      if (first > 12 && second <= 12) {
        // 只有「日 = first」合法
        day = first;
        month = second;
      } else if (second > 12 && first <= 12) {
        // 只有「月 = first」合法(MM/dd/yyyy)
        month = first;
        day = second;
      } else {
        // 两个数字都 ≤12(或都 >12):歧义写法。默认 dd-MM,可按配置切到 MM-dd。
        ambiguousDateCount++;
        if (preferDayFirstForAmbiguous) {
          day = first;
          month = second;
        } else {
          month = first;
          day = second;
        }
      }

      return _buildRealDate(
        year,
        month,
        day,
        _g(dayMonthFirst, 4),
        _g(dayMonthFirst, 5),
        _g(dayMonthFirst, 6),
      );
    }

    // 其余格式不支持:返回 null(由调用方决定怎么办)。
    // 尤其不要让 `DateTime.now()` 兜底 —— 那会把「2026.01.05」「昨天」这类
    // 未识别写法伪装成导入时刻的账单。
    return null;
  }

  /// yyyy-MM-dd / yyyy/MM/dd,时间部分可选
  static final RegExp _yearFirstPattern = RegExp(
      r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$');

  /// dd-MM-yyyy / MM/dd/yyyy,时间部分可选
  static final RegExp _dayMonthFirstPattern = RegExp(
      r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$');

  static int _g(Match m, int i) => int.tryParse(m.group(i) ?? '') ?? 0;

  /// 时分秒是否合法。`24:00:00` 是 ISO 8601 的"当日结束"写法,按合法处理;
  /// 其余 0-23 / 0-59 / 0-59 之外的一律拒绝(不允许溢出进位)。
  static bool _isRealTime(int hour, int minute, int second) {
    if (hour == 24 && minute == 0 && second == 0) return true;
    if (hour < 0 || hour > 23) return false;
    if (minute < 0 || minute > 59) return false;
    if (second < 0 || second > 59) return false;
    return true;
  }

  /// 该年月日是否真实存在(拒绝 DateTime 的静默进位)。
  static bool _isRealDate(int year, int month, int day) {
    if (month < 1 || month > 12) return false;
    if (day < 1 || day > 31) return false;
    final probe = DateTime(year, month, day);
    return probe.year == year && probe.month == month && probe.day == day;
  }

  /// 构造日期;任一分量非法(日历不存在 / 时分秒越界)→ null。
  static DateTime? _buildRealDate(
      int year, int month, int day, int hour, int minute, int second) {
    if (!_isRealDate(year, month, day)) return null;
    if (hour == 24 && minute == 0 && second == 0) {
      // ISO 8601「24:00:00」= 当日结束 → 用 DateTime 的进位语义得到次日零点
      return DateTime(year, month, day, hour, minute, second);
    }
    if (!_isRealTime(hour, minute, second)) return null;
    return DateTime(year, month, day, hour, minute, second);
  }

  /// 尝试解析日期字符串,失败时返回 null
  ///
  /// 与 [parse] 方法的区别是:解析失败时返回 null 而不是当前时间。
  static DateTime? tryParse(String? dateStr) {
    if (dateStr == null || dateStr.trim().isEmpty) {
      return null;
    }

    return parseOrNull(dateStr);
  }
}
