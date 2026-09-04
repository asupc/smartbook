# 智记 SmartBook —— 自动记账项目

本目录承载 **智记 SmartBook** —— vivo Android 自动记账方案,基于上游 **BeeCount**(开源跨端客户端)与 **BeeCount-Cloud**(可自托管服务端)二开(品牌已统一为 SmartBook / SmartBook Cloud)。

> ## 🙏 致谢 —— 感谢原创作者
>
> **本项目的上游开源作者**:[sunxiao](https://github.com/TNT-Likely)(GitHub: **TNT-Likely**)
>
> 本项目基于其开源项目二次开发:
>
> - **[BeeCount](https://github.com/TNT-Likely/BeeCount)** —— Flutter 开源跨端记账客户端(通知/截图/OCR/AI 记账、本地统计)
> - **[BeeCount-Cloud](https://github.com/TNT-Likely/BeeCount-Cloud)** —— FastAPI + React 自托管记账服务端
>
> **特此向原作者致敬**:没有其慷慨开源与授权,就没有本项目。上游的代码、设计思路与知识产权均归原作者所有;所有许可协议文本已**原样保留在仓库中**。作为二开后的衍生作品,我们遵循上游许可的要求:个人使用/学习研究/非营利组织/开源贡献免费,商业使用需向原作者购买商业授权(见下文「许可证」)。

## 当前方案结论

- 后端：**SmartBook-Cloud**（自托管，Docker 一键部署，FastAPI + React Web 端）
- 客户端：**SmartBook** 开源客户端（Flutter / Android / iOS / Web），直接复用其通知监听、截图 OCR、AI 自动记账、本地统计能力
- 技术栈（客户端）：Flutter + Riverpod + Drift(SQLite)；服务端 FastAPI + SQLite/PostgreSQL + React
- 统计方式：SmartBook 客户端本地统计 + SmartBook-Cloud Web 端统计
- 正式账本：SmartBook-Cloud（自托管）
- 采集来源：
  - 短信监听（本项目新增，见「与上游的功能差异（实测验证）」）
  - 通知监听（SmartBook 已内置 + 本项目增强 NotificationWatcher）
  - 截图导入 / OCR + AI 记账（SmartBook 已内置）
  - 手动记账


## 与上游的功能差异（实测验证）

> **实测方式（2026-09-04）**
>
> - **服务端**：将上游仓库（`TNT-Likely/BeeCount-Cloud` `main`）与本项目 `server/` 分别本地起服（FastAPI + SQLite），抓取 `/openapi.json` 逐端点 diff；上游官方线上实例当日已全量切换为本项目镜像，故上游侧以本地运行源码为准。
> - **客户端**：本项目以真机（vivo Android，v1.0.20）实测；上游侧核对克隆仓库（`TNT-Likely/BeeCount` `main`）代码行为（上游官方发行渠道为 iOS App Store / Google Play，未本地运行）。
> - 本节的差异均经上述方式核实；与 `docs/development-plan.md`、旧文档不一致之处，**以本节为准**（如「大额/异常提醒」已下线、「支付宝 CSV 导入」上游已有）。

### 客户端（基于 BeeCount）

| 功能 | 上游 BeeCount（实测） | 本项目 SmartBook（实测） | 差异性质 |
|---|---|---|---|
| 品牌 | 「蜜蜂记账 BeeCount」、包名 `com.tntlikely.beecount` | 「智记 SmartBook」、包名 `com.smartbook.zhi`、URL scheme `smartbook://`；旧 key / 旧路径保留兼容迁移 | 更名 |
| 短信自动记账 | **无**：AndroidManifest 无 `RECEIVE_SMS`，全仓库零 `sms` 代码 | 有：SMS 广播接收器（银行/支付白名单 + 验证码/营销/余额提醒过滤 + 指纹去重 + 持久化队列）→ 自定义大模型解析 → 自动入账；`RECEIVE_SMS` 仅此一项，原文不落盘 | 新增 |
| 支付通知监听 | **无 `NotificationListenerService`**：「通知」实为每日提醒闹钟（`NotificationReceiver` + `zonedSchedule` 每天重复）；真自动记账靠截图/无障碍 + iOS 快捷指令文本 | 有：`NotificationWatcher` 捕获支付通知（包名白名单 + 垃圾过滤 + 指纹去重 + 队列）→ AI → 入账 | 新增 |
| 截图自动记账 | 有：Android 无障碍监听（`ScreenshotObserver`）+ OCR 双引擎 + AI | 相同 + 两段写入修复（500ms 防抖跳掉 rename 事件）、「记账成功自动删截图」开关 | 增强 |
| 详情页自动记账（无障碍读屏） | **无** | 有：`ScreenTextWatcher` 监听支付宝/抖音/京东/微信账单详情页自动入账；vivo 无障碍适配与引导 | 新增 |
| 待确认/候选队列 | **无**：AI 解析完直接入账 | 有：「自动入账校验」开关开启后，低置信（<0.9）+ 疑似重复（同类型金额 ±5% 且 10 分钟内、或同备注同金额）进待确认队列，可确认/编辑后入账/拒绝，开关可回退直入账 | 新增 |
| 大额/异常消费提醒 | 仅有**手动** AI 快捷指令「异常支出提醒」；无自动阈值检测 | **已下线**：自动大额/异常提醒引擎主动移除（仅剩 `AnomalyDetector` 数学模块与 l10n 元数据残留，不再触发） | 上游无 → 本项目不复刻 |
| 手动模拟测试 | 仅「记账提醒」页的「发送测试通知」（作用于每日提醒闹钟） | 有：「手动模拟测试」入口，可注入模拟短信/通知/屏幕文本，直接走完整 AI → 入账链路 | 新增 |
| 来源渠道 → 账户映射 | **无** | 有：短信/通知来源解析出渠道名（注入 AI 先验）+ 渠道 → 账户映射设置（AI 账户名 > 映射 > 默认账户） | 新增 |
| 统计与报表 | 分类统计/排行、月/年/自定义月份、**环比**（海报「环比上月」）、年度报告 | 保留上述 + 新增 **同比**、账户分布、商户 Top、自定义区间统计、JSON 结构化导出 | 增强 |
| 导入/导出 | 支付宝/微信账单 CSV 导入（`AlipayBillParser`/`WeChatBillParser`）、交易 CSV 导出、YAML 配置导出 | 相同（复用上游解析器） | 一致 |
| AI prompt | 解析层兼容 `confidence`（默认 0.8），但 prompt 模板不要求、无低置信处理 | prompt 模板要求 `confidence` 输出，低置信分流进待确认 | 增强 |
| AI 调用记录 | **无**（客户端只把数据发给用户自配的 AI 服务商） | 有：AI 调用记录上报服务端（含输入图片上行），服务端永久保留、可手动删除 | 新增 |
| 云同步方案 | **5 种**：BeeCount Cloud / iCloud / WebDAV / S3 / Supabase（三个 Tab：离线/备份同步/云端协同） | 仅 离线 + SmartBook Cloud 两个 Tab（底层库与兼容层保留） | 移除 4 种 BYOC 方案 |
| 推广位 | 有：蜜蜂家当 BeeAssets、给项目 Star、打赏（仅 iOS StoreKit） | 全部移除 | 移除 |
| 隐私 | 无「原文统计/一键清除」 | 数据管理页「隐私面板」：原文统计（截图/附件占用、待确认候选数）、一键清除原文（保留交易） | 新增 |
| 运维健康 | 无检测面板 | 有：自动记账健康检测（权限/开关/AI 配置/电池优化聚合）+ vivo 保活引导 | 新增 |
| 其余能力 | AI 对话/语音记账/OCR、多账本/预算/周期记账、桌面小组件（6 类 × 12 规格）、主题装扮、暗黑模式、简中/繁中/英/韩 | 全部保留 | 一致 |

### 服务端（基于 BeeCount-Cloud）

| 功能 | 上游 Cloud（实测） | 本项目 SmartBook Cloud（实测） | 差异性质 |
|---|---|---|---|
| Web UI 技术栈 | shadcn 风格（Radix + Tailwind + cva + lucide + cmdk + recharts） | 全站 antd 重构（登录/交易/账户/分类/分析/备份/设置/PAT 等页面 + Toast/ConfirmDialog） | 重构 |
| PWA | 安装横幅（`PwaInstallBanner` + `beforeinstallprompt` 拦截）+ 更新横幅 + Service Worker + Share Target 入站 | **移除安装横幅**与 Share Target；保留 SW「新版本可用」更新横幅 | 部分移除 |
| 2FA / TOTP | 有：`/auth/2fa` 六端点 + 登录挑战 + `TwoFactorChallengeView` + 迁移 `0005_2fa_totp` | **无**（openapi diff 六端点全部消失） | 移除 |
| 「问 AI」文档 RAG | 有：`/ai/ask` + `/ai/docs-index/status` + `/admin/rag/{status,refresh}` + `EMBEDDING_*` 配置 + 6h 启动刷新 + Web 命令面板「问 AI」入口 | `/ai/ask` 与 `docs_index.py` 索引服务保留；**RAG 维护端点与 Web 入口移除** | 部分移除 |
| AI 调用记录 | **无** | 有：`/ai/logs` 全套 8 端点（上报/列表/详情/图片上行/批删/单删/图片读取）+ Web「AI 调用记录」页；日志永久保留、手动删除；另新增 `POST /ai/logs/image` 图片上行 | 新增 |
| 管理端 | 用户/设备（`OpsDevicesPanel`）/服务端日志/备份/数据清理/overview | 上述全部保留 + 新增 AI 分析日志（`/admin/ai-analysis-logs` ×2）+ **疑似重复交易管理**（`/admin/duplicate-transactions` ×2 + 页面） | 增强 |
| 备份体系 | rclone 多远端 fan-out（R2/S3/WebDAV/B2）+ AES-256 加密 + 计划/保留期（18 端点） | 相同 | 一致 |
| 共享账本 | 邀请码/成员双角色/`/member-stats`/MCP（streamable HTTP + 30 天调用日志）/导入 token 流程 | 相同（openapi 逐项一致） | 一致 |
| 同步层 | 历史 bug：增量 pull 三值逻辑、merge 漏字段（曾多次难复现） | 已修复 + 全局同步测试 + merge 契约测试（`test_mobile_push_<entity>_partial_update_keeps_existing_fields` 风格） | 修复 |
| 品牌 | `APP_NAME = "BeeCount Cloud"`、官方镜像 `sunxiao0721/beecount-cloud` | 自建镜像 `smartbook-server`（`deploy/build_docker.sh`）、docker 服务 `smartbook-cloud`/`smartbook-db`、env `SMARTBOOK_*` | 更名 |

### 工作区 / 部署（本项目新增部分）

- `client/` + `server/` 收进**统一 git 仓库**（上游两个项目各自独立仓库）；服务端目录原为 `beecount-cloud`，已重命名为 `server`（本地无独立 `.git`）
- `deploy/`：客户端构建脚本 `build.sh`、服务端镜像构建脚本 `build_docker.sh`、`docker-compose.yml` 部署模板
- 根文档：`CLAUDE.md`（AI 工作指南）、`AGENTS.md`、`docs/` 二开规划（`development-plan.md` 主计划、`backend-selection.md`、`ai-custom-model.md`、`app-feature-plan.md`）
- 工具脚本：`scripts/seed_categories_tags.py`（分类/标签注册）、`server/scripts/`（seed_demo、grant_admin、rebuild_all_projections、备份等）

## 目录结构

```text
server/                             SmartBook-Cloud 服务端源码（FastAPI + React）
  LICENSE / LICENSE_EN              上游 BeeCount Cloud 软件许可协议（原样保留，未修改）
client/                             SmartBook 客户端源码（Flutter）
  LICENSE / LICENSE_EN              上游 BeeCount 软件许可协议（原样保留，未修改）
  COMMERCIAL_LICENSE.md             上游商业授权说明（价格与购买流程，原样保留，未修改）
docs/
  backend-selection.md             后端选型（当前：SmartBook）
  ai-custom-model.md               AI 记账接入自定义大模型方案
  app-feature-plan.md              App 功能方案（基于 SmartBook）
  development-plan.md              开发计划（需求对比 + 里程碑，当前主文档，含二开修改清单细节）
  android-technical-architecture.md Android 技术架构（原自研方案，已废止）
  data-model-and-parser-pipeline.md 本地数据模型与解析流水线（原自研方案，已废止）
  ui-and-mvp-plan.md               UI 结构与 MVP 开发计划（原自研方案，已废止）
deploy/
  build.sh                        SmartBook 客户端一键构建脚本（APK/AAB）
  build_docker.sh                 smartbook-server 镜像一键构建脚本
  docker-compose.yml               SmartBook-Cloud 部署模板
  .env                            SmartBook-Cloud 部署环境变量模板
.env.example                       部署环境变量模板（根目录，供复制）
```

## 选定后端：SmartBook / SmartBook-Cloud

选择 **SmartBook / SmartBook-Cloud**：

- 官方支持简体中文，界面与操作逻辑符合国人记账习惯（收支流水 + 分类占比 + 月度统计）
- 客户端开源，通知监听 / 截图 OCR / AI 自动记账 / 去重已内置
- 服务端暴露标准 REST API（`/api/v1`），支持程序化写入交易（含 `Idempotency-Key` 去重），JWT / PAT 鉴权
- 许可证为 BSL：个人使用、学习研究、非营利组织免费（详见下文「许可证」）

详细对比与 API 证据见 `docs/backend-selection.md`。

## 本地启动

> 部署步骤参考上游仓库：<https://github.com/TNT-Likely/BeeCount-Cloud>（其 `README` / `docs/`）。**本项目部署已脱离官方镜像**：使用自建镜像 `smartbook-server`（`deploy/build_docker.sh` 构建），模板见下。

1. 复制环境变量文件：

   ```powershell
   Copy-Item .env.example .env
   ```

2. 替换 .env 中的 `CHANGE_ME` 值（`JWT_SECRET`、数据库密码等）。

3. 构建自建镜像并启动服务端（不依赖官方镜像）：

   ```powershell
   bash deploy/build_docker.sh   # 构建 smartbook-server 镜像（需 docker daemon）
   docker compose up -d
   ```

4. 访问（使用已部署的服务器实例）：

   ```text
   Web 端     http://localhost:8869
   接口文档   http://localhost:8869/docs
   ```

5. 在 Android 端安装 SmartBook 开源客户端，在设置里把自建服务端地址配置为你部署的实例地址（本地默认 `http://localhost:8869`）并用服务器初始化的管理员账号登录，即可启用通知监听 / 短信监听 / 截图自动记账同步。

6. **接入自定义大模型（AI 记账）**：在客户端 App「AI 服务商管理」页添加自定义服务商（Base URL + API Key + 文本/视觉/语音模型），它会自动同步到服务端。仅需模型走 OpenAI 兼容协议（DeepSeek / Kimi / Qwen / 自托管 vLLM / Ollama 均可）。详见 `docs/backend-selection.md`「自定义大模型接入方案」。


## 后续开发顺序

优先采用"零自研 / 少自研"路线：

1. 部署 SmartBook-Cloud 并配置 JWT、数据库；
2. 用 SmartBook 开源客户端对接自建服务端，人工记账验证同步与统计；
3. 在客户端配置自定义大模型服务商（OpenAI 兼容），启用短信/通知监听、截图 OCR / AI 自动记账，跑通自动链路；
4. 针对性改造：适配 vivo / OriginOS 后台保活、特定银行短信解析（M4 已提供保活引导与渠道映射）；
5. 精简 App 界面：移除/隐藏内置推广位（M0.5 已完成）；
6. 评估是否需要独立客户端，或直接复用 SmartBook。

## 许可证

本项目为 **BeeCount / BeeCount-Cloud 的下游衍生作品**，全部代码遵循**原作者 sunxiao（GitHub: TNT-Likely）的原始许可协议**。**许可协议文本未做任何修改**，原样存放于：

- 根目录：`LICENSE`（导引式说明，指向下列原文）
- 客户端：`client/LICENSE`（中文）、`client/LICENSE_EN`（英文）—— *BeeCount 软件许可协议*
- 服务端：`server/LICENSE`（中文）、`server/LICENSE_EN`（英文）—— *BeeCount Cloud 软件许可协议*
- 商业授权说明（价格与购买流程）：`client/COMMERCIAL_LICENSE.md`

### 授权范围（摘自上游许可原文）

| 用途 | 许可 |
|---|---|
| ✅ 个人使用 / 学习研究 / 非营利组织内部使用 / 开源贡献 | 免费（可自由使用、修改、分发） |
| ❌ 商业使用（作为产品/服务提供给客户、在盈利性组织中使用、基于源码开发商业产品、集成进商业软件、提供付费云服务 / SaaS） | 需向原作者购买付费商业授权 |

商业授权联系：

- 邮箱：sunxiaoyes@outlook.com
- Issues：<https://github.com/TNT-Likely/BeeCount-Cloud/issues>

### 上游许可要求我们履行的义务（已落实）

1. **保留版权声明** —— 原始版权声明与本许可协议完整保留：© 2024-2026 sunxiao（GitHub: TNT-Likely）；许可文件全部保留于仓库。
2. **源代码公开** —— 本修改版本的源代码已在公开仓库中发布（修改版必须公开源码的义务）。
3. **禁止移除标识** —— 未移除或改写版权标识、许可声明与作者信息；许可文件恢复为上游原文
4. **商标** —— "BeeCount" 及其相关标识归原作者所有，本项目不使用其商标作为产品品牌，发布品牌为自有名称 **SmartBook / 智记**。代码中残留的 `beecount` 字串均为旧 key 兼容迁移与上游资源引用（仓库 URL、官方镜像名、Supabase 桶默认值等），属有意保留，详见 `CLAUDE.md`。

> ⚠️ 免责声明（来自上游许可原文）：软件按"现状"提供，不作任何明示或暗示保证；原作者及版权持有人不对使用本软件产生的任何损失负责。
