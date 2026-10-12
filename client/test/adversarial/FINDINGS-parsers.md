# 解析器/文本处理域 — 对抗性测试发现报告

**范围**：SmartBook Flutter 客户端（`D:\github\smartbook\client`）的解析器与文本处理域。
**日期**：2026-10-11
**方法**：只新建 `test/adversarial/**` 测试，不改 `lib/**` 任何产品代码。
**运行**：`flutter test test/adversarial/<file>.dart`（每文件独立跑，flake 复查 3 次以上结果一致）。

## 汇总

| 测试文件 | 测试数 | 绿 | 红 |
| --- | --- | --- | --- |
| `parsers_amount_date_adversarial_test.dart` | 72 | 52 | **20** |
| `csv_encoding_adversarial_test.dart` | 39 | 30 | **9** |
| `ai_json_response_adversarial_test.dart` | 82 | 68 | **14** |
| `notification_fingerprint_adversarial_test.dart` | 54 | 47 | **7** |
| **合计** | **247** | **197** | **50** |

50 条红色测试 = 确认缺陷（部分为同根因的不同表现）。另附 30+ 条 HARDENING（当前行为可辩护但脆弱，测试断言当前行为并通过）。
所有 50 条红测**期望值都是"正确行为"**（断言失败即证明产品行为不符预期），非"锁定错误行为"。连续跑 4 次结果完全一致，无 flake。

严重级分布：**critical 2 / high 14 / medium 28 / low 6**。

---

## 1. 金额链路：非有限值穿透 → 账本余额渲染崩溃（critical）

**标题**：`Infinity` 金额从 AI 响应一路穿透到账本余额，非紧凑模式的余额渲染抛 `RangeError`。

**证据链**（三处源码协同）：
- `lib/ai/core/json_response_parser.dart:123-125` — `_sanitize` 用 `if (amt == null || amt.abs() <= 0) return null;` 做有效性判定。`NaN.abs() <= 0` 与 `Infinity.abs() <= 0` 恒为 `false`，于是**非有限金额不被丢弃**。
- `lib/data/repositories/local/local_repository.dart:378-404` — `addTransaction` 无 `isFinite` 校验。实测 `Infinity` 被 SQLite 接受并落库（`amount` 列读回 `Infinity`）；`NaN` 侥幸被 `NOT NULL` 约束挡住（抛 `SqliteException(1299)`）。
- `lib/data/repositories/local/local_ledger_repository.dart:107-127` — `getLedgerStats` 用 `SUM(CASE ... END)` 聚合，一笔 `Infinity` 使 `balance = Infinity`。
- `lib/utils/format_utils.dart:122-124` — `formatBalanceFull` 取 `absBalance.toStringAsFixed(2).split('.')[1]`。`toStringAsFixed` 对 `NaN`/`Infinity` 返回不含 `.` 的字符串 → **`parts[1]` 越界 → `RangeError`**。

**测试**（3 条）：
- `ai_json_response_adversarial_test.dart` › `崩溃链闭环:NaN/Infinity 金额 → 落库 → 余额渲染崩溃` › `Infinity 金额可落库(数据库层无 isFinite 校验)`
- 同组 › `NaN 金额被 sqlite NOT NULL 拒绝(侥幸挡住)`（此条绿，作为对照）
- 同组 › `Infinity 落库后账本余额渲染抛 RangeError`
- 同组（金额滤网）› `amount="NaN" 穿过滤网(应被丢弃)`、`amount="Infinity" 穿过滤网(应被丢弃)`、`JSON 字面量 1e400 溢出成 Infinity 并穿过`
- `parsers_amount_date_adversarial_test.dart` › `格式化:formatBalance / formatBalanceFull 边界` › `formatBalanceFull(NaN) 抛 RangeError`、`formatBalanceFull(Infinity) 抛 RangeError`、`formatBalanceFull(1e21) 抛 RangeError(指数记法无小数点)`

**期望 vs 实际**：
```
期望：parse('[{"amount":"NaN"}]') → []（丢弃）        实际：1 笔，amount = NaN
期望：addTransaction(amount: Infinity) 被拒绝          实际：落库成功，读回 Infinity
期望：stats.balance.isFinite == true                  实际：balance = -Infinity
期望：formatBalanceFull(Infinity) 返回字符串           实际：RangeError (length): Only valid value is 0: 1
```
（`1e21` 也崩 —— `toStringAsFixed` 在 ≥1e21 走指数记法 `"1e+21"`，同样无 `.`。`ledger_card.dart:211` 在「非紧凑金额」开关下直接调 `formatBalanceFull(ledger.balance, ...)`，所以这是用户可达路径。）

**一句话复现**：让 AI（或任何上游）回一笔 `{"amount":"Infinity"}` 的账单，入账后把账本卡的金额显示切到非紧凑模式 → 账本页抛 `RangeError`。

---

## 2. CSV：引号内换行没有做字段内行切分（critical）

**标题**：RFC 4180 合法的内嵌换行被当行尾，一行被拆成两行，其后整份文件列错位。

**源码**：`lib/services/import/csv_parser.dart:11-14`
```dart
final lines = text
    .split('\n')                                      // ← 先切行
    .where((l) => l.trim().isNotEmpty)
    .toList(growable: false);
```
`_splitDelimitedLine` 虽然支持引号内的分隔符,但**行切分发生在它之前** —— 引号状态跨越不了换行。

**测试**（3 条，`csv_encoding_adversarial_test.dart`）：
- `引号内的换行把一行拆成两行`
- `拆行后数据行列数少于表头(列错位)`
- `CRLF 形式的内嵌换行同样被拆(且保留 \r 语义破坏)`

**期望 vs 实际**：
```
输入：'商家,备注,金额\n盒马,"多行\n备注",88.00\n'
期望：2 行 → [表格行] [盒马, "多行\n备注", 88.00]
实际：3 行 → [['商家','备注','金额'], ['盒马','多行'], ['备注,88.00']]
     └─ 数据行只剩 2 列（表头 3 列）→ amount 列索引越界 → 该行金额缺失
```

**一句话复现**：导入一份备注/商品名含换行的账单 CSV（电商导出常见），从该行起金额与日期全部错位。

---

## 3. CSV：分隔符按"字符计数"选择，tab 文件被误判（high）

**标题**：`_detectDelimiter` 用"出现次数最多"选分隔符而不看列数一致性；制表符文件里备注含较多逗号即被误判为逗号文件，随后所有 tab 被删除。

**源码**：`lib/services/import/csv_parser.dart:57-95`（计数选择）+ `:23-27`（非 tab 分隔符时 `replaceAll('\t','')` 删除**全部**制表符）。

**测试**：`csv_encoding_adversarial_test.dart` › `CSV:分隔符自动检测(计数法)` › `tab 文件 + 备注含逗号 → 分隔符误判为逗号,表头塌成 1 列` / `同一份 tab 文件的数据行列数 ≠ 表头列数(整份错位)`

**期望 vs 实际**：
```
输入：'日期\t金额\t备注\n2026-01-01\t1.00\t买,买,买,买\n...(3 数据行)'
期望：表头 3 列（日期 / 金额 / 备注）
实际：表头 1 列（"日期金额备注" —— tab 被删），数据行 4 列（按逗号切）
     └─ 列映射全部失效 → 整份导入无效
```

**一句话复现**：导入一份 tab 分隔、备注含 2 个以上逗号的账单（逗号数 > tab 数即触发）。

---

## 4. 文件编码：单个坏字节使整个 UTF-8 文件变 GBK 乱码（high）

**标题**：U+FFFD 检测触发的 GBK 兜底把"单点损坏"放大成"整份乱码"。

**源码**：`lib/services/import/file_reader.dart:137-157`
```dart
try {
  final utfText = utf8.decode(bytes, allowMalformed: false);
  if (!utfText.contains('\uFFFD')) return utfText;   // ← 只有一个 U+FFFD 就整体放弃
} catch (_) {}
try {
  final gbkText = gbk_bytes.decode(bytes);
  if (_containsChineseCharacters(gbkText)) return gbkText;   // ← 乱码必含汉字 → 通过
} catch (_) {}
```
关键：UTF-8 的 `EF BF BD`（U+FFFD 本身）是**合法 GBK**，所以"含 U+FFFD 的合法 UTF-8"会被 GBK 重新解码成乱码，且乱码里必然含汉字，检测通过。

**测试**（3 条，`csv_encoding_adversarial_test.dart` › `文件编码:decodeBytes`）：
- `单个坏字节使整个 UTF-8 文件变 GBK 乱码`
- `合法含 U+FFFD 的 UTF-8 文本也变乱码`
- `UTF-8 被截断的多字节序列 → 乱码(不 partial-decode)`

**期望 vs 实际**：
```
输入：utf8('交易') + [0xFF] + utf8('时间')
期望：'交易\uFFFD时间'（单点损坏）
实际：'浜ゆ槗￦椂闂´'（整串乱码）

输入：utf8('备注\uFFFD测试')（完全合法的 UTF-8）
期望：'备注\uFFFD测试'
实际：'澶囨敞锟芥祴璇'（整串乱码）
```
副产品：无 BOM 的 UTF-16 走同一路径产出乱码（`UTF-16 无 BOM → 乱码;奇数尾字节被丢弃`，此条为 HARDENING/绿）。

**一句话复现**：导入一份 UTF-8 账单，其中任意一个字节损坏（或备注里用户真的打了 `�`）→ 整份文件乱码且不被察觉。

---

## 5. 日期：格式表顺序把 `dd-MM-yyyy` 判成公元 8 年（high）

**标题**：`_tryParseCommonFormats` 的格式顺序让 `yyyy-MM-dd` 抢走 `03-04-2026`，年份被当成"日"并溢出进位。

**源码**：`lib/utils/date_parser.dart:88-103`（格式列表顺序：`'yyyy-MM-dd HH:mm:ss'`、`'yyyy-MM-dd HH:mm'`、…、`'yyyy/MM/dd HH:mm:ss'` … 之后才是 `'dd-MM-yyyy'`）。

**测试**：`parsers_amount_date_adversarial_test.dart` › `日期:DateParser 与非法日期的静默顺延` › `"03-04-2026" 被 yyyy-MM-dd 抢走 → 0008-10-16` / `"01-02-2026" 同样塌成 0006-08-19` / `"05/03/2026" 被 yyyy/MM/dd 抢走 → 0010-09-16`

**期望 vs 实际**：
```
输入：'03-04-2026'        期望：2026-04-03（dd-MM-yyyy）     实际：0008-10-16
输入：'01-02-2026'        期望：2026-02-01 或 2026-01-02    实际：0006-08-19
输入：'05/03/2026'        期望：2026-03-05 或 2026-05-03    实际：0010-09-16
```
差 ~2018 年。导入页把该值当 `happenedAt` 落库；`validDate`（`year > 1970`）会拦住 0008/0006/0010 —— 也就是说这几行会变成 invalid 而不是错日期，但用户只会看到"无效行"，无法知道是日期格式问题。

**一句话复现**：导入一份日-月-年（或月/日/年）写法的账单 CSV。

---

## 6. 日期：不可解析 → `now()`，导入页的 1970 sentinel 是死代码（high）

**标题**：`DateParser.tryParse` 文档说"失败返回 null"，实际返回 `DateTime.now()`；导入页据此判定"无效行"的 sentinel 因此几乎永不生效，垃圾日期直接当成交易日期入账。

**源码**：
- `lib/utils/date_parser.dart:120-126` — `tryParse` → `parse(dateStr, fallback: null)`
- `lib/utils/date_parser.dart:37` — `return fallback ?? DateTime.now();` ← fallback 为 null 时返回 now()
- `lib/pages/data/import_confirm_page.dart:1069` — `final date = DateParser.tryParse(dateStr) ?? DateTime(1970, 1, 1);`（注释明说"非法/空日期使用 epoch sentinel，导入服务会拒绝该行"）
- `lib/services/data_import_service.dart:260-261` — `validDate = year > 1970 && year <= now.year + 1`

后果：兜底出的 `now()` **恰好落在合法区间**，`validDate` 拦不住。

**测试**（`parsers_amount_date_adversarial_test.dart` › `日期:DateParser 与非法日期的静默顺延`，共 12 条红）：
`2026-02-30 应被拒绝(拒绝而非顺延)`、`2025-02-29(非闰年)应被拒绝`、`中文非法日期 2026年2月30日 应被拒绝`、`2026年13月40日 应被拒绝(而非跨年顺延)`、`无法解析的日期串 → now()(导入页 sentinel 失效)`、`"2026.01.05"(点分隔)不被识别 → now()`、`"Jan 5, 2026"(英文月份)不被识别 → now()`、`"0" 不被识别 → now()`、`相对日期「昨天/前天」不被识别 → now()(中文账单常见)`、`上午12点 / 下午12点 歧义: 全部落成 now() 且无法区分`、`全角数字日期 → now()`、`13月40日(无年份)不匹配中文正则 → now()`

**期望 vs 实际**：
```
输入：'2026-02-30'        期望：null（不存在的日期）              实际：2026-03-02
输入：'2025-02-29'        期望：null                             实际：2025-03-01
输入：'2026年13月40日'     期望：null                            实际：2027-02-09
输入：'待定'              期望：1970 sentinel → 该行 invalid      实际：DateTime.now()
输入：'昨天'              期望：昨天 00:00 或 sentinel            实际：导入那一刻
输入：'2026.01.05'        期望：2026-01-05 或 sentinel           实际：导入那一刻
输入：'上午12点'/'下午12点' 期望：两者相差 12 小时                  实际：同一次 now() 兜底
```
附带：`日期:导入页 sentinel 与导入服务的 validDate 交互` › `now() 兜底的值能通过 validDate(垃圾日期不会被拦)` 把这条链锁死（绿）。

**一句话复现**：导入一份日期列写成 `2026.01.05`（点分隔）或含 `昨天` 的账单 → 这些行落库时间为导入时刻。

---

## 7. 日期：非法日历日期被"顺延"而非拒绝（medium）

**标题**：`2026-02-30`、`2025-02-29` 等不存在的日期被 `DateTime`/`DateFormat` 静默进位到相邻日期。

**源码**：`lib/utils/date_parser.dart:41-47`（`DateTime.parse` 不校验日历）、`:56-79`（中文分支 `DateTime(y,m,d)` 同样顺延）、`lib/ai/core/bill_info.dart:399-419`（AI 时间解析同病）。

**测试**：
- `parsers_amount_date_adversarial_test.dart` › `2026-02-30 应被拒绝(拒绝而非顺延)`、`2025-02-29(非闰年)应被拒绝`、`中文非法日期 2026年2月30日 应被拒绝`、`2026年13月40日 应被拒绝(而非跨年顺延)`
- `ai_json_response_adversarial_test.dart` › `时间:兜底、时区、非法值` › `"2026-2-30" 应被拒绝而非顺延`、`"2026年2月30日" 应被拒绝而非顺延`、`"2026-05-26 99:99:99" 应被拒绝而非进位`

**期望 vs 实际**：
```
输入：'2026-02-30'                 期望：null / 拒绝        实际：2026-03-02
输入：'2025-02-29'                 期望：null / 拒绝        实际：2025-03-01
输入：'2026年13月40日'             期望：null / 拒绝        实际：2027-02-09
输入：'2026-05-26 99:99:99'       期望：null / 拒绝        实际：2026-05-30 04:40:39
```
最后一条尤其危险：`_parseTime` 的本地正则分支构造 `DateTime(2026,5,26,99,99,99)` 并成功返回，`timeInferred` 保持 `false` —— 这笔"时间可信"的假时间会绕过策略层的 `time_precision_weak` 闸门（`lib/services/automation/auto_book_policy.dart:219-229`）。

---

## 8. 金额清洗：全角符号/汉字混排使金额归零，整行被判 invalid（high）

**标题**：导入页金额清洗只删 ASCII `¥`/`$`，不处理全角 `￥`、汉字、全角数字。

**源码**：`lib/pages/data/import_confirm_page.dart:1063`
```dart
final amountClean = (amountStr ?? '').replaceAll(RegExp(r'[¥$,+-]'), '');
final amount = double.tryParse(amountClean)?.abs() ?? 0.0;
```
`[¥$,+-]` 里的 `¥` 是 **U+00A5**（半角），不含 **U+FFE5**（全角 `￥`）。

**测试**（`parsers_amount_date_adversarial_test.dart` › `金额:导入页清洗(与 import_confirm_page 同口径)`）：
- `全角￥前缀金额被解析成 0.0(整行判无效)`
- `金额+文字混排「共￥88.00元」→ 0.0`
- `全角数字金额 → 0.0`

**期望 vs 实际**：
```
输入：'￥100.00'      期望：100.0        实际：0.0 → 导入服务记 invalid，整行丢弃
输入：'共88.00元'     期望：88.0         实际：0.0
输入：'１２３'         期望：123.0        实际：0.0
```
支付宝导出的「金额（元）」列在部分版本里带全角 `￥`。

---

## 9. 金额清洗：Unicode 负号导致退款金额静默丢失（medium）

**标题**：`normalizeRefundAmount` 的删除集不含 U+2212（数学减号）/U+FF0D（全角减号）/U+2013。

**源码**：`lib/services/import/bill_parser.dart:33-38` 与 `lib/services/import/parsers/generic_parser.dart:16-21`
```dart
double.tryParse(raw.replaceAll(RegExp(r'[¥￥$,+，]'), '').trim())?.abs();
```

**测试**：`parsers_amount_date_adversarial_test.dart` › `金额:退款金额归一 normalizeRefundAmount` › `Unicode 负号(−/－)导致退款金额丢弃`

**期望 vs 实际**：`normalizeRefundAmount('\u221250.00')` 期望 `50.0`，实际 `null` → 该行退款金额整笔丢失，下游按"无退款"处理。

---

## 10. AI JSON：字段类型错使整笔账单被静默跳过（high）

**标题**：`BillInfo.fromJson` 对若干字段用裸 `as String?` / `as int?` 强转；AI 把 `note`/`category` 写成数字（极常见）时抛 `TypeError`，被 `parse` 的 catch 接住 → **整笔丢失**，仅留一条 warning 日志。

**源码**：`lib/ai/core/bill_info.dart:311-324`（`note`/`category`/`ledgerId`/`account`/`from_account`/`to_account`/`merchant`/`card_last4` 裸强转）、`lib/ai/core/json_response_parser.dart:59-61`（catch 后 `continue`）。

**测试**：`ai_json_response_adversarial_test.dart` › `字段类型错:强转抛错吞掉整笔` › `note 给数字 → 整笔被跳过` / `category 给数字 → 整笔被跳过` / `ledgerId 给字符串 → 整笔被跳过`

**期望 vs 实际**：
```
输入：'[{"amount":-30,"note":88}]'
期望：至少保留 amount=-30（note 置空或 toString）
实际：[] —— 整笔丢失。日志：数组第 1 项解析失败,跳过: type 'int' is not a subtype of type 'String?' in type cast
```
同批其它笔不受影响（`一笔类型错不拖累同批其它笔`，绿）。对比：`external_id` 走 `_firstString`（`toString()`），数字型不崩 —— 说明代码里已有两种容错范式，只是没铺开。

---

## 11. AI JSON：多个 BOM / 数组退化导致笔数静默丢失（medium）

**标题**：`_extractBalancedBlock` 找到的块内含 BOM 时数组路径抛 `FormatException`，退化到单对象路径只救回第一笔。

**源码**：`lib/ai/core/json_response_parser.dart:36-73`（数组优先 → 失败 fallback 单对象）、`:195-224`（`_extractBalancedBlock` 不做 BOM 清理）

**测试**：`ai_json_response_adversarial_test.dart` › `围栏/前后文字/BOM/空输入` › `BOM 出现在 `[` 与 `{` 之间:数组路径失败、退化单对象` / `每个对象前都有 BOM → 只救回第一笔`

**期望 vs 实际**：
```
输入：'[<BOM>{"amount":-30},{"amount":-88}]'
期望：2 笔                                  实际：1 笔
日志：数组 JSON 解析失败,尝试单对象 fallback: FormatException ... 账单提取成功(单对象)
```
逐段加 BOM 的网关/代理场景下，第 2 笔起全部静默丢失（无错误上报）。

---

## 12. 提示词拼装：OCR 文本里的占位符被二次替换（medium）

**标题**：`PromptBuilder.build` 用顺序 `replaceAll` 拼装，且 `{{OCR_TEXT}}` 的替换**早于** `{{CATEGORIES}}` / `{{ACCOUNTS}}` / `{{CURRENCIES}}`，于是用户/被识别文本里出现这些占位符时会被替换成真实数据。

**源码**：`lib/ai/core/prompt_builder.dart:263-271`（替换顺序）

**测试**：`ai_json_response_adversarial_test.dart` › `prompt 拼装:注入与占位符` › `OCR 文本里的 {{CATEGORIES}} 被二次替换(提示词注入面)`

**期望 vs 实际**：
```
输入：ocrText = '备注 {{CATEGORIES}} 结束'
期望：prompt 含字面量 '备注 {{CATEGORIES}} 结束'
实际：prompt 含 '备注 分类列表:支出：餐饮… 结束'
```
对照：`{{BILL_GUARD}}` 因为在 `{{OCR_TEXT}}` **之前**替换，侥幸不被二次替换（行为不一致，也是同一根因的证据）。另 `注入语句原样进入 prompt`（绿/HARDENING）显示 OCR 内容与指令同层，无分隔标记。

---

## 13. 指纹：所有指纹都是裸分隔符拼接，可构造碰撞（medium）

**标题**：`smsFingerprint` / `notifyFingerprint` / `screenTextFingerprint` 都是 `sha256(字段用 '|' 拼接)`，无转义/无长度前缀，字段边界可互换。

**源码**：`lib/services/automation/auto_billing_service.dart:1077-1082`（`'$sender|$body'`）、`:1091-1105`（`'$pkg|$key|$id|$postTime|$title|$body'`）、`:1109-1114`（`'$pkg|$text'`）
native 同口径：`android/app/src/main/kotlin/com/smartbook/zhi/SmsReceiver.kt:139-144`、`NotificationWatcher.kt:172-191`、`ScreenTextWatcher.kt:601-606`

**测试**（`notification_fingerprint_adversarial_test.dart`，3 条红）：
- `smsFingerprint:分隔符拼接的碰撞面` › `sender/body 边界互换 → 指纹碰撞`
- `notifyFingerprint:身份字段与内容字段的边界` › `notificationKey/title/body 边界互换 → 指纹碰撞`
- `screenTextFingerprint / billFingerprint` › `pkg/text 边界互换 → 指纹碰撞`

**期望 vs 实际**：
```
smsFingerprint('95555', '消费100|转账')     = fa5437318961eb49
smsFingerprint('95555|消费100', '转账')     = fa5437318961eb49   ← 同一指纹
screenTextFingerprint('com.x', 'a|b')      = 22b8f9f04a5e23e1
screenTextFingerprint('com.x|a', 'b')      = 22b8f9f04a5e23e1   ← 同一指纹
```
危害等级有限（sender 是号码、pkg 是包名，两者的取值域不含 `|`），但屏幕文本来自无障碍抓取的整棵文本树，**内容侧可控**；一旦上游某天把 title 或 key 的来源改成可含 `|` 的字段，碰撞面立即扩大。同一根因还有一个更现实的表现：`billFingerprint` 的 `channel` 完全不归一（`channel 不归一:大小写/空白变化即不同指纹`，绿/HARDENING）—— 渠道名在版本间中文化/加空格会让旧指纹全 miss，导致重复入账。

---

## 14. 指纹：`billFingerprint` 金额精度归一吞掉 0.01 元以内差异（low）

**标题**：`amount.abs().toStringAsFixed(2)` 使 88.004 与 88.00 得到同一指纹。

**源码**：`lib/services/automation/auto_billing_service.dart:1916-1935`

**测试**：`notification_fingerprint_adversarial_test.dart` › `billFingerprint(小时粒度 + 方向)` › `金额 0.005 以内差异 → 可能同指纹(精度归一)`

**期望 vs 实际**：`-88.004` 与 `-88.0` 期望不同指纹，实际相同。精度归一是去重的**有意设计**（注释已说明），但意味着折扣券前后 4 厘差异的真实两笔会被当成同一笔。列为 low。

---

## 15. 导入状态：`退款关闭` 同时命中"退款"与"不可记账"（medium）

**标题**：`isNonBookableStatus` 与 `isRefundStatus` 对同一状态给出冲突判定，导入服务按失效丢弃。

**源码**：`lib/services/data_import_service.dart:592-621`（两个判定无优先级协调；`isNonBookableStatus` 的 `'关闭'` 子串先命中）；`lib/services/import/parsers/alipay_parser.dart:113`（`normalizeStatus` 把 `退款关闭` 归一成 `refund`，与过滤口径冲突）。

**测试**：`notification_fingerprint_adversarial_test.dart` › `导入状态归一:退款与"不可记账"的判定交叉` › `"退款关闭"同时命中退款与不可记账(被 ignored)`

**期望 vs 实际**：
```
DataImportService.isNonBookableStatus('退款关闭')  期望 false（能记账的退款）  实际 true → 该行被 ignored
AlipayBillParser().normalizeStatus('退款关闭')    = 'refund'
```
即"退款被撤销/关闭"这笔资金实际可能已退回，但既不记支出也不记退款收入。

---

## 16. 提醒时间：非法入参被"溢出进位"，无范围校验（medium）

**标题**：`calculateNextReminderTime` 不校验 `hour`/`minute` 范围，非法值被 `DateTime` 构造器静默进位。

**源码**：`lib/utils/notification_util.dart:72-84`

**测试**：`notification_fingerprint_adversarial_test.dart` › `notification_util:下次提醒时间` › `越界 hour=25 / minute=61 应被拒绝而非静默进位` / `负数 hour/minute 应被拒绝而非反向进位`

**期望 vs 实际**：
```
calculateNextReminderTime(25, 61)   期望：抛错或钳制到 23:59   实际：次日 02:01（静默）
calculateNextReminderTime(-1, -1)   期望：抛错                   实际：当日 22:59（静默）
```
UI 侧的输入控件通常限制范围，但 helper 是公开 API。附：`当天时刻已过(含当前分钟)→ 顺延到明天或今天`（绿）—— 该分钟已被算作"已过"，用户设"每天 8:30"在 8:30:45 保存会看到"下次明天"。

---

## 17. 解析器：短文件（<6 行）的表头探测退回描述行（medium）

**标题**：`GenericBillParser._findHeaderByColumnConsistency` 要求"表头后至少 5 行同列数"，短文件永远不满足 → 带描述行的短文件把描述行当表头。

**源码**：`lib/services/import/parsers/generic_parser.dart:39-71`（`if (consistentCount >= 5)`）+ `:33-34`（兜底 `return 0`）

**测试**：`parsers_amount_date_adversarial_test.dart` › `解析器列映射与表头探测` › `短文件(2 数据行)带描述行应找到真表头(行 1)`

**期望 vs 实际**：
```
输入：[['我的账单导出'], ['日期','金额','类型','备注'], [数据1], [数据2]]
期望：表头行 = 1                                  实际：0（描述行）
    └─ 列映射为空 → 所有行缺 date/amount → 整份文件导入无效
```
支付宝/微信的关键词路径（`_findHeaderRow`）不受影响（同组有对照绿测）。注意：**≥5 数据行**时列数一致性判据能正确工作（`findHeaderRow` 返回 1），所以这只影响短账单/短导出。

---

## 18. 空白分隔模式的金额陷阱（medium）

**标题**：`_splitSpaceSeparatedLine` 把**单个空格**也当分隔符，空格千分位金额 `1 234.56` 被切成两列。

**源码**：`lib/services/import/csv_parser.dart:126-170`（`spaceRun > 0` 即分隔，忽略行首空格），注释声称"多个连续空格视为一个分隔"与实现不符。

**测试**：`csv_encoding_adversarial_test.dart` › `CSV:空白分隔模式的金额陷阱` › `空格千分位金额 "1 234.56" 被切成两列(整行右移)` / `单空格分隔在空白模式下也被当分隔符`

**期望 vs 实际**：
```
输入：'日期  金额  备注\n2026-01-01  1 234.56  早餐\n'
期望：数据行 3 列，金额 = "1 234.56"
实际：数据行 4 列（"1"、"234.56" 各自成列）→ 该行从金额列起整体右移
```

---

## 19. AI JSON：截断/多组 JSON 的静默丢笔（low）

- **截断**：`截断的数组只救回第一个完整对象`（HARDENING/绿）—— `[{...},{...},` 只入账第 1 笔，其余静默消失。
- **多组 JSON 取第一组**：`多组 JSON 只取第一组(可能误取示例)`（HARDENING/绿）—— `示例:[{...}] 实际:[{...}]` 会入账**示例**金额。
- **tags 脏数据**：`tags:[null]` → `["null"]`、`tags:[123]` → `["123"]`、`tags:[[1,2]]` → `["[1, 2]"]`（3 条绿/HARDENING）。`_parseTags`（`lib/ai/core/bill_info.dart:452-466`）对 List 元素用 `toString()` 且不校验类型，脏字符串会被 `_addTags` 落成真实标签。

---

## HARDENING 条目清单（当前行为可辩护但脆弱，测试已锁定）

### `parsers_amount_date_adversarial_test.dart`
| 条目 | 说明 |
| --- | --- |
| 欧式千分位 `1.234,56` → `1.23456` | 量级差 ~1000 倍；中文账单不出现，自定义/欧式导出会 |
| `NaN`/`Infinity` 字符串透传 | 归一函数不做 `isFinite` 校验，依赖调用方拦截（实际未全拦，见第 1 项） |
| 空格千分位 ` 1 234.56` → null | 银行导出的空格千分位整笔丢退款 |
| `2026-01-01 24:00:00` → 次日 00:00 | `DateTime.parse` 接受 24 点 |
| `20260904` 被当 `yyyyMMdd` | 8 位纯数字的隐式格式 |
| `epoch 0` / `年份 9999` 边界可用 | 极值不被拒 |
| 带 `+08:00` 偏移正常折算 | 无 8h 漂移（正向锁） |
| `DateFormat yyyy-MM-dd` 对非法日期顺延 | 同 `DateTime` 行为 |
| `formatBalance(NaN)` → `-¥NaN万` | 不崩但脏字符串直进 UI |
| `formatBalanceFull(1e20)` → 20 位整数 | 宽度爆炸但可用 |
| `-0.0` 不显示负号 | `balance >= 0` 判定符号位 |
| 裸 `¥` 不猜（回退本位币） | 有意义红线，锁定 |
| 歧义符号上下文无交集 → 不猜 | 同上 |
| 裸 `$` 吃业界默认 USD，上下文 SGD 被忽略 | 有意优先级，锁定 |
| 单字母 `K` → MMK（缅元） | 歧义未排除；`K` 常被当"千" |
| `US\$`（转义）不在符号表 | 仅 `US$` 命中 |
| `'Transaction Status'` 不映射 status | 英文复合表头盲区 |
| 微信 `normalizeStatus` 缺 `已支出/已收入` | 原样透传，靠下游白名单侥幸安全 |

### `csv_encoding_adversarial_test.dart`
| 条目 | 说明 |
| --- | --- |
| 未闭合引号吞掉行内后续内容 | 容错方向是"吞并"而非报错 |
| 字段内 tab 被删除 | 数据静默丢失 |
| 全角逗号 `，` 不作分隔符 | 中文用户从网页复制的表头整行塌 1 列 |
| 全角空格 U+3000 不作空白分隔 | 同源 |
| 单空格也是分隔符 | 与注释"多个连续空格"不符 |
| 字段内 BOM 被 trim 吃掉 | 数据静默变化 |
| 纯空白行被静默丢弃 | 不产生错误行，但信息丢失 |
| `\x0b`/`\x0c` 不切行 | 非标准行分隔符 |
| `=`/`@` 前缀不转义 | 当前无 CSV 导出路径，风险受限 |
| 无 BOM 的 UTF-16 不被识别 | 走 UTF-8/GBK 路径产出乱码 |
| UTF-16 奇数尾字节被 pair 循环丢弃 | `[0xFF,0xFE,0x41]` → `''` |
| latin1 兜底实际不可达 | 注释与实现不符 |

### `ai_json_response_adversarial_test.dart`
| 条目 | 说明 |
| --- | --- |
| 空/纯空白/emoji/无 JSON → 空 list | 不抛异常（正向锁） |
| 未加引号的 `NaN` 不是合法 JSON | 整块丢弃 |
| 单引号 JSON 不支持 | 只清 trailing comma |
| 显式 `null` 字段按缺失处理 | 除 amount 外的 null 都安全留空 |
| 全角数字金额 → 整笔丢弃 | 无告警上浮到 UI |
| 一笔类型错不拖累同批其它笔 | 逐笔 try/catch |
| `external_id` 数字被 `toString()` 兼容 | 印证两种容错范式并存 |
| `confidence:'abc'` → 1.0 且标记"已提供" | `confidence_missing` 闸门不会拦它 |
| 截断的数组只救回第一个完整对象 | 其余静默丢失 |
| 200/2000/100000 层嵌套不崩 | 无栈溢出 |
| 多组 JSON 只取第一组 | 可能入账示例金额 |
| 非字符串币种静默按缺失 | 不抛异常 |
| `{{BILL_GUARD}}` 在 OCR 文本里未被二次替换 | 与 `{{CATEGORIES}}` 行为不一致（同根因） |
| 注入语句原样进入 prompt | OCR 内容与指令同层 |
| 自定义模板缺占位符 → 能力静默缺失 | `missingPlaceholdersIn` 仅 UI 提示 |

### `notification_fingerprint_adversarial_test.dart`
| 条目 | 说明 |
| --- | --- |
| 正文首尾空白不归一 | 空白敏感 |
| 不做 NFC/NFD 归一 | 组合字符/预组合字符不同指纹 |
| 仅 id 非零即走 6 段格式 | 与 native 判据一致 |
| 标题体变体各自独立指纹 | 靠语义判重收敛 |
| 空白/字段顺序都进指纹 | 不做归一 |
| 三路指纹互不相同 | 指纹层不做跨源协调 |
| 支付宝/微信/云闪付标题变体互不相同 | 同上 |
| pkg 参与指纹 | 同渠道多包名无互判 |
| `isUtc` 标记不影响指纹 | 只取墙上时刻 |
| `time=null` 与有值不同指纹 | 两个 null 无法区分 |
| `note`/`type` trim，`channel` 不 trim | 归一力度不一致 |
| `toStringAsFixed(2)` 让 1.001/1.004 同指纹 | 有意设计 |
| 当前分钟被判定为"已过" | 设"每天 8:30"在 8:30:45 保存看到"下次明天" |
| 空 payload 被忽略 | 无跳转目标 |
| 畸形 payload 原样透传 | 无 URI 白名单 |
| `billFingerprint` 对 NaN/Infinity 不抛异常 | 指纹自洽 |
| `isNonBookableStatus` 子串匹配 | `取消退款成功` 被判不可记账 |
| 微信 parser 缺 `已支出/已收入` 映射 | 靠下游白名单侥幸安全 |
| 指纹入口对畸形输入(空/控制字符/emoji/100KB)不抛异常 | 正向锁 |
| 状态判定英文大小写不敏感 | 正向锁 |

---

## 未能验证项

1. **native 与 Dart 指纹的实际字节级一致性**：三处 Kotlin 实现（`SmsReceiver.kt:139-144`、`NotificationWatcher.kt:172-191`、`ScreenTextWatcher.kt:601-606`）与 Dart 侧公式逐字比对后一致（`"$sender|$body"` / `"$pkg|$key|$id|$postTime|$title|$text"` / `"$pkg|$text"`，均取前 8 字节 hex）。但**没有运行 Kotlin 单测**（需 Gradle/Android SDK），所以"同口径"结论来自源码阅读而非执行证据。既有 Kotlin 单测 `android/app/src/test/.../{SmsReceiver,NotificationWatcher,ScreenTextWatcher}Test.kt` 未运行。

2. **`import_confirm_page.dart` 的私有方法未经 widget 测试直接调用**：`_buildImportDataFromCsv` 是 `_ImportConfirmPageState` 的私有方法，测试需要 pump 整个页面 + Riverpod + DB。本报告中"导入页清洗/日期兜底"的结论用**逐字复制的等价实现**（`importPageAmount` / `importPageDate`）断言，与源码 `:1063` / `:1069` 行逐字一致；但"用户点导入时页面真的走到这几行"这一层由读源码确认（`initState` → `_autoDetectMapping` → `_startImport` → `_buildImportDataFromCsv` 链路完整），未做端到端 widget 验证。

3. **`AiExtractionEngine` 全链路的端到端**：`JsonResponseParser` 是纯函数，测试已覆盖。但 `extractFromText` → relay HTTP → 解析 → `_persistAll` 的整条链需要 mock `AIProviderFactory`，本次未做（`_persistAll` 的 `skipIfProcessed` 语义由源码阅读确认：命中即 `duplicateCount++` 且 `continue`，不落库不进候选）。

4. **并发竞态**：`_persistChain`（`lib/services/ai/ai_bookkeeper.dart`）是显式的串行链，`_processingChain`（各 MonitorService）同构；未构造确定性并发测试来验证"同一笔的多路捕获是否真的不会双记账"。考虑到协议本身有 `Completer` 串行化 + 事件表幂等，未找到可确定性复现的竞态，故未写测试。

5. **`notifyFingerprint` 与 native 在"部分身份字段"边界的一致性**：Dart 判据 `(key?.trim().isNotEmpty) || id != 0 || postTime != 0` 与 Kotlin `key.isNullOrBlank() && id == 0 && postTime == 0L` 逻辑等价（已逐字核对），但 native 侧的 `s.key.ifBlank { "${s.id}:${s.tag ?: ""}" }` 归一化在 Dart 侧无对应逻辑 —— 若 native 把空 key 归一成 `"42:"` 而 Dart 侧收到空串，`hasIdentity` 判据两侧仍一致（都用 `id != 0` 兜住），未发现分叉，但也未在真机验证。

6. **`FileReaderService.readFile` 的流式读取（256KB 分块）**：本次只测了纯函数 `decodeBytes`。分块拼接逻辑（`_readFileWithProgress`）要求真实文件句柄，未测。

7. **`XlsxReader.convertXlsxToCSV`**：需要构造真实 xlsx 二进制，本次未测（其"转出 CSV"只在单元格含 `,`/`"`/`\n` 时才加引号包裹，**不含 `\r` 判断之外的列数一致性**，可能把含逗号的单元格正确转义 —— 但转出的 CSV 再进 `CsvParser.parse` 时仍会遇到第 2 项的内嵌换行缺陷，这条链未端到端验证）。

---

## 附：如何复跑

```bash
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd /d/github/smartbook/client
flutter test test/adversarial/parsers_amount_date_adversarial_test.dart --reporter compact
flutter test test/adversarial/csv_encoding_adversarial_test.dart --reporter compact
flutter test test/adversarial/ai_json_response_adversarial_test.dart --reporter compact
flutter test test/adversarial/notification_fingerprint_adversarial_test.dart --reporter compact
```

所有 40 条红测均带 `// ADVERSE FINDING: <标题>` 行内注释；所有 HARDENING 条目带 `// HARDENING: <说明>` 注释。未修改 `lib/**` 任何产品代码，未修改既有测试文件。
