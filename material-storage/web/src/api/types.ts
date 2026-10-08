/** ms-api Pydantic schemas 镜像(只挑前端用到的字段)。*/

export interface Me {
  id: string;
  open_id: string | null;
  union_id: string | null;
  name: string;
  email: string | null;
  organization_id: string | null;
  is_active: boolean;
  is_system_admin: boolean;
  // PR-2: 可新建项目(口径 = is_org_admin ∨ 用户组 project_creator,含系统 admin)。
  // 可选 —— 旧后端无此字段,消费侧用 `?? is_system_admin` 回落。
  is_project_creator?: boolean;
  // #149: 本地密码已设置(可走账号密码登录 / 修改密码)
  password_set: boolean;
  // #149: 首次登录强制改密(仅 password_set=true 时后端才报 true)
  must_change_password: boolean;
}

export interface AdminBrief {
  user_id: string;   // users.id UUID(#148 起,不再用飞书 open_id)
  name: string;
}

// ─── directory(#150 本地用户/组 CRUD)───────────────────────────────────────
export interface DirectoryUser {
  id: string;
  username: string | null;
  name: string;
  email: string | null;
  is_active: boolean;
  must_change_password: boolean;
  created_at: string;
  resigned_at: string | null;
}

export interface DirectoryUserCreateOut extends DirectoryUser {
  temporary_password: string;
}

export interface DirectoryGroup {
  id: string;
  name: string;
  description: string | null;
  member_count: number;
  created_at: string;
  // PR-2: 组级「新建项目」权限回显(新后端定向 read OpenFGA tuple;旧后端无此字段 → undefined 视为 false)
  can_create_project?: boolean;
}

export interface DirectoryGroupMember {
  user_id: string;
  username: string | null;
  name: string;
  email: string | null;
  is_active: boolean;
}

export interface Project {
  id: string;
  code: string;
  name: string;
  description: string | null;
  organization_id: string;
  minio_bucket: string;
  visibility: 'public' | 'private' | 'stealth';
  is_archived: boolean;
  created_at: string;
  admins: AdminBrief[];
  my_roles: ('admin' | 'uploader' | 'downloader' | 'viewer')[];
}

// ─── 项目角色 / initial_grants(方案 §3:创建时直通授权)─────────────────────
export type ProjectRole = 'admin' | 'uploader' | 'downloader' | 'viewer';

/** initial_grants / 权限模板 items 共用的授权条目(kind + id + roles)。*/
export interface GrantEntry {
  kind: 'user' | 'group';
  id: string;            // user: users.id UUID(active) / group: groups.id UUID
  roles: ProjectRole[];
}

// ─── 项目权限模板(方案 §4;require_system_admin)────────────────────────────
export interface GrantTemplateItem extends GrantEntry {
  name: string;          // 解析后的主体名(主体已删/未命中走短 id 兜底)
  missing: boolean;      // true = 主体已删(预填后提交会被建项目存在性校验 400 拦下)
}

export interface GrantTemplate {
  id: string;
  name: string;
  description: string | null;
  is_default: boolean;
  items: GrantTemplateItem[];
}

// ─── GET /api/v1/users(PR-2 起弱门放宽至 project creator)────────────────────
/** /users 精简条目(镜像 users.UserBrief;只回 active 用户,停用走短 id 兜底)。*/
export interface UserBrief {
  id: string;
  username: string | null;
  open_id: string | null;
  union_id: string | null;
  name: string;
  email: string | null;
}

// ─── 默认模板直通 / 刷新默认权限(PR-3)─────────────────────────────────────
/** apply-default 单项目结果:成功项有 applied / skipped_stale,失败项只有 error(两种形状勿混用)。*/
export interface ApplyDefaultProjectResult {
  project_id: string;
  applied?: number;        // 实际补写的授权条目数(read 差集后,幂等跳过不计)
  skipped_stale?: number;  // 默认模板中主体已删/停用而跳过的条目数
  error?: string;          // 仅失败项有(部分成功语义:单项目失败不阻塞其余)
}

/** POST /api/v1/admin/grant-templates/apply-default 响应。*/
export interface ApplyDefaultResult {
  results: ApplyDefaultProjectResult[];
  total_applied: number;
  total_skipped: number;
}

export interface Folder {
  id: string;
  project_id: string;
  parent_folder_id: string | null;
  name: string;
  minio_prefix: string;
  is_sensitive: boolean;
  created_at: string;
  my_can_view?: boolean;
  my_can_download?: boolean;
  my_can_upload?: boolean;
  my_can_admin?: boolean;
}

export interface Asset {
  id: string;
  folder_id: string;
  filename: string;
  minio_bucket: string;
  minio_key: string;
  etag: string | null;
  minio_version_id: string | null;
  size_bytes: number;
  content_type: string | null;
  created_at: string;
  // 软删时间;普通列表恒 null,回收站列表有值
  deleted_at?: string | null;
  // #151: 手工标签 + 备注(盲搜素材)
  user_labels: string[];
  notes: string | null;
  tags?: {
    thumbnail_key?: string;
    thumbnail_width?: number;
    thumbnail_height?: number;
    thumbnail_failed?: string;
    // livp 实况短片(ffmpeg 转码的 H.264);预览走 live-preview-url 签名
    live_video_key?: string;
    [k: string]: unknown;
  };
}

/** #151 盲搜结果 = Asset + 所在 folder / project 上下文(跨 folder 展示用)。*/
export interface SearchResult extends Asset {
  folder_name: string;
  project_id: string;
  project_name: string;
}

/** 回收站列表 = items 分页窗口(上限 500)+ total 全量计数(角标/清空提示用)。*/
export interface TrashAssets {
  items: Asset[];
  total: number;
}

// ─── 批量文件名前缀(PR-1:POST /api/v1/assets/batch-prefix)────────────────
export type BatchPrefixAction = 'add' | 'remove';

/** 批量改名结果(尽力而为 + 对账:renamed + skipped 恒等于提交的 asset_ids 数)。*/
export interface AssetBatchPrefixResult {
  renamed: number;
  skipped: number;
  // 键固定 ASCII,前端做中文映射(见 BatchPrefixModal)
  skipped_reasons: {
    too_long: number;         // add:加前缀后超长
    no_match: number;         // remove:不以该前缀开头
    already_prefixed: number; // add:已带该前缀
    empty_result: number;     // remove:剥离后为空串
    deleted: number;          // 已删除/不存在
  };
}

/** 文件夹文件列表 = items 分页窗口(服务端分页)+ total 全量计数(分页器用)。*/
export interface AssetList {
  items: Asset[];
  total: number;
}

export type ApprovalStatus = 'pending' | 'approved' | 'rejected' | 'revoked' | 'expired';
export type ApprovalAction = 'download' | 'access';
// #129: 加 folder 支持精细化临时 download 申请
export type ApprovalTargetType = 'sensitive_folder' | 'asset' | 'project' | 'folder';

export interface Approval {
  id: string;
  applicant_user_id: string;
  target_type: ApprovalTargetType;
  target_id: string;
  action: ApprovalAction;
  duration_seconds: number | null;
  reason: string;
  status: ApprovalStatus;
  feishu_instance_code: string | null;
  approver_user_id: string | null;
  decided_at: string | null;
  decision_note: string | null;
  created_at: string;
  // #136/#137: backend enrich — 资源名 + 父项目(folder/asset 导航用)
  target_name?: string | null;
  parent_project_id?: string | null;
  // 审批人视角:申请人姓名 + asset 目标所在 folder(跳转/溯源用)
  requester_name?: string | null;
  folder_id?: string | null;
}

export interface DownloadLink {
  url: string;
  expires_in: number;
  is_sensitive: boolean;
}

// ─── share(iter3;#154:飞书 IM 推送下线,纯链接分享)──────────────────────────
export interface ShareCreateOut {
  token: string;
  landing_url: string;
  expires_at: string;
}

export interface ShareResolve {
  kind: 'asset' | 'folder';
  target_id: string;
  sharer_name: string | null;
  expires_at: string;
  asset?: { id: string; filename: string; size_bytes: number; content_type: string | null };
  download_url?: string;
  download_expires_in?: number;
  folder?: { id: string; project_id: string; name: string; is_sensitive: boolean };
}

// ─── notifications(#153)─────────────────────────────────────────────────────
export type NotificationKind =
  | 'approval_pending'
  | 'approval_decided'
  | 'folder_invite'
  | 'share';

export interface NotificationItem {
  id: string;
  kind: NotificationKind | string;
  title: string;
  body: string | null;
  link: string | null;
  read_at: string | null;
  created_at: string;
}

export interface NotificationsList {
  items: NotificationItem[];
  total: number;
  unread_count: number;
}
