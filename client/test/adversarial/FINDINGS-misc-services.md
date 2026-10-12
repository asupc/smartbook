# 杂项服务域（周期记账/汇率/隐私证据/存储/匹配器）对抗性测试发现报告

**状态说明（如实记录）**：本域独立攻击组两轮均遭遇 API 限频中断（第一轮 09:20、第二轮 14:xx），
产出为**部分完成**：1 个测试文件（`misc_json_backup_adversarial_test.dart`，23 用例）
+ 探测阶段（probe 脚本）已验证但**未编码成测试**的若干发现。
其余 4–5 个计划文件（周期记账/汇率/隐私证据/存储损坏/匹配器）**未产出** —— 属本轮未完成项。

---

## 一、已落盘测试的确切状态（复跑实测）

`client/test/adversarial/misc_json_backup_adversarial_test.dart`：**23 用例 = 15 绿 / 8 红**

### 红色清单与分类（8 条）

| # | 测试名 | 分类 | 性质 |
|---|---|---|---|
| 1 | `ADVERSE: amount=Infinity 落库后端整份备份无法 JSON 编码 → 导出整体失败` | ADVERSE 红 ✓ | **真实缺陷** |
| 2 | `ADVERSE: nativeAmount=Infinity 同样让整份备份导出失败` | ADVERSE 红 ✓ | **真实缺陷**（同根因） |
| 3 | `HARDENING: 截断的备份 JSON 只是解析失败,不产生副作用` | **测试自身缺陷** | 见下 §1.1 |
| 4 | `ADVERSE: 备注含半角引号 → 发射出的 YAML 无法再解析(备份不可用)` | ADVERSE 红 ✓ | **真实缺陷** |
| 5 | `ADVERSE: 备注注入已有键 → 整份配置抛 Duplicate mapping key` | ADVERSE 红 ✓ | **真实缺陷** |
| 6 | `ADVERSE: 备注注入 amount 可抬高周期账单金额(重复键)` | ADVERSE 红 ✓ | **真实缺陷**（注入面） |
| 7 | `ADVERSE: 单条坏 start_date 使整批周期账单静默丢弃(不报错)` | ADVERSE 红 ✓ | **真实缺陷**（断言数值有误，见 §1.2） |
| 8 | `ADVERSE: 坏行在后 → 前面的行已提交,导入"部分成功"无提示` | ADVERSE 红 ✓ | **真实缺陷** |

**结论：7 条真实缺陷 + 1 条测试自身缺陷。**

#### 1.1 关于第 3 条（测试自身缺陷，非产品缺陷）

该用例断言「截去 JSON 末字符后 `jsonDecode` 仍能正常返回」。JSON 的最末字符恒为 `}`，
删掉它必然使 JSON 非法 —— 断言前提本身不成立，因此必红。
**产品行为（解析失败即抛 `FormatException`、不产生副作用）恰恰是安全/期望行为。**
按本轮「既有产出不删不改」的约束，未修改该文件；此处记录以正确定性。

#### 1.2 关于第 7 条（断言数值不准，缺陷本身成立）

用例注释称「实际 0 条入库」，实测实际为 **1 条**（好行先被导入）——
即：坏行**中断了整个导入循环**，其后的行全部丢失，且函数静默返回（无错误、无计数）。
缺陷成立（§1.3 与第 8 条同根因），但注释中的数字描述不准确。

#### 1.3 缺陷根因（配置 YAML 导出/导入）

- **导出侧**：`lib/services/export/config_export_service.dart` 手工拼接 YAML 标量，
  未对备注中的半角引号 / 换行做转义 → 导出物不可再解析（第 4 条）；
  备注可直接注入 `键: 值` 行，产生重复键（第 5 条）甚至抬高周期账单金额（第 6 条）。
- **导入侧**：`config_import_service`（或等价实现）在循环内 `DateTime.parse(item.startDate)`，
  单条坏日期抛出的 `FormatException` 被外层 catch 吞掉 → **整个 for 循环中止**，
  其后所有好行丢失，且函数静默返回成功（第 7、8 条）。
- **备份侧**：`lib/services/export/json_backup_service.dart` 的 `buildBackupJson` 对
  `Infinity` 金额（可由解析器/AI 链路写入，见解析器域 P-1）无法 `jsonEncode` →
  整份备份导出失败（第 1、2 条）。与解析器域的 `isFinite` 守卫族同根因。

---

## 二、探测阶段已验证、但未编码成测试的发现（证据已留存于本轮会话）

> 这些发现由 probe 脚本实测确认（含具体输出），因限频中断未固化为测试文件。
> 归入「未能验证（未固化为可复跑证据）」。

1. **配置 YAML 的换行备注被静默改写**：双引号标量内的换行在解析时折叠为空格
   （实测 `第一行\n第二行` → 回读为 `第一行 第二行`）。既有测试把该用例标为 ADVERSE
   但断言是「可解析」（通过），未捕捉这一**静默内容损坏**。
2. **导入幂等键对 externalId 大小写敏感**：`_keyHash(external)` 未小写化，
   同一订单号换大小写（`ABC123` vs `abc123`）重复导入 → 产生两笔交易；
   而 `findTransactionByExternalId` 是归一化查询（大小写不敏感）→ **两侧口径不一致**。
3. **`seedDatabase` 非幂等**：二次调用 → 分类 59 → 119 条（含重复）、账本 2 条；
   且分类表无 (name, kind) 唯一约束兜底。可达路径窄（welcome 流程重入）。
4. **`ChannelAccountStore.save` 不强制容量上限**：超限（>200）列表可持久化，
   upsert 的单点裁剪永不收敛。
5. **`AnomalyDetector` 无生产调用方**：全仓 grep 仅测试/探测引用 →
   其边界行为（含 `Infinity` 输入产生 `ratio=Infinity` 判定）当前不可达，
   属未接线模块。
6. **`PostProcessor` 顺序规则**：`runAfterDownloadC` 不触发 `markLocalChanged`/上传
   （方向性正确）；`runC` 在非 SyncEngine 实现下遵循 `auto_sync` 开关 —— 未发现顺序冲突。

---

## 三、覆盖矩阵（本域计划 vs 实际）

| 攻击面 | 计划文件 | 实际 |
|---|---|---|
| 备份→恢复往返 / 损坏备份 / YAML 注入 / 坏行处理 | `misc_json_backup_*` | ✅ 23 用例（15G/8R） |
| 周期记账（月末 31 日/闰年/幂等/模板变更） | `misc_recurring_*` | ❌ 未产出（探测仅覆盖坏行中断） |
| 汇率（0/负/NaN/Inf/往返漂移/非法币种） | `misc_currency_*` | ❌ 未产出 |
| 隐私证据本地侧（TTL 边界/损坏 JSON/clear 竞态） | `misc_privacy_evidence_*` | ❌ 未产出 |
| 存储损坏（4 个 store 的 JSON/容量/并发/迁移） | `misc_stores_corruption_*` | ❌ 未产出（探测覆盖 seed/store 容量） |
| 匹配器（分类/渠道规则/后处理/异常检测/种子） | `misc_matchers_*` | ❌ 未产出（探测覆盖 6 条发现） |

**未完成原因**：API 限频（两轮）导致攻击组预算耗尽于探测阶段，未进入测试固化。
本域部分覆盖由相邻域承担：金额/日期解析在解析器域、存储写在数据层域、
PostProcessor/同步方向在同步引擎域。
