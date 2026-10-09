"""Pydantic API I/O models — Phase B-2 first batch。"""
from __future__ import annotations

import unicodedata
import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# ProjectRole Literal 定义处(permissions.py 只 import settings/openfga_sdk,无循环依赖)
from app.services.permissions import ProjectRole


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ─── projects ─────────────────────────────────────────────────────────────────
class InitialGrantIn(BaseModel):
    """新建项目初始授权条目(方案 §3.1)。

    user 需存在且 active / group 需存在(存在性校验在 create_project 前置,
    400 指明第几条);roles 非空在 Pydantic 层拦(422),去重 + 固定顺序落在
    create_project 路由内(PROJECT_ROLES 常量在 routers,models 层不 import)。
    """

    kind: Literal["user", "group"]
    id: uuid.UUID                      # user: users.id(需 active);group: groups.id(需存在)
    roles: list[ProjectRole] = Field(..., min_length=1)


class ProjectCreateIn(BaseModel):
    code: str = Field(..., min_length=2, max_length=64, pattern=r"^[a-z0-9][a-z0-9\-]*$")
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    # 留空 = 用 user.organization_id 或 settings.default_organization_id
    organization_id: uuid.UUID | None = None
    minio_bucket: str = Field(..., max_length=63)
    # 必填:指派的项目 admin(系统 admin 创建,需要明确指派 sub-admin;
    # 可以是自己 = me.id;UI 默认填创建者)
    admin_user_id: uuid.UUID = Field(..., description="项目管理员的 users.id UUID")
    # 新建项目初始授权(可选;方案 §3.1):不传 / 空 = 现行为完全不变
    initial_grants: list[InitialGrantIn] | None = None


class AdminBrief(BaseModel):
    user_id: str
    name: str


class ProjectOut(ORMModel):
    id: uuid.UUID
    code: str
    name: str
    description: str | None
    organization_id: uuid.UUID
    minio_bucket: str
    visibility: str       # public / private / stealth
    is_archived: bool
    created_at: datetime
    admins: list[AdminBrief] = []
    # 当前 user 在本项目的有效 role 列表(单 user 可有多 role,如 admin+uploader);
    # ['admin'|'uploader'|'downloader'|'viewer'];空 = 仅靠 visibility=public 见
    my_roles: list[str] = []


# ─── assets ───────────────────────────────────────────────────────────────────
class AssetOut(ORMModel):
    id: uuid.UUID
    folder_id: uuid.UUID
    filename: str
    minio_bucket: str
    minio_key: str
    etag: str | None
    minio_version_id: str | None
    size_bytes: int
    content_type: str | None
    created_at: datetime
    # 软删时间;普通列表恒 None(已删的查不到),回收站列表有值
    deleted_at: datetime | None = None
    # B-4:worker 生成的缩略图 / 标签等 metadata;前端按需读
    tags: dict = {}
    # 标签 + 盲搜(#151):用户自由标签 + 备注
    user_labels: list[str] = []
    notes: str | None = None


class SearchResultOut(AssetOut):
    """跨 folder 盲搜结果 — AssetOut + 归属信息(前端导航 / 展示用)。"""

    folder_name: str
    project_id: uuid.UUID
    project_name: str


class AssetMetaUpdateIn(BaseModel):
    """打标 / 改标(#151)。

    user_labels / notes 缺省 = 不改该项;显式传空数组 / 空串 = 清空。
    labels_mode(方案 §1.1):replace(默认)= 整条替换,现行为完全不变;
    merge = 与 DB 现值取并集(DB 现值在前、新标签追加在后,顺序写死),
    并集仍过 50 条上限 —— 批量跨页打标用,未加载行的旧标签不被清掉。
    """

    user_labels: list[str] | None = None
    notes: str | None = None
    labels_mode: Literal["merge", "replace"] = "replace"


class AssetBatchPrefixIn(BaseModel):
    """批量文件名前缀(方案 §1.1)。

    prefix 校验:禁 "/"(前缀拼进 filename,路径分隔符会越出 folder 语义)、
    禁控制字符(Cc 类)、strip 后非空;服务端 NFC 归一,归一后复检 ≤128
    (归一可能合并码点,只查归一前长度会漏)。路由拿到的 prefix 已是
    归一后的值(「前缀比较两侧 NFC」的输入侧)。
    """

    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=1000)
    action: Literal["add", "remove"]
    prefix: str = Field(..., min_length=1, max_length=128)

    @field_validator("prefix")
    @classmethod
    def _nfc_and_charset(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("prefix 不能为空白")
        if "/" in stripped:
            raise ValueError("prefix 不能包含路径分隔符 /")
        if any(unicodedata.category(ch) == "Cc" for ch in stripped):
            raise ValueError("prefix 不能包含控制字符")
        normalized = unicodedata.normalize("NFC", stripped)
        if len(normalized) > 128:
            raise ValueError("prefix NFC 归一后超长(>128)")
        return normalized


class TrashOut(BaseModel):
    """回收站列表 — items 为分页窗口(上限 500),total 为全量计数。

    total 独立返回:角标计数与「清空回收站」的规模提示不能被窗口截断误导。
    """

    items: list[AssetOut]
    total: int


class AssetListOut(BaseModel):
    """文件夹文件列表 — items 为分页窗口(默认 100,上限 500)+ total 全量计数。

    服务端分页:此前固定 limit=100 且前端不翻页,folder 超 100 后旧文件在
    列表里静默消失(数据仍在);total 独立返回让分页器展示真实规模。
    """

    items: list[AssetOut]
    total: int


# ─── upload presigned ─────────────────────────────────────────────────────────
class UploadUrlRequest(BaseModel):
    folder_id: uuid.UUID
    filename: str = Field(..., min_length=1, max_length=512)
    content_type: str = "application/octet-stream"
    size_bytes: int = Field(..., ge=0)


class UploadMultipartCreateOut(BaseModel):
    upload_id: str
    key: str
    bucket: str


class UploadPartUrlOut(BaseModel):
    url: str
    expires_in: int


class UploadCompleteIn(BaseModel):
    upload_id: str
    # 必填:complete 按主键解析 folder。按 key 目录前缀反查在生产库会命中跨
    # project 的同名目录树(uq_folder_project_prefix 是 (project_id, prefix)
    # 维度,跨 project 同前缀合法)→ scalar_one_or_none 多行命中裸 500
    folder_id: uuid.UUID
    bucket: str
    key: str
    parts: list[dict[str, int | str]]


# ─── download link ────────────────────────────────────────────────────────────
class DownloadLinkOut(BaseModel):
    url: str
    expires_in: int
    is_sensitive: bool


# ─── approvals(iter6)────────────────────────────────────────────────────────
class ApprovalCreateIn(BaseModel):
    # #129: 加 folder 支持(model + permissions + approval_service 全链路接通)
    target_type: str = Field(..., pattern=r"^(sensitive_folder|asset|project|folder)$")
    target_id: uuid.UUID
    action: str = Field(..., pattern=r"^(download|access)$",
                        description="download=临时下载(grant_explicit_download);"
                                    "access=邀请进 sensitive_folder")
    duration_seconds: int | None = Field(None, ge=60, le=365 * 24 * 3600,
                                         description="None=永久(仅 action=access 时)")
    reason: str = Field(..., min_length=4, max_length=2000)


class ApprovalDecisionIn(BaseModel):
    decision_note: str | None = Field(None, max_length=2000)


# ─── folders(iter7)──────────────────────────────────────────────────────────
class FolderCreateIn(BaseModel):
    project_id: uuid.UUID
    parent_folder_id: uuid.UUID | None = None
    name: str = Field(..., min_length=1, max_length=255)
    is_sensitive: bool = False
    minio_prefix: str | None = Field(None, max_length=1024,
                                      description="未给则自动 = '<parent_prefix>/<name>/'")


class FolderOut(ORMModel):
    id: uuid.UUID
    project_id: uuid.UUID
    parent_folder_id: uuid.UUID | None
    name: str
    minio_prefix: str
    is_sensitive: bool
    created_at: datetime
    # 当前 user 对本 folder 的有效权限(派生 can_*)— get_folder 时填充
    my_can_view: bool = False
    my_can_download: bool = False
    my_can_upload: bool = False
    my_can_admin: bool = False


class FolderInviteIn(BaseModel):
    # subject 二选一 — 任选其一传(#154:department 轴写入下线,ADR-0007):
    user_id: uuid.UUID | None = None      # 单人 user(users.id UUID)
    group_id: str | None = None           # 本地用户组(groups.id UUID)
    # 邀请等级(v4 新增,旧调用方默认 viewer)
    level: str = Field("viewer", pattern=r"^(viewer|downloader)$")
    duration_seconds: int | None = Field(None, ge=60, le=365 * 24 * 3600,
                                         description="None=永久邀请;int=时间限定")


class ApprovalOut(ORMModel):
    id: uuid.UUID
    applicant_user_id: uuid.UUID
    target_type: str
    target_id: uuid.UUID
    action: str
    duration_seconds: int | None
    reason: str
    status: str
    feishu_instance_code: str | None
    approver_user_id: uuid.UUID | None
    decided_at: datetime | None
    decision_note: str | None
    created_at: datetime
    # #136/#137: router 层 enrich(approval row 无这俩列;反查 resolve_target_name)
    # target_name = 人类可读资源名;parent_project_id = folder/asset 时的父项目(导航用)
    target_name: str | None = None
    parent_project_id: uuid.UUID | None = None
    # 审批人视角:申请人姓名 + asset 目标所在 folder(审批行跳转/溯源用)
    requester_name: str | None = None
    folder_id: uuid.UUID | None = None


# ─── 本地账号密码登录(#149)──────────────────────────────────────────────
class LocalLoginIn(BaseModel):
    """账号密码登录;username 不强制邮箱格式(拼音 / 工号友好)。"""

    username: str = Field(..., min_length=1, max_length=128)
    password: str = Field(..., min_length=1, max_length=128)


class ChangePasswordIn(BaseModel):
    """修改密码:old_password 必填;new_password 走密码策略校验。"""

    old_password: str = Field(..., min_length=1, max_length=128)
    new_password: str = Field(..., min_length=1, max_length=128)


# ─── 百度网盘备份(方案 §5.2,批次 1:binding + 网盘目录浏览)───────────────────
class BaiduBindingOut(BaseModel):
    """绑定状态;bound = status=='active'(expired/unbound 均提示重新绑定)。"""

    bound: bool
    status: str                       # active / expired / unbound
    expires_at: datetime | None = None
    # UI 显示绑定账号(§4:昵称缺失回退展示 uid);未绑定为 None
    baidu_uid: str | None = None
    nickname: str | None = None


class BaiduAuthorizeUrlOut(BaseModel):
    """oob 授权链接(用户在任意可上网设备浏览器打开,授权后复制授权码回填)。"""

    url: str


class BaiduBindIn(BaseModel):
    """授权码回填(10 分钟内单次有效;只换 token 不存 code)。"""

    code: str = Field(..., min_length=1, max_length=256, description="oob 授权码")


class BaiduBindOut(BaseModel):
    """绑定/重授权成功返回。"""

    bound: bool = True
    status: str = "active"
    expires_at: datetime
    baidu_uid: str
    nickname: str | None = None


class BaiduNetdiskFolderOut(BaseModel):
    """网盘目录树节点(folder=1 时百度仅返回 path,name 由后端从 path 末段派生)。"""

    path: str
    name: str


class BaiduNetdiskFoldersOut(BaseModel):
    """网盘目录懒加载响应;truncated=True 时前端提示「目录过大,分批浏览」。"""

    list: list[BaiduNetdiskFolderOut]
    truncated: bool = False


class BaiduTaskCreateIn(BaseModel):
    """新建备份任务(§5.2):target_folder_id 不传 = 项目根(自动创建承接夹)。"""

    source_dir: str = Field(..., min_length=1, max_length=1024, description="网盘目录绝对路径")
    project_id: uuid.UUID
    target_folder_id: uuid.UUID | None = None


class BaiduTaskOut(BaseModel):
    """任务对象(§3.1/§5.2;queued/eta_seconds 等为接口派生,前端契约对齐 WP2)。"""

    id: uuid.UUID
    source_dir: str
    project_id: uuid.UUID
    project_name: str | None = None
    target_folder_id: uuid.UUID | None = None
    target_folder_name: str | None = None      # NULL = 目标夹已删除(UI 显示「(已删除)」)
    target_auto_created: bool = False
    status: str                                 # enumerating/running/completed/cancelled/failed
    queued: bool = False                        # 派生态派生:活动中但当前无 runner 实际推进
    fail_reason: str | None = None
    cancel_requested: bool = False
    total_files: int | None = None
    done_files: int | None = None
    failed_files: int | None = None
    skipped_files: int | None = None
    cancelled_files: int | None = None
    total_bytes: int | None = None
    done_bytes: int = 0
    speed_bps: int = 0
    eta_seconds: int | None = None              # speed_bps<=0 → None(「估算中」)
    retryable_failed_files: int | None = None   # failed 且 non_retryable=false 行数
    created_at: datetime
    updated_at: datetime


class BaiduTasksPage(BaseModel):
    """任务分页(ORDER BY created_at DESC, id DESC 稳定排序,§5.2)。"""

    items: list[BaiduTaskOut]
    total: int


class BaiduTaskFileOut(BaseModel):
    """manifest 行;target_path = 行级目录回退任务级目录 + rel_path 动态拼装(§5.2)。"""

    id: uuid.UUID
    fs_id: int
    source_path: str
    source_size: int
    rel_path: str
    target_path: str | None = None             # 皆 NULL = 目标已删除(UI 回退源路径+标注)
    status: str
    overwrite: bool = False
    bytes_done: int = 0
    attempts: int = 0
    last_error: str | None = None
    non_retryable: bool = False
    asset_id: uuid.UUID | None = None
    created_at: datetime
    updated_at: datetime


class BaiduTaskFilesPage(BaseModel):
    items: list[BaiduTaskFileOut]
    total: int


class BaiduCancelOut(BaseModel):
    """cancel 202 响应:finalized=true=API 已直接终态化,false=交 worker 消费(§5.2)。"""

    finalized: bool


class BaiduReviveOut(BaseModel):
    """复活型操作(retry-failed/单文件 retry/overwrite)202 响应。"""

    finalized: bool = True
    status: str                                 # 复活后的目标状态(enumerating/running)
