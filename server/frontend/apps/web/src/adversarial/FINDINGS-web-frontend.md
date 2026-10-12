# Web 前端对抗性测试发现报告

**范围**：`server/frontend/apps/web`（React + TS + Vite + antd 5；vitest）。
**日期**：2026-10-11。**方法**：只新建 `src/adversarial/**`，未改任何产品代码与既有测试。
**基线**：既有 18 文件 100 条全绿（未受影响）。

## 汇总

| 文件 | 测试数 | 绿 | 红 |
|---|---|---|---|
| `lib.adversarial.test.ts` | 32 | 31 | 1 |
| `state.adversarial.test.ts` | 18 | 14 | 4 |
| `api_i18n.adversarial.test.ts` | 21 | 18 | 3 |
| **合计** | **71** | **63** | **8** |

运行：`cd server/frontend/apps/web && pnpm vitest run src/adversarial/`

---

## 红色发现（8 条 → 5 条发现）

### W-1【medium】三个错误码映射到不存在的 i18n key → 用户看到裸 key 字符串

- **证据**：`api_i18n.adversarial.test.ts` › `每个 ERROR_KEYS 值在 en/zh-CN/zh-TW 里存在`（3 条红）
- **源码**：`src/i18n/errors.ts:40`（`SHARE_ROLE_FORBIDDEN: 'error.SHARE_ROLE_FORBIDDEN'`）、`:56`（`SHARE_MEMBER_USER_NOT_FOUND: 'error.SHARE_MEMBER_USER_NOT_FOUND'`）
- **字典核实**：`grep -c` 在 `src/i18n/{en,zh-CN,zh-TW}.ts` 全部为 **0**（三语都缺）
- **期望 vs 实际**：期望提示「你没有该共享账本的权限」类可读文案；实际 `t()` 回落返回 key 本身 → UI 显示 `error.SHARE_ROLE_FORBIDDEN`
- **一句话复现**：在共享账本里用 viewer 角色尝试写操作 → 后端返 `SHARE_ROLE_FORBIDDEN` → 前端 toast 显示裸 key。
- **修复**：三本字典补 `error.SHARE_ROLE_FORBIDDEN` / `error.SHARE_MEMBER_USER_NOT_FOUND` 两条。

### W-2【medium】`parseRoute` 遇残缺百分号编码抛 `URIError` → 整页白屏

- **证据**：`state.adversarial.test.ts` 三条红（`/app/%`、`/app/%E0%A4%A` 均抛 `URIError: URI malformed`；连带「合法 AppRoute 兜底」「斜杠变体全收敛」两条组合断言也红）
- **源码**：`src/state/router.ts`（`decodeURIComponent` 调用点，未 try/catch）
- **期望 vs 实际**：期望非法路径回落 default/login 路由；实际未捕获异常冒泡 —— `AdminLayout` 在 render 期调用 `parseRoute`，全仓无 ErrorBoundary → 白屏
- **一句话复现**：地址栏输入 `/app/%` 回车 → 整页崩。
- **修复**：`decodeURIComponent` 包 try/catch，失败时按原始段处理。

### W-3【low】`effectiveRateToBase` 对极小汇率返回 `Infinity`

- **证据**：`lib.adversarial.test.ts` › `effectiveRateToBase:极大/极小汇率与 1/0 防护`
- **源码**：`packages/web-features/src/lib/assetAggregation.ts:92-94`（`Number.isFinite(raw) && raw > 0` 通过后 `1 / raw`）
- **期望 vs 实际**：契约「无效汇率 → null」，实际 `raw=1e-320` 时 `1/raw = Infinity` 直接返回 → 资产折算出 Infinity
- **修复**：`1/raw` 后再校验 `Number.isFinite`。

### W-4【low】权限矩阵无「未知角色默认拒绝」路径（安全边界靠服务端）

- **证据**：`state.adversarial.test.ts` › 三条权限测试（绿，HARDENING 钉住）
- **说明**：12 种角色（含 `__proto__`/`constructor`/超长/注入串/undefined）对 4 类关键操作**全部放行**。这是「单用户 per-ledger」的有意设计（能看见账本即 owner），但意味着前端零防线，任何 role 字段畸形都不影响放行。

---

## 覆盖清单（63 绿）

- **lib**：资产聚合空/负/NaN/极大值、多币种折算、合并分组不改写入参（frozen 输入）、`balance=0` 权威值、currency 大小写归组、blobUrl/header-skins/useAvatarUrl 边界
- **state**：权限 12×4 全排列、路由（合法编码往返、`%00`、超长 10k、缺参/斜杠变体、`/APP/` 大小写、workspace `../` 不穿 admin）、24 个 section 往返稳定
- **api/i18n**：localizeError 七种非 Error 抛出物、未知/空 code、WRITE_CONFLICT 参数占位（`0` 保留、`null` 回落 unknown）、message 1MB 不截断、duck-typed 伪 ApiError、三语 key 集合一致、无空值翻译、Proxy 探针属性/原型名不告警/不污染原型

## 未能验证

- DOM 渲染层（组件/交互）：`jsdom`/`testing-library` 未在本包 devDeps 中确认可装，未测渲染与事件
- 真实 LocaleProvider 的 `t()` 实现（在 `packages/ui`）：本报告用 fake translator 测 `localizeError` 契约
- SSE/WebSocket 实时链路（`useSyncSocket`）
