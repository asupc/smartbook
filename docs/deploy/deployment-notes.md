# 部署须知(deployment notes)

随版本累积的部署约束与已知行为限制。反向代理 / TLS 配置见同目录
`reverse-proxy.md`。

## 单 worker 约定(内置限流为进程内状态)

以下机制的状态只存在于**单个进程内**,多 worker(`uvicorn --workers N`、
gunicorn 多进程、k8s 多副本)部署时会按 worker 数放大限额,且每个 worker
独立计数:

| 机制 | 位置 | 上限 |
|---|---|---|
| `/api/v1/ai/relay/*` 限流 | `src/routers/ai/relay.py` `_RATE_WINDOWS` | 单 user 60 次 / 60s |
| 同 (user, provider) LLM 并发闸 | `src/routers/ai/relay.py` `_PROVIDER_SEMS` | 服务商配置的「并发数」 |
| auth 限流(login/register 等) | `src/routers/auth.py` `_rate_limit_buckets` | `RATE_LIMIT_MAX_REQUESTS` / `RATE_LIMIT_WINDOW_SECONDS` |

**部署约定:SmartBook-Cloud 以单 worker 运行**(`docker-compose.yml` 的
`uvicorn` 默认即单 worker)。这不是性能约束 —— 服务端 DB 密集路径已用
threadpool / `asyncio.to_thread` 并发,单 worker + 异步 I/O 足以支撑个人/
家庭规模;真正需要横向扩展时,应先把上述限流状态迁到 DB / Redis。

字典膨胀已做防护(窗口滑空删 key、闲置信号量定期清理),但**跨 worker
不共享计数**这一点只能靠部署约定保证。

## 已知行为限制

- **SQLite batch downgrade 与表达式索引(已知限制)**:SQLite 上带
  `batch_alter_table` 的 downgrade 通过「反射重建表」实现,alembic 对表达式
  索引(如 `coalesce(created_at, happened_at) DESC`)的反射保留是尽力而为,
  不构成框架级保证。当前迁移链的 head→base→head 往返实测通过(索引数
  一致,0029 的 drop 已加 `if_exists` 防御),但**生产部署约定只升不降**;
  如确需回滚多步,回滚后应对照 `models.py` 的 Index 定义核对该表索引是否
  齐全,缺失的热索引在对应迁移的 upgrade 里手工重建。
- **净值历史按当前汇率重放**:`GET /read/workspace/net-worth-history` 的历史
  各月净值是用**查询时刻**的汇率(自动缓存 + 用户 override)把外币账户
  余额折算到主币种后重放的,不回放历史时点汇率。多币种用户的历史净值曲线
  会随当日汇率整体漂移(例如美元账户占比较高时,人民币净值随 USD/CNY
  波动)。这与交易级统计(`native_amount` 落库快照,按记账时汇率)口径
  不同,是已知的简化;如需历史时点汇率需要新增汇率历史存储,当前无计划。
