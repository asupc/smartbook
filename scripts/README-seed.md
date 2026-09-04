# 分类 / 标签初始化脚本

## 用途

在已部署的 SmartBook-Cloud `/api/v1` 上用脚本注册常用**两级分类**与**标签**。

这套分类/标签与 `docs/app-feature-plan.md` 5.1 的「默认分类树」对齐，方便客户端（SmartBook App）与 Web 端直接使用，无需在界面里逐个手工添加。

## 前置条件

脚本需要：

1. **能登录的账号凭证**，二选一：
   - 管理员邮箱 + 密码（`/api/v1/auth/login` 走 JWT）；或
   - Personal Access Token（自托管 Web 端「个人设置 → API 令牌」生成，`/api/v1/profile/pats`）。
2. **目标账本 id（`ledger_id`）**——从 SmartBook-Cloud Web 端或 `GET /api/v1/read/ledgers` 获取。

> ⚠️ 注意：当前部署实例 **已关闭注册**（`POST /api/v1/auth/register` 返回 403 “Registration disabled”），
> 因此**无法用脚本新建账号**，必须使用已有管理员账号或 PAT。仓库内也不含任何真实凭证（仅 `.env.example` / `deploy/.env` 的 `CHANGE_ME` 占位）。

## 运行

PowerShell：

```powershell
# 方式一：JWT 登录
$env:SMARTBOOK_BASE = "https://your-server:8888"
$env:SMARTBOOK_EMAIL = "admin@example.com"
$env:SMARTBOOK_PASSWORD = "******"
$env:SMARTBOOK_LEDGER_ID = "<你的账本 id>"
python scripts/seed_categories_tags.py

# 方式二：PAT
$env:SMARTBOOK_BASE = "https://your-server:8888"
$env:SMARTBOOK_PAT = "bc_xxxx"
$env:SMARTBOOK_LEDGER_ID = "<你的账本 id>"
python scripts/seed_categories_tags.py
```

bash：

```bash
export SMARTBOOK_BASE="https://your-server:8888"
export SMARTBOOK_EMAIL="admin@example.com"
export SMARTBOOK_PASSWORD="******"
export SMARTBOOK_LEDGER_ID="<你的账本 id>"
python scripts/seed_categories_tags.py
```

## 会写入什么

- **支出分类（两级）**：`餐饮 / 交通 / 购物 / 居住 / 通讯 / 娱乐 / 医疗 / 教育 / 宠物 / 母婴 / 人情往来 / 缴费 / 汽车 / 退款 / 其他`，每个主类带 2–6 个子类。
- **收入分类（一级）**：`工资、奖金、理财收益、红包、兼职、退款收入、报销、其他收入`。
- **转账/还款（一级）**：`转账、还款、提现`（kind=transfer，默认只作分类不作消费）。
- **标签**：`工作、家庭、旅行、健康、人情、固定支出、必需、免报销`。

脚本**幂等**：按 `(名称, kind)` / 名称 与现有数据比对，已存在则跳过，不会重复创建。

## 同步写入模型说明

该服务端写入接口（`/api/v1/write/ledgers/{ledger_id}/categories|tags`）采用 **sync 并发控制**：

- 每次创建需传 `base_change_id`（取账本的 `source_change_id`）；
- 成功后返回 `new_change_id`，作为下一条请求的 `base_change_id`，保证串行递增，避免并发冲突；
- 可选 `request_id`（≤128 字符）用作幂等，脚本已为每条生成稳定 request_id。

脚本已自动处理上述递增逻辑。

## 注意事项

- 若账本内已有部分分类/标签，脚本会跳过而非覆盖。
- 分类的子类通过 `parent_name` 挂到对应主类；如主类已存在但子类缺失，会补建子类。
- 需要 `python3`（脚本运行时已确认 3.14 可用），仅用标准库，无第三方依赖。
