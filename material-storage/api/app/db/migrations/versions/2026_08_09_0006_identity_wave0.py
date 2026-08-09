"""identity wave0 地基 — ADR-0007(issue #148)

Revision ID: 20260809_0006
Revises: 20260518_0005
Create Date: 2026-08-09

- users.password_hash / must_change_password:本地账号密码登录地基(P1 #149 使用)
- 新表 groups / group_memberships:本地用户组(OpenFGA group subject 从飞书 gid
  迁到本地 groups.id UUID,存量 tuple 由 scripts/migrate_subjects_to_uuid.py 重写)
- 新表 notifications:应用内通知(弃飞书后的最小通知通道)
- assets.user_labels ARRAY + GIN;assets.filename pg_trgm GIN(标签 + 盲搜发现 UX 地基)
- request_link_tokens.receiver_open_id → receiver_user_id(users.id FK 语义;
  OpenFGA subject 切换 open_id → users.id UUID 的 DB 侧配套)
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260809_0006"
down_revision: str | Sequence[str] | None = "20260518_0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ─── users:本地密码登录地基 ────────────────────────────────────────────
    op.add_column("users", sa.Column("password_hash", sa.String(255)))
    op.add_column(
        "users",
        sa.Column(
            "must_change_password", sa.Boolean,
            server_default=sa.true(), nullable=False,
        ),
    )

    # ─── groups / group_memberships:本地用户组 ────────────────────────────
    op.create_table(
        "groups",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("name", sa.String(128), unique=True, nullable=False),
        sa.Column("description", sa.String(1024)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    op.create_table(
        "group_memberships",
        sa.Column("group_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("groups.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("group_id", "user_id"),
    )

    # ─── notifications:应用内通知 ─────────────────────────────────────────
    op.create_table(
        "notifications",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("body", sa.String(2000)),
        sa.Column("link", sa.String(1024)),
        sa.Column("read_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_notifications_user_id", "notifications", ["user_id"])

    # ─── assets:用户标签 + 盲搜索引 ───────────────────────────────────────
    op.add_column(
        "assets",
        sa.Column(
            "user_labels", sa.ARRAY(sa.String(64)),
            server_default=sa.text("'{}'"), nullable=False,
        ),
    )
    op.create_index(
        "ix_asset_user_labels", "assets", ["user_labels"],
        postgresql_using="gin",
    )
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    # 已有的 btree ix_asset_filename 保留(精确/排序用);trgm 用于模糊盲搜
    op.create_index(
        "ix_asset_filename_trgm", "assets", ["filename"],
        postgresql_using="gin",
        postgresql_ops={"filename": "gin_trgm_ops"},
    )

    # ─── request_link_tokens:receiver open_id → users.id ──────────────────
    op.add_column(
        "request_link_tokens",
        sa.Column("receiver_user_id", postgresql.UUID(as_uuid=True)),
    )
    op.execute(
        "UPDATE request_link_tokens r SET receiver_user_id = u.id "
        "FROM users u "
        "WHERE r.receiver_open_id IS NOT NULL "
        "AND u.feishu_open_id = r.receiver_open_id"
    )
    op.drop_column("request_link_tokens", "receiver_open_id")


def downgrade() -> None:
    # request_link_tokens 反向(回填不到的 receiver 留 NULL,可接受)
    op.add_column(
        "request_link_tokens",
        sa.Column("receiver_open_id", sa.String(64)),
    )
    op.execute(
        "UPDATE request_link_tokens r SET receiver_open_id = u.feishu_open_id "
        "FROM users u "
        "WHERE r.receiver_user_id IS NOT NULL "
        "AND u.id = r.receiver_user_id"
    )
    op.drop_column("request_link_tokens", "receiver_user_id")

    op.drop_index("ix_asset_filename_trgm", table_name="assets")
    op.drop_index("ix_asset_user_labels", table_name="assets")
    op.drop_column("assets", "user_labels")

    op.drop_index("ix_notifications_user_id", table_name="notifications")
    op.drop_table("notifications")
    op.drop_table("group_memberships")
    op.drop_table("groups")

    op.drop_column("users", "must_change_password")
    op.drop_column("users", "password_hash")
