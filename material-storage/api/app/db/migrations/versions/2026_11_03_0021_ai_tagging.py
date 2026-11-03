"""AI 打标 + 视频切片数据地基 — ai_jobs / asset_ai_annotations / asset_video_segments(迁移 0021)

Revision ID: 20261103_0021
Revises: 20261031_0020
Create Date: 2026-11-03

需求:`docs/qdev/2026-11-03-ai-tagging-slicing.md` §2.1(DDL 逐字依据);
方案正本 `rushes-spec/material-storage/ai-tagging-slicing-plan.md` §6。
纯增量迁移:三张新表只引用 assets(FK ON DELETE CASCADE),不动既有表/列/索引 ——
旧代码(0020 head)与新 schema 兼容共存;回滚 = 停 ms-ai-worker + downgrade 弃表
(正本 §6「回滚 = 停容器弃表」,不动 assets 表任何列)。

设计要点(正本 §6):
- ai_jobs:行认领 CAS(claim_token)/ 心跳(heartbeat_at)载体;status 取值域
  pending|running|done|failed|skipped(failed=瞬时失败待 sweeper 重试,
  skipped=永久终态不重试);last_error 是受控 token 集(ml_error/minio_missing/
  minio_transient/decode_failed/asset_gone/poison/partial,无 ffmpeg_timeout 写入方),
  不落自由文本 —— 沿 thumbnail_failed「不落敏感信息」哲学,且按 token 精确 DELETE/筛选。
- asset_ai_annotations:PK (asset_id, model_version) —— 换模型/换词表 = 新版本行,
  旧行保留,active 版本由 settings 指定,搜索只命中 active;searchable_text 是
  搜索第四路唯一命中面(context_path + tags + 描述 + 各段描述聚合),配 GIN trgm
  索引(pg_trgm 扩展已由迁移 0006 建立,此处不重复 CREATE EXTENSION)。
- asset_video_segments:虚拟切片(决策 D1);UNIQUE (asset_id, idx) 刻意不含
  model_version —— 段结构由场景检测参数决定,重跑/换版本 = DELETE 该 asset 全部
  旧段后重写,防多版本段无限堆积(model_version 仅记录)。

存量数据迁移:无(全量新表;存量素材打标走 backfill_ai.py,不属本迁移)。
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261103_0021"
down_revision: str | Sequence[str] | None = "20261031_0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ─── ai_jobs(打标/切片任务行:行认领 CAS + 心跳 + sweeper 扫描)─────────
    op.create_table(
        "ai_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("asset_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("assets.id", ondelete="CASCADE"), nullable=False),
        # annotate | slice | refresh(应用层 Literal 校验,按仓库惯例不引入 DB enum/CHECK)
        sa.Column("kind", sa.String(16), nullable=False),
        # pending | running | done | failed | skipped(skipped=永久终态,不重试)
        sa.Column("status", sa.String(16), server_default="pending", nullable=False),
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        # 认领时生成,CAS 凭据(终态回写 WHERE claim_token,防接管后旧 worker 复写)
        sa.Column("claim_token", postgresql.UUID(as_uuid=True)),
        # 心跳只刷此列,判活/接管依据
        sa.Column("heartbeat_at", sa.DateTime(timezone=True)),
        # 受控 token 集(见 docstring),不落自由文本
        sa.Column("last_error", sa.String(128)),
        sa.Column("model_version", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("asset_id", "kind", "model_version", name="uq_ai_job"),
    )
    # sweeper 扫描索引(每 10min 按 status + updated_at 挑任务,方案 §8.5)
    op.create_index("ix_ai_jobs_status_updated", "ai_jobs", ["status", "updated_at"])

    # ─── asset_ai_annotations(打标结果;搜索第四路唯一命中面)───────────────
    op.create_table(
        "asset_ai_annotations",
        sa.Column("asset_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("assets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("model_version", sa.String(64), nullable=False),
        # coarse | refined(refined 为 P2 精标预留:新 model_version 新行)
        sa.Column("tier", sa.String(8), server_default="coarse", nullable=False),
        # 打标时的 项目名/目录链/文件名 快照(可读出「哪个项目的什么素材」)
        sa.Column("context_path", sa.String(600), nullable=False),
        sa.Column("tags_zh", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("tags_en", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        # description 呈现用(中文)/ description_en 原始(英文)
        sa.Column("description", sa.Text()),
        sa.Column("description_en", sa.Text()),
        # 聚合命中面:context_path + tags_zh/en + description(_en) + 各段描述(正本 §9)
        sa.Column("searchable_text", sa.Text(), server_default="", nullable=False),
        # 降级标记(partial 等 —— 软预算止损的落点)
        sa.Column("meta", postgresql.JSONB(), server_default=sa.text("'{}'::jsonb"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("asset_id", "model_version"),
    )
    # GIN trgm:搜索第四路 ILIKE 走索引(pg_trgm 扩展已由迁移 0006 建立)
    op.create_index(
        "ix_ai_annotation_trgm", "asset_ai_annotations", ["searchable_text"],
        postgresql_using="gin",
        postgresql_ops={"searchable_text": "gin_trgm_ops"},
    )

    # ─── asset_video_segments(虚拟切片段,D1)──────────────────────────────
    op.create_table(
        "asset_video_segments",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("asset_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("assets.id", ondelete="CASCADE"), nullable=False),
        # 段序,0 起
        sa.Column("idx", sa.Integer(), nullable=False),
        sa.Column("start_ms", sa.BigInteger(), nullable=False),
        sa.Column("end_ms", sa.BigInteger(), nullable=False),
        # 该段关键帧对象 key 数组(前缀 keyframes/{asset_id}/,按需签发 presigned URL)
        sa.Column("keyframe_keys", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("tags_zh", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("tags_en", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("description", sa.Text()),
        # 降级标记:segmented_by(interval/scene)/describe_failed 等(验收 #5 判定落点)
        sa.Column("meta", postgresql.JSONB(), server_default=sa.text("'{}'::jsonb"), nullable=False),
        # 仅记录,不参与唯一键(UNIQUE 刻意不含 model_version,见 docstring)
        sa.Column("model_version", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("asset_id", "idx", name="uq_ai_segment"),
    )
    # UNIQUE 前导列即 asset_id(asset_id, idx),无需单列 asset_id 索引(正本 §6)


def downgrade() -> None:
    op.drop_index("ix_ai_annotation_trgm", table_name="asset_ai_annotations")
    op.drop_table("asset_ai_annotations")
    op.drop_index("ix_ai_jobs_status_updated", table_name="ai_jobs")
    op.drop_table("ai_jobs")
    op.drop_table("asset_video_segments")
