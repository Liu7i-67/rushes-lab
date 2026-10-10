"""项目逻辑删除两列 — 深隐藏+可恢复(需求文档 2026-10-10 F6/D1)

Revision ID: 20261010_0015
Revises: 20261009_0014
Create Date: 2026-10-10

projects 加列:
- deleted_at timestamptz NULL:非空 = 已删除,列表/详情一律过滤(含 system admin);
- deleted_by uuid NULL FK users.id ON DELETE SET NULL:记录操作人(user 删后置 NULL,
  审计另有 actor 快照);索引 ix_projects_deleted_at 供已删除列表排序/过滤。

存量数据迁移:无(全 NULL = 未删除);is_archived 行为不变。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261010_0015"
down_revision: str | Sequence[str] | None = "20261009_0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "projects",
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "projects",
        sa.Column("deleted_by", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "fk_projects_deleted_by_users",
        "projects", "users",
        ["deleted_by"], ["id"],
        ondelete="SET NULL",
    )
    op.create_index("ix_projects_deleted_at", "projects", ["deleted_at"])


def downgrade() -> None:
    op.drop_index("ix_projects_deleted_at", table_name="projects")
    op.drop_constraint("fk_projects_deleted_by_users", "projects", type_="foreignkey")
    op.drop_column("projects", "deleted_by")
    op.drop_column("projects", "deleted_at")
