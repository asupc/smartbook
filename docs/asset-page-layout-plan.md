# 服务端资产页 · 大屏看板布局（方案 A）实施计划

> 状态：**已确认方案、待实施**（2026-09-07）
> 关联预览：`docs/asset-page-layout-preview.html`（方案 A 的可交互静态演示，假数据）
> 前置：方案 A/B/C/D 对比见 `docs/asset-page-layout-preview.html`；本轮已确定选用**方案 A（KPI + 双图并排 + 底部密集账户表格）**，并按用户要求把 KPI 扩为 **8 项**（资产 4 项 + 本月/本年收支 4 项）。

---

## 目标

把服务端资产页（`server/frontend/apps/web/src/pages/sections/AccountsPage.tsx`）从「mobile 卡片纵向堆叠」改成 PC 大屏看板，核心是：

- **新增**：8 项 KPI 总览区（4 列 × 2 行）+ 资产构成 / 净资产趋势**双图并排**（去掉「构成/走势」tab，两者同屏）。
- **替换**：底部可折叠的 `BankCardTile` 彩卡网格 → 可排序 `antd Table`。
- **保留**：多币种折算口径、`converted` 汇总逻辑、`AccountsPanel` 的 CRUD / 编辑 / 调整余额 / 隐藏 / 删除交互，以及 `AssetsCompositionMini`/`NetWorthTrend` 只读组件（改为 full/Card 版）。

## 背景：为什么这样拆

- 现状 `converted` 汇总卡（`AccountsPage.tsx:496`）把「净资产 + 资产/负债 + 构成/走势 tab」全挤在**一张长条卡**里，构成和走势被 tab 强制二选一。大屏（Content 无 max-width，`AdminLayout.tsx:331` p-6 + 侧栏 220px，1920 下约 1680px 内容宽）空间完全够用，只是布局没利用起来。
- 8 项 KPI 需要额外数据源：`fetchWorkspaceAnalytics`（`OverviewPage.tsx:159` 已调用 `scope: 'year'|'month'`）。资产数据用现有 `converted`，收支用 `summary.income_total/expense_total`。

---

## 改动文件

| 文件 | 改动 | 量级 |
|------|------|------|
| `server/frontend/apps/web/src/pages/sections/AccountsPage.tsx` | 主改造：布局重组 + KPI 数据 | 大（核心） |
| `server/frontend/packages/web-features/src/features/AccountsPanel.tsx` | 新增/保留 `AssetKpiRow` 展示组件（或放 accounts page） | 小 |
| `apps/web/src/i18n/{en,zh-CN,zh-TW}.ts` | KPI/表格列头的 i18n key | 小 |
| `apps/web/src/components/dashboard/AssetCompositionDonut.tsx` | （可选）暴露可传 `currency`/`approx` 的 props 以承接折算视图 | 极小 |

> `AccountsPanel` 是共享组件（`TransactionsPanel.tsx` 等也用到），**不直接在它内部改主结构**——大屏布局由 `AccountsPage` 编排，`AccountsPanel` 只保留账户列表/CRUD 部分并暴露新 props，避免影响其它调用方。

---

## 实施步骤

### 步骤 1：KPI 数据源（`AccountsPage.tsx`）

在 `refresh`（`AccountsPage.tsx:144`）里并行拉取收支统计：

```ts
const [monthSummary, setMonthSummary] = usePageCache<WorkspaceAnalyticsSummary | null>('accounts:monthSummary', null)
const [yearSummary, setYearSummary]   = usePageCache<WorkspaceAnalyticsSummary | null>('accounts:yearSummary', null)
```

在已拉 `accountRows` 的 `Promise.all` 里追加两个 analytics 请求（复用 `OverviewPage.tsx:159` 的 `tzOffsetMinutes` / `currentPeriod` 逻辑，`activeLedgerId` 维度）：

```ts
fetchWorkspaceAnalytics(token, { scope:'month', metric:'expense', period: currentPeriod, ledgerId: activeLedgerId, tzOffsetMinutes })
fetchWorkspaceAnalytics(token, { scope:'year',  metric:'expense', ledgerId: activeLedgerId, tzOffsetMinutes })
```

每个 `.catch(() => null)`，任一失败置 null 不阻塞账户列表（对齐现有 rates/overrides 容错）。切账本（`refresh` 依赖里已有 `activeLedgerId`）自动重拉。

> KPI 口径：资产 4 项来自 `converted`（`AccountsPage.tsx:418`）；收支 4 项来自上面两个 summary。**本月口径与本项目其它页一致**（`currentPeriod` 由 `month_start_day` 算出），后续如需对比上月用 `periodLabel` 倒推。

### 步骤 2：KPI 行渲染组件（`AccountsPanel.tsx` 或新建 `AssetKpiRow.tsx`）

纯展示组件，props：

```ts
type AssetKpiRowProps = {
  netWorth: number; assetTotal: number; liabilityTotal: number
  accountCount: number; currencyCount: number; hiddenCount: number
  monthIncome: number; monthExpense: number
  yearIncome: number; yearExpense: number
  base: string; approx?: boolean   // 多币种时前缀 ≈
}
```

渲染为 4 列 × 2 行：
- **第一行（资产总览）**：净资产 / 总资产 / 总负债 / 账户规模 —— 加两条 `divider-label` 分隔线居中标题「资产总览」「收支统计」，复用 `AccountsPage.tsx:521` 的资产/负债 `<Amount>` 色彩块。
- **第二行（收支统计）**：本月收入 / 本月支出 / 本年收入 / 本年支出。
- 每格用 `<Amount>` 保证等宽、`white-space:nowrap` 防断行；`accountCount = rows.length`、`currencyCount = new Set(rows.map(r=>r.currency)).size`、`hiddenCount = rows.filter(r=>r.hidden).length`。

### 步骤 3：双图并排（`AccountsPage.tsx` `return` 内 496-617 区段）

把 `converted` 分支里的**单张折算卡**改成**两张并排卡**（`grid gap-4 lg:grid-cols-[5fr_6fr]`）：

- **左卡 · 资产构成**：full 版 `AssetCompositionDonut`（复用 `OverviewSection.tsx:128` 完整 Card 版），接收 `accounts={rows}` + 折算后的 `currency`/`approx`。去掉现有「构成/走势 tab」（`AccountsPage.tsx:566-592`）。
- **右卡 · 净资产趋势**：full 版 `NetWorthTrend`（`embedded={false}`，自带 Card），`data={netWorthHistory}`。它内部已有资产/负债/净资产三条线切换（`NetWorthTrend.tsx:40-49`），正好互补。

保留 `converted.needsBase`（多币种未设主币种）引导卡逻辑不变（`475-494`）。

### 步骤 4：底部账户表格（替换 `AccountsPanel` 内的彩卡网格）

改动最大的部分。`AccountsPanel.tsx:193-208` 的卡片网格（`BankCardTile`）替换为 antd `Table`：

- **保留**分组折叠的**表头**，行渲染从 16:11 彩卡 → 表格行。列：账户（图标+名称+币种 badge）/ 类型 / 币种 / 余额（负数红）/ 本月收入 / 本月支出 / 信用额度（估值账户「当前估值」、信用卡「已用/额度」）/ 操作（编辑/删除）。
- 类型分支复用 `BankCardTile.tsx:672-750` 的 `isValuation`/`isCreditCard`/`hasStats` 判断，把 `StatCell` 转成 `<td>`。
- 用 `computeTypeGroups(visibleRows, t)`（`AccountsPanel.tsx:1125`）仍按类型分组，组头保留 id/小计/折叠（antd `Table` 分组或自定义 rowSpan；推荐自定义分组表头以保留「负债」badge 与跨币种小计）。
- 底部「已隐藏」分区（`HiddenAccountsSection`）保留为表格下方独立折叠区。

> **保留「彩卡」作为可切换视图**（可选）：`Table` 为主，`BankCardTile` 网格可经紧凑切换器保留。若只想上表格，删掉 `BankCardTile` 网格只留 `HiddenAccountsSection`（默认建议保留「已隐藏」区用旧网格）。

### 步骤 5：i18n

在 `en.ts` / `zh-CN.ts` / `zh-TW.ts` 三处补 key：
- `accounts.kpi.netWorth / assets / liabilities / accountCount / currencyCount`
- `accounts.kpi.monthIncome / monthExpense / yearIncome / yearExpense`
- 表格列头：`accounts.table.type / currency / balance / monthIncome / monthExpense / creditLimit / currentValue / actions`（部分已有，缺的补）

### 步骤 6：断点降级

- `KPI 行`：固定 4 列；`<lg` 时 2 列 × 4 行（移动/窄窗口）。
- `双图`：`lg:grid-cols-[5fr_6fr]`；`<lg` 单列堆叠。
- `表格`：antd Table 自带横向滚动，窄屏不破坏。

> 与服务端其它页的 `lg:`/`xl:` 断点一致（`OverviewSection.tsx`、`AdminLayout.tsx:331`）。

---

## 风险 / 注意

1. **`converted` 复用**：构成图与 KPI 用同一 `converted` 折算口径——多币种缺汇率币种从总额/donut 剔除（`AccountsPage.tsx:437-444`），KPI 的「资产/负债/净资产」用同一套，保证数字间自洽。**不要让 KPI 另起一套汇率计算**。
2. **`AccountsPanel` 共享性**：只加 props（如 `denseTable`/`renderAsTable`）或把主结构留在 `AccountsPage`，避免影响 `TransactionsPanel` 等调用方。改动前 grep 确认 `AccountsPanel` 所有引用点。
3. **本月「超支」KPI**：预览里「超支 4%」需预算对照才有意义。若资产页无现成预算数据，建议先只显示收支金额 + 环比，**不显示超支 badge**（避免误导）。要的话从 `fetchBudgetsWithUsage` 接入。
4. **净收入/净资产 tone**：`Amount` 的 `tone` 已处理正负色（`positive`/`negative`），资产负债沿用 `AccountsPage.tsx:522-557` 的 emerald/rose 配色。
5. **回归**：确认 `handleAdjustBalance`、删除确认、`onClickAccount` 详情弹窗、编辑弹窗在新表格行上仍能触发（`AccountDetailDialog` 在 `GlobalEntityDialogs`，表格行点击照常 `dispatchOpenDetailAccount`，`AccountsPage.tsx:653`）。

---

## 验收清单

- [ ] 1920 宽下：8 项 KPI 分两行（资产 4 + 收支 4），金额不断行、等宽对齐。
- [ ] 构成图 + 走势图并排同时可见（不再被 tab 二选一）。
- [ ] 底部账户表格可排序、过滤、横向滚动；估值账户显「当前估值」、信用卡显「已用/额度」。
- [ ] 点表格行弹出账户详情（`dispatchOpenDetailAccount`）；编辑/删除/调整余额均可用。
- [ ] 多币种场景：KPI 带「≈」前缀和缺失汇率提示，与现有 `converted` 口径一致。
- [ ] 切账本/WS 同步触发刷新，KPI、双图、表格随 `refresh` 同步重拉。
- [ ] `AccountsPanel` 其它调用方编译/交互不受影响。
- [ ] `tsc` + `vitest`（如 `assetAggregation.test.ts` 覆盖聚合口径）通过。

---

## 执行策略（建议）

**分两阶段，先上半部分再看效果**：
- **阶段 1（步骤 1–3）**：KPI 总览 + 构成/走势双图并排，**保留现有彩卡列表**。先让你看上半部分效果。
- **阶段 2（步骤 4）**：表格替换（改动最大、最可能回归），确认后才动。

若要求一次做完，也可全量实施。

---

## 相关的既有布局现状（供实施对照）

- `AccountsPage.tsx` 折算汇总卡四态：`converted===null` / `converted.needsBase` / 折算汇总卡（`AccountsPage.tsx:496-617`）。
- `AccountsPanel.tsx` `MobileStyleAssets`：顶部单/多币种 hero + 分类型折叠彩卡网格（`193-208`）+ `HiddenAccountsSection`（`216-223`）。
- `BankCardTile` 类型分支：估值 `VALUATION_TYPES_SET`（`543-550`）、信用卡 `isCreditCard`、`hasStats`（`579-591`）。
- `AssetCompositionDonut`（`dashboard/AssetCompositionDonut.tsx`）：full Card 版，recharts。
- `NetWorthTrend`（`dashboard/NetWorthTrend.tsx`）：`embedded` 参数切换 Card 内嵌/独立，内部三条线切换。
