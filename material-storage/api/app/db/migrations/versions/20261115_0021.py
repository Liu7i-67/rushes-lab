"""用户模块组级授权 — users.created_by + 存量回填 + user_create_grants(迁移 0021)

Revision ID: 20261115_0021
Revises: 20261031_0020
Create Date: 2026-11-15

需求:`docs/qdev/2026-11-15-user-delegation.md`(§4 数据库修改方案)。
纯增量迁移:新列全 NULL、新表独立 —— 旧代码(0020 head)与新 schema 兼容共存
(回滚流程基石:先回滚代码,DB 无须 downgrade)。

1) users.created_by(UUID NULL FK users.id ON DELETE SET NULL,照 0015
   deleted_by 惯例显式命名 fk_users_created_by_users):账号创建人;列先加 →
   存量回填 → 后挂 FK(回填行与 FK 互不影响,顺序只为读迁移日志顺手)。
2) 存量回填(方案 D7,audit user_created 的 actor 是创建人唯一可靠来源):
   每个用户取其 user_created 审计事件**最新一条**(event_time DESC)的
   actor_user_id 写入 created_by,仅填 NULL 行。details->>'user_id' 是 JSONB
   文本,历史脏数据可能非 UUID(早期事件格式漂移),故 ~ 正则防护后再 ::uuid,
   防非法文本让整条 UPDATE 500。无任何 user_created 来源的行保持 NULL
   (前端显示「—」)。
3) 新表 user_create_grants(组对组授权关系,方案 D2 不进 FGA):复合主键
   (group_id, target_group_id) 天然防重,双 FK ON DELETE CASCADE —— 授权组 /
   目标组任一删除即级联清授权行(F13 不孤儿);created_at server_default。
   语义:(B, T) 行 = B 组成员拥有用户模块访问权,且新建用户时可把用户加入
   T 组;授权态 = B 存在 ≥1 行(无独立 bool 开关,方案 D1)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261115_0021"
down_revision: str | Sequence[str] | None = "20261031_0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# 存量回填 SQL(见模块 docstring 2)):DISTINCT ON + event_time DESC 取每用户
# 最新一条;正则防非法 uuid 文本进 ::uuid;仅填 created_by IS NULL 行
_BACKFILL_CREATED_BY_SQL = """
UPDATE users AS u
SET created_by = latest.actor_user_id
FROM (
    SELECT DISTINCT ON (details->>'user_id')
        (details->>'user_id')::uuid AS target_user_id,
        actor_user_id
    FROM audit_events
    WHERE event_type = 'user_created'
      AND actor_user_id IS NOT NULL
      AND details->>'user_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ORDER BY details->>'user_id', event_time DESC
) AS latest
WHERE u.id = latest.target_user_id
  AND u.created_by IS NULL
"""


def upgrade() -> None:
    # ─── users.created_by(F1:账号创建人)──────────────────────────────────
    op.add_column(
        "users", sa.Column("created_by", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.execute(_BACKFILL_CREATED_BY_SQL)
    # FK 后挂(0015 deleted_by 同款显式命名);自引用 users.id,创建人被删 SET NULL
    op.create_foreign_key(
        "fk_users_created_by_users",
        "users", "users",
        ["created_by"], ["id"],
        ondelete="SET NULL",
    )

    # ─── user_create_grants(组对组授权,D2)────────────────────────────────
    op.create_table(
        "user_create_grants",
        sa.Column("group_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("target_group_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True),
            server_default=sa.func.now(), nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["group_id"], ["groups.id"],
            ondelete="CASCADE", name="fk_user_create_grants_group_id_groups",
        ),
        sa.ForeignKeyConstraint(
            ["target_group_id"], ["groups.id"],
            ondelete="CASCADE", name="fk_user_create_grants_target_group_id_groups",
        ),
    )


def downgrade() -> None:
    op.drop_table("user_create_grants")
    op.drop_constraint("fk_users_created_by_users", "users", type_="foreignkey")
    op.drop_column("users", "created_by")
