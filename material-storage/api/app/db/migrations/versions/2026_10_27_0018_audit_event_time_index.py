"""audit_events 加 event_time 单列索引 — 使用统计(需求文档 2026-10-27 F4)

Revision ID: 20261027_0018
Revises: 20261019_0017
Create Date: 2026-10-27

audit_events 加 ix_audit_event_time(event_time 单列 btree):使用统计按纯
event_time 窗口过滤/日分桶,既有复合索引(ix_audit_event_type_time /
ix_audit_actor_time)前导列都不是 event_time,时间窗口扫描走不到索引。
不用 CONCURRENTLY,沿 0017 惯例。tables.py 模型元数据同批改 ——
test_db_schema 断言读模型元数据而非 DB 内省。

存量数据迁移:无(纯索引,不动数据)。
"""
from collections.abc import Sequence

from alembic import op

revision: str = "20261027_0018"
down_revision: str | Sequence[str] | None = "20261019_0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index("ix_audit_event_time", "audit_events", ["event_time"])


def downgrade() -> None:
    op.drop_index("ix_audit_event_time", table_name="audit_events")
