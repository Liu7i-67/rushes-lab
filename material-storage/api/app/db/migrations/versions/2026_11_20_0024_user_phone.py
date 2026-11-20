"""users 加 phone 列 + 一号一账号唯一约束 — 手机绑定/短信找回密码(迁移 0024)

Revision ID: 20261120_0024
Revises: 20261119_0023
Create Date: 2026-11-20

需求:`docs/qdev/2026-11-20-phone-bind-sms-reset.md`(B1 包);
方案:`rushes-spec/material-storage/phone-bind-and-sms-password-reset-plan.md` §4。

- users.phone VARCHAR(20) NULL:中国大陆手机号(11 位),NULL = 未绑定;纯增量列,
  旧代码不读 phone,新 schema 对旧代码无影响,无须数据回填即可上线(回填走 B5
  批量绑定脚本,独立步骤)。
- 唯一性**显式 create_unique_constraint**(方案钉子 1):列定义 unique=True 只发
  普通 ALTER 不渲染 UNIQUE(0008/0010 前科,0009 专门补建);且用 unique constraint
  而非 unique index —— tests/test_db_schema.py 的 pg_constraint contype='u' 防假绿
  断言只覆盖 constraint。PG 唯一约束自带背书索引,查询语义与唯一索引等价。
- downgrade:先 drop_constraint(type_="unique") 再 drop_column;唯一约束的背书
  索引归约束所有,**不能 op.drop_index**(会报依赖错误)。仅建议在未写入数据时
  使用;已有绑定数据后回滚走「保留列只回代码」(方案 §9.3)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261120_0024"
down_revision: str | Sequence[str] | None = "20261119_0023"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("phone", sa.String(20), nullable=True))
    # 显式唯一约束(勿用列定义 unique=True:0008/0010 只发普通 ALTER 不渲染 UNIQUE)
    op.create_unique_constraint("uq_users_phone", "users", ["phone"])


def downgrade() -> None:
    # 背书索引归约束所有:先 drop_constraint,不能 op.drop_index(依赖错误)
    op.drop_constraint("uq_users_phone", "users", type_="unique")
    op.drop_column("users", "phone")
