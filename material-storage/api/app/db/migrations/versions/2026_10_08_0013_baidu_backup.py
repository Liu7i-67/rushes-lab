"""百度网盘备份三张表 — 方案 §4(批次 1 后端基建)

Revision ID: 20261008_0013
Revises: 20260930_0012
Create Date: 2026-10-08

一次建三表(方案 §10:批次分层是功能分层,非迁移拆分):
- baidu_bindings:每 user 一条绑定(token 双列 Fernet 密文;baidu_uid NOT NULL
  防 NULL==NULL 误判换绑;status 软解绑语义)
- baidu_backup_tasks:任务(租约/接力/轮起点/计数/取消语义全套列;
  partial unique index uq_baidu_task_active 保证同绑定至多一个活动中任务)
- baidu_backup_task_files:manifest(断点三元组;UNIQUE(task_id, rel_path))

FK ondelete 对齐方案 §4:task_files.task_id→CASCADE、task_files.asset_id→SET NULL、
task_files.target_folder_id→SET NULL、tasks.user_id→RESTRICT(并建索引)、
tasks.binding_id→RESTRICT、tasks.project_id→RESTRICT、tasks.target_folder_id→
nullable+SET NULL(目标夹被删后置空,明细展示「(已删除)」)。

存量数据迁移:无(新表)。回滚:三表独立可一级回退(方案 §11 —— 须在
BAIDU_BACKUP_ENABLED=false 且 sweeper 终态化完成之后执行 downgrade)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261008_0013"
down_revision: str | Sequence[str] | None = "20260930_0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ─── baidu_bindings:每 user 一条绑定 ──────────────────────────────────
    op.create_table(
        "baidu_bindings",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("access_token_enc", sa.Text(), nullable=False),
        sa.Column("refresh_token_enc", sa.Text(), nullable=False),
        sa.Column("baidu_uid", sa.String(32), nullable=False),
        sa.Column("nickname", sa.String(128)),
        sa.Column("access_token_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(16), server_default="active", nullable=False),
        sa.Column("last_authorized_at", sa.DateTime(timezone=True)),
        sa.Column("token_rotated_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_id", name="uq_baidu_binding_user"),
    )

    # ─── baidu_backup_tasks:任务 ──────────────────────────────────────────
    op.create_table(
        "baidu_backup_tasks",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("binding_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("baidu_bindings.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("bound_baidu_uid", sa.String(32)),   # 创建时从 binding 快照(换绑甄别)
        sa.Column("source_dir", sa.String(1024), nullable=False),
        sa.Column("project_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("projects.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("target_folder_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("folders.id", ondelete="SET NULL")),
        sa.Column("target_auto_created", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("status", sa.String(16), server_default="enumerating", nullable=False),
        sa.Column("cancel_requested", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("cancel_reason", sa.String(64)),
        sa.Column("retry_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("enum_done", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("total_files", sa.Integer()),
        sa.Column("done_files", sa.Integer()),
        sa.Column("failed_files", sa.Integer()),
        sa.Column("skipped_files", sa.Integer()),
        sa.Column("cancelled_files", sa.Integer()),
        sa.Column("total_bytes", sa.BigInteger()),
        sa.Column("done_bytes", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("speed_bps", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("speed_anchor_bytes", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("speed_anchor_at", sa.DateTime(timezone=True)),
        sa.Column("runner_id", sa.String(64)),
        sa.Column("lease_until", sa.DateTime(timezone=True)),
        sa.Column("lease_seq", sa.Integer(), server_default="0", nullable=False),
        sa.Column("dispatched_at", sa.DateTime(timezone=True)),
        sa.Column("round_started_at", sa.DateTime(timezone=True)),
        sa.Column("fail_reason", sa.String(512)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    # user_id FK 建索引(方案 §4);status 索引供 sweeper/列表扫描
    op.create_index("ix_baidu_backup_tasks_user_id", "baidu_backup_tasks", ["user_id"])
    op.create_index("ix_baidu_backup_tasks_status", "baidu_backup_tasks", ["status"])
    # 同绑定同时最多一个活动中任务(应用层检查之外的硬兜底,撞唯一约束统一转 409)
    op.create_index(
        "uq_baidu_task_active", "baidu_backup_tasks", ["binding_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('enumerating','running')"),
    )

    # ─── baidu_backup_task_files:manifest ─────────────────────────────────
    op.create_table(
        "baidu_backup_task_files",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("task_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("baidu_backup_tasks.id", ondelete="CASCADE"), nullable=False),
        sa.Column("fs_id", sa.BigInteger(), nullable=False),
        sa.Column("source_path", sa.Text(), nullable=False),   # 仅展示用,不进索引
        sa.Column("source_size", sa.BigInteger(), nullable=False),
        sa.Column("rel_path", sa.String(1024), nullable=False),
        sa.Column("target_folder_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("folders.id", ondelete="SET NULL")),
        sa.Column("asset_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("assets.id", ondelete="SET NULL")),
        sa.Column("status", sa.String(16), server_default="pending", nullable=False),
        sa.Column("overwrite", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("bytes_done", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("minio_upload_id", sa.Text()),   # 方案 VARCHAR 不定长 → Text(PG 语义等价)
        sa.Column("minio_bucket", sa.String(63)),
        sa.Column("minio_key", sa.String(1024)),
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        sa.Column("last_error", sa.String(512)),
        sa.Column("non_retryable", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("dlink", sa.Text()),
        sa.Column("dlink_fetched_at", sa.DateTime(timezone=True)),
        sa.Column("dlink_expires_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("task_id", "rel_path", name="uq_baidu_task_file_relpath"),
    )
    op.create_index("ix_baidu_backup_task_files_task_id", "baidu_backup_task_files", ["task_id"])
    op.create_index("ix_baidu_backup_task_files_status", "baidu_backup_task_files", ["status"])


def downgrade() -> None:
    op.drop_index("ix_baidu_backup_task_files_status", table_name="baidu_backup_task_files")
    op.drop_index("ix_baidu_backup_task_files_task_id", table_name="baidu_backup_task_files")
    op.drop_table("baidu_backup_task_files")
    op.drop_index("uq_baidu_task_active", table_name="baidu_backup_tasks")
    op.drop_index("ix_baidu_backup_tasks_status", table_name="baidu_backup_tasks")
    op.drop_index("ix_baidu_backup_tasks_user_id", table_name="baidu_backup_tasks")
    op.drop_table("baidu_backup_tasks")
    op.drop_table("baidu_bindings")
