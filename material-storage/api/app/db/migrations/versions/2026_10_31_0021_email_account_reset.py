"""邮箱绑定/找回密码数据地基 — 邮箱归一化 + users 两新列 + 邮箱唯一索引 +
password_reset_tokens 表(迁移 0021,方案 §4 / docs/qdev 2026-11-04)。

Revision ID: 20261031_0021
Revises: 20261031_0020
Create Date: 2026-10-31

步骤(upgrade,§4.3):
  1) 归一化 UPDATE 两条:email 一律 lower(btrim(...))(单向,downgrade 不恢复
     原大小写/首尾空白;需对账的先 backup_prod.sh 或导出 id,email 留档);
  2) 重复/跨列冲突检测 —— **全部用 text() 显式 SQL,不 import User 模型**
     (代码同步后容器内已是新 ORM,任何 select(User) 都会 SELECT 新列撞旧
     schema,0020 同款失败面);有输出抛 RuntimeError,**只打印用户 id,
     不打印邮箱**(日志防 PII 泄露);
  3) ADD COLUMN 两条(email_verified_at NULL 不回填 / session_version 默认 0);
  4) 建 uq_users_email_lower 部分唯一索引(R9/D2:一个邮箱只属一个账号);
  5) 建 password_reset_tokens 表 + 索引(§4.2)。

★ 锁策略:users 表百级量,普通 ``CREATE UNIQUE INDEX`` 的 SHARE 锁毫秒级,
迁移按单事务执行即可(§4.3 说明);若未来用户量上万,照 0020 的
autocommit_block() + CREATE INDEX CONCURRENTLY 写法并处理失败留下的 INVALID
索引。归一化 UPDATE 与检测 SELECT 同理,不做表级并发优化。

迁移完成 → restart 之间的窗口内**暂停一切 email 写入**(旧代码不捕获
IntegrityError,撞新唯一索引会 500,见方案 §9.3 第 3 步)。

存量数据迁移:email_verified_at 不回填(D3:存量邮箱一律未验证);
session_version 全 0(存量 JWT 无 ver 按 0,迁移后不掉线,D6)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy import text
from sqlalchemy.dialects import postgresql

revision: str = "20261031_0021"
down_revision: str | Sequence[str] | None = "20261031_0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# btrim 口径与 §4.4 预检 #2 一致(PG E'' 转义串;Python 侧保留反斜杠字面量)
_TRIM = "E' \\t\\n\\r\\f\\v'"


def upgrade() -> None:
    # ─── 1) 归一化(单向;downgrade 不恢复)────────────────────────────────
    op.execute(
        text(
            f"UPDATE users SET email = lower(btrim(email, {_TRIM})) "
            "WHERE email IS NOT NULL"
        )
    )
    op.execute(text("UPDATE users SET email = NULL WHERE email = ''"))

    # ─── 2) 重复 / 跨列冲突检测(text(),不 import ORM;只报用户 id)────────
    bind = op.get_bind()
    dup_rows = bind.execute(
        text(
            "SELECT lower(email) AS le, array_agg(id::text) AS ids"
            " FROM users WHERE email IS NOT NULL"
            " GROUP BY 1 HAVING count(*) > 1"
        )
    ).fetchall()
    conflict_rows = bind.execute(
        text(
            "SELECT a.id AS a_id, b.id AS b_id FROM users a JOIN users b"
            f" ON lower(btrim(a.username, {_TRIM})) = lower(btrim(b.email, {_TRIM}))"
            " AND a.id <> b.id"
        )
    ).fetchall()
    if dup_rows or conflict_rows:
        dup_ids = [i for _le, ids in dup_rows for i in ids]
        conflict_ids = [i for a_id, b_id in conflict_rows for i in (a_id, b_id)]
        raise RuntimeError(
            "duplicate/conflicting emails, resolve before migration:"
            f" duplicate user_ids={dup_ids},"
            f" username_vs_email user_ids={conflict_ids}"
        )

    # ─── 3) users 两新列(ADD COLUMN 仅改 catalog,ACCESS EXCLUSIVE 极短)───
    op.add_column(
        "users", sa.Column("email_verified_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "users",
        sa.Column(
            "session_version", sa.Integer(), nullable=False,
            server_default="0",
        ),
    )

    # ─── 4) 邮箱唯一索引(R9/D2;users 百级,普通建索引即可,见 docstring)──
    op.create_index(
        "uq_users_email_lower",
        "users",
        [sa.text("lower(email)")],
        unique=True,
        postgresql_where=sa.text("email IS NOT NULL AND email <> ''"),
    )

    # ─── 5) password_reset_tokens(§4.2)────────────────────────────────────
    op.create_table(
        "password_reset_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        # 只存 SHA-256 hex(64 字符);明文 token 不落库(D8)
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True)),
        # 签发时 sha256(lower(email)) 快照;不复制完整邮箱(PII 最小化)
        sa.Column("email_hash", sa.String(64)),
        sa.Column("request_ip", sa.String(64)),
        # 写库前截断 [:512](与 audit_events.user_agent 同宽)
        sa.Column("user_agent", sa.String(512)),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("token_hash", name="uq_password_reset_tokens_token_hash"),
    )
    op.create_index(
        "ix_password_reset_tokens_user_id", "password_reset_tokens", ["user_id"],
    )
    op.create_index(
        "ix_password_reset_tokens_expires_at", "password_reset_tokens", ["expires_at"],
    )


def downgrade() -> None:
    # 归一化不恢复(单向);只删表/索引/两列。须先停 ms-api/ms-worker 再
    # downgrade(新代码读已删列会 500,方案 §9.4)。
    op.drop_index(
        "ix_password_reset_tokens_expires_at", table_name="password_reset_tokens",
    )
    op.drop_index(
        "ix_password_reset_tokens_user_id", table_name="password_reset_tokens",
    )
    op.drop_table("password_reset_tokens")
    op.drop_index("uq_users_email_lower", table_name="users")
    op.drop_column("users", "session_version")
    op.drop_column("users", "email_verified_at")
