"""百度备份多任务并发改造 — 并发方案 §2.2(baidu-backup-multi-task-concurrency-plan)

Revision ID: 20261019_0017
Revises: 20261010_0016
Create Date: 2026-10-19

四件事(§2.2,一个 migration,前后兼容;tables.py 模型元数据同批改 ——
test_db_schema 断言读模型元数据而非 DB 内省):
- DROP uq_baidu_task_active(binding_id WHERE active 的 UNIQUE)—— 解除「单绑定
  单活动任务」,否则第二个任务根本建不出来
- CREATE uq_baidu_task_running:UNIQUE(binding_id) WHERE status='running' —— 弱一级
  兜底,恰好护住最危险的「同绑定双下载循环」;枚举期互斥由准入层负责
- CREATE idx_baidu_task_active_binding:非唯一 partial (binding_id) WHERE active,
  供准入查询(现状 tasks 表上不存在任何按 binding_id 的非唯一索引)
- baidu_bindings 加 vip_type smallint NULL(§3.1 分道数据源;NULL=未知,按非会员
  处理,随 bind/重授权/任务创建/复活自然回填,不做批量回灌)

存量数据迁移:无(每绑定恰 1 条活动行,索引改型不动数据)。
回滚钉子(§5.4):downgrade 重建 uq_baidu_task_active —— 若存在「1 running +
多个 dormant」多活动行,建唯一索引直接失败。回滚顺序必须:先停 worker → 用
新代码逐任务取消清理多余活动行 → 回滚代码 → downgrade 前断言
`SELECT binding_id FROM baidu_backup_tasks WHERE status IN ('enumerating','running')
GROUP BY binding_id HAVING count(*)>1` 为空(迁移后旧创建兜底已失效,并发双建
仍可能产出双活动行,断言把住最后一道闸)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261019_0017"
down_revision: str | Sequence[str] | None = "20261010_0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # 1) 解除「单绑定单活动任务」(§2.2 第 1 条)
    op.drop_index("uq_baidu_task_active", table_name="baidu_backup_tasks")
    # 2) 弱一级兜底:running-only 唯一(§2.2 第 2 条)
    op.create_index(
        "uq_baidu_task_running", "baidu_backup_tasks", ["binding_id"],
        unique=True,
        postgresql_where=sa.text("status = 'running'"),
    )
    # 3) 准入查询非唯一 partial 索引(§2.2 第 3 条)
    op.create_index(
        "idx_baidu_task_active_binding", "baidu_backup_tasks", ["binding_id"],
        postgresql_where=sa.text("status IN ('enumerating','running')"),
    )
    # 4) vip_type 分道数据源(§2.2 第 4 条 / §3.1)
    op.add_column("baidu_bindings", sa.Column("vip_type", sa.SmallInteger()))


def downgrade() -> None:
    # 反向:删新索引 → 重建旧唯一索引 → drop vip_type 列(§5.4 回滚钉子见模块
    # docstring:重建唯一索引前必须清理同绑定多余活动行,否则直接失败)
    op.drop_index("idx_baidu_task_active_binding", table_name="baidu_backup_tasks")
    op.drop_index("uq_baidu_task_running", table_name="baidu_backup_tasks")
    op.create_index(
        "uq_baidu_task_active", "baidu_backup_tasks", ["binding_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('enumerating','running')"),
    )
    op.drop_column("baidu_bindings", "vip_type")
