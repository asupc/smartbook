"""P1-B3 —— main.py 的 AI outbox worker 接线单测。

`_start/_stop_ai_log_outbox_worker_task` —— 开关关时不建任务,开时先恢复
lease 再起 worker,stop_event 优雅关停且幂等。

(原 P1-A4/A5 的 retention 循环已随「用户数据永久保留」改造删除,本文件
仅保留 outbox 接线部分。)

startup/shutdown 的 on_event 集成测试不可行(TestClient 不带 with 上下文不触发
lifespan,带 with 会连带起 backup scheduler / MCP session manager 等全部
startup 副作用),故直接单测接线 helper 本体 —— 注册的 on_event handler 只是
透传调用它们。
"""
from __future__ import annotations

import asyncio

from src import main

# ─────────────────────── P1-B3: outbox worker 接线 ───────────────────────


def test_outbox_wiring_disabled_creates_no_task(monkeypatch):
    async def scenario():
        monkeypatch.setattr(main.settings, "ai_log_outbox_enabled", False)
        await main._start_ai_log_outbox_worker_task(main.app)
        assert getattr(main.app.state, "ai_log_outbox_task", None) is None

    asyncio.run(scenario())


def test_outbox_wiring_start_recovers_leases_and_stops_clean(monkeypatch):
    from src.services.ai import analysis_log_worker

    calls = {"recover": 0, "worker": 0}
    stop_events = []

    def fake_recover():
        calls["recover"] += 1

    async def fake_worker(stop_event):
        calls["worker"] += 1
        stop_events.append(stop_event)
        await stop_event.wait()

    monkeypatch.setattr(main.settings, "ai_log_outbox_enabled", True)
    monkeypatch.setattr(analysis_log_worker, "recover_stale_leases", fake_recover)
    monkeypatch.setattr(analysis_log_worker, "run_worker_forever", fake_worker)

    async def scenario():
        await main._start_ai_log_outbox_worker_task(main.app)
        # create_task 只调度不执行,让一步 loop 使 worker 协程真正进入
        await asyncio.sleep(0)
        assert calls == {"recover": 1, "worker": 1}
        task = main.app.state.ai_log_outbox_task
        assert not task.done()
        # stop:置位 stop_event,worker 协程返回,task 完成;重复 stop 幂等
        await main._stop_ai_log_outbox_worker_task(main.app)
        assert task.done()
        assert stop_events[0].is_set()
        await main._stop_ai_log_outbox_worker_task(main.app)

    try:
        asyncio.run(scenario())
    finally:
        # 单例 app 上的 state 不泄漏给后续测试
        for attr in ("ai_log_outbox_task", "ai_log_outbox_stop"):
            if hasattr(main.app.state, attr):
                delattr(main.app.state, attr)
