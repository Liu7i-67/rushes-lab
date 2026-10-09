"""百度集成测试专用 arq worker 入口(tests.test_baidu_integration._spawn_worker 用)。

与 app.workers.main.WorkerSettings 的差异只有一点:cron_jobs 为空 —— sweeper 由
pytest 进程内直呼(sweep_stalled_baidu_tasks),子进程 cron 会在 kill -9/SIGTERM
故障注入窗口内按 5min 节奏抢占派发/急停终态化,造成用例抖动。job 函数本身与
生产完全同源(baidu_backup_run,timeout=3600/max_tries=1)。
"""
from __future__ import annotations

from typing import ClassVar

from arq.connections import RedisSettings
from arq.worker import func

from app.workers.baidu_backup import baidu_backup_run
from app.workers.main import _build_redis_settings


class WorkerSettings:
    functions: ClassVar[list[object]] = [
        func(baidu_backup_run, timeout=3600, max_tries=1),
    ]
    cron_jobs: ClassVar[list[object]] = []
    redis_settings: ClassVar[RedisSettings] = _build_redis_settings()
    max_jobs: ClassVar[int] = 4
    job_timeout: ClassVar[int] = 60
    keep_result: ClassVar[int] = 300
