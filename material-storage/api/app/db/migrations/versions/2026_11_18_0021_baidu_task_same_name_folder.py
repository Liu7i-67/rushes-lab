"""百度备份任务【创建同名文件夹】开关 — baidu_backup_tasks 加列(迁移 0021)

Revision ID: 20261118_0021
Revises: 20261115_0021
Create Date: 2026-11-18

需求:`docs/qdev/2026-11-18-baidu-backup-same-name-folder.md`(§6 数据库修改方案 / F12)。
`create_same_name_folder` boolean NOT NULL DEFAULT false:开启且显式目标夹 B 时,
导入内容落 `B/<网盘目录末段名>`(F2);项目根模式创建时后端静默归一 false(F4,
承接夹名=末段名,行为已等价勾选态)。

纯增量迁移:单列带 server_default(PG 11+ 常量默认加列仅改 catalog,不重写全表,
不阻塞在线写入),存量任务行由 DEFAULT 归 false = 现状行为,零数据迁移;旧代码
与新 schema 兼容共存(回滚流程基石:先回滚代码,DB 无须 downgrade)。
`uq_baidu_task_running` partial index 不受影响。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261118_0021"
down_revision: str | Sequence[str] | None = "20261115_0021"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "baidu_backup_tasks",
        sa.Column(
            "create_same_name_folder", sa.Boolean(),
            nullable=False, server_default=sa.false(),
        ),
    )


def downgrade() -> None:
    op.drop_column("baidu_backup_tasks", "create_same_name_folder")
