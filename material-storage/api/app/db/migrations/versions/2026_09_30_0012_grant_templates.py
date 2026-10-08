"""项目权限模板两张表 — 方案 §4.1(批次三 C-Step2)

Revision ID: 20260930_0012
Revises: 20260809_0011
Create Date: 2026-09-30

- project_grant_templates:模板头(同 org 内 name 唯一 uq_pgt_org_name;
  partial unique index uq_pgt_default_per_org 保证每 org 至多 1 个 is_default
  —— 全库首例 partial index,ORM 侧声明见 tables.py,alembic 侧显式落)
- project_grant_template_items:模板条目(template 删除级联;roles JSONB;
  (template_id, subject_kind, subject_id) 唯一)

存量数据迁移:无(新表)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260930_0012"
down_revision: str | Sequence[str] | None = "20260809_0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ─── project_grant_templates:模板头 ───────────────────────────────────
    op.create_table(
        "project_grant_templates",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("organizations.id"), nullable=False),
        sa.Column("name", sa.String(128), nullable=False),
        sa.Column("description", sa.String(1024)),
        sa.Column("is_default", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("organization_id", "name", name="uq_pgt_org_name"),
    )
    # 每 org 至多 1 个 default(partial unique index)
    op.create_index(
        "uq_pgt_default_per_org", "project_grant_templates", ["organization_id"],
        unique=True, postgresql_where=sa.text("is_default"),
    )

    # ─── project_grant_template_items:模板条目 ────────────────────────────
    op.create_table(
        "project_grant_template_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("template_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("project_grant_templates.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("subject_kind", sa.String(8), nullable=False),
        sa.Column("subject_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("roles", postgresql.JSONB, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint(
            "template_id", "subject_kind", "subject_id", name="uq_pgt_item_subject",
        ),
    )


def downgrade() -> None:
    op.drop_table("project_grant_template_items")
    op.drop_index("uq_pgt_default_per_org", table_name="project_grant_templates")
    op.drop_table("project_grant_templates")
