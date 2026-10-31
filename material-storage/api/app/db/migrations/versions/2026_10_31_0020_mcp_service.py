"""MCP 素材服务数据地基 — PAT 表 + audit_events 认证列 + system_flags(迁移 0020)

Revision ID: 20261031_0020
Revises: 20261028_0019
Create Date: 2026-10-31

需求:`docs/qdev/2026-10-30-mcp-service.md`(数据库修改节 / D2-D4 / D13)。
纯增量迁移:audit_events 两列均 nullable、新表独立 —— 旧代码(0019 head)与新
schema 兼容共存(回滚流程基石:先 rsync 回旧代码,DB 无须 downgrade)。

审计事件的认证列 `auth_token_id` 指向 personal_access_tokens,ondelete=SET NULL
(照仓库审计惯例 tables.py:256/263:不能 CASCADE 否则删用户连带删审计行,
不能 RESTRICT 否则删用户直接失败)。"删用户 → CASCADE 删 token → 逐条 SET NULL
扫 audit_events" 会全表扫描,故首版就建索引。

★ 锁级别(prod 第 3 步是旧代码在线时 upgrade,普通 DDL 会阻塞全站 audit 写入):
  1) op.add_column(nullable, 无 default) = 仅改 catalog,ACCESS EXCLUSIVE 极短;
  2) FK 必须写成 `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID`:
     普通 ADD CONSTRAINT 默认做全表校验,持 SHARE ROW EXCLUSIVE(阻塞写、不阻塞读)
     直到校验完成 —— 会把全站 audit.write 阻塞,比 0019 事故面更大;NOT VALID
     跳过初始全表校验,只在极短窗口持锁。**不做 VALIDATE**:如确需强校验,另起
     迁移做 `VALIDATE CONSTRAINT`(SHARE UPDATE EXCLUSIVE,不阻塞写);
  3) ix_audit_auth_token_id 用 `op.get_context().autocommit_block()` +
     `CREATE INDEX CONCURRENTLY`:普通 CREATE INDEX 持 SHARE 锁会阻塞全站
     audit.write。★ CONCURRENTLY 失败会留 INVALID 索引(且本迁移不回滚该
     INVALID 索引),处置:先 `DROP INDEX CONCURRENTLY ix_audit_auth_token_id`
     再重跑 `alembic upgrade head`(不能原地重试,同名索引会已存在报错)。
     注意 autocommit_block 会先提交本迁移之前的 DDL(Alembic 文档语义):若
     失败点在索引,`alembic current` 仍是 0019,重跑前需先手工清掉已提交的
     半成品(按下方 downgrade 顺序回退后重跑,或补建索引后 `alembic stamp
     20261031_0020`)—— 不要盲目 stamp。

system_flags(DB 为正本,MCP 通道配置 `mcp_channel`):迁移内**幂等 seed**
默认行 `{"enabled": false, "max_concurrency": 8, "per_token_concurrency": 4,
"per_token_rpm": 120, "per_ip_rpm": 600}`(ON CONFLICT DO NOTHING,对齐 D6
"seed 必须能通过 PUT 校验器")。**downgrade→再 upgrade 会回落到默认行**
(管理员已调配额丢失,纯新功能期可接受,对齐 0019「纯偏好数据」写法)。

存量数据迁移:无(新表 + 两列 NULL,存量审计行一律视为 session)。
"""
import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261031_0020"
down_revision: str | Sequence[str] | None = "20261028_0019"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# 迁移内自带默认值(不 import app.services.mcp_settings:迁移必须对后续代码
# 改动免疫;两侧一致性由 tests/test_mcp_settings.py 的默认值断言兜住)
_DEFAULT_MCP_FLAG: dict[str, bool | int] = {
    "enabled": False,
    "max_concurrency": 8,
    "per_token_concurrency": 4,
    "per_token_rpm": 120,
    "per_ip_rpm": 600,
}


def upgrade() -> None:
    # ─── personal_access_tokens(MCP 个人访问令牌,D2/D3)──────────────────
    op.create_table(
        "personal_access_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(128), nullable=False),
        # 明文只存 SHA-256 hex(64 字符);token_prefix = 明文前 16 字符(列表识别)
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("token_prefix", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True)),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("token_hash", name="uq_pat_token_hash"),
    )
    op.create_index(
        "ix_personal_access_tokens_user_id", "personal_access_tokens", ["user_id"],
    )

    # ─── system_flags(DB 为正本的配置 KV;mcp_channel 默认行)────────────
    op.create_table(
        "system_flags",
        sa.Column("key", sa.String(64), primary_key=True),
        sa.Column("value", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
    )
    op.execute(
        sa.text(
            "INSERT INTO system_flags (key, value)"
            " VALUES (:key, CAST(:value AS jsonb))"
            " ON CONFLICT (key) DO NOTHING"
        ).bindparams(
            key="mcp_channel",
            value=json.dumps(_DEFAULT_MCP_FLAG),
        )
    )

    # ─── audit_events 认证列(D4)──────────────────────────────────────────
    op.add_column("audit_events", sa.Column("auth_method", sa.String(16), nullable=True))
    op.add_column(
        "audit_events",
        sa.Column("auth_token_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    # NOT VALID:跳过全表校验,避免普通 ADD CONSTRAINT 的长锁阻塞 audit.write(见 docstring)
    op.execute(
        "ALTER TABLE audit_events"
        " ADD CONSTRAINT fk_audit_events_auth_token_id"
        " FOREIGN KEY (auth_token_id)"
        " REFERENCES personal_access_tokens (id)"
        " ON DELETE SET NULL"
        " NOT VALID"
    )
    # CONCURRENTLY:不阻塞 audit 写入;失败留 INVALID 索引的处置见 docstring
    with op.get_context().autocommit_block():
        op.execute(
            "CREATE INDEX CONCURRENTLY ix_audit_auth_token_id"
            " ON audit_events (auth_token_id)"
        )


def downgrade() -> None:
    # 先并发删索引(autocommit block),再删约束/列/表
    with op.get_context().autocommit_block():
        op.execute("DROP INDEX CONCURRENTLY IF EXISTS ix_audit_auth_token_id")
    op.execute(
        "ALTER TABLE audit_events"
        " DROP CONSTRAINT IF EXISTS fk_audit_events_auth_token_id"
    )
    op.drop_column("audit_events", "auth_token_id")
    op.drop_column("audit_events", "auth_method")
    op.drop_table("system_flags")
    op.drop_index("ix_personal_access_tokens_user_id", table_name="personal_access_tokens")
    op.drop_table("personal_access_tokens")
