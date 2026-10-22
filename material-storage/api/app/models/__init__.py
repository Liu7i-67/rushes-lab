"""Pydantic API I/O models — Phase B-2 first batch。"""
from __future__ import annotations

import re
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


class ArtistAccountIn(BaseModel):
    """内嵌开通艺人账号(组长建项目同步建号,方案 §4.1)。字段约束与 UserCreateIn 同款。"""

    username: str = Field(..., min_length=2, max_length=64, pattern=r"^[a-zA-Z0-9._-]+$")
    name: str = Field(..., min_length=1, max_length=128)

    @field_validator("name")
    @classmethod
    def _name_format(cls, v: str | None) -> str | None:
        # 复用 UserCreateIn 同款校验器(:482-493):strip + 拒绝全空白,
        # 防止纯空格姓名过 422
        return _validate_name_format(v)


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
    # 目录模板(可选;方案 §4.2):不传 / null = 现行为完全不变(零回归);
    # 传入则在建项目后把模板条目物化为 folders(模板不存在 / 跨 org → 400)
    folder_template_id: uuid.UUID | None = None
    # 内嵌开通艺人账号(可选;艺人账号内嵌方案 §4.1):不传 / null = 纯项目创建
    # (现状行为);传入则在项目建成后同步开通账号并入「艺人」组、授项目三角色
    artist_account: ArtistAccountIn | None = None


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


class ArtistAccountCreatedOut(BaseModel):
    """内嵌建号一次性回显(方案 D10):temporary_password 只在 POST /projects 201
    响应体回显,不落 audit / log(照 UserCreateOut「只回显一次」注释惯例)。"""

    user_id: uuid.UUID
    username: str
    name: str
    temporary_password: str


class ProjectCreatedOut(ProjectOut):
    """POST /projects 201 专用响应(方案 D10):与 GET 列表/详情的 ProjectOut 分离,
    artist_account 仅创建时填充;不带 artist_account 时序列化为恒 null 键(结构兼容、
    无功能影响;勿用 response_model_exclude_none —— 会连 description 等既有可空键
    一并剥掉,反而改变现状响应形状)。"""

    artist_account: ArtistAccountCreatedOut | None = None


# ─── 目录模板(2026-10-10,方案 §4.1)─────────────────────────────────────────
class FolderTemplateEntryIn(BaseModel):
    """目录模板条目入参:一条目录相对路径,如 `素材/视频/原始`(无前后 `/`)。

    结构 / 长度 / 深度校验在路由层 `_validate_entry_paths`(422 指明第几条、
    何因);strip 后的值才是校验与持久化对象(路由层负责,Pydantic 不归一化)。
    """

    path: str = Field(..., min_length=1, max_length=600)


class FolderTemplateIn(BaseModel):
    """POST /admin/folder-templates 入参;entries 1..200 条(空模板无意义,§11)。"""

    name: str = Field(..., min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    entries: list[FolderTemplateEntryIn] = Field(..., min_length=1, max_length=200)


class FolderTemplateEntryOut(BaseModel):
    path: str


class FolderTemplateOut(BaseModel):
    """模板出参(列表项与单对象同形);带全量 entries 供 NewProjectModal 预览。"""

    id: uuid.UUID
    name: str
    description: str | None
    entry_count: int
    entries: list[FolderTemplateEntryOut]


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


class AssetBatchMoveIn(BaseModel):
    """批量移动资产(W6 一期:项目内移动,方案 §6.2)。

    asset_ids ≤1000(batch-prefix 同上限);一期不收 cross_project 字段 ——
    跨项目是物理迁移(换 bucket),二期单独拍板,一期端点显式断言整批恰属
    一个项目且 target_folder 同项目(漏断言会把项目内端点变成事实跨项目入口)。
    """

    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=1000)
    target_folder_id: uuid.UUID


class AssetBatchMoveSkipOut(BaseModel):
    """单资产跳过条目(reason 固定 ASCII 枚举,前端中文映射,batch-prefix 同款):
    duplicate_location = 已在目标夹;duplicate_filename = 目标夹已有同名未软删
    资产(决策 15,与百度导入 (folder_id, filename) 查重口径对齐,排除软删);
    deleted = 已软删或不存在(快照查不到)。"""

    asset_id: uuid.UUID
    reason: str


class AssetBatchMoveOut(BaseModel):
    """尽力而为 + 结果报告:对账恒等式 moved_count + len(skipped) + len(fga_pending)
    = 提交 asset_ids 去重后条数。fga_pending = DB 已迁入目标夹但 OpenFGA parent
    tuple 交换失败(重试后仍败,不 500 掩盖,方案 §6.2)。"""

    moved_count: int
    skipped: list[AssetBatchMoveSkipOut] = []
    fga_pending: list[uuid.UUID] = []


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
    带 locate 查询参数时返回 locate_index = 目标在与列表同排序
    (created_at DESC, id DESC,未软删,本夹)下的 0 基全量序号;
    locate 缺省 / 目标不存在 / 已软删 / 他夹 → null(不区分原因)。
    """

    items: list[AssetOut]
    total: int
    locate_index: int | None = None


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
    # 整棵子树(含本夹直接)活跃文件数(deleted_at IS NULL;软删不计)——
    # 仅 list_folders 端点回填,create/get 单条响应均为默认 0,单条消费方勿依赖
    # (folder-subtree-file-badge 方案 §3.1/§3.4;口径走 parent_folder_id 结构链,
    # 禁 minio_prefix 前缀匹配 §2)
    subtree_file_count: int = 0
    # 本夹直属(不含子树)活跃文件数(同 deleted_at IS NULL 口径)——与
    # subtree_file_count 同惯例:仅 list_folders 端点回填(direct GROUP BY 直出),
    # create/get 单条响应恒默认 0;app 据此区分「N 项 / 子级 M 项」两级展示
    # (2026-10-22 app-polish-2 K1;子树数只作弱提示不再作主数字)
    direct_file_count: int = 0
    # 当前 user 对本 folder 的有效权限(派生 can_*)— get_folder 时填充
    my_can_view: bool = False
    my_can_download: bool = False
    my_can_upload: bool = False
    my_can_admin: bool = False
    # 组级「删除文件/文件夹」开关生效态(2026-10-16 F8)= is_org_file_deleter(当前
    # user)且 folder#can_view(**裸 FGA check,不含 public 浏览直通,决策 #9**,
    # 与四个删除守门的组开关分支同口径)且非 sensitive;**不含**系统管理员直通
    # (系统 admin 的删除入口由 my_can_admin 闸门表达,本字段只反映组开关授权)。
    # 仅 get_folder 端点回填(与 my_can_* 同惯例),列表/创建响应为默认 False
    my_delete_grant: bool = False


class FolderInviteIn(BaseModel):
    # subject 二选一 — 任选其一传(#154:department 轴写入下线,ADR-0007):
    user_id: uuid.UUID | None = None      # 单人 user(users.id UUID)
    group_id: str | None = None           # 本地用户组(groups.id UUID)
    # 邀请等级(v4 新增,旧调用方默认 viewer)
    level: str = Field("viewer", pattern=r"^(viewer|downloader)$")
    duration_seconds: int | None = Field(None, ge=60, le=365 * 24 * 3600,
                                         description="None=永久邀请;int=时间限定")


class FolderUpdateIn(BaseModel):
    """PATCH /folders/{id} 入参(W4/W5 目录改名 / 层级移动,需求 §3.5)。

    name 与 parent_folder_id 至少传一;「是否传了」由路由以 model_fields_set 判定
    (缺省 ≠ 显式 null):parent_folder_id **显式传 null** = 移为项目一级
    (前端目标集合含项目根);name 显式传 null 一律 422(不改名请省略字段)。
    """

    name: str | None = Field(None, min_length=1, max_length=255)
    parent_folder_id: uuid.UUID | None = Field(
        None, description="新父文件夹 id;显式 null = 移为项目一级",
    )


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
    """网盘目录树条目(目录 + 文件两态;文件行前端灰显不可选,保持「选目录建任务」语义)。

    目录:size_bytes=None,path 即完整路径(现状口径),name 从 path 末段派生;
    文件:size_bytes 恒有值(百度缺省按 0),path 由路由层按目录 + server_filename
    显式拼接(文件条目的 path 字段实测亦为完整路径,与枚举侧口径一致;拼接是
    为了显式自证、不依赖该字段口径)。
    """

    path: str
    name: str
    is_dir: bool = True
    size_bytes: int | None = None


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
    # W1 创建时跨项目路径预警:目标前缀与其他项目文件夹重叠时回填对方项目名
    # (≤3,rtrim('/') 归一比较,不过滤归档/软删)。仅创建响应由 handler 后赋值
    # 回填,列表/详情侧不落库、保持默认(见 routers/baidu_backup.py create_task)。
    cross_project_prefix_overlap: bool = False
    overlap_project_names: list[str] | None = None
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


# ─── admin directory 用户管理(2026-10-10 F3/F4/F5,B2 集中定义)────────────────
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _validate_email_format(value: str | None) -> str | None:
    """email 轻量格式校验(D6:仅格式,不发验证邮件;不引 email-validator 新依赖)。

    None 放行(未填 / 显式清空);空白串视为未填归一成 None(兼容旧客户端
    email="" 的创建行为);其余须形如 local@domain.tld 的宽松格式。
    """
    if value is None:
        return None
    v = value.strip()
    if not v:
        return None
    if not _EMAIL_RE.fullmatch(v):
        raise ValueError("email 格式不正确")
    return v


def _validate_name_format(value: str | None) -> str | None:
    """name 轻量校验(契约「提供则须非空」,POST/PATCH 同口径)。

    None 放行(PATCH 未传 = 不改);strip 后为空(空串 / 全空白)→
    ValueError(422);其余返回去首尾空白后的值入库。
    """
    if value is None:
        return None
    v = value.strip()
    if not v:
        raise ValueError("name 不能为空 / 全空白")
    return v


class DirectoryUserOut(BaseModel):
    """admin 目录用户条目(列表分页项 / 编辑响应基类;不泄露 password_hash)。"""

    id: uuid.UUID
    username: str | None
    name: str
    email: str | None
    is_active: bool
    must_change_password: bool
    created_at: datetime
    resigned_at: datetime | None
    # W1:登录锁定状态,**只反映 user 维度**(IP 维度命中时登录照样 429 但不在此
    # 显示,前端 pill 文案需标注「用户名维度」);列表端点批量 pipeline MGET 三形态
    # 锁 key,详情/建号/编辑响应单查真实值;锁定状态以实时查 Redis 为准,不从审计推断
    login_locked: bool = False


class UserCreateIn(BaseModel):
    """POST /admin/directory/users 入参。

    username 建后即定(D7);email 轻格式校验(D6);group_ids=F3 建用户同时
    入组(默认 [],≤50 对齐权限模板上限 D9),组存在性在路由内先全量校验
    (任一无效 → 422,用户不创建,F3.3 原子)。
    """

    username: str = Field(..., min_length=2, max_length=64,
                          pattern=r"^[a-zA-Z0-9._-]+$",
                          description="登录名:拼音/工号友好,不强制邮箱格式")
    name: str = Field(..., min_length=1, max_length=128)
    email: str | None = Field(None, max_length=255)
    # ≤50 上限(D9)在路由层校验:契约要求超限 422 detail 含 invalid_group_ids,
    # Pydantic max_length 的校验错误文案不带该标识
    group_ids: list[uuid.UUID] = Field(default_factory=list)

    @field_validator("name")
    @classmethod
    def _name_format(cls, v: str | None) -> str | None:
        return _validate_name_format(v)

    @field_validator("email")
    @classmethod
    def _email_format(cls, v: str | None) -> str | None:
        return _validate_email_format(v)


class UserUpdateIn(BaseModel):
    """PATCH /admin/directory/users/{id} 入参(§3):全部可选,缺省=不改。

    name 提供则须非空;email 显式 null=清空(D6,路由以 model_fields_set
    区分「未传」与「传 null」);group_ids 全量同步终态(D3,以勾选集为准
    diff 加/移);username 不可改(D7 建后即定)。
    """

    name: str | None = Field(None, min_length=1, max_length=128)
    email: str | None = Field(None, max_length=255)
    # ≤50 上限(D9)同 UserCreateIn:路由层校验,422 带 invalid_group_ids 标识
    group_ids: list[uuid.UUID] | None = Field(None)

    @field_validator("name")
    @classmethod
    def _name_format(cls, v: str | None) -> str | None:
        return _validate_name_format(v)

    @field_validator("email")
    @classmethod
    def _email_format(cls, v: str | None) -> str | None:
        return _validate_email_format(v)


class DirectoryUserDetailOut(DirectoryUserOut):
    """§2 用户详情 = DirectoryUserOut + 所属组(group_names 与 group_ids 同序)。"""

    group_ids: list[uuid.UUID]
    group_names: list[str]


class DirectoryUsersPageOut(BaseModel):
    """§4 用户列表分页(D4 破坏性改版,前端同批改);total=同条件(q/is_active)count。"""

    items: list[DirectoryUserOut]
    total: int
    limit: int
    offset: int
