/// 导入场景的金额文本清洗。
///
/// 存在的意义:导入页的金额列脏法五花八门(全角符号、全角数字、汉字单位、
/// 货币名混排),原先的 `replaceAll(RegExp(r'[¥$,+-]'), '')` 只覆盖半角 ASCII,
/// 于是 `￥100.00`、`共88.00元`、`１２３` 全部解析失败 → 金额 0.0 → 整行被判
/// invalid 静默丢弃(用户只看到"无效行",不知道是格式问题)。
///
/// 与 [normalizeRefundAmount] 的**口径差异(有意如此,不要合并)**:
/// - 本文件的函数用在**导入页主金额列**,目标是"尽量救回可识别的金额",
///   接受全角数字/汉字混排;
/// - `normalizeRefundAmount`(各 provider parser)用在退款列,遇到 `１００`
///   这类不确定写法必须返回 null(宁可不记也不误算)。两者共用清洗会互相
///   污染:放宽退款侧会把"不确定"变成"猜一个值",收紧导入侧会整行丢金额。
library;

/// 清洗金额文本:全角 → 半角、去货币符号/汉字单位/千分位/空白。
///
/// 保留:数字、小数点、正负号、科学计数法指数;其余字符(汉字、字母、
/// 货币符号、分隔符)一律删除 —— 调用方随后用 [parseImportAmount] 解析,
/// 解析不出数字才算失败。不要在这里判"是否合法",那是调用方的事。
///
/// 例:`'共￥88.00元'` → `'88.00'`;`'１２３'` → `'123'`;`'1,234.56'` → `'1234.56'`。
String cleanAmountText(String? raw) {
  if (raw == null) return '';
  var s = raw;

  // 1. 全角 ASCII(U+FF01..U+FF5E)→ 半角。覆盖全角数字 ０-９、全角逗号 ，、
  //    全角句点 ．、全角加号/减号 ＋/－、全角货币符号 ￥(U+FFE5 不在该区间,
  //    单独处理)。
  s = s.replaceAllMapped(
    RegExp('[\uFF01-\uFF5E]'),
    (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
  );

  // 2. 全角空格 / 不换行空格 / 各种 Unicode 空白 → 普通空格(下一步一并删除)
  s = s.replaceAll(RegExp('[\u3000\u00A0\u202F]'), ' ');

  // 3. 汉字单位与货币名:先长后短(人民币 → 元),避免残留单字。
  s = s.replaceAll('人民币', '');
  s = s.replaceAll(RegExp('[元块钱圆角分]'), '');

  // 4. 货币符号(U+00A5/U+FFE5 半角与全角 ¥、$、€、£、₩、฿、₽、₹ 等)
  s = s.replaceAll(RegExp('[\u00A5\uFFE5\$€£₩฿₽₹]'), '');

  // 5. 千分位与分组分隔符(半/全角逗号、下划线、空格、顿号)
  s = s.replaceAll(RegExp('[,_ 、]'), '');

  // 6. 数学符号区的破折号/短横线:统一成 ASCII '-' 让 double.tryParse 认
  s = s.replaceAll(RegExp('[\u2212\uFF0D\u2013\u2014]'), '-');

  return s.trim();
}

/// 解析导入页金额文本。失败/空/纯文字 → `0.0`(调用方据此判 invalid)。
///
/// 先整体 `double.tryParse`(保证 `1e10`、`12.345` 这类正常写法逐字等价),
/// 失败再退到"取第一个数字串"(`共88.00元` 这类混排文字)。
double parseImportAmount(String? raw) {
  final cleaned = cleanAmountText(raw);
  if (cleaned.isEmpty) return 0.0;

  final direct = double.tryParse(cleaned);
  if (direct != null) return direct.abs();

  // 混排文字:取第一个数字串(含小数与科学计数法指数)。
  final match =
      RegExp(r'\d+(?:\.\d+)?(?:[eE][+-]?\d+)?').firstMatch(cleaned);
  if (match == null) return 0.0;
  return double.tryParse(match.group(0)!)?.abs() ?? 0.0;
}
