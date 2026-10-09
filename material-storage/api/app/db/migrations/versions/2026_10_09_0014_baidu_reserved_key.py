"""百度导入 F2b 预定 key 列 — random-suffix 导入(需求文档 2026-10-09)

Revision ID: 20261009_0014
Revises: 20261008_0013
Create Date: 2026-10-09

baidu_backup_task_files 加列 reserved_key varchar(1024) NULL:
- 语义:F2b「随机后缀导入」的路由侧预定目标 key(NULL=未预定,走 canonical key);
- 不复用 minio_key —— 该列承担断点续传会话寻址语义(三元组直读),耦合易错;
- 行成功终态后 reserved_key 保留(历史可溯);无存量数据迁移要求(列可空)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261009_0014"
down_revision: str | Sequence[str] | None = "20261008_0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "baidu_backup_task_files",
        sa.Column("reserved_key", sa.String(1024), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("baidu_backup_task_files", "reserved_key")
