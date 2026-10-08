"""DB schema smoke test — Phase B-2。

不连真实 DB,只 verify model 定义有效(metadata create / drop OK)。
集成 test 需要起 PG + 跑 migration,留 Phase B-3 CI。
"""
from app.db.tables import (
    Asset,
    AuditEvent,
    BaiduBackupTask,
    BaiduBackupTaskFile,
    BaiduBinding,
    Base,
    Folder,
    Organization,
    Project,
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
        "notifications",
        "project_grant_templates",
        "project_grant_template_items",
        "baidu_bindings",
        "baidu_backup_tasks",
        "baidu_backup_task_files",
    }


def test_asset_unique_constraint() -> None:
    """asset 表必须有 (bucket, key, version) 唯一约束。"""
    constraints = {c.name for c in Asset.__table__.constraints}
    assert "uq_asset_minio_object_version" in constraints


def test_folder_unique_constraint() -> None:
    constraints = {c.name for c in Folder.__table__.constraints}
    assert "uq_folder_project_prefix" in constraints


def test_audit_event_indices() -> None:
    """audit_events 必须有 event_type + time 复合索引(查询性能)。"""
    indices = {idx.name for idx in AuditEvent.__table__.indexes}
    assert "ix_audit_event_type_time" in indices
    assert "ix_audit_actor_time" in indices


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


def test_baidu_task_active_partial_unique_index() -> None:
    """同绑定同时至多一个活动中任务(partial unique index 硬兜底,方案 §4)。"""
    indices = {i.name: i for i in BaiduBackupTask.__table__.indexes}
    idx = indices.get("uq_baidu_task_active")
    assert idx is not None
    assert idx.unique is True
    # partial 谓词:WHERE status IN ('enumerating','running')
    where_sql = str(idx.dialect_options["postgresql"]["where"])
    assert "enumerating" in where_sql and "running" in where_sql


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
            rows = (await db.execute(text(
                "SELECT conname FROM pg_constraint"
                " WHERE conrelid = 'users'::regclass AND contype = 'u'"
            ))).scalars().all()
    except Exception as e:  # 环境不可用 → skip(连接拒绝 / 无 docker 等)
        pytest.skip(f"需要可连的 PG(容器测试,待 docker): {e}")
    uniques = set(rows)
    assert "uq_users_username" in uniques, f"缺 uq_users_username,实际: {uniques}"
    assert "uq_users_oidc_sub" in uniques, f"缺 uq_users_oidc_sub,实际: {uniques}"
