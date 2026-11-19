"""user_prefs 用户级偏好表 — 设置页「默认收拢全部文件夹」(迁移 0023)

Revision ID: 20261119_0023
Revises: 20261118_0022
Create Date: 2026-11-19

需求:`docs/qdev/2026-11-19-settings-mcp-collapse-folders.md`(§5/§6/F10/F11)。
新建 user_prefs:user_id UUID PK FK→users.id ON DELETE CASCADE;prefs JSONB
NOT NULL DEFAULT '{}'::jsonb;updated_at TIMESTAMPTZ NOT NULL DEFAULT now()。
每 user 恰一行,Web/App 双端经 GET/PUT /api/v1/me/preferences 读写同一份
服务端偏好(无行用户隐式全默认 false,首写时应用侧 upsert 建行)。

存量数据迁移:无(全部用户隐式默认 false,首写才建行);降级 drop_table 即弃
全部用户偏好(纯偏好数据,可接受,照 0019「user_project_pins」写法)。
纯增量迁移:旧代码(0022 head)不认识新表,与新 schema 兼容共存。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261119_0023"
down_revision: str | Sequence[str] | None = "20261118_0022"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_prefs",
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("prefs", postgresql.JSONB(), nullable=False,
                  server_default=sa.text("'{}'::jsonb")),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("user_id"),
    )


def downgrade() -> None:
    op.drop_table("user_prefs")
