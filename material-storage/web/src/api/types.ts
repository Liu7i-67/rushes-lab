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
  // 项目逻辑删除(§10):可删除项目(口径 = is_org_admin ∨ 用户组 project_deleter,含系统 admin)。
  // 可选 —— 旧后端无此字段,消费侧用 `?? is_system_admin` 回落。
  is_project_deleter?: boolean;
  // 目录模板(方案 §3.3):可管理目录模板(口径 = is_org_admin ∨ 用户组 folder_template_manager,
  // 含系统 admin)。可选 —— 旧后端无此字段,消费侧用 `?? is_system_admin` 回落。
  is_folder_template_manager?: boolean;
  // 艺人账号内嵌(方案 §4.4):新建项目弹窗「艺人账号」区闸门(口径 = is_org_admin ∨
  // 用户组 artist_account_creator,含系统 admin)。可选 —— 旧后端无此字段,消费侧用
  // `?? is_system_admin` 回落(照 is_project_creator 惯例)。
  is_artist_account_creator?: boolean;
  // 删除文件/文件夹权限可授予用户组(2026-10-16):可删除文件与文件夹(口径 =
  // is_system_admin ∨ 用户组 file_deleter,不含 org admin 直通)。可选 —— 旧后端无
  // 此字段,消费侧用 `?? false` 回落(与 is_project_* 不同:旧后端本就无组级删除
  // 授权能力,回落 false 而非 is_system_admin;当前删除闸门实际走 Folder.my_delete_grant)。
  is_file_deleter?: boolean;
  // #149: 本地密码已设置(可走账号密码登录 / 修改密码)
  password_set: boolean;
  // #149: 首次登录强制改密(仅 password_set=true 时后端才报 true)
  must_change_password: boolean;
  // 百度网盘备份(方案 §5.2):功能开关,控制用户菜单入口显隐
  baidu_backup_enabled: boolean;
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
  // W1(2026-10-17):登录锁定态 —— 列表端点批量 MGET 三形态 username/email/name 的
  // Redis user 锁 key,**只反映 user 维度**(IP 维度命中时此处不置位,登录仍会 429)。
  // 「解锁」行按钮与「登录已锁定」pill 依此渲染。可选 —— 旧后端无此字段,消费侧
  // falsy 回落(不渲染解锁入口,同 is_project_creator 惯例)。
  login_locked?: boolean;
}

export interface DirectoryUserCreateOut extends DirectoryUser {
  temporary_password: string;
}

// §4:用户列表分页返回(total = 同 q/is_active 条件 count;破坏性变更,D4)
export interface DirectoryUsersPage {
  items: DirectoryUser[];
  total: number;
  limit: number;
  offset: number;
}

// §2:用户详情(编辑弹窗回显;group_names 与 group_ids 同序)
export interface DirectoryUserDetail extends DirectoryUser {
  group_ids: string[];
  group_names: string[];
}

// §3:PATCH 用户(全部可选键,缺省=不改;email 显式 null = 清空;group_ids 全量同步终态)
export interface DirectoryUserUpdateIn {
  name?: string;
  email?: string | null;
  group_ids?: string[];
}

export interface DirectoryGroup {
  id: string;
  name: string;
  description: string | null;
  member_count: number;
  created_at: string;
  // PR-2: 组级「新建项目」权限回显(新后端定向 read OpenFGA tuple;旧后端无此字段 → undefined 视为 false)
  can_create_project?: boolean;
  // §5: 组级「删除项目」权限回显(仿 can_create_project;旧后端无此字段 → undefined 视为 false)
  can_delete_project?: boolean;
  // 目录模板(方案 §4.3):组级「管理目录模板」权限回显(仿 can_create_project;旧后端无此字段 → undefined 视为 false)
  can_manage_folder_templates?: boolean;
  // 艺人账号(方案 §4.3):组级「新建项目时创建艺人账号」权限回显(仿 can_create_project;旧后端无此字段 → undefined 视为 false)
  can_create_artist_account?: boolean;
  // 删除文件/文件夹权限可授予用户组(2026-10-16):组级「删除文件与文件夹」权限回显
  // (仿 can_delete_project,真实态存 OpenFGA file_deleter tuple;旧后端无此字段 → undefined 视为 false)
  can_delete_files?: boolean;
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

// ─── 艺人账号内嵌(方案 §4.1:POST /api/v1/projects 扩展)──────────────────────
/** 内嵌开通艺人账号入参(镜像 ArtistAccountIn;字段约束与 UserCreateIn 同款,服务端复检)。*/
export interface ArtistAccount {
  username: string;
  name: string;
}

/** 一次性回显的艺人账号创建结果(照 UserCreateOut「只回显一次」语义;不落 audit/log)。*/
export interface ArtistAccountCreated {
  user_id: string;
  username: string;
  name: string;
  temporary_password: string;
}

/** POST /projects 创建响应 = Project + artist_account(GET 列表/详情仍为 Project,不带该字段)。*/
export interface ProjectCreated extends Project {
  // 不带 artist_account 提交时后端序列化为 null(结构兼容键)
  artist_account?: ArtistAccountCreated | null;
}

/** POST /api/v1/projects 请求体(原 useCreateProject 内匿名内联类型,本次提名导出)。*/
export interface CreateProjectBody {
  code: string;
  name: string;
  description?: string;
  organization_id?: string;
  minio_bucket: string;
  admin_user_id: string;   // 必填:指派项目 admin(可以是自己;users.id UUID)
  initial_grants?: GrantEntry[];   // 可选:创建时同时授权(方案 §3;不传/空 = 现行为)
  folder_template_id?: string;     // 目录模板(方案 §4.2):可选;不选不传 = 与现状一致
  // 艺人账号内嵌(方案 §4.1):可选;不传 = 纯项目创建(现状行为)
  artist_account?: ArtistAccount;
}

// ─── 项目逻辑删除(§7:GET /api/v1/projects/deleted)──────────────────────────
/** 已删除项目条目(深隐藏+可恢复;deleted_by_name 为后端解析的操作人姓名)。*/
export interface DeletedProject {
  id: string;
  code: string;
  name: string;
  description: string | null;
  visibility: Project['visibility'];
  deleted_at: string;
  deleted_by: string | null;
  deleted_by_name: string | null;
}

/** 已删除项目分页窗口。*/
export interface DeletedProjectsPage {
  items: DeletedProject[];
  total: number;
  limit: number;
  offset: number;
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

// ─── 目录模板(方案 §4.1;/api/v1/admin/folder-templates)─────────────────────
/** 目录模板条目:项目根下的相对路径(如 `素材/视频/原始`;无前后 `/`)。*/
export interface FolderTemplateEntry {
  path: string;
}

/** 目录模板(列表项与 POST/PATCH 返回同形;entries 全量返回供树预览)。*/
export interface FolderTemplate {
  id: string;
  name: string;
  description: string | null;
  entry_count: number;
  entries: FolderTemplateEntry[];
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
  // 删除文件/文件夹权限可授予用户组(2026-10-16):组织级 file_deleter 开关对当前用户
  // 生效态(口径 = is_org_file_deleter ∧ folder#can_view ∧ 非 sensitive,不含系统
  // admin 直通)。删除文件/删除文件夹/回收站闸门用它与 my_can_admin 取或;可选 ——
  // 旧后端无此字段,消费侧用 `?? false` 回落。
  my_delete_grant?: boolean;
  // 子树活跃文件计数(整棵子树含本夹直接,deleted_at IS NULL):仅 GET /folders 列表端点
  // 回填,create/get 单条响应恒 0。>0 → 侧栏文件夹图标实心。可选 —— 旧后端无此字段,
  // 消费侧用 `?? 0` 回落。
  subtree_file_count?: number;
  // 直属活跃文件计数(不含子树):仅 GET /folders 列表端点回填,create/get 单条响应
  // 恒 0。2026-10-22 文件夹计数两端统一:>0 才在行内显示「N 项」;=0 不显示任何
  // 数字(即使子树有文件)。可选 —— 旧后端无此字段,消费侧用 `?? 0` 回落。
  direct_file_count?: number;
}

// ─── W4/W5:目录改名 / 移动(六项优化 2026-10-17;PATCH /api/v1/folders/{id})──
/** PATCH /folders/{id} 请求体(至少传一项;改名与移动同端点,前端拆两个入口)。
 *  parent_folder_id 显式 null = 移为项目一级(项目根);sensitive 源禁移动(后端 enforce)。*/
export interface FolderUpdateIn {
  name?: string;
  parent_folder_id?: string | null;
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

// ─── W6 一期:文件批量移动(六项优化 2026-10-17;POST /api/v1/assets/batch-move)──
/** 单条跳过明细(reason 键固定 ASCII:duplicate_location / duplicate_filename,前端中文映射)。*/
export interface AssetBatchMoveSkipped {
  asset_id: string;
  reason: string;
}

/** 批量移动结果(对账恒等式:moved_count + skipped 条数 + fga_pending 条数 = 提交数)。
 *  fga_pending = DB 已移动但 FGA parent tuple 交换失败的资产 id(后台幂等巡检兜底,
 *  页面明示「权限同步延迟」;HTTP 恒 200,不以 500 掩盖)。*/
export interface AssetBatchMoveResult {
  moved_count: number;
  skipped: AssetBatchMoveSkipped[];
  fga_pending: string[];
}

/** 文件夹文件列表 = items 分页窗口(服务端分页)+ total 全量计数(分页器用)。*/
export interface AssetList {
  items: Asset[];
  total: number;
  // 盲搜跳转定位(方案 §2.1):locate 目标在与列表同排序(created_at DESC, id DESC)
  // 下的 0 基全量序号,不受 limit/offset 窗口影响。locate 缺省 / 目标不存在、已软删、
  // 他夹 → null(不区分原因)。可选 —— 旧后端无此键,消费侧按「键存在且为 number」
  // 判读(FolderDetailPage 失败守卫②,兼容混合部署窗口)。
  locate_index?: number | null;
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

// ─── 百度网盘备份(方案 §5.2;/api/v1/baidu/backup/*)─────────────────────────
export type BaiduBindingStatus = 'active' | 'expired' | 'unbound';

/** GET /backup/binding → 绑定状态(§5.2 三字段;身份字段为方案 §5.1 uinfo 落库的展示扩展) */
export interface BaiduBinding {
  bound: boolean;
  status: BaiduBindingStatus;
  expires_at: string | null;
  // bind 时 uinfo 落库的百度账号身份;nickname 缺失时 UI 回退 uid。可选:兼容仅含三字段的响应
  nickname?: string | null;
  baidu_uid?: string | null;
}

/** GET /backup/netdisk/folders → 网盘条目(目录+文件,懒加载一层;排序后端做:目录前文件后) */
export interface BaiduNetdiskFolder {
  path: string;              // 绝对路径(以 / 开头;文件为父目录+文件名拼好的完整路径)
  name: string;
  is_dir: boolean;           // true=目录(可展开可选);false=文件(仅展示不可选)
  size_bytes: number | null; // 文件字节数;目录为 null
}

/** GET /backup/netdisk/folders 完整响应;truncated=聚合分页未取尽(仅显示部分内容) */
export interface BaiduNetdiskFoldersOut {
  list: BaiduNetdiskFolder[];
  truncated: boolean;
}

export type BaiduTaskStatus = 'enumerating' | 'running' | 'completed' | 'cancelled' | 'failed';

export interface BaiduBackupTask {
  id: string;
  source_dir: string;                    // 网盘所选目录绝对路径
  project_id: string;
  project_name?: string | null;          // 列表/明细展示用(后端 enrich)
  target_folder_id: string | null;       // 被删后置 NULL(SET NULL),UI 显示「(已删除)」
  target_folder_name?: string | null;    // 后端 enrich;NULL=目标夹已删除
  target_auto_created?: boolean;         // true=自动创建的承接夹(项目根语义)
  // 创建时刻检测:目标前缀与其他项目文件夹重叠(rtrim 归一比较,方案 W1)。创建响应恒返回;
  // 列表/详情侧为默认值 false/null(不回填),前端仅在创建流读用
  cross_project_prefix_overlap: boolean;
  overlap_project_names: string[] | null; // 命中时的对方项目名(≤3,无 ORDER BY);无命中为 null
  status: BaiduTaskStatus;
  // 接口派生字段(§3.1):活动中但当前无 runner 实际推进(排队中)——true 时状态 Tag 显示「排队中」
  queued?: boolean;
  fail_reason: string | null;
  total_files: number | null;
  done_files: number | null;
  failed_files: number | null;
  skipped_files: number | null;
  cancelled_files?: number | null;
  total_bytes: number | null;
  done_bytes: number;
  speed_bps: number;
  // 接口层按 speed_bps 计算;speed_bps<=0 → null,UI 显示「估算中」(§6)
  eta_seconds: number | null;
  // failed 任务中 non_retryable=false 的行数(「全部重试失败」按钮可用性;缺失时回退 failed_files>0)
  retryable_failed_files?: number | null;
  created_at: string;
  updated_at: string;
}

export interface BaiduTasksPage {
  items: BaiduBackupTask[];
  total: number;
}

export type BaiduFileStatus =
  | 'pending'
  | 'skipped_exists'
  | 'importing'
  | 'success'
  | 'failed'
  | 'cancelled';

export interface BaiduTaskFile {
  id: string;
  fs_id: number;
  source_path: string;                   // 原网盘绝对路径
  source_size: number;
  rel_path: string;                      // 相对 source_dir
  // 接口拼装的预计导入路径;NULL=目标夹已删除(UI 回退源路径并标注「(目标已删除)」)
  target_path: string | null;
  status: BaiduFileStatus;
  last_error: string | null;
  non_retryable: boolean;                // 结构性失败:重试置灰、retry-failed 排除
  overwrite?: boolean;                   // 覆盖导入标记(清除-再导入)
  attempts: number;
}

export interface BaiduTaskFilesPage {
  items: BaiduTaskFile[];
  total: number;
}

/** 复活型操作(retry-failed/单文件 retry/overwrite/random-suffix)202 响应。 */
export interface BaiduReviveOut {
  finalized: boolean;                    // true=已直接复位派发,false=交 worker 消费
  status: string;                        // 复活后的目标任务状态(enumerating/running)
}

// ─── 管理员备份任务视图(W3;/api/v1/admin/baidu-backup)───────────────────────
// 管理观测面看存量事实:不随 baidu_backup_enabled 门控;require_system_admin。
// 后端契约见 docs/qdev/2026-10-14-baidu-admin-observability.md 接口定义①②③。

/** 任务归属用户(join users;username 可空 —— 飞书账号无本地用户名,name NOT NULL)。 */
export interface AdminBaiduTaskUser {
  id: string;
  username: string | null;
  name: string;
}

/** 任务归属项目(join projects;FK RESTRICT,项目行总在)。 */
export interface AdminBaiduTaskProject {
  id: string;
  name: string;
}

/** 目标文件夹(夹已删 → null,target_folder_id SET NULL)。 */
export interface AdminBaiduTaskFolder {
  id: string;
  name: string;
}

/** GET /admin/baidu-backup/tasks 列表项(聚合列 NULL 序列化 0 兜底;fail_reason 截 200)。 */
export interface AdminBaiduTask {
  id: string;
  user: AdminBaiduTaskUser;
  status: BaiduTaskStatus;
  source_dir: string;
  project: AdminBaiduTaskProject;
  target_folder: AdminBaiduTaskFolder | null;
  total_files: number;
  done_files: number;
  failed_files: number;
  skipped_files: number;
  cancelled_files: number;
  total_bytes: number;
  done_bytes: number;
  created_at: string;
  updated_at: string;
  fail_reason: string | null;
  cancel_requested: boolean;
}

export interface AdminBaiduTasksPage {
  items: AdminBaiduTask[];
  total: number;
}

/** 详情里的当前绑定行(baidu_bindings;baidu_uid 为该表列名)。 */
export interface AdminBaiduTaskBinding {
  id: string;
  baidu_uid: string;
  status: BaiduBindingStatus;
}

/** GET /admin/baidu-backup/tasks/{id} = TaskItem + 绑定快照/当前绑定/取消原因/调度观测。 */
export interface AdminBaiduTaskDetail extends AdminBaiduTask {
  bound_baidu_uid: string | null;      // 创建时从 binding 快照(换绑甄别锚点)
  binding: AdminBaiduTaskBinding | null;
  cancel_reason: string | null;        // user_cancel / binding_replaced
  // ── 调度观测字段(BaiduBackupTask 列,均可空)──
  retry_count: number;                 // 复活次数
  enum_done: boolean;                  // 枚举完成标记(复活时复位 false 重枚举)
  dispatched_at: string | null;        // 最近派发时刻(NULL=从未派发)
  round_started_at: string | null;     // 轮起点(两次复活之间;48h 判停依据)
  lease_until: string | null;          // 租约到期(即心跳)
  runner_id: string | null;
}

/** GET /admin/baidu-backup/tasks/{id}/files 文件明细行(last_error 截 200)。 */
export interface AdminBaiduTaskFile {
  id: string;
  source_path: string;                   // 原网盘绝对路径
  rel_path: string;                      // 相对 source_dir
  status: BaiduFileStatus;
  bytes_done: number;
  attempts: number;
  non_retryable: boolean;
  last_error: string | null;
  asset_id: string | null;
  updated_at: string;
}

export interface AdminBaiduTaskFilesPage {
  items: AdminBaiduTaskFile[];
  total: number;
}

// ─── 审计(W2b;GET /api/v1/admin/audit)─────────────────────────────────────
/** 审计事件行(原 AdminAuditPage 页内接口上移;消费方:AdminAuditPage)。
 *  W2b(2026-10-17)补名:target_project_name / target_asset_filename 由后端按页内
 *  target_asset_id 集合批量反查回填;purge 后 asset 行已删 → null(前端回落显示
 *  UUID 片段,不报错)。可选 —— 旧后端无此字段,消费侧空值回落。 */
export interface AuditEvent {
  id: string;
  event_type: string;
  event_time: string;
  actor_user_id: string | null;
  actor_name: string | null;
  actor_open_id: string | null;
  target_asset_id: string | null;
  target_project_id: string | null;
  // W2b 反查补名(LEFT JOIN 口径,查不到回 null)
  target_asset_filename?: string | null;
  target_project_name?: string | null;
  target_minio_key: string | null;
  request_ip: string | null;
  details: Record<string, unknown>;
  // C 包(2026-10-19):UA 裸列透传(写入端已截 512,展示端前端再截断)
  user_agent?: string | null;
  // C 包(2026-10-19):details 白名单键批量补名(key=details 键名,value=纯显示名,
  // 不带类型后缀;查不到/垃圾值不进 dict)。可选 —— 旧后端无此字段,消费侧回落现行为。
  resolved_names?: Record<string, string>;
}
