"""百度备份会员同绑定多路并发 — 删 running 唯一 belt 索引(迁移 0022)

Revision ID: 20261118_0022
Revises: 20261118_0021
Create Date: 2026-11-18

需求:`docs/qdev/2026-11-18-baidu-vip-parallel-backup.md`(§3.2/C0)。
DROP uq_baidu_task_running(UNIQUE(binding_id) WHERE status='running',0017 建):
partial 唯一谓词只能引用本表行内列,无法表达「非会员绑定才限 1」(vip_type 在
baidu_bindings 表),保留即把会员钉死 1 路。同绑定 running 数上限的防线移交
参数化准入门控(admission_top_task_ids:会员道 rn ≤ vip_par / 非会员道 rn ≤ 1;
回滚杆 env BAIDU_VIP_PARALLEL_PER_BINDING=1)。
仅删索引,无数据变更,秒级完成。

回滚语义:downgrade 原样重建该索引(定义照抄 0017 upgrade,逐字一致)。
前置条件(runbook):库中存在同绑定多条 running 时重建唯一索引直接失败 ——
先拉回滚杆 env=1 或等任务排空,确保每绑定 ≤1 running 再 downgrade;
否则先终态化多余 running 行。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261118_0022"
down_revision: str | Sequence[str] | None = "20261118_0021"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # belt 索引退役(§3.2;会员多路并发下同绑定 running 上限由准入门控负责)
    op.drop_index("uq_baidu_task_running", table_name="baidu_backup_tasks")


def downgrade() -> None:
    # 定义照抄 2026_10_19_0017 upgrade 原文(可逆;重建前置条件见模块 docstring
    # runbook:每绑定 ≤1 running 才能建唯一索引)
    op.create_index(
        "uq_baidu_task_running", "baidu_backup_tasks", ["binding_id"],
        unique=True,
        postgresql_where=sa.text("status = 'running'"),
    )
