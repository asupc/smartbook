#!/usr/bin/env python3
"""
SmartBook-Cloud 分类 / 标签初始化脚本。

在已部署的 SmartBook-Cloud 上注册常用分类（两层）与标签。
遵循该服务端的 sync 写入模型：每次创建需要
  - 认证（JWT 或 PAT，Authorization: Bearer <token>）
  - 目标账本 ledger_id
  - 当前 base_change_id（来自账本的 source_change_id，成功后用返回的 new_change_id 递增）

用法（PowerShell 或 bash）：

    # 方式一：用 JWT 直接登录（需要管理员邮箱 + 密码）
    $env:SMARTBOOK_BASE = "https://your-server:8888"
    $env:SMARTBOOK_EMAIL = "admin@example.com"
    $env:SMARTBOOK_PASSWORD = "******"
    $env:SMARTBOOK_LEDGER_ID = "<你的账本 id>"
    python scripts/seed_categories_tags.py

    # 方式二：用 Personal Access Token（自托管 Web 端个人设置里生成）
    $env:SMARTBOOK_BASE = "https://your-server:8888"
    $env:SMARTBOOK_PAT = "bc_xxx"
    $env:SMARTBOOK_LEDGER_ID = "<你的账本 id>"
    python scripts/seed_categories_tags.py

说明：
  - 脚本是幂等的：已存在的分类/标签会被跳过（按 name + kind 匹配），不会重复创建。
  - 分类为两级：level=1 为主类，level=2 为子类（通过 parent_name 挂到主类下）。
  - 标签为一级，支持颜色。
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

BASE = os.environ.get("SMARTBOOK_BASE", "https://your-server:8888").rstrip("/")
LEDGER_ID = os.environ.get("SMARTBOOK_LEDGER_ID", "")
EMAIL = os.environ.get("SMARTBOOK_EMAIL", "")
PASSWORD = os.environ.get("SMARTBOOK_PASSWORD", "")
PAT = os.environ.get("SMARTBOOK_PAT", "")

API = BASE + "/api/v1"


# ---------------------------------------------------------------------------
# 默认分类树（两级）。structure: (主类名, 子类列表)
# 与 docs/app-feature-plan.md 5.1「默认分类树」对齐。
# ---------------------------------------------------------------------------
CATEGORY_TREE = [
    ("餐饮", ["早餐", "午餐", "晚餐", "外卖", "零食饮品", "聚餐"]),
    ("交通", ["公交地铁", "打车", "加油", "停车", "高铁机票", "共享单车"]),
    ("购物", ["服饰", "美妆", "日用百货", "数码电器", "快递"]),
    ("居住", ["房租", "房贷", "水电燃气", "物业", "维修"]),
    ("通讯", ["话费", "宽带", "流量"]),
    ("娱乐", ["电影", "游戏", "运动", "旅行", "KTV"]),
    ("医疗", ["药品", "门诊", "住院", "体检"]),
    ("教育", ["书籍", "课程", "考试报名"]),
    ("宠物", ["宠物粮", "宠物医疗", "宠物用品"]),
    ("母婴", ["奶粉", "尿布", "玩具"]),
    ("人情往来", ["红包送礼", "请客", "份子钱"]),
    ("缴费", ["社保", "保险", "会员订阅"]),
    ("汽车", ["保养", "车险", "洗车"]),
]
# 一级叶子分类（本身是独立类别；退款/其他这类与主类重名的不再配子级，避免重名歧义）
LEAF_EXPENSE_CATEGORIES = ["退款", "其他"]

# 收入类（一级，简短即可）
INCOME_CATEGORIES = [
    "工资", "奖金", "理财收益", "红包", "兼职", "退款收入", "报销", "其他收入",
]

# 转账不是消费/收入类别，不作为分类；如需可单独加：
TRANSFER_CATEGORIES = ["转账", "还款", "提现"]

# ---------------------------------------------------------------------------
# 默认标签（一级）
# ---------------------------------------------------------------------------
TAGS = [
    {"name": "工作", "color": "#4A90D9"},
    {"name": "家庭", "color": "#E57373"},
    {"name": "旅行", "color": "#4DB6AC"},
    {"name": "健康", "color": "#81C784"},
    {"name": "人情", "color": "#BA68C8"},
    {"name": "固定支出", "color": "#FFB74D"},
    {"name": "必需", "color": "#A1887F"},
    {"name": "免报销", "color": "#90A4AE"},
]


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
def _req(method, url, token, body=None, timeout=30):
    data = None
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            body = json.loads(raw)
        except Exception:
            body = raw
        return e.code, body
    except urllib.error.URLError as e:
        print(f"[错误] 无法连接 {url}: {e}", file=sys.stderr)
        sys.exit(1)


def get_token():
    if PAT:
        return PAT, "PAT"
    if EMAIL and PASSWORD:
        body = {
            "email": EMAIL,
            "password": PASSWORD,
            "client_type": "web",
            "device_id": "seed-py",
            "device_name": "seed-category-tags-py",
        }
        status, resp = _req("POST", f"{API}/auth/login", "")
        if status == 200 and resp and resp.get("access_token"):
            return resp["access_token"], "JWT(login)"
        print(f"[错误] 登录失败 HTTP {status}: {resp}", file=sys.stderr)
        sys.exit(1)
    print("[错误] 需要设置 SMARTBOOK_EMAIL+SMARTBOOK_PASSWORD 或 SMARTBOOK_PAT", file=sys.stderr)
    sys.exit(1)


def get_ledger(token):
    url = f"{API}/read/ledgers/{LEDGER_ID}"
    status, resp = _req("GET", url, token)
    if status == 200 and resp:
        return resp
    print(f"[错误] 读取账本失败 HTTP {status}: {resp}", file=sys.stderr)
    sys.exit(1)


def list_categories(token, ledger_id):
    url = f"{API}/read/ledgers/{ledger_id}/categories"
    status, resp = _req("GET", url, token)
    if status != 200:
        print(f"[警告] 读取分类失败 HTTP {status}: {resp}", file=sys.stderr)
        return []
    return resp or []


def list_tags(token, ledger_id):
    url = f"{API}/read/ledgers/{ledger_id}/tags"
    status, resp = _req("GET", url, token)
    if status != 200:
        print(f"[警告] 读取标签失败 HTTP {status}: {resp}", file=sys.stderr)
        return []
    return resp or []


def _ensure_change_id(token, ledger_id):
    """获取当前 source_change_id，作为写入的 base_change_id。"""
    ledger = get_ledger(token)
    cid = ledger.get("source_change_id", 0)
    if cid is None:
        cid = 0
    return int(cid)


def _create_category(token, ledger_id, base_change_id, name, kind, level, parent_name=None,
                     sort_order=0, icon=None, request_id=None):
    body = {
        "base_change_id": base_change_id,
        "name": name,
        "kind": kind,
        "level": level,
        "sort_order": sort_order,
    }
    if parent_name:
        body["parent_name"] = parent_name
    if icon:
        body["icon"] = icon
    if request_id:
        body["request_id"] = request_id[:128]
    url = f"{API}/write/ledgers/{ledger_id}/categories"
    status, resp = _req("POST", url, token, body)
    return status, resp


def _create_tag(token, ledger_id, base_change_id, name, color=None, request_id=None):
    body = {
        "base_change_id": base_change_id,
        "name": name,
    }
    if color:
        body["color"] = color
    if request_id:
        body["request_id"] = request_id[:128]
    url = f"{API}/write/ledgers/{ledger_id}/tags"
    status, resp = _req("POST", url, token, body)
    return status, resp


def _next_change_id(resp, current):
    if resp and isinstance(resp, dict):
        n = resp.get("new_change_id")
        if isinstance(n, int) and n is not None:
            return n
    return current


def main():
    if not LEDGER_ID:
        print("[错误] 请设置环境变量 SMARTBOOK_LEDGER_ID（目标账本 id）", file=sys.stderr)
        sys.exit(1)

    token, token_type = get_token()
    print(f"[OK] 已认证：{token_type}")

    ledger = get_ledger(token)
    print(f"[OK] 账本：{ledger.get('ledger_name')} ({ledger.get('ledger_id')})\n")

    existing_cats = list_categories(token, LEDGER_ID)
    existing_tags = list_tags(token, LEDGER_ID)
    existing_cat_keys = {(c.get("name"), c.get("kind")) for c in existing_cats}
    existing_tag_names = {t.get("name") for t in existing_tags}

    # 用稳定的 request_id 保证幂等（同一名称+kind 不重复创建）
    seq = 0

    def make_rid(prefix, name):
        nonlocal seq
        seq += 1
        return f"seed-{prefix}-{seq}-{name}"

    base_change = _ensure_change_id(token, LEDGER_ID)

    # --- 支出分类（两级）---
    print("== 支出分类 ==")
    for parent, children in CATEGORY_TREE:
        pkey = (parent, "expense")
        if pkey not in existing_cat_keys:
            status, resp = _create_category(
                token, LEDGER_ID, base_change, parent, "expense", 1,
                sort_order=0, request_id=make_rid("cat", parent),
            )
            base_change = _next_change_id(resp, base_change)
            if status == 200:
                existing_cat_keys.add(pkey)
                print(f"  [新建] {parent}")
            else:
                print(f"  [失败] {parent} HTTP {status}: {resp}")
        else:
            print(f"  [已存在] {parent}")

        for child in children:
            ch_name = child
            ckey = (ch_name, "expense")
            if ckey not in existing_cat_keys:
                status, resp = _create_category(
                    token, LEDGER_ID, base_change, ch_name, "expense", 2,
                    parent_name=parent, sort_order=0, request_id=make_rid("cat", ch_name),
                )
                base_change = _next_change_id(resp, base_change)
                if status == 200:
                    existing_cat_keys.add(ckey)
                    print(f"    [新建] {parent}/{ch_name}")
                else:
                    print(f"    [失败] {parent}/{ch_name} HTTP {status}: {resp}")
            else:
                print(f"    [已存在] {parent}/{ch_name}")

    # --- 一级叶子支出分类（退款/其他，单独成类，无子级）---
    print("== 一级叶子支出分类 ==")
    for name in LEAF_EXPENSE_CATEGORIES:
        key = (name, "expense")
        if key not in existing_cat_keys:
            status, resp = _create_category(
                token, LEDGER_ID, base_change, name, "expense", 1,
                sort_order=0, request_id=make_rid("cat", name),
            )
            base_change = _next_change_id(resp, base_change)
            if status == 200:
                existing_cat_keys.add(key)
                print(f"  [新建] {name}")
            else:
                print(f"  [失败] {name} HTTP {status}: {resp}")
        else:
            print(f"  [已存在] {name}")

    # --- 收入分类（一级）---
    print("== 收入分类 ==")
    for name in INCOME_CATEGORIES:
        key = (name, "income")
        if key not in existing_cat_keys:
            status, resp = _create_category(
                token, LEDGER_ID, base_change, name, "income", 1,
                sort_order=0, request_id=make_rid("cat", name),
            )
            base_change = _next_change_id(resp, base_change)
            if status == 200:
                existing_cat_keys.add(key)
                print(f"  [新建] {name}")
            else:
                print(f"  [失败] {name} HTTP {status}: {resp}")
        else:
            print(f"  [已存在] {name}")

    # --- 转账/还款（一级，若需要）---
    print("== 转账/还款 ==")
    for name in TRANSFER_CATEGORIES:
        key = (name, "transfer")
        if key not in existing_cat_keys:
            status, resp = _create_category(
                token, LEDGER_ID, base_change, name, "transfer", 1,
                sort_order=0, request_id=make_rid("cat", name),
            )
            base_change = _next_change_id(resp, base_change)
            if status == 200:
                existing_cat_keys.add(key)
                print(f"  [新建] {name}")
            else:
                print(f"  [失败] {name} HTTP {status}: {resp}")
        else:
            print(f"  [已存在] {name}")

    # --- 标签 ---
    print("== 标签 ==")
    for tag in TAGS:
        if tag["name"] in existing_tag_names:
            print(f"  [已存在] {tag['name']}")
            continue
        status, resp = _create_tag(
            token, LEDGER_ID, base_change, tag["name"], tag.get("color"),
            request_id=make_rid("tag", tag["name"]),
        )
        base_change = _next_change_id(resp, base_change)
        if status == 200:
            existing_tag_names.add(tag["name"])
            print(f"  [新建] {tag['name']}")
        else:
            print(f"  [失败] {tag['name']} HTTP {status}: {resp}")

    print("\n[完成] 分类/标签初始化结束。")


if __name__ == "__main__":
    main()
