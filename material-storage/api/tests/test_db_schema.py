"""DB schema smoke test — Phase B-2。

不连真实 DB,只 verify model 定义有效(metadata create / drop OK)。
集成 test 需要起 PG + 跑 migration,留 Phase B-3 CI。
"""

from app.db.tables import (
    AiJob,
    Asset,
    AssetAiAnnotation,
    AssetVideoSegment,
    AuditEvent,
    BaiduBackupTask,
    BaiduBackupTaskFile,
    BaiduBinding,
    Base,
    Folder,
    PersonalAccessToken,
    SystemFlag,
    User,
)


def test_all_tables_in_metadata() -> None:
    table_names = {t.name for t in Base.metadata.tables.values()}
    assert table_names == {
        "organizations",
        "users",
        "projects",
        "folders",
        "assets",
        "audit_events",
        "approvals",
        "request_link_tokens",
        "groups",
        "group_memberships",
        # 0019:用户↔项目置顶(用户私有偏好;照 group_memberships 复合主键风格)
        "user_project_pins",
        "notifications",
        "project_grant_templates",
        "project_grant_template_items",
        "project_folder_templates",
        "project_folder_template_entries",
        "baidu_bindings",
        "baidu_backup_tasks",
        "baidu_backup_task_files",
        # 0020:MCP 素材服务(PAT + 系统配置 KV)
        "personal_access_tokens",
        "system_flags",
        # 0021:AI 打标 + 视频切片(任务行 / 打标结果 / 虚拟切片段)
        "ai_jobs",
        "asset_ai_annotations",
        "asset_video_segments",
    }


def test_asset_unique_constraint() -> None:
    """asset 表必须有 (bucket, key, version) 唯一约束。"""
    constraints = {c.name for c in Asset.__table__.constraints}
    assert "uq_asset_minio_object_version" in constraints


def test_asset_size_bytes_is_bigint() -> None:
    """size_bytes 必须显式 BigInteger(对齐 migration 0001 的 bigint 列)。

    裸 Mapped[int] 会被推导成 Integer:>2.1GB 资产的 INSERT 参数按 int4 编码,
    asyncpg 直接 OverflowError(普通上传与百度导入同命中)。
    """
    from sqlalchemy import BigInteger

    col = Asset.__table__.c.size_bytes
    assert isinstance(col.type, BigInteger), f"size_bytes 列类型应为 BIGINT,实际 {col.type}"


def test_folder_unique_constraint() -> None:
    constraints = {c.name for c in Folder.__table__.constraints}
    assert "uq_folder_project_prefix" in constraints


def test_audit_event_indices() -> None:
    """audit_events 必须有 event_type + time 复合索引与 event_time 单列索引。"""
    indices = {idx.name for idx in AuditEvent.__table__.indexes}
    assert "ix_audit_event_type_time" in indices
    assert "ix_audit_actor_time" in indices
    assert "ix_audit_event_time" in indices


# ─── MCP 素材服务(migration 20261031_0020)────────────────────────────────────


def test_audit_event_auth_columns() -> None:
    """D4:audit_events 加 auth_method / auth_token_id 两列(nullable,存量行为 NULL)。

    auth_token_id 的 FK 必须 SET NULL(照审计列惯例:不能 CASCADE/RESTRICT),
    且首版就建索引(删用户级联删 PAT 时 SET NULL 会全表扫 audit_events)。
    """
    cols = AuditEvent.__table__.c
    assert "auth_method" in cols
    assert "auth_token_id" in cols
    assert cols.auth_method.nullable is True
    assert cols.auth_method.type.length == 16
    assert cols.auth_token_id.nullable is True
    fks = {fk.parent.name: fk for fk in AuditEvent.__table__.foreign_keys}
    assert fks["auth_token_id"].ondelete == "SET NULL"
    assert fks["auth_token_id"].target_fullname == "personal_access_tokens.id"
    assert "ix_audit_auth_token_id" in {i.name for i in AuditEvent.__table__.indexes}


def test_personal_access_token_schema() -> None:
    """D2/D3:PAT 表 —— token_hash 唯一(64)、token_prefix 16、user_id 索引 + CASCADE。"""
    cols = PersonalAccessToken.__table__.c
    assert cols.token_hash.type.length == 64
    assert cols.token_hash.nullable is False
    assert cols.token_prefix.type.length == 16
    assert cols.name.type.length == 128
    assert cols.expires_at.nullable is False
    assert cols.last_used_at.nullable is True
    assert cols.revoked_at.nullable is True
    constraints = {c.name for c in PersonalAccessToken.__table__.constraints}
    assert "uq_pat_token_hash" in constraints
    assert "ix_personal_access_tokens_user_id" in {
        i.name for i in PersonalAccessToken.__table__.indexes
    }
    fks = {fk.parent.name: fk for fk in PersonalAccessToken.__table__.foreign_keys}
    assert fks["user_id"].ondelete == "CASCADE"


def test_system_flags_schema() -> None:
    """D5/迁移 0020:system_flags(key PK + JSONB NOT NULL + TimestampMixin)。"""
    from sqlalchemy.dialects.postgresql import JSONB

    cols = SystemFlag.__table__.c
    assert cols.key.primary_key is True
    assert cols.key.type.length == 64
    assert isinstance(cols.value.type, JSONB)
    assert cols.value.nullable is False
    assert {"created_at", "updated_at", "key", "value"} == set(cols.keys())


# ─── AI 打标 + 视频切片三表(需求 §2.1,migration 20261103_0021)────────────────


def test_ai_job_schema() -> None:
    """ai_jobs:行认领 CAS/心跳载体 —— uq_ai_job 唯一 + sweeper 扫描索引 + FK CASCADE。

    claim_token / heartbeat_at nullable(「创建后未派发」「派发后未认领」窗口为
    NULL);last_error 为受控 token 集(varchar(128),不落自由文本)。
    """
    cols = AiJob.__table__.c
    assert cols.kind.type.length == 16
    assert cols.status.type.length == 16
    assert cols.status.nullable is False
    assert cols.attempts.nullable is False
    assert cols.claim_token.nullable is True
    assert cols.heartbeat_at.nullable is True
    assert cols.last_error.type.length == 128
    assert cols.last_error.nullable is True
    assert cols.model_version.type.length == 64
    constraints = {c.name for c in AiJob.__table__.constraints}
    assert "uq_ai_job" in constraints
    assert "ix_ai_jobs_status_updated" in {i.name for i in AiJob.__table__.indexes}
    fks = {fk.parent.name: fk for fk in AiJob.__table__.foreign_keys}
    assert fks["asset_id"].ondelete == "CASCADE"
    assert fks["asset_id"].target_fullname == "assets.id"


def test_asset_ai_annotation_schema() -> None:
    """asset_ai_annotations:PK (asset_id, model_version) —— 换模型/换词表 = 新版本行。

    searchable_text 为搜索第四路唯一命中面,须有 GIN trgm 索引(pg_trgm 迁移 0006 已建)。
    """
    from sqlalchemy.dialects.postgresql import JSONB

    cols = AssetAiAnnotation.__table__.c
    pk_cols = [c.name for c in AssetAiAnnotation.__table__.primary_key.columns]
    assert pk_cols == ["asset_id", "model_version"]
    assert cols.tier.type.length == 8
    assert cols.context_path.type.length == 600
    assert cols.context_path.nullable is False
    assert cols.searchable_text.nullable is False
    for name in ("tags_zh", "tags_en", "meta"):
        assert isinstance(cols[name].type, JSONB), f"{name} 列类型应为 JSONB,实际 {cols[name].type}"
        assert cols[name].nullable is False
    fks = {fk.parent.name: fk for fk in AssetAiAnnotation.__table__.foreign_keys}
    assert fks["asset_id"].ondelete == "CASCADE"
    indices = {i.name: i for i in AssetAiAnnotation.__table__.indexes}
    idx = indices.get("ix_ai_annotation_trgm")
    assert idx is not None, "缺 ix_ai_annotation_trgm(搜索第四路命中面索引)"
    assert idx.dialect_options["postgresql"]["using"] == "gin"
    assert idx.dialect_options["postgresql"]["ops"] == {"searchable_text": "gin_trgm_ops"}


def test_asset_video_segment_schema() -> None:
    """asset_video_segments:虚拟切片段 —— uq_ai_segment UNIQUE (asset_id, idx) 刻意
    不含 model_version(重跑 = 删旧段重写,防多版本段无限堆积);毫秒边界显式
    BigInteger(对齐 size_bytes 惯例);段只整批重写,无 updated_at。"""
    from sqlalchemy import BigInteger
    from sqlalchemy.dialects.postgresql import JSONB

    cols = AssetVideoSegment.__table__.c
    assert isinstance(cols.start_ms.type, BigInteger), f"start_ms 应为 BIGINT,实际 {cols.start_ms.type}"
    assert isinstance(cols.end_ms.type, BigInteger), f"end_ms 应为 BIGINT,实际 {cols.end_ms.type}"
    assert isinstance(cols.keyframe_keys.type, JSONB)
    constraints = {c.name for c in AssetVideoSegment.__table__.constraints}
    assert "uq_ai_segment" in constraints
    fks = {fk.parent.name: fk for fk in AssetVideoSegment.__table__.foreign_keys}
    assert fks["asset_id"].ondelete == "CASCADE"
    assert "updated_at" not in cols
    # 唯一键刻意不含 model_version(正本 §6)
    uq = next(c for c in AssetVideoSegment.__table__.constraints if c.name == "uq_ai_segment")
    assert [col.name for col in uq.columns] == ["asset_id", "idx"]


def test_user_open_id_unique() -> None:
    """飞书 open_id 唯一但可空(#150:本地新用户无飞书身份;ADR-0007 后保留只读历史对照)。"""
    col = User.__table__.c.feishu_open_id
    assert col.unique is True
    assert col.nullable is True


def test_user_oidc_sub_column() -> None:
    """通用 OIDC 登录身份键(#154:nullable + unique + index,未配置 provider 时全 NULL)。"""
    col = User.__table__.c.oidc_sub
    assert col.nullable is True
    assert col.unique is True
    assert {i.name for i in User.__table__.indexes} >= {"ix_users_oidc_sub"}


def test_user_username_column() -> None:
    """本地登录名列(#150:唯一 + 可空 + 索引;老飞书用户为 NULL)。"""
    col = User.__table__.c.username
    assert col.unique is True
    assert col.nullable is True
    assert {i.name for i in User.__table__.indexes} >= {"ix_users_username"}


# ─── 百度网盘备份三表(方案 §4,migration 20261008_0013)────────────────────────


def test_baidu_binding_unique_user() -> None:
    """每 user 至多一条绑定(方案 §4:unique — one binding per user)。"""
    constraints = {c.name for c in BaiduBinding.__table__.constraints}
    assert "uq_baidu_binding_user" in constraints
    col = BaiduBinding.__table__.c.baidu_uid
    assert col.nullable is False  # NOT NULL 防线:uinfo 失败 → 绑定整体失败


def test_baidu_task_running_partial_unique_index() -> None:
    """同绑定 running 唯一兜底(uq_baidu_task_running,并发方案 §2.2 第 2 条/T7)。

    原 uq_baidu_task_active(全活动唯一)已随迁移 0017 删除(多任务排队,§2.5);
    新兜底恰好护住最危险的「同绑定双下载循环」,枚举期互斥由 VIP 分道准入层负责
    (D3:DB 护下载互斥、准入护执行互斥)。断言口径 = 模型元数据。
    """
    indices = {i.name: i for i in BaiduBackupTask.__table__.indexes}
    assert "uq_baidu_task_active" not in indices, (
        "旧全活动唯一索引必须已删(并发方案 §2.2 第 1 条,否则第二个任务建不出来)"
    )
    idx = indices.get("uq_baidu_task_running")
    assert idx is not None, "缺 uq_baidu_task_running(并发方案 §2.2 第 2 条)"
    assert idx.unique is True
    # partial 谓词:WHERE status = 'running'
    where_sql = str(idx.dialect_options["postgresql"]["where"])
    assert "running" in where_sql
    # 谓词列含 binding_id(UNIQUE(binding_id) WHERE ...)
    assert [c.name for c in idx.columns] == ["binding_id"]


def test_baidu_task_running_index_predicate_is_deliberate_subset() -> None:
    """uq_baidu_task_running 的 partial 谓词恰为 {'running'}(D3 刻意子集,T7)。

    防回归:谓词被「顺手」改回 ACTIVE_STATUSES 全集会让枚举期第二个任务建不出来
    (多任务排队语义被静默拆除);只应护 running 下载互斥。
    """
    import re

    indices = {i.name: i for i in BaiduBackupTask.__table__.indexes}
    idx = indices["uq_baidu_task_running"]
    where_sql = str(idx.dialect_options["postgresql"]["where"])
    statuses_in_predicate = set(re.findall(r"'([a-z_]+)'", where_sql))
    assert statuses_in_predicate == {"running"}, (
        f"uq_baidu_task_running 谓词状态集应为刻意子集 {{'running'}}(D3),实际 {sorted(statuses_in_predicate)}"
    )


def test_baidu_task_active_binding_index_predicate_matches_active_statuses() -> None:
    """idx_baidu_task_active_binding(非唯一 partial 准入索引,§2.2 第 3 条)的
    partial 谓词状态集与 ACTIVE_STATUSES 常量严格一致(T7 谓词漂移断言)。

    防回归:任一侧增删活动状态(如新增状态机档位)而另一侧未跟 → 准入查询漏行
    (该状态的活动任务不参与准入/接管),出现「应用层放行、索引不覆盖」的并发窗口。
    """
    import re

    from app.services.baidu_backup import ACTIVE_STATUSES

    indices = {i.name: i for i in BaiduBackupTask.__table__.indexes}
    idx = indices["idx_baidu_task_active_binding"]
    assert idx.unique is False, "准入查询索引必须为非唯一 partial(§2.2 第 3 条)"
    assert [c.name for c in idx.columns] == ["binding_id"]
    where_sql = str(idx.dialect_options["postgresql"]["where"])
    statuses_in_predicate = set(re.findall(r"'([a-z_]+)'", where_sql))
    assert statuses_in_predicate == set(ACTIVE_STATUSES), (
        f"idx_baidu_task_active_binding 谓词 {sorted(statuses_in_predicate)} 与 "
        f"ACTIVE_STATUSES {sorted(ACTIVE_STATUSES)} 不一致"
    )


def test_baidu_binding_vip_type_column() -> None:
    """vip_type 分道数据源列(并发方案 §2.2 第 4 条/§3.1/T7):smallint NULL。

    NULL=未知,按非会员处理(保守归类保护会员槽位,D9);随 bind/重授权/任务
    创建/复活 best-effort 回填,不做批量回灌。
    """
    from sqlalchemy import SmallInteger

    col = BaiduBinding.__table__.c.vip_type
    assert col.nullable is True
    assert isinstance(col.type, SmallInteger), f"vip_type 列类型应为 SMALLINT,实际 {col.type}"


def test_baidu_task_file_relpath_unique() -> None:
    """manifest 唯一键绑 (task_id, rel_path)(方案 §4:绑 rel_path 不绑 source_path)。"""
    constraints = {c.name for c in BaiduBackupTaskFile.__table__.constraints}
    assert "uq_baidu_task_file_relpath" in constraints


def test_baidu_task_file_fk_ondelete() -> None:
    """FK ondelete 照方案 §4:task_id→CASCADE;asset_id/target_folder_id→SET NULL。"""
    fks = {fk.parent.name: fk for fk in BaiduBackupTaskFile.__table__.foreign_keys}
    assert fks["task_id"].ondelete == "CASCADE"
    assert fks["asset_id"].ondelete == "SET NULL"
    assert fks["target_folder_id"].ondelete == "SET NULL"
    task_fks = {fk.parent.name: fk for fk in BaiduBackupTask.__table__.foreign_keys}
    assert task_fks["user_id"].ondelete == "RESTRICT"
    assert task_fks["binding_id"].ondelete == "RESTRICT"
    assert task_fks["project_id"].ondelete == "RESTRICT"
    assert task_fks["target_folder_id"].ondelete == "SET NULL"


def test_baidu_task_file_reserved_key_column() -> None:
    """F2b 预定 key 列(migration 20261009_0014):nullable varchar(1024)。

    NULL=未预定走 canonical key;不复用 minio_key(断点续传会话寻址语义)。
    """
    from sqlalchemy import String

    col = BaiduBackupTaskFile.__table__.c.reserved_key
    assert col.nullable is True
    assert isinstance(col.type, String)
    assert col.type.length == 1024


# ─── 数据库层唯一约束(F3,容器测试)────────────────────────────────────────────
async def test_live_db_unique_constraints_on_local_identity() -> None:
    """F3:username / oidc_sub 的 UNIQUE 必须真实存在于数据库层。

    migration 0008/0010 的 `op.add_column(unique=True)` 不渲染 UNIQUE,
    ix_users_username / ix_users_oidc_sub 只是普通 btree —— 上面 ORM 元数据断言
    是假绿。0009 迁移补了 uq_users_username / uq_users_oidc_sub,这里直接查
    pg_constraint 验证。需要可连的 PG(容器测试,待 docker);本机无 DB 自动 skip。
    """
    import pytest
    from sqlalchemy import text

    from app.db.session import get_sessionmaker

    try:
        async with get_sessionmaker()() as db:
            rows = (
                (
                    await db.execute(
                        text(
                            "SELECT conname FROM pg_constraint"
                            " WHERE conrelid = 'users'::regclass AND contype = 'u'"
                        )
                    )
                )
                .scalars()
                .all()
            )
    except Exception as e:  # 环境不可用 → skip(连接拒绝 / 无 docker 等)
        pytest.skip(f"需要可连的 PG(容器测试,待 docker): {e}")
    uniques = set(rows)
    assert "uq_users_username" in uniques, f"缺 uq_users_username,实际: {uniques}"
    assert "uq_users_oidc_sub" in uniques, f"缺 uq_users_oidc_sub,实际: {uniques}"
