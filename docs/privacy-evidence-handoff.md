# SmartBook 原始记账证据策略 Handoff

- **日期**：2026-09-05
- **工作区**：`D:\gitee\auto-ledger`
- **当前分支**：`master`
- **任务目标**：调整客户端隐私策略，允许按用户配置在客户端和 SmartBook Cloud 服务端保存短信、支付通知、账单详情页文本等原始记账证据；客户端与服务端仅负责只读展示，不让原始证据进入普通交易同步链路。
- **当前结论**：核心数据层和服务端接口已基本完成，但 Web 端远程展示、客户端远程展示和最终全量验证尚未完成，**不能宣称任务完成**。
- **Git**：本次没有 commit / push。工作区包含本任务改动和其他既有未提交改动，接手者不得直接整体提交。

---

## 1. 已完成的设计和实现

### 1.1 客户端策略

规范实现位于：

- `D:\gitee\auto-ledger\client\lib\services\privacy\raw_evidence_policy.dart`
- `D:\gitee\auto-ledger\client\lib\services\privacy\raw_evidence_sync_service.dart`

策略支持：

- 默认策略和按来源覆盖；
- 本地保存开关；
- 服务端保存开关；
- 本地保留天数；
- 服务端保留天数；
- 上传状态、重试次数、过期清理；
- 服务端上传开启时，即使本地长期保存关闭，也会保留上传所需的临时队列记录。

当前默认值是隐私优先：本地和服务端原始证据均默认关闭，用户需要在隐私面板主动开启。

### 1.2 客户端数据库

主要文件：

- `D:\gitee\auto-ledger\client\lib\data\db.dart`
- `D:\gitee\auto-ledger\client\lib\data\db.g.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_event.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_event_store.dart`

`auto_book_events` 已支持：

- `raw_title`
- `raw_text`
- `raw_actor`
- `raw_metadata_json`
- `raw_evidence_local_enabled`
- `raw_evidence_server_enabled`
- 本地/服务端独立过期时间
- `raw_evidence_upload_state`
- `raw_evidence_uploaded_at`
- `raw_evidence_upload_attempts`
- `raw_evidence_last_error`

当前客户端数据库 schema 已推进到 **v36**，v34、v35、v36 migration 均已写入 `db.dart`。生成文件已经重新生成。

原始证据只保存在自动入口事件表中，不进入 `transactions`，也不进入 `local_changes` / `sync_changes`。

### 1.3 自动入口接入

已接入原始正文/来源信息的入口：

- `D:\gitee\auto-ledger\client\lib\services\platform\sms_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\notify_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\screen_text_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart`

短信会记录发送者和正文；支付通知会记录包名、标题和正文；屏幕文本会记录包名和页面文本。截图/图片目前仍主要保留事件 hash/path 摘要，原图远程展示尚未完成。

### 1.4 客户端隐私面板

文件：

- `D:\gitee\auto-ledger\client\lib\pages\data\privacy_panel_page.dart`

已经增加：

- 原始证据总数和按来源统计；
- 本地原始正文列表；
- 原文详情展示；
- 按来源清理；
- 全部清理；
- 默认策略与 SMS / notification / screenText / screenshot 等来源策略配置；
- 本地和服务端保留天数配置。

### 1.5 服务端存储和 API

主要文件：

- `D:\gitee\auto-ledger\server\src\models.py`
- `D:\gitee\auto-ledger\server\src\schemas.py`
- `D:\gitee\auto-ledger\server\src\routers\evidence.py`
- `D:\gitee\auto-ledger\server\src\main.py`
- `D:\gitee\auto-ledger\server\alembic\versions\0022_raw_bookkeeping_evidence.py`

新增表：`raw_bookkeeping_evidence`

特点：

- 不进入 `sync_changes`；
- `(user_id, event_key)` 唯一，支持客户端重试幂等；
- 用户隔离；
- `ledger_id` 会校验当前用户是否有权限访问；
- 正文、标题、元数据有长度限制；
- 支持过期清理；
- 列表接口返回正文预览，详情接口返回完整正文。

接口：

```text
POST   /api/v1/evidence/raw
GET    /api/v1/evidence/raw
GET    /api/v1/evidence/raw/{evidence_id}
PATCH  /api/v1/evidence/raw/{evidence_id}
DELETE /api/v1/evidence/raw/{evidence_id}
POST   /api/v1/evidence/raw/cleanup
```

权限约定：

- 客户端上传/删除/清理使用 `app_write`；
- Web 读取使用 `web_read`；
- Web 页面不应提供新增或修改正文的编辑入口，只做查看和清理。

### 1.6 Cloud Provider 适配

文件：

- `D:\gitee\auto-ledger\client\packages\flutter_cloud_sync\lib\src\providers\smartbook_cloud_provider.dart`
- `D:\gitee\auto-ledger\client\lib\providers\sync_providers.dart`

已增加独立的原始证据上传/读取/删除/清理方法。该通道不调用普通交易 `pushChanges`，不写入 `sync_changes`。

---

## 2. 当前验证结果

### 2.1 服务端定向测试

命令：

```powershell
cd D:\gitee\auto-ledger\server
.venv\Scripts\python.exe -m pytest -q tests/test_raw_evidence.py
```

当前结果：

```text
3 passed
```

覆盖：

- 新增与同 `event_key` 幂等更新；
- 列表、详情、删除；
- 用户隔离；
- 按时间清理；
- 正文和元数据大小限制。

### 2.2 Drift 代码生成

命令：

```powershell
cd D:\gitee\auto-ledger\client
dart run build_runner build --delete-conflicting-outputs
```

已成功执行，`db.g.dart` 已更新。

### 2.3 Flutter 分析

相关文件分析目前没有 Dart 编译级 `error`；但项目存在大量既有 `info` / `warning` lint，`flutter analyze` 仍会以非零状态退出。完整客户端测试、APK 构建和真机验证尚未在最终工作树状态下全部重跑。

---

## 3. 尚未完成的事项

### P0：必须完成

1. **Web 前端只读展示**
   - `server/frontend/packages/api-client` 尚未增加 evidence API client；
   - 尚未新增原始证据页面；
   - 尚未加入侧栏导航、路由和中英文文案；
   - 尚未实现列表、筛选、详情、删除/清理操作。

2. **客户端远程展示**
   - 当前移动端隐私页主要展示本地事件；
   - 尚未把服务端列表/详情接入客户端 UI；
   - 尚未实现本地/服务端数据源切换。

3. **上传恢复链路**
   - 需要确认冷启动、登录恢复、网络恢复时是否稳定触发 `syncPending()`；
   - 需要验证上传失败退避和重复上传幂等；
   - 需要确认上传成功后本地短期队列按策略清理。

### P1：整理和质量

4. 清理中断过程中留下的旧路径重复实现：

```text
D:\gitee\auto-ledger\client\lib\services\automation\raw_evidence_policy.dart
D:\gitee\auto-ledger\client\lib\services\automation\raw_evidence_sync_service.dart
```

规范实现应只保留 `client/lib/services/privacy/` 下的版本。

5. 补齐并运行客户端新增测试：

```text
D:\gitee\auto-ledger\client\test\services\raw_evidence_policy_store_test.dart
D:\gitee\auto-ledger\client\test\services\raw_evidence_store_test.dart
D:\gitee\auto-ledger\client\test\data\raw_evidence_migration_test.dart
D:\gitee\auto-ledger\client\test\widgets\privacy_panel_raw_evidence_test.dart
```

6. 运行服务端全量测试和客户端全量测试。

7. 更新隐私政策文档，明确：
   - 原始短信/通知是否保存由用户配置决定；
   - 服务端保存的是用户自己的原始证据；
   - Web/客户端展示不等于再次触发 AI 或自动记账；
   - 用户可以删除本地和服务端证据。

---

## 4. 接手时必须遵守的架构约束

1. **原始证据不能写进 `sync_changes`。**
2. **不能把短信/通知正文写入日志。** 日志只允许 source、长度、hash 前缀和状态。
3. **不能把原始正文写入 `transactions.note`。**
4. 服务端 evidence API 必须继续按 `user_id` 隔离。
5. Web 与移动端的展示页面只能查看、删除、清理，不应重新提交原始文本进行记账。
6. 所有客户端自动入口仍必须经过 `AutoBookCoordinator`。
7. 不要把本任务与现有 AI Provider、候选确认页等未提交改动混合提交。
8. 提交前必须先取得用户明确确认；当前不要执行 commit/push。

---

## 5. 推荐下一步执行顺序

1. 删除 `client/lib/services/automation/` 下重复的 raw evidence 文件，并统一 import。
2. 修正并运行客户端 raw evidence 定向测试。
3. 增加 Web API client：`list/get/delete/cleanup`。
4. 增加 Web 只读页面、导航和 i18n。
5. 将客户端远程读取接入隐私面板。
6. 重跑：

```powershell
cd D:\gitee\auto-ledger\server
.venv\Scripts\python.exe -m pytest tests/

cd D:\gitee\auto-ledger\client
flutter test --no-pub
flutter build apk --debug --flavor dev --no-pub
```

7. 最后执行一轮人工验收：短信、通知、屏幕文本、离线、杀进程恢复、服务端删除、客户端刷新、策略关闭后的不落盘行为。

---

## 6. 完成情况附记（2026-09-05 第二轮接手）

本节是接手后的核对与收尾记录,原清单语义不变:

- **P0-1 Web 只读展示:已完成**。`packages/api-client/src/evidence.ts`(list/get/delete/cleanup,无上传/改写入口)、`apps/web/src/pages/sections/RawEvidencePage.tsx`(来源+日期筛选、分页、详情 Drawer、单条删除、按来源清理;按登录会话 remount 防串号,错误提示不回显服务端原文)、路由 `settings/raw-evidence`、侧栏 `nav.rawEvidence`、ScrollText 图标、zh-CN/zh-TW/en 全量文案。`tsc -b` 无错误;`vitest run` 10 文件 66 用例全过(含 `evidence.test.ts` 3 例)。
- **P0-2 客户端远程展示:已完成**。隐私面板新增「本机 / 服务端」SegmentedButton 切换;`RemoteRawEvidencePanel`(`lib/pages/data/remote_raw_evidence_panel.dart`)经 `rawEvidenceRemoteStoreProvider` 读取,含来源筛选、分页、详情、删除。
- **P0-3 上传恢复链路:已确认**。冷启动/登录恢复由 `ref.listen(smartbookCloudProviderInstance, fireImmediately)` 触发,网络恢复由 connectivity 监听触发,新事件由 Drift 表 watch 触发;`syncPending()` 串行化防并发;失败按 30s→6h 持久化指数退避(`rawEvidenceNextRetryAt`);服务端按 `(user_id, event_key)` 幂等 upsert(IntegrityError 兜底);上传成功后按本地保留策略清除临时原文;服务端到期数据启动+每 15 分钟清理(`raw_evidence_retention.py`)。
- **P1-4 重复实现:已删除**。`automation/raw_evidence_*` 两个文件已不存在,无残留 import,规范实现仅在 `services/privacy/`。
- **P1-5 客户端定向测试:全过**。policy_store / store / migration / privacy_panel / remote_panel 共 26 例通过。
- **P1-6 全量验证**:server `pytest tests/` 全过(含 raw evidence 3 例 + AI 中转/服务商 CRUD 新增用例);client `flutter test --no-pub` 748 例全过 1 skipped;`flutter build apk --debug --flavor dev` 通过(见本节末尾核对结论)。
- **P1-7 隐私政策文档:已完成**。`docs/privacy-policy.md`(中英双语)+ 应用内 `privacy_policy_page.dart` 接入,覆盖四要点:保存由用户配置决定且默认关闭;服务端仅保存用户自己的证据;查看/刷新/删除不触发 AI 或自动记账;本机与服务端可分别删除清理。

架构约束(第 4 节)逐条复查通过:证据不入 `sync_changes`/`transactions.note`;平台监听日志只含来源/长度/hash/状态;evidence API 全程 user_id 隔离;Web/客户端只读展示;自动入口仍统一经 `AutoBookCoordinator`。

仍需用户完成的:第 5.7 条真机人工验收(短信/通知/屏幕文本、离线、杀进程恢复、策略关闭后的不落盘行为)。按第 4.8 条,提交(commit)仍需用户明确确认。
