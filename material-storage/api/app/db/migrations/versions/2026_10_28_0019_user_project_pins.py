"""user_project_pins 用户置顶表 — 项目置顶(需求文档 2026-10-28 B1)

Revision ID: 20261028_0019
Revises: 20261027_0018
Create Date: 2026-10-28

新建 user_project_pins(user_id + project_id 复合主键,双 CASCADE;
created_at server_default now):用户私有项目置顶偏好,只增删无更新。
无额外索引(复合主键 (user_id, project_id) 已覆盖「按 user 查」前缀),
照 group_memberships 复合主键风格(0006)。

存量数据迁移:无(新表);降级 drop_table 即弃全部用户置顶偏好(纯偏好数据,可接受)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261028_0019"
down_revision: str | Sequence[str] | None = "20261027_0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_project_pins",
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("project_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("projects.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("user_id", "project_id"),
    )


def downgrade() -> None:
    op.drop_table("user_project_pins")
