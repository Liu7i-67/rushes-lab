"""SQLAlchemy 2.x ORM models — Phase B-2 first batch。

设计要点:
- UUID PK(uuid7 时间排序);created_at / updated_at server-side default
- audit_events 是中心:所有 event 同表 + event_type 区分(简化第一版);
  Phase B-2 后续按事件量评估是否拆 sub-table
- 用户 snapshot 列(open_id / name / email)冗余存,user 软删/inactive 后审计仍可读
  (ADR-0005 §11.2 Gap 10 / PR #30 修订版)
- folder.is_sensitive 标记敏感目录;OpenFGA tuple 用 sensitive_folder type 区分
  (model layer 用 type 级隔离,数据层用 boolean 简化 schema)
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
    literal_column,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """所有 ORM 模型基类。"""


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class Organization(Base, TimestampMixin):
    __tablename__ = "organizations"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    feishu_tenant_key: Mapped[str | None] = mapped_column(String(64), unique=True)

    projects: Mapped[list["Project"]] = relationship(back_populates="organization")


class User(Base, TimestampMixin):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    # #150:本地用户没有飞书身份 → 列改 nullable;飞书老用户保留历史对照(只读,不再参与登录/权限)
    feishu_open_id: Mapped[str | None] = mapped_column(String(64), unique=True, index=True)
    feishu_union_id: Mapped[str | None] = mapped_column(String(64), index=True)
    # #154:通用 OIDC provider 留口的身份匹配键(sub claim);NULL = 非 OIDC 用户
    oidc_sub: Mapped[str | None] = mapped_column(String(255), unique=True, index=True)
    # 本地登录名(ADR-0007 / P1 #149):拼音/工号友好格式,不强制邮箱;老飞书用户 NULL
    username: Mapped[str | None] = mapped_column(String(64), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    email: Mapped[str | None] = mapped_column(String(255))
    # 本地账号密码登录(ADR-0007,P1 #149 启用);password_hash NULL = 未设密码
    password_hash: Mapped[str | None] = mapped_column(String(255))
    must_change_password: Mapped[bool] = mapped_column(
        Boolean, server_default="true", default=True, nullable=False
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    resigned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    organization_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("organizations.id", ondelete="SET NULL")
    )


class Project(Base, TimestampMixin):
    __tablename__ = "projects"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    organization_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("organizations.id", ondelete="RESTRICT"), nullable=False
    )
    code: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None]
    minio_bucket: Mapped[str] = mapped_column(String(63), nullable=False)
    # 元数据可见性(项目列表过滤):
    #   public  — org member 都看到 metadata,可申请加入
    #   private — 只 project member 看到(default)
    #   stealth — 完全隐藏,只 admin 主动邀请(connection 知 code 输入申请)
    visibility: Mapped[str] = mapped_column(String(16), default="private", nullable=False)
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    organization: Mapped[Organization] = relationship(back_populates="projects")
    folders: Mapped[list["Folder"]] = relationship(back_populates="project")


class Folder(Base, TimestampMixin):
    __tablename__ = "folders"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    project_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), nullable=False
    )
    parent_folder_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folders.id", ondelete="CASCADE")
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    minio_prefix: Mapped[str] = mapped_column(String(1024), nullable=False)
    # 权限语义判定字段:仍被 routers(folders/assets 等)用于 OpenFGA object_type 选择,
    # 是敏感目录权限语义的判定地基。禁止 drop(百度网盘备份导入功能依赖)。
    is_sensitive: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    project: Mapped[Project] = relationship(back_populates="folders")
    assets: Mapped[list["Asset"]] = relationship(back_populates="folder")

    __table_args__ = (
        UniqueConstraint("project_id", "minio_prefix", name="uq_folder_project_prefix"),
        Index("ix_folder_project_sensitive", "project_id", "is_sensitive"),
    )


class Asset(Base, TimestampMixin):
    __tablename__ = "assets"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    folder_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("folders.id", ondelete="RESTRICT"), nullable=False
    )
    filename: Mapped[str] = mapped_column(String(512), nullable=False)
    minio_bucket: Mapped[str] = mapped_column(String(63), nullable=False)
    minio_key: Mapped[str] = mapped_column(String(1024), nullable=False)
    etag: Mapped[str | None] = mapped_column(String(128))
    minio_version_id: Mapped[str | None] = mapped_column(String(128))
    size_bytes: Mapped[int] = mapped_column(nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(255))
    media_metadata: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict, nullable=False)
    tags: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict, nullable=False)
    # 用户自由标签(标签 + 盲搜发现 UX 地基,#148 wave0;GIN 索引见 __table_args__)
    user_labels: Mapped[list[str]] = mapped_column(
        ARRAY(String(64)), default=list, server_default="{}", nullable=False
    )
    # 素材备注(盲搜匹配范围:文件名 + user_labels + 备注,#151;trgm 索引见 __table_args__)
    notes: Mapped[str | None] = mapped_column(Text)

    uploader_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    folder: Mapped[Folder] = relationship(back_populates="assets")

    __table_args__ = (
        UniqueConstraint("minio_bucket", "minio_key", "minio_version_id",
                         name="uq_asset_minio_object_version"),
        Index("ix_asset_folder_created", "folder_id", "created_at"),
        Index("ix_asset_filename", "filename"),
        Index("ix_asset_user_labels", "user_labels", postgresql_using="gin"),
        Index("ix_asset_filename_trgm", "filename", postgresql_using="gin",
              postgresql_ops={"filename": "gin_trgm_ops"}),
        Index("ix_asset_notes_trgm", "notes", postgresql_using="gin",
              postgresql_ops={"notes": "gin_trgm_ops"}),
        # #151 review F8:盲搜 user_labels 模糊匹配走 array_to_string 表达式索引
        # (对应 migration 0011;ORM Index 仅声明,schema 以 migration 为准)
        Index(
            "ix_asset_user_labels_str_trgm",
            literal_column("array_to_string(user_labels, ' ')"),
            postgresql_using="gin",
            postgresql_ops={"array_to_string(user_labels, ' ')": "gin_trgm_ops"},
        ),
    )


class ApprovalRequest(Base, TimestampMixin):
    """审批申请 — iter6。

    用户对 sensitive_folder / asset 发起下载/访问申请;
    admin 批准 → 写 OpenFGA grant tuple(grant_explicit_download /
    invite_to_sensitive_folder),并把 tuple 引用存在 granted_tuple_ref(JSONB),
    撤销时直接定位删除。
    """
    __tablename__ = "approvals"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)

    applicant_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )

    # 申请目标:('sensitive_folder' | 'asset' | 'project'),配合 target_id 定位
    target_type: Mapped[str] = mapped_column(String(32), nullable=False)
    target_id: Mapped[uuid.UUID] = mapped_column(nullable=False, index=True)

    # 申请的动作:'download'(临时下载)| 'access'(永久邀请 sensitive_folder)
    action: Mapped[str] = mapped_column(String(32), nullable=False)

    duration_seconds: Mapped[int | None]   # None = 永久(action=access 时)
    reason: Mapped[str] = mapped_column(String(2000), nullable=False)

    # pending / approved / rejected / revoked / expired
    status: Mapped[str] = mapped_column(String(16), default="pending", nullable=False, index=True)

    # 飞书审批集成(iter7):每个申请对应飞书审批一个 instance
    feishu_instance_code: Mapped[str | None] = mapped_column(String(64), unique=True, index=True)

    # 决策
    approver_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decision_note: Mapped[str | None] = mapped_column(String(2000))

    # OpenFGA 写回的 tuple 引用(撤销/审计用)
    # 形如 {"user":"user:X","relation":"explicit_downloader","object":"asset:Y","permanent":false}
    granted_tuple_ref: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict, nullable=False)

    __table_args__ = (
        Index("ix_approval_target", "target_type", "target_id"),
        Index("ix_approval_status_created", "status", "created_at"),
    )


class AuditEvent(Base):
    """Audit 中心:所有业务事件落库;ADR-0005 §11.2 Gap 10。"""
    __tablename__ = "audit_events"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)

    # event_type 枚举(string,Phase B-2 不引入 enum):
    #   upload / download / proxy_download / signed_url_issued / signed_url_revoked
    #   approval_submitted / approval_state_changed
    #   admin_session_login / admin_session_logout / session_revoked_due_to_resign
    #   sidecar_task_started / sidecar_task_succeeded / sidecar_task_failed
    event_type: Mapped[str] = mapped_column(String(64), nullable=False, index=True)

    # actor snapshot(冗余,user 删后仍可读)
    actor_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    actor_open_id_snapshot: Mapped[str | None] = mapped_column(String(64))
    actor_name_snapshot: Mapped[str | None] = mapped_column(String(128))
    actor_email_snapshot: Mapped[str | None] = mapped_column(String(255))

    target_asset_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("assets.id", ondelete="SET NULL"), index=True
    )
    target_project_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("projects.id", ondelete="SET NULL"), index=True
    )
    target_minio_key: Mapped[str | None] = mapped_column(String(1024))

    # 跨系统幂等;格式 <source>:<source_event_id>[:<status>]
    dedup_key: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    trace_id: Mapped[uuid.UUID | None] = mapped_column(index=True)

    request_ip: Mapped[str | None] = mapped_column(String(64))
    user_agent: Mapped[str | None] = mapped_column(String(512))

    details: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict, nullable=False)
    event_time: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    inserted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_audit_event_type_time", "event_type", "event_time"),
        Index("ix_audit_actor_time", "actor_user_id", "event_time"),
    )


class RequestLinkToken(Base):
    """admin 生成的"申请入口"分享 token(#112)。

    接收者落地 → 看到资源元信息 → 走正常 approval 流程(不是直接授权)。
    跟 share token(audit_events 反范式)语义独立,所以独立表。
    多次使用,首次时间记 used_at;一次性需求后续加 single_use 字段。
    """
    __tablename__ = "request_link_tokens"

    token: Mapped[str] = mapped_column(String(64), primary_key=True)
    target_type: Mapped[str] = mapped_column(String(32), nullable=False)
    target_id: Mapped[uuid.UUID] = mapped_column(nullable=False)
    allowed_actions: Mapped[list[str]] = mapped_column(ARRAY(String(16)), nullable=False)

    inviter_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True,
    )
    # nullable = 任意登录用户;非空 = 限定只此 user 可用(backend POST approvals 时强制 check)
    # #148:receiver_open_id(飞书)→ receiver_user_id(users.id UUID;软关联,不加 FK)
    receiver_user_id: Mapped[uuid.UUID | None] = mapped_column()

    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False,
    )
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        Index("ix_request_link_target", "target_type", "target_id"),
        Index("ix_request_link_expires", "expires_at"),
    )


class Group(Base, TimestampMixin):
    """本地用户组(ADR-0007)— OpenFGA group subject 从飞书 gid 迁到本地 groups.id。

    subject 形如 group:<groups.id UUID>#member;飞书同步来的组在
    scripts/migrate_subjects_to_uuid.py 里以 uuid5(NAMESPACE_DNS, "feishu:group:{gid}")
    落成本地行(idempotent)。
    """
    __tablename__ = "groups"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    description: Mapped[str | None] = mapped_column(String(1024))


class GroupMembership(Base):
    """group ↔ user 成员关系(复合主键;无 updated_at,成员关系只增删)。"""
    __tablename__ = "group_memberships"

    group_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("groups.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Notification(Base):
    """应用内通知(ADR-0007 弃飞书后的最小通知通道;#148 wave0 只建表)。"""
    __tablename__ = "notifications"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    body: Mapped[str | None] = mapped_column(String(2000))
    link: Mapped[str | None] = mapped_column(String(1024))
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class ProjectGrantTemplate(Base, TimestampMixin):
    """项目权限模板(方案 §4.1,批次三)— 保存的授权组合预设 {主体, 角色}。

    应用方式 = 前端预填(§4.3):新建项目时选模板把 items 预填进 initial_grants,
    后端不感知模板、模板事后修改不影响任何已建项目。同 org 内 name 唯一;
    partial unique index 保证每 org 至多 1 个 is_default。
    """
    __tablename__ = "project_grant_templates"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    organization_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("organizations.id"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    description: Mapped[str | None] = mapped_column(String(1024))
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    __table_args__ = (
        UniqueConstraint("organization_id", "name", name="uq_pgt_org_name"),
        # 每 org 至多 1 个 default(全库首例 partial unique index)
        Index(
            "uq_pgt_default_per_org", "organization_id", unique=True,
            postgresql_where=text("is_default"),
        ),
    )


class ProjectGrantTemplateItem(Base):
    """模板条目:单主体(user | group)的一组角色;template 删除级联。

    roles 为 list[ProjectRole](全库 ORM 惯例 JSONB,不用 JSON)。
    """
    __tablename__ = "project_grant_template_items"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    template_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("project_grant_templates.id", ondelete="CASCADE"), nullable=False
    )
    subject_kind: Mapped[str] = mapped_column(String(8), nullable=False)  # 'user' | 'group'
    subject_id: Mapped[uuid.UUID] = mapped_column(nullable=False)
    roles: Mapped[list[str]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        UniqueConstraint(
            "template_id", "subject_kind", "subject_id", name="uq_pgt_item_subject",
        ),
    )


class BaiduBinding(Base, TimestampMixin):
    """百度网盘绑定(方案 §4)— 每 user 一条;token 双列 Fernet 密文。

    - status:active / expired(refresh 确认失效或密钥轮换解密失败)/ unbound
      (软解绑:密文已清空,行保留供任务历史 FK 引用)
    - baidu_uid NOT NULL:uinfo 失败/缺 uid → 本次绑定整体失败(502)——否则
      NULL==NULL 会让真换绑被误判"同账号",绕过断点作废防线产出跨账号静默损坏
    - last_authorized_at:仅 bind/重授权(调 uinfo)时刷新 —— 换绑甄别锚点之一
    - token_rotated_at:任何 token 覆盖写入(绑定/重授权/refresh)都刷新 ——
      403 dlink 甄别锚点(防仅 refresh 过的同账号任务被误判换绑)
    """
    __tablename__ = "baidu_bindings"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    access_token_enc: Mapped[str] = mapped_column(Text, nullable=False)
    refresh_token_enc: Mapped[str] = mapped_column(Text, nullable=False)
    baidu_uid: Mapped[str] = mapped_column(String(32), nullable=False)
    nickname: Mapped[str | None] = mapped_column(String(128))
    access_token_expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    status: Mapped[str] = mapped_column(
        String(16), default="active", server_default="active", nullable=False
    )
    last_authorized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    token_rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        # one binding per user(方案 §4);显式命名供 test_db_schema 断言
        UniqueConstraint("user_id", name="uq_baidu_binding_user"),
    )


class BaiduBackupTask(Base, TimestampMixin):
    """百度网盘备份任务(方案 §4)— 单绑定同时至多一个活动中任务。

    状态:enumerating(清单准备中)→ running → completed / cancelled / failed。
    时间戳谓词必须显式含 NULL 分支(SQL 中 NULL 参与比较恒为假):任务在
    「创建后未派发」「派发后未认领」两窗口 dispatched_at / runner_id / lease_until
    均为 NULL(方案 §4 状态谓词)。
    """
    __tablename__ = "baidu_backup_tasks"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    binding_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("baidu_bindings.id", ondelete="RESTRICT"), nullable=False
    )
    # 创建时从 binding 快照:换绑甄别(409 前置与 not_found 文案)统一比较此快照
    # 与当前 binding.baidu_uid(§4)
    bound_baidu_uid: Mapped[str | None] = mapped_column(String(32))
    source_dir: Mapped[str] = mapped_column(String(1024), nullable=False)
    project_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("projects.id", ondelete="RESTRICT"), nullable=False
    )
    # 目标夹被删后置 NULL,明细展示「(已删除)」(方案 §4)
    target_folder_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folders.id", ondelete="SET NULL")
    )
    target_auto_created: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False
    )
    status: Mapped[str] = mapped_column(
        String(16), default="enumerating", server_default="enumerating", nullable=False,
        index=True,
    )
    cancel_requested: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False
    )
    # user_cancel / binding_replaced(急停走 fail_reason=feature_disabled,不经此列)
    cancel_reason: Mapped[str | None] = mapped_column(String(64))
    retry_count: Mapped[int] = mapped_column(
        default=0, server_default="0", nullable=False
    )  # 复活次数(audit dedup_key 轮次维度)
    # 枚举完成标记:runner 枚举完成置 running 时同事务置位;复活时 false→重枚举
    enum_done: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False
    )
    # 聚合口径一律由 manifest 行状态 GROUP BY 重算,不做增量维护(方案 §6)
    total_files: Mapped[int | None]
    done_files: Mapped[int | None]
    failed_files: Mapped[int | None]
    skipped_files: Mapped[int | None]
    cancelled_files: Mapped[int | None]
    total_bytes: Mapped[int | None] = mapped_column(BigInteger)
    done_bytes: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )
    # 滚动吞吐(锚点差分),ETA=剩余字节/此值;≤0 时接口 ETA 返 null 显示「估算中」
    speed_bps: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )
    speed_anchor_bytes: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )
    speed_anchor_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    runner_id: Mapped[str | None] = mapped_column(String(64))
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # 即心跳
    # 派发版本号:每次派发自增,job 按 expected_seq 认领(互斥唯一凭证之一)
    lease_seq: Mapped[int] = mapped_column(default=0, server_default="0", nullable=False)
    # 最近派发时刻:sweeper 节流(NULL=从未派发,必须被接管)
    dispatched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # 轮起点(两次复活之间):认领 COALESCE 保留、仅复活派发与并发门控退出复位
    # NULL —— 48h 判停依据(从未认领=NULL 不参与判停)
    round_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # binding_expired / timeout / file_failed / enum_rate_limited / enum_failed /
    # manifest_too_large / feature_disabled(方案 §4 取值域)
    fail_reason: Mapped[str | None] = mapped_column(String(512))

    __table_args__ = (
        # 同绑定同时最多一个活动中任务(应用层检查之外的硬兜底,撞唯一约束统一转 409)
        Index(
            "uq_baidu_task_active", "binding_id", unique=True,
            postgresql_where=text("status IN ('enumerating','running')"),
        ),
    )


class BaiduBackupTaskFile(Base, TimestampMixin):
    """任务 manifest 行(方案 §4)— 不落 MinIO 前先建 DB 行。

    断点续传三元组 (minio_upload_id, minio_bucket, minio_key) 在 create_multipart
    时同事务落定(abort 按三元组直读,防目标夹被删后 key 无法重建);dlink 仅存
    原始值不拼 access_token,8h 缓存由 dlink_fetched_at/dlink_expires_at 记账。
    """
    __tablename__ = "baidu_backup_task_files"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("baidu_backup_tasks.id", ondelete="CASCADE"), nullable=False, index=True
    )
    fs_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    source_path: Mapped[str] = mapped_column(Text, nullable=False)  # 仅展示用,不进索引
    source_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    # 相对 source_dir;唯一键绑 (task_id, rel_path) —— source_dir 创建时定长,
    # rel_path ≤600 足以唯一定位行(绑 source_path 会因 source_dir 变长误伤浅目录长文件)
    rel_path: Mapped[str] = mapped_column(String(1024), nullable=False)
    # 导入时按需建出的目录链(展示"预计导入路径"用)
    target_folder_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folders.id", ondelete="SET NULL")
    )
    asset_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("assets.id", ondelete="SET NULL")
    )
    # pending / skipped_exists / importing / success / failed / cancelled
    status: Mapped[str] = mapped_column(
        String(16), default="pending", server_default="pending", nullable=False,
        index=True,
    )
    overwrite: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False
    )  # 覆盖导入标记(清除-再导入,导入时复查 can_admin)
    bytes_done: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )  # 已完成 multipart parts 的累计字节(断点偏移)
    # MinIO multipart 会话(断点续传载体);VARCHAR 不定长 → Text(PG 语义等价)
    minio_upload_id: Mapped[str | None] = mapped_column(Text)
    minio_bucket: Mapped[str | None] = mapped_column(String(63))   # 列宽对齐 assets.minio_bucket
    minio_key: Mapped[str | None] = mapped_column(String(1024))
    attempts: Mapped[int] = mapped_column(default=0, server_default="0", nullable=False)
    last_error: Mapped[str | None] = mapped_column(String(512))
    # not_found 类终态:retry-failed 排除、单文件 retry 409、UI 置灰
    non_retryable: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False
    )
    dlink: Mapped[str | None] = mapped_column(Text)
    dlink_fetched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    dlink_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("task_id", "rel_path", name="uq_baidu_task_file_relpath"),
    )
