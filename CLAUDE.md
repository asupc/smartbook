# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

**智记 SmartBook** —— vivo Android **自动记账** 工作区,基于两个上游开源项目二开(fork):上游客户端 **BeeCount**(`https://github.com/TNT-Likely/BeeCount.git`)、上游服务端 **BeeCount-Cloud**;2026-09-03 已完成全仓品牌更名(**BeeCount → SmartBook 智记 / SmartBook Cloud**),含标识符层(applicationId `com.smartbook.zhi`、Dart 包名 `smartbook`、Web 包 `@smartbook/*`、URL scheme `smartbook://`、docker 服务 `smartbook-cloud`/`smartbook-db`、env `SMARTBOOK_*`)。上游引用(仓库 URL、官方镜像 `sunxiao0721/beecount-cloud`、Supabase 桶 `beecount-backups`、RAG 语料 `BeeCount-Website`)全部保留。

- **客户端** `client/` — SmartBook(Flutter + Riverpod + Drift/SQLite),克隆自上游远端,**无独立 `.git`,由根仓库跟踪**。
- **服务端** `server/`(原目录名 `beecount-cloud`)— SmartBook-Cloud(FastAPI + React),源码在本地、无独立 `.git`;部署用本地自建镜像(`smartbook-server`,由 `deploy/build_docker.sh` 构建),已完全脱离官方镜像。
- 旧选型 Firefly III 已弃用(理由见 `docs/backend-selection.md`);原自研 App/解析器方案已废止。

工作区根目录是 git 仓库(初始历史已清,当前已正常提交);`client/` 与 `server/` 均无独立 `.git`,由根仓库跟踪。提交前先与用户确认。

## 常用命令

### 客户端构建(主要产物来源)

在 Windows 的 Git Bash 中:

```bash
bash deploy/build.sh                        # 构建 prod 版 APK(默认 arm64,~20MB),产物放到 deploy/
bash deploy/build.sh --arch universal       # 全 ABI 通用版(~46MB)
bash deploy/build.sh --arch arm64 --with-aab
bash deploy/build.sh --flavor dev --analyze-only
```

- 工具链硬定位置:`FLUTTER_HOME`(`$HOME/devtools/flutter-3.27.3-sdk`)、`JAVA_HOME`(`$HOME/devtools/jdk-17`)、Android SDK(`platforms;android-36` + `build-tools;35.0.0`),可用环境变量覆盖。
- 版本号由 `--app-version` / `--build-number` 写入 `client/pubspec.yaml`。
- 产物(APK/AAB + sha256)统一放到 `deploy/`;服务端 `build_docker.sh` 构建后自动 `docker save` 导出镜像 tar 到 `deploy/`(`smartbook-server-<tag>.tar`)。
- 已知坑:项目在 D:、Pub 缓存在 C: 跨盘符,Kotlin 增量缓存会报 "base files have different roots" 导致回退非增量编译,脚本已自动清理。手跑 `flutter build` 同样会踩,遇到先删 `client/android/app/build`、`client/android/.gradle` 再重试。
- 也可 `source client/env.sh` 后手跑 flutter 命令(`flutter build apk --debug --flavor dev` 可验证 Android 链路,2026-09 实测通过)。

### 服务端测试 / 开发(在 `server/` 内)

无根级构建;Python 工具链都在 `server/` 内(Git Bash + venv):

```bash
cd server
python -m pytest tests/                      # 全部测试(等价 make test)
python -m pytest tests/test_xxx.py::test_yyy # 单个测试
make lint                                    # ruff check src tests alembic
make typecheck                               # mypy src
make migrate                                 # alembic upgrade head
make dev-api                                 # 本地起服(0.0.0.0:8080,首次自动建 venv + migrate)
make dev-web                                 # pnpm workspace 前端(frontend/ ,pnpm@10)
```

- 本地 DB 默认 SQLite(`smartbook.db` 在仓根),`make wipe-local` 清理本地开发数据。
- 前端(React)在 `server/frontend/`(pnpm workspace,`apps/web`)。⚠️ **web 构建验证受限**:workspace 包 `server/frontend/packages/{api-client,ui,web-features}` 源码未被 git 跟踪(目录为空),仅存在于 gitignored 的 `node_modules/@smartbook/*` 副本中;干净克隆需先补回这三个包源码,否则 alias/tsconfig 指向的 `../../packages/*/src` 为空,`make dev-web`/build 无法解析 `@smartbook/*`(2026-09 时点已确认,待处理)。

### 生产部署(根目录)

`server/` 使用自建镜像 `smartbook-server`(构建:仓库根 `bash deploy/build_docker.sh`,需 docker daemon),不依赖官方镜像。之后:

```powershell
Copy-Item .env.example .env   # 替换所有 CHANGE_ME(JWT_SECRET、DB 密码)
docker compose up -d          # smartbook-cloud + smartbook-db(PostgreSQL);JWT_SECRET 缺失会快速失败
```

生产实例信息(域名/版本)不写入仓库(隐私);部署模板见 `deploy/docker-compose.yml`,env 模板见根目录 `.env.example`。

## 架构大图

数据流:App 本地(Drift)先写 → 离线优先,网络恢复后经 WebSocket/API 与 **服务端** 双向同步;服务端 Web 端(React)同源。

### 二开工作的两个入口

1. **客户端** `client/` — 改 Flutter App(界面、监听、OCR/AI 记账)。注意:上游内部路径(`lib/ai/...` 等)只存在于 `client/` 下,不要当代码在别处。
2. **服务端** `server/` — 改任何服务端逻辑前,**必读 `server/CLAUDE.md`,动同步相关代码必读 `server/docs/SYNC_ARCHITECTURE.md`**。该代码块曾出过多次难复现 bug(ledger_id 通道误用、漏 merge 字段),根因都是隐式契约未被强制。

### 服务端关键契约

- **存储形态三件套,不得混用**:
  - `sync_changes` — 事件流,append-only,`change_id` 自增,增量 pull 的唯一来源;只 insert 不 UPDATE。
  - `read_*_projection` — 5 张 denorm 表,**读路径唯一权威源**;LWW / rename cascade 落盘于此。
  - `ledger_snapshot` — 已废弃,新代码不要主动写。
- **路由组织**:`src/routers/<group>/` 包(`__init__.py` 聚合 + `_shared.py` 共享 + `<entity>.py` 端点);新增同步实体的 6 步清单见 `server/CLAUDE.md`,并必须补 merge 契约测试(`test_mobile_push_<entity>_partial_update_keeps_existing_fields` 风格)。
- **鉴权**:JWT + PAT;交易写入支持 `Idempotency-Key` 去重。部署实例已关闭注册(403),脚本/测试请用已有账号或 PAT。

### 自定义大模型(两条独立路径)

1. Chat/Vision → AI 记账:客户端「AI 服务商管理」页配置(OpenAI 兼容协议),会自动同步到服务端,无服务端代码。
2. Embedding → 服务端「问 AI」文档 RAG(`EMBEDDING_*` 环境变量,可选)。

### 工具脚本

- `scripts/seed_categories_tags.py` — 向已部署实例注册两级分类/标签(/api/v1 写入,幂等,需账号或 PAT + ledger_id)。用法见 `scripts/README-seed.md`。
- `server/scripts/` 有 seed_demo、grant_admin、rebuild_all_projections、备份脚本等。

## 注意

- **品牌残留说明**:代码中仍会出现 `beecount` 字样,均为**有意保留**:(1) 客户端/服务端里的旧 key 兼容迁移(SharedPreferences、localStorage、YAML、SQLite 文件搬移等,一般带「品牌更名前」注释);(2) 上游出处与真实资产(URL、域名、官方镜像名、Supabase 桶默认值 `beecount-backups`)。新增代码一律用 `smartbook` / SmartBook,不要动这些兼容点。
- **已废止文档(勿当现行)**: `docs/android-technical-architecture.md`、`docs/data-model-and-parser-pipeline.md`、`docs/ui-and-mvp-plan.md`(原自研方案)。现行: `docs/backend-selection.md`、`app-feature-plan.md`、`ai-custom-model.md`、**`development-plan.md`(主计划,M0 → M0.5 → M1 里程碑,实施前先读)**。
- **计划中的二开是新功能,非上游已有**:已实现 —— 短信监听、自动记账四路(截图/支付通知/短信/账单详情页无障碍 `ScreenTextWatcher`)、"待确认/疑似重复"确认队列(自动入账校验候选制)。
- **有意移除的既有功能**:上游的大额/异常支出提醒,二开时**主动删除**(l10n 仅残留 M3 文案 `autoBillingLargeAmount*`,无代码引用);勿将其当作未完成计划或重新引入。
- **许可证 BSL**:个人/非营利/研究免费,商业用途需付费授权(见 `client/COMMERCIAL_LICENSE.md`)。
- `.env*` 已被 gitignore,绝不可提交真实密钥。
