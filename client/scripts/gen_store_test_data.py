#!/usr/bin/env python3
"""生成商店截图用的测试账本 CSV + 配置 YAML（中英双语）。

输出：
  demo/store_test_zh.csv          — 中文交易数据 100 条
  demo/store_test_en.csv          — 英文交易数据 100 条
  demo/store_setup_zh.yaml        — 中文配置：5 账户 + 59 分类（含图标）+ 24 标签（含颜色）
  demo/store_setup_en.yaml        — 英文配置

用法：
  python3 scripts/gen_store_test_data.py

为什么需要 YAML：SmartBook 的 CSV 导入链不识别"图标"列，且账户/标签字段
缺乏必要属性（账户类型、标签颜色）。SmartBook 自带的「配置导入」功能
（lib/services/export/config_export_service.dart）接受完整 YAML，能
一次性导入分类（带 Material 图标）、账户（带类型）、标签（带颜色）。
所以工作流：先导 YAML（建好账户/分类/标签的"骨架"），再导交易 CSV
（按名匹配到现有的带颜色/图标的实体）。

中英文有意区分：账户、标签、分类的命名都按语言独立（zh CSV 用中文名，
en CSV 用英文名），导入后 app 里同时有两套数据，分别对应中英截图。

数据策略：
  - 时间：2026-01-01 ~ 2026-04-29（往前推 ~120 天）
  - 分布：4 月 ~40，3 月 ~25，2 月 ~20，1 月 ~15（最近月份更密）
  - 收入 ~10 / 支出 ~90
  - 分类严格对齐 lib/l10n/app_{zh,en}.arb 里的 categoryExpenseList / categoryIncomeList
  - 分类图标严格对齐 lib/services/data/seed_service.dart 里的默认 Material 图标
  - 标签和颜色严格对齐 lib/services/data/tag_seed_service.dart
    （多个标签在 CSV 里用英文逗号分隔，CSV writer 会自动加引号）
  - 账户类型对齐 lib/data/db.dart 的 Account.type（cash / bank_card / credit_card）
  - ~30% 条目带备注
  - ~50% 支出条目带 1-2 个标签，按分类语义匹配
  - 同一逻辑条目在 zh / en 两份里的金额/日期/类型完全一致，仅分类名+备注+标签+账户本地化
"""

from __future__ import annotations

import csv
import random
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

# ---------- 分类（必须与 i18n 文件完全一致）----------

EXPENSE_ZH = [
    "餐饮", "交通", "购物", "娱乐", "居家", "家庭", "通讯", "水电", "住房", "医疗",
    "教育", "宠物", "运动", "数码", "旅行", "烟酒", "母婴", "美容", "维修", "社交",
    "学习", "汽车", "打车", "地铁", "外卖", "物业", "停车", "捐赠", "送礼", "纳税",
    "饮料", "服装", "零食", "发红包", "水果", "游戏", "书", "爱人", "装修", "日用品",
    "彩票", "股票", "社保", "快递", "工作",
]
EXPENSE_EN = [
    "Dining", "Transport", "Shopping", "Entertainment", "Home", "Family", "Communication",
    "Utilities", "Housing", "Medical", "Education", "Pets", "Sports", "Digital", "Travel",
    "Alcohol & Tobacco", "Baby Care", "Beauty", "Repair", "Social", "Learning", "Car",
    "Taxi", "Subway", "Delivery", "Property", "Parking", "Donation", "Give Gift", "Tax",
    "Beverage", "Clothing", "Snacks", "Send Red Packet", "Fruit", "Game", "Book", "Lover",
    "Decoration", "Daily Goods", "Lottery", "Stock", "Social Security", "Express", "Work",
]
INCOME_ZH = [
    "工资", "理财", "收红包", "奖金", "报销", "兼职", "收礼", "利息", "退款",
    "投资收益", "二手转卖", "社会保障", "退税退费", "公积金",
]
INCOME_EN = [
    "Salary", "Investment", "Receive Red Packet", "Bonus", "Reimbursement", "Part-time",
    "Receive Gift", "Interest", "Refund", "Investment Income", "Second-hand", "Social Benefit",
    "Tax Refund", "Provident Fund",
]

assert len(EXPENSE_ZH) == len(EXPENSE_EN) == 45
assert len(INCOME_ZH) == len(INCOME_EN) == 14

# ---------- 默认分类图标（与 lib/services/data/seed_service.dart 完全一致）----------
# 顺序与 EXPENSE_ZH / EXPENSE_EN / INCOME_ZH / INCOME_EN 严格对应。
# 图标名为 Material Icons（与 lib/services/data/category_service.dart 的 getCategoryIcon switch 对齐）。

EXPENSE_ICONS = [
    "restaurant", "directions_car", "shopping_cart", "movie", "home",
    "family_restroom", "phone", "flash_on", "home_work", "local_hospital",
    "school", "pets", "fitness_center", "smartphone", "flight",
    "local_bar", "child_care", "face", "handyman", "group",
    "school", "directions_car", "local_taxi", "directions_subway", "delivery_dining",
    "apartment", "local_parking", "volunteer_activism", "card_giftcard", "receipt_long",
    "local_cafe", "checkroom", "fastfood", "wallet", "eco",
    "sports_esports", "menu_book", "favorite", "home_repair_service", "local_laundry_service",
    "confirmation_number", "trending_up", "security", "local_shipping", "work_outline",
]

INCOME_ICONS = [
    "work", "account_balance", "wallet", "emoji_events", "receipt",
    "schedule", "card_giftcard", "monetization_on", "undo", "trending_up",
    "sell", "health_and_safety", "receipt_long", "account_balance_wallet",
]

assert len(EXPENSE_ICONS) == 45
assert len(INCOME_ICONS) == 14

# ---------- 账户清单 ----------
# 账户类型对齐 lib/data/db.dart 的 Account.type：cash / bank_card / credit_card。
# 中英刻意不对应同名：zh 用国内常见（招行/微信/支付宝/工行/现金），
# en 用美国常见（Chase/Apple Pay/PayPal/BoA/Cash），让两套截图都符合本地用户使用习惯。
# 索引位置含义保持一致（idx 0=信用卡, 1=电子钱包1, 2=电子钱包2, 3=借记银行, 4=现金）。

ACCOUNT_ZH = ["招商信用卡", "微信", "支付宝", "工商银行卡", "现金"]
ACCOUNT_EN = ["Chase Credit", "Apple Pay", "PayPal", "BoA Checking", "Cash"]
ACCOUNT_TYPES = ["credit_card", "cash", "cash", "bank_card", "cash"]
# 权重 zh/en 略有差别：美国用户信用卡使用更普遍，Chase 权重更高，Cash 更低。
ACCOUNT_WEIGHTS_ZH = [30, 25, 20, 15, 10]
ACCOUNT_WEIGHTS_EN = [40, 25, 15, 15, 5]
A_CMB, A_WECHAT, A_ALIPAY, A_ICBC, A_CASH = 0, 1, 2, 3, 4
assert (len(ACCOUNT_ZH) == len(ACCOUNT_EN) == len(ACCOUNT_TYPES)
        == len(ACCOUNT_WEIGHTS_ZH) == len(ACCOUNT_WEIGHTS_EN) == 5)

# 货币：zh 用 CNY，en 用 USD（写入 yaml 的 currency 字段，CSV 金额按对应货币区间）
CURRENCY_ZH = "CNY"
CURRENCY_EN = "USD"

# ---------- 默认标签（与 lib/services/data/tag_seed_service.dart 一致）----------

# 索引顺序与 tag_seed_service.dart 的 getDefaultTags() 完全一致，方便对照。
TAG_ZH = [
    "美团", "饿了么", "淘宝", "京东", "拼多多", "星巴克", "瑞幸咖啡", "麦当劳",
    "肯德基", "盒马", "山姆", "Costco",
    "出差", "旅行", "聚餐", "网购", "日常",
    "报销", "可退款", "已退款",
    "语音记账", "图片记账", "拍照记账", "AI记账",
]
TAG_EN = [
    "Meituan", "Eleme", "Taobao", "JD.com", "Pinduoduo", "Starbucks", "Luckin Coffee", "McDonald's",
    "KFC", "Hema", "Sam's Club", "Costco",
    "Business Trip", "Travel", "Dining Out", "Online Shopping", "Daily",
    "Reimbursable", "Refundable", "Refunded",
    "Voice", "Image", "Camera", "AI",
]
# 颜色严格对齐 tag_seed_service.dart 的 getDefaultTags()
TAG_COLORS = [
    "#FF5722", "#2196F3", "#FF9800", "#F44336", "#E91E63", "#009688", "#795548", "#FFC107",
    "#D32F2F", "#00BCD4", "#3F51B5", "#673AB7",
    "#607D8B", "#00E676", "#FF4081", "#536DFE", "#8BC34A",
    "#9C27B0", "#CDDC39", "#4CAF50",
    "#FF9800", "#4CAF50", "#2196F3", "#9C27B0",
]
assert len(TAG_ZH) == len(TAG_EN) == len(TAG_COLORS) == 24

# 标签语义索引（方便后面给 CategoryTemplate 引用）
T_MEITUAN, T_ELEME, T_TAOBAO, T_JD, T_PDD = 0, 1, 2, 3, 4
T_STARBUCKS, T_LUCKIN, T_MCD, T_KFC = 5, 6, 7, 8
T_HEMA, T_SAMS, T_COSTCO = 9, 10, 11
T_BIZTRIP, T_TRAVEL, T_DINING, T_ONLINESHOP, T_DAILY = 12, 13, 14, 15, 16
T_REIMBURSE = 17

# ---------- 每个分类的"模板"：金额范围 + 双语备注样本 + 关联标签 ----------

@dataclass(frozen=True)
class CategoryTemplate:
    cat_idx: int           # 在 EXPENSE_*/INCOME_* 里的下标
    amount_lo: float       # CNY 区间下限
    amount_hi: float       # CNY 区间上限
    amount_lo_usd: float   # USD 区间下限（按美国典型物价手工设计，不是简单汇率换算）
    amount_hi_usd: float   # USD 区间上限
    weight: int            # 出现频率权重
    notes_zh: tuple[str, ...]
    notes_en: tuple[str, ...]
    # 关联标签候选（TAG_* 索引）。生成时按 tag_prob 抽 0-2 个。
    tag_candidates: tuple[int, ...] = ()
    tag_prob: float = 0.0  # 0.0 = 必无标签；0.6 = 60% 至少打 1 个


# 支出模板（按真实生活频率给权重）
# USD 区间按美国典型物价：fast food 早餐 5-10、午餐 8-15、casual dinner 15-30；
# subway $2.90、Uber $10-25；rent 一居室 $1500-2800；coffee $4-8。
EXPENSE_TEMPLATES = [
    # 餐饮：随机贴聚餐 / 星巴克 / 瑞幸 / 麦当劳 / 肯德基（视金额而定，简化为均匀采样）
    CategoryTemplate(0, 12, 80, 8, 35, 14, ("早餐", "公司午餐", "晚饭", "和同事聚餐", "周末家常", "便利店午饭"),
                     ("Breakfast", "Company lunch", "Dinner", "With colleagues", "Weekend home meal", "Lunch at convenience store"),
                     tag_candidates=(T_DINING, T_STARBUCKS, T_LUCKIN, T_MCD, T_KFC), tag_prob=0.35),
    CategoryTemplate(1, 6, 50, 2, 15, 8, ("公交", "通勤", "地铁卡充值"),
                     ("Bus", "Commute", "Subway card top-up"),
                     tag_candidates=(T_DAILY,), tag_prob=0.25),
    # 购物：淘宝 / 京东 / 拼多多 / 网购
    CategoryTemplate(2, 30, 480, 15, 120, 6, ("日用补货", "京东下单", "拼多多"),
                     ("Daily restock", "Amazon order", "Online purchase"),
                     tag_candidates=(T_TAOBAO, T_JD, T_PDD, T_ONLINESHOP), tag_prob=0.7),
    CategoryTemplate(3, 20, 200, 10, 60, 4, ("电影票", "话剧", "音乐节"),
                     ("Movie ticket", "Concert", "Show"),
                     tag_candidates=(T_DAILY,), tag_prob=0.2),
    CategoryTemplate(4, 40, 260, 20, 80, 3, ("家居小件", "厨房用品"),
                     ("Home accessories", "Kitchen supplies"),
                     tag_candidates=(T_HEMA, T_SAMS, T_DAILY), tag_prob=0.4),
    CategoryTemplate(5, 80, 600, 40, 200, 2, ("孝敬父母", "亲戚来访"),
                     ("For parents", "Family visit")),
    CategoryTemplate(6, 30, 200, 30, 100, 3, ("话费充值", "宽带续费"),
                     ("Phone bill", "Internet bill")),
    CategoryTemplate(7, 80, 380, 60, 180, 4, ("电费", "燃气费", "水费"),
                     ("Electricity", "Gas", "Water")),
    CategoryTemplate(8, 3000, 4500, 1500, 2800, 4, ("房租", "月租"),
                     ("Rent", "Monthly rent")),
    CategoryTemplate(9, 30, 350, 20, 200, 2, ("药店", "门诊"),
                     ("Pharmacy", "Doctor co-pay"),
                     tag_candidates=(T_REIMBURSE,), tag_prob=0.5),
    CategoryTemplate(10, 100, 880, 30, 300, 2, ("买书", "线上课程"),
                     ("Books", "Online course"),
                     tag_candidates=(T_TAOBAO, T_JD), tag_prob=0.4),
    CategoryTemplate(11, 40, 320, 25, 120, 2, ("猫粮", "宠物医院"),
                     ("Cat food", "Vet visit"),
                     tag_candidates=(T_TAOBAO, T_DAILY), tag_prob=0.3),
    CategoryTemplate(12, 30, 240, 15, 90, 3, ("健身房", "羽毛球场"),
                     ("Gym membership", "Yoga class"),
                     tag_candidates=(T_DAILY,), tag_prob=0.3),
    # 数码：京东 / 网购
    CategoryTemplate(13, 80, 1800, 30, 600, 2, ("耳机", "充电器", "数据线"),
                     ("Earbuds", "Charger", "Cable"),
                     tag_candidates=(T_JD, T_TAOBAO, T_ONLINESHOP), tag_prob=0.75),
    # 旅行：旅行 / 出差
    CategoryTemplate(14, 200, 1600, 80, 600, 2, ("周边游", "高铁票"),
                     ("Weekend trip", "Train ticket"),
                     tag_candidates=(T_TRAVEL, T_BIZTRIP), tag_prob=0.85),
    CategoryTemplate(17, 50, 360, 20, 120, 2, ("护肤品", "理发"),
                     ("Skincare", "Haircut"),
                     tag_candidates=(T_TAOBAO, T_DAILY), tag_prob=0.4),
    CategoryTemplate(22, 18, 60, 8, 30, 5, ("打车回家", "下雨打车"),
                     ("Uber home", "Lyft in rain"),
                     tag_candidates=(T_DAILY,), tag_prob=0.25),
    CategoryTemplate(23, 5, 18, 2, 4, 4, ("地铁", ""),
                     ("Subway", ""),
                     tag_candidates=(T_DAILY,), tag_prob=0.2),
    # 外卖：美团 / 饿了么（必贴标签）
    CategoryTemplate(24, 22, 80, 12, 35, 6, ("美团外卖", "饿了么", "周末外卖"),
                     ("DoorDash", "Uber Eats", "Weekend delivery"),
                     tag_candidates=(T_MEITUAN, T_ELEME), tag_prob=0.95),
    # 饮料：星巴克 / 瑞幸
    CategoryTemplate(30, 8, 35, 4, 8, 4, ("奶茶", "咖啡", "矿泉水"),
                     ("Bubble tea", "Coffee", "Bottled water"),
                     tag_candidates=(T_STARBUCKS, T_LUCKIN), tag_prob=0.5),
    # 服装：淘宝 / 网购
    CategoryTemplate(31, 80, 600, 25, 150, 2, ("外套", "T 恤", "运动鞋"),
                     ("Jacket", "T-shirt", "Sneakers"),
                     tag_candidates=(T_TAOBAO, T_ONLINESHOP), tag_prob=0.7),
    CategoryTemplate(32, 6, 40, 3, 12, 3, ("零食补给", "饼干"),
                     ("Snack restock", "Cookies"),
                     tag_candidates=(T_HEMA, T_SAMS), tag_prob=0.3),
    CategoryTemplate(34, 12, 60, 4, 15, 2, ("水果店", "草莓"),
                     ("Grocery fruit", "Strawberries"),
                     tag_candidates=(T_HEMA,), tag_prob=0.4),
    CategoryTemplate(36, 30, 180, 10, 25, 1, ("纸质书", "电子书"),
                     ("Paperback", "E-book"),
                     tag_candidates=(T_JD, T_TAOBAO), tag_prob=0.6),
    # 日用品：盒马 / 山姆 / Costco / 日常
    CategoryTemplate(39, 20, 120, 8, 30, 3, ("洗护用品", "纸巾"),
                     ("Toiletries", "Paper towels"),
                     tag_candidates=(T_HEMA, T_SAMS, T_COSTCO, T_DAILY), tag_prob=0.7),
    CategoryTemplate(43, 8, 35, 5, 15, 2, ("快递费", ""),
                     ("Shipping", ""),
                     tag_candidates=(T_ONLINESHOP,), tag_prob=0.4),
]

# 收入模板：每月 1 笔工资 + 零星其它（默认不打标签）
# USD 区间按美国 mid-level 月薪 4500-7500、年终奖 500-2500、利息 2-30。
INCOME_TEMPLATES = [
    CategoryTemplate(0, 11000, 14500, 4500, 7500, 10, ("月薪", "工资到账"),
                     ("Monthly salary", "Paycheck")),
    CategoryTemplate(2, 50, 500, 20, 200, 3, ("微信红包", "群里抢的"),
                     ("Birthday gift", "Cash gift")),
    CategoryTemplate(3, 800, 4000, 500, 2500, 2, ("项目奖金", "季度奖"),
                     ("Project bonus", "Quarterly bonus")),
    CategoryTemplate(5, 200, 1500, 100, 500, 2, ("周末兼职", "稿费"),
                     ("Weekend gig", "Freelance fee")),
    CategoryTemplate(9, 100, 800, 50, 400, 2, ("理财收益", "基金分红"),
                     ("ETF dividend", "Fund return")),
    CategoryTemplate(7, 5, 80, 2, 30, 1, ("活期利息", ""),
                     ("Savings interest", "")),
]

# ---------- 时间分布 ----------

# 月份 -> 期望条数
MONTH_DENSITY = {1: 15, 2: 20, 3: 25, 4: 40}
LATEST_DATE = datetime(2026, 4, 29, 22, 0, 0)


def random_datetime_in_month(year: int, month: int, rng: random.Random,
                             max_day: int | None = None) -> datetime:
    """月内随机时间。max_day 用于限制 4 月不超过 29 日。"""
    if month == 12:
        next_month = datetime(year + 1, 1, 1)
    else:
        next_month = datetime(year, month + 1, 1)
    last_day = (next_month - timedelta(days=1)).day
    if max_day is not None:
        last_day = min(last_day, max_day)
    day = rng.randint(1, last_day)
    hour = rng.choice([7, 8, 9, 10, 12, 13, 14, 18, 19, 20, 21, 22])
    minute = rng.randint(0, 59)
    second = rng.randint(0, 59)
    return datetime(year, month, day, hour, minute, second)


# ---------- 生成逻辑 ----------

@dataclass
class LogicalEntry:
    """语言无关的逻辑条目。kind=expense/income，cat_idx 指向 EXPENSE_*/INCOME_*。"""
    dt: datetime
    kind: str
    cat_idx: int
    amount_cny: float  # 中文 CSV 用（CNY 区间）
    amount_usd: float  # 英文 CSV 用（USD 区间，按美国典型物价独立设计）
    note_idx: int  # -1 表示无备注；否则取模板 notes_*[note_idx]
    tag_indices: tuple[int, ...]  # 关联标签的 TAG_* 索引（可空）
    account_idx_zh: int  # 0..4 对应 ACCOUNT_ZH 索引（按 ACCOUNT_WEIGHTS_ZH 权重）
    account_idx_en: int  # 0..4 对应 ACCOUNT_EN 索引（按 ACCOUNT_WEIGHTS_EN 权重）


def pick_weighted(rng: random.Random, templates: list[CategoryTemplate]) -> CategoryTemplate:
    return rng.choices(templates, weights=[t.weight for t in templates], k=1)[0]


def pick_tags(rng: random.Random, tpl: CategoryTemplate) -> tuple[int, ...]:
    """按模板 tag_prob 决定要不要打标签；要打就从 candidates 抽 1 个，
    再小概率追加第 2 个（让多标签也有展示）。"""
    if not tpl.tag_candidates or rng.random() >= tpl.tag_prob:
        return ()
    cands = list(tpl.tag_candidates)
    first = rng.choice(cands)
    if len(cands) > 1 and rng.random() < 0.18:
        cands.remove(first)
        return (first, rng.choice(cands))
    return (first,)


def pick_account_random(rng: random.Random, weights: list[int]) -> int:
    """按指定权重加权随机选一个账户索引。"""
    return rng.choices(range(len(ACCOUNT_ZH)), weights=weights, k=1)[0]


def gen_amounts(rng: random.Random, tpl: CategoryTemplate) -> tuple[float, float]:
    """同一条交易在 zh/en 两份里数额独立采样（保留各自区间真实感）。
    返回 (cny, usd) 两个金额。"""
    cny = round(rng.uniform(tpl.amount_lo, tpl.amount_hi), 2)
    usd = round(rng.uniform(tpl.amount_lo_usd, tpl.amount_hi_usd), 2)
    return cny, usd


def generate_entries(rng: random.Random) -> list[LogicalEntry]:
    entries: list[LogicalEntry] = []

    # 账户分配规则：
    # - 工资 / 房租 / 投资收益 / 理财 / 利息 → 借记银行卡（A_ICBC，固定）
    # - 大额支出 → 信用卡（A_CMB）或借记银行（A_ICBC）
    # - 小额日常 → 按对应语言权重随机
    # zh 与 en 各按自己权重独立选账户（同一条交易在两份 CSV 里账户可不同，更真实）。
    SALARY_LIKE_INCOME_CATS = {0, 1, 7, 9}  # 工资 / 理财 / 利息 / 投资收益
    # 大额阈值按对应货币区间分别判断
    LARGE_THRESHOLD_CNY = 500.0
    LARGE_THRESHOLD_USD = 100.0

    def assign_account_idx(amt_cny: float, amt_usd: float, weights: list[int],
                           threshold: float, amt: float) -> int:
        if amt >= threshold:
            return rng.choices([A_CMB, A_ICBC], weights=[60, 40], k=1)[0]
        return pick_account_random(rng, weights)

    # 1) 每月 1 笔工资（4 笔），固定在 5-10 日
    salary_tpl = INCOME_TEMPLATES[0]
    for month in (1, 2, 3, 4):
        day = rng.randint(5, 10)
        if month == 4:
            day = min(day, 10)
        cny, usd = gen_amounts(rng, salary_tpl)
        entries.append(LogicalEntry(
            dt=datetime(2026, month, day, rng.randint(9, 11), rng.randint(0, 59), rng.randint(0, 59)),
            kind="income",
            cat_idx=salary_tpl.cat_idx,
            amount_cny=cny,
            amount_usd=usd,
            note_idx=0,  # "月薪" / "Paycheck"
            tag_indices=(),
            account_idx_zh=A_ICBC,
            account_idx_en=A_ICBC,
        ))

    # 2) 其它收入 ~6 笔
    other_income_count = 6
    for _ in range(other_income_count):
        tpl = pick_weighted(rng, INCOME_TEMPLATES[1:])
        month = rng.choices([1, 2, 3, 4], weights=[15, 20, 25, 40], k=1)[0]
        max_day = 29 if month == 4 else None
        dt = random_datetime_in_month(2026, month, rng, max_day=max_day)
        cny, usd = gen_amounts(rng, tpl)
        note_idx = rng.choice([-1, -1, 0, rng.randint(0, len(tpl.notes_zh) - 1)])
        if note_idx >= len(tpl.notes_zh):
            note_idx = -1
        # 利息 / 投资收益 / 理财 走银行卡；红包/兼职/奖金等走电子钱包
        if tpl.cat_idx in SALARY_LIKE_INCOME_CATS:
            acc_zh = acc_en = A_ICBC
        else:
            acc_zh = rng.choice([A_WECHAT, A_ALIPAY, A_ICBC])
            acc_en = rng.choice([A_WECHAT, A_ALIPAY, A_ICBC])
        entries.append(LogicalEntry(
            dt=dt, kind="income", cat_idx=tpl.cat_idx,
            amount_cny=cny, amount_usd=usd,
            note_idx=note_idx, tag_indices=(),
            account_idx_zh=acc_zh, account_idx_en=acc_en,
        ))

    # 3) 房租：每月 1 笔
    housing_tpl = next(t for t in EXPENSE_TEMPLATES if t.cat_idx == 8)
    for month in (1, 2, 3, 4):
        day = rng.randint(1, 5)
        cny, usd = gen_amounts(rng, housing_tpl)
        entries.append(LogicalEntry(
            dt=datetime(2026, month, day, rng.randint(9, 18), rng.randint(0, 59), rng.randint(0, 59)),
            kind="expense",
            cat_idx=housing_tpl.cat_idx,
            amount_cny=cny,
            amount_usd=usd,
            note_idx=0,  # "房租" / "Rent"
            tag_indices=(),
            account_idx_zh=A_ICBC,
            account_idx_en=A_ICBC,
        ))

    # 4) 其它支出，按月分布凑够 100 总数
    target_total = 100
    remaining = target_total - len(entries)
    expense_per_month = {1: 11, 2: 16, 3: 21, 4: 36}
    diff = remaining - sum(expense_per_month.values())
    expense_per_month[4] += diff

    other_expense_tpls = [t for t in EXPENSE_TEMPLATES if t.cat_idx != 8]
    for month, count in expense_per_month.items():
        max_day = 29 if month == 4 else None
        for _ in range(count):
            tpl = pick_weighted(rng, other_expense_tpls)
            dt = random_datetime_in_month(2026, month, rng, max_day=max_day)
            cny, usd = gen_amounts(rng, tpl)
            # ~30% 带备注
            if rng.random() < 0.30 and tpl.notes_zh:
                note_idx = rng.randint(0, len(tpl.notes_zh) - 1)
                if not tpl.notes_zh[note_idx]:
                    note_idx = -1
            else:
                note_idx = -1
            tag_indices = pick_tags(rng, tpl)
            acc_zh = assign_account_idx(cny, usd, ACCOUNT_WEIGHTS_ZH, LARGE_THRESHOLD_CNY, cny)
            acc_en = assign_account_idx(cny, usd, ACCOUNT_WEIGHTS_EN, LARGE_THRESHOLD_USD, usd)
            entries.append(LogicalEntry(
                dt=dt, kind="expense", cat_idx=tpl.cat_idx,
                amount_cny=cny, amount_usd=usd,
                note_idx=note_idx, tag_indices=tag_indices,
                account_idx_zh=acc_zh, account_idx_en=acc_en,
            ))

    entries.sort(key=lambda e: e.dt, reverse=True)
    return entries


# ---------- 输出 ----------

def write_csv(entries: list[LogicalEntry], path: Path, lang: str) -> None:
    if lang == "zh":
        header = ["日期", "类型", "金额", "分类", "备注", "标签", "账户"]
        kind_label = {"expense": "支出", "income": "收入"}
        expense_names = EXPENSE_ZH
        income_names = INCOME_ZH
        tag_names = TAG_ZH
        account_names = ACCOUNT_ZH
    else:
        header = ["Date", "Type", "Amount", "Category", "Note", "Tags", "Account"]
        kind_label = {"expense": "Expense", "income": "Income"}
        expense_names = EXPENSE_EN
        income_names = INCOME_EN
        tag_names = TAG_EN
        account_names = ACCOUNT_EN

    rows: list[list[str]] = [header]
    for e in entries:
        if e.kind == "expense":
            cat_name = expense_names[e.cat_idx]
            tpl = next(t for t in EXPENSE_TEMPLATES if t.cat_idx == e.cat_idx)
        else:
            cat_name = income_names[e.cat_idx]
            tpl = next(t for t in INCOME_TEMPLATES if t.cat_idx == e.cat_idx)

        if e.note_idx >= 0:
            notes = tpl.notes_zh if lang == "zh" else tpl.notes_en
            note = notes[e.note_idx] if e.note_idx < len(notes) else ""
        else:
            note = ""

        # 多标签用英文逗号分隔；CSV writer 会自动给含逗号的字段加引号
        tags_str = ",".join(tag_names[i] for i in e.tag_indices)

        amount = e.amount_cny if lang == "zh" else e.amount_usd
        account_idx = e.account_idx_zh if lang == "zh" else e.account_idx_en

        rows.append([
            e.dt.strftime("%Y-%m-%d %H:%M:%S"),
            kind_label[e.kind],
            f"{amount:.2f}",
            cat_name,
            note,
            tags_str,
            account_names[account_idx],
        ])

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows)
    print(f"  写入 {path}: {len(rows) - 1} 条")


def _build_setup_yaml(lang: str) -> str:
    """生成 SmartBook 配置导入用的完整 YAML（accounts + categories + tags）。

    格式与 lib/services/export/config_export_service.dart 的 toMap 输出一致：
      - 顶层 keys：version / exported_at / accounts / categories / tags
      - 每段下用 `items:` 包裹列表
      - 字段顺序参考 AccountItem.toMap / CategoryItem.toMap / TagItem.toMap
    """
    if lang == "zh":
        account_names = ACCOUNT_ZH
        expense_names = EXPENSE_ZH
        income_names = INCOME_ZH
        tag_names = TAG_ZH
        currency = CURRENCY_ZH
        comment_lang = "简体中文 / CNY"
    else:
        account_names = ACCOUNT_EN
        expense_names = EXPENSE_EN
        income_names = INCOME_EN
        tag_names = TAG_EN
        currency = CURRENCY_EN
        comment_lang = "English / USD"

    now_iso = datetime.now().isoformat()
    lines = [
        "# SmartBook 配置（商店截图测试用）",
        f"# 语言 / 货币：{comment_lang}",
        f"# 导出时间：{now_iso}",
        "",
        "version: 1",
        f'exported_at: "{now_iso}"',
        "",
        "# ----- 账户（5 个）-----",
        "accounts:",
        "  items:",
    ]
    for i, name in enumerate(account_names):
        lines.extend([
            f'    - name: "{name}"',
            f'      type: "{ACCOUNT_TYPES[i]}"',
            f'      currency: "{currency}"',
            f'      initial_balance: 0.0',
        ])

    lines.extend([
        "",
        "# ----- 分类（45 支出 + 14 收入，含 Material 图标）-----",
        "categories:",
        "  items:",
    ])
    for i, name in enumerate(expense_names):
        lines.extend([
            f'    - name: "{name}"',
            f'      kind: "expense"',
            f'      sort_order: {i}',
            f'      level: 1',
            f'      icon: "{EXPENSE_ICONS[i]}"',
            f'      icon_type: "material"',
        ])
    for i, name in enumerate(income_names):
        lines.extend([
            f'    - name: "{name}"',
            f'      kind: "income"',
            f'      sort_order: {i}',
            f'      level: 1',
            f'      icon: "{INCOME_ICONS[i]}"',
            f'      icon_type: "material"',
        ])

    lines.extend([
        "",
        "# ----- 标签（24 个，含 Material 调色板颜色）-----",
        "tags:",
        "  items:",
    ])
    for i, name in enumerate(tag_names):
        lines.extend([
            f'    - name: "{name}"',
            f'      color: "{TAG_COLORS[i]}"',
        ])

    return "\n".join(lines) + "\n"


def write_setup_yaml(path: Path, lang: str) -> None:
    """生成 SmartBook 配置 YAML。"""
    yaml_content = _build_setup_yaml(lang)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml_content, encoding="utf-8")
    print(f"  写入 {path}: 5 账户 + 59 分类 + 24 标签")


def main() -> None:
    rng = random.Random(20260429)
    entries = generate_entries(rng)
    assert len(entries) == 100, f"期望 100 条，实际 {len(entries)}"

    project_root = Path(__file__).resolve().parent.parent
    demo_dir = project_root / "demo"

    print(f"生成 {len(entries)} 条测试账本（共 {sum(1 for e in entries if e.kind == 'income')} 收入 / "
          f"{sum(1 for e in entries if e.kind == 'expense')} 支出）")
    write_csv(entries, demo_dir / "store_test_zh.csv", "zh")
    write_csv(entries, demo_dir / "store_test_en.csv", "en")

    print("生成配置 YAML（账户 + 分类 + 标签，含图标和颜色）")
    write_setup_yaml(demo_dir / "store_setup_zh.yaml", "zh")
    write_setup_yaml(demo_dir / "store_setup_en.yaml", "en")

    print()
    print("完成。导入流程：")
    print("  1. SmartBook 设置 → 配置导入 → 选 store_setup_<lang>.yaml")
    print("     (会创建 5 账户、59 分类带图标、24 彩色标签)")
    print("  2. SmartBook 设置 → 数据 → 导入 CSV → 选 store_test_<lang>.csv")
    print("     (按名匹配到第 1 步刚导入的账户/分类/标签)")
    print("  （切换系统语言后再做 en 那一套，账户/分类/标签自动按语言区分）")


if __name__ == "__main__":
    main()
