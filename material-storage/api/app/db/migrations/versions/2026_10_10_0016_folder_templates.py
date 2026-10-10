"""目录模板两张表 — 方案 §2(2026-10-10 目录模板模块)

Revision ID: 20261010_0016
Revises: 20261010_0015
Create Date: 2026-10-10

- project_folder_templates:模板头(同 org 内 name 唯一 uq_pft_org_name,
  约束显式命名供 IntegrityError→409 按名匹配)
- project_folder_template_entries:模板条目(template 删除级联;
  (template_id, path) 唯一 uq_pft_entry_path;path 为目录相对路径字符串,
  如 `素材/视频/原始`,方案 §1-D1)

存量数据迁移:无(新表)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261010_0016"
down_revision: str | Sequence[str] | None = "20261010_0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ─── project_folder_templates:模板头 ──────────────────────────────────
    op.create_table(
        "project_folder_templates",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("organizations.id"), nullable=False),
        sa.Column("name", sa.String(128), nullable=False),
        sa.Column("description", sa.String(1024)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("organization_id", "name", name="uq_pft_org_name"),
    )

    # ─── project_folder_template_entries:模板条目 ─────────────────────────
    op.create_table(
        "project_folder_template_entries",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("template_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("project_folder_templates.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("path", sa.String(600), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("template_id", "path", name="uq_pft_entry_path"),
    )


def downgrade() -> None:
    op.drop_table("project_folder_template_entries")
    op.drop_table("project_folder_templates")
