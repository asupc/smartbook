# Widget / 交互层对抗性测试发现报告

**范围**：`client/lib/widgets/biz/`、`client/lib/pages/**`（Flutter widget 层）。
**日期**：2026-10-11。**方法**：只新建 `test/adversarial/ui_*`，未改任何产品代码与既有测试。
**基线**：全量 `flutter test` 1034 通过 / 1 跳过 / 3 既有失败（均为测试腐烂，与本报告无关）。

> **2026-10-11 批次 C7 + X 修复状态**（见 `ADVERSARIAL-FIX-PLAN-2026-10-11.md` §三 批次 C7/X）：
> - **U-1 已修**（`amount_editor_sheet.dart`）：`_append` 整数位上限 12 / 小数位 2，表达式行改
>   `Expanded`+`Flexible`+`FittedBox(scaleDown)`；完成键 `isEnabled` 与提交前各加 `isFinite` 断言。
>   文件头「12 绿 / 2 红」→ 现 **19 绿 / 0 红**（整文件单跑）。
> - **U-2 已修**（`pending_confirmation_page.dart`）：筛选行/批量条/卡片动作行/对比标题行改
>   `Wrap`/`Flexible`+`ellipsis`；`_chip` 文本加 `maxLines:1`+ellipsis。
>   320×640 与 420×900+textScale2.0 回归均绿。
> - **「未能验证 1」（待确认页批量挂起）已定位并解除**：真实根因**不是** logger/toast 的 2s
>   timer，而是 `PendingCandidateStore._serial` 的**进程级静态 Future 尾链** —— 在
>   `testWidgets` 的 fake-async zone 里建立的尾链，下一条用例再 `.then` 时回调被排到上一个
>   用例已废弃的 zone，永不触发（挂起）。页面新增 `candidateLoader`/`store` 注入点后，
>   `ui_pending_confirmation_adversarial_test.dart` 可**整文件单跑**：8 绿 / 0 红 / 0
>   "did not complete"。
> - **「未能验证 2」（运算符键 onTap 不可达）已证伪并补测**：原因是旧探针用
>   `find.widgetWithText` 匹配 `Text.rich` 失败，且未推进 `kDoubleTapTimeout`(300ms)
>   窗口。产品代码补 Key 锚点（`AmountEditorSheet.opKey1Anchor/opKey2Anchor/doneKeyAnchor`）
>   后，`tester.tap` + `pump(400ms)` 即可驱动 `applyOp`/`applyEquals`；已补运算模式
>   提交、等号回填、除零保护 4 条 widget 级测试。

## 汇总（修复后）

| 文件 | 测试数 | 绿 | 红 | 运行方式 |
|---|---|---|---|---|
| `ui_amount_editor_adversarial_test.dart` | 19 | **19** | **0** | 整文件可跑 |
| `ui_pending_confirmation_adversarial_test.dart` | 8 | **8** | **0** | **整文件可跑**（修复前须逐条单跑） |

## 原始红色发现（4 条 → 3 条发现，均已修复）

### U-1【medium，已修】金额编辑器无输入位数上限 → 窄屏渲染溢出 + 可提交 `Infinity`

- **文件**：`ui_amount_editor_adversarial_test.dart`（原 2 条红）
- **源码**：`lib/widgets/biz/amount_editor_sheet.dart` `_append`（只约束「两位小数」，无长度上限）、
  完成键 `total.abs() > 0` 无 `isFinite` 校验
- **修复**：`_append` 拆出 `_nextAmountString`，整数位上限 12、小数位上限 2（超限按键直接忽略）；
  表达式行改可收缩布局；完成键 `isEnabled` 加 `total.isFinite`，提交前再断言一次（非法值 → toast + 不提交）。
- **回归**：`U-1:*` 4 条（窄屏 20 位不溢出、310 位提交有限、小数位上限、12 位不误伤）。

### U-2【medium，已修】待确认页在窄屏 / 大字体下布局溢出

- **文件**：`ui_pending_confirmation_adversarial_test.dart`（原 2 条红）
- **源码**：`lib/pages/automation/pending_confirmation_page.dart`。实测溢出归属为
  **筛选行**（`Row ← Column ← Padding ← ColoredBox ← ConstrainedBox ← Container`，320 宽溢出 161px），
  另卡片底部动作行、批量条、对比标题行同属不可收缩族。
- **修复**：筛选行 / 批量条 / 卡片动作行 / 对比标题行改 `Wrap`；动作按钮文本 `maxLines:1`+ellipsis；
  `_chip` 文本加 ellipsis；对比标题加 `ConstrainedBox(maxWidth: 220)`。
- **回归**：`U-2 回归:*` 2 条（320×640、420×900+textScale 2.0）。

---

## 覆盖清单（修复后 27 绿）

**金额编辑器（19 绿）**：零金额不可提交、负初值取绝对值、多点号只留一个、超精度截断、前导零去除、
U-1 位数上限 4 条、双击完成只提交一次（防重入闸门有效）、空金额/`0.` 不可提交、备注 400 字符 emoji
原样透传、月末日期初值不顺延、大字体 2.0 不溢出、320 宽不溢出、运算模式 4 条（进入运算模式不提交、
10+5=15 提交、连点等号非重入、除零返回被除数且有限）

**待确认页（8 绿）**：空态不崩、单条候选渲染金额/备注、疑似重复显示匹配度 94% 与查看对比入口、
超长 emoji 备注（300×🚀）不崩、50 条候选批量渲染不炸、大字体 2.0 不溢出（U-2 回归）、
320 宽不溢出（U-2 回归）

---

## 未能验证（测试基建限制，非产品结论）

1. **待确认页动作链**（确认入账 / 忽略 / 恢复 / 合并到已删目标）：这些动作会经
   `billCreationService` 触发 logger + toast 的定时器。语义由服务层测试覆盖：
   `test/services/automation/b4_restore_and_decisions_test.dart`、
   `test/widgets/pending_confirmation_comparison_test.dart`（后者已覆盖对比弹窗）。
   **注**：原记录的「pending timer 致同文件批量挂起」经批次 X 复现证伪 —— 真实原因是
   `PendingCandidateStore` 静态尾链跨 fake-async zone（已由页面注入点解除，见文件头状态块）。
2. **交易编辑器保存链**（`transaction_editor_page.dart` 全链路保存）：依赖 `PostProcessor.sync` /
   widget 更新 / 附件服务等平台侧依赖，widget 级未覆盖。
3. **设置页开关快速连点**：`auto_billing_settings_page.dart` 构造即触发多条平台通道调用
   （通知权限/无障碍状态），Windows 测试宿主无实现，未覆盖。
