/**
 * 用户可见的后端枚举 → 中文 label 集中映射(#118)。
 *
 * 原则:
 * - 只换"用户在 UI 上肉眼看到"的展示,**不动**底层数据流(契约 / API / CSV / audit details / mono ID)
 * - 缺 key 时直接返回 raw token 不报错 — 兼容后端新增 event_type 没同步加 label 的情况
 * - keep mono 字体不变(advisor 决策:跟现有视觉一致性 > 中文渲染纯净)
 *
 * 后端 event_type 全集来自 `grep event_type= ... | sort -u`(2026-05-18),共 22 种
 */

export const EVENT_TYPE_LABEL: Record<string, string> = {
  access_denied: '访问被拒',
  approval_card_updated: '审批卡片已更新',
  approval_notified: '审批通知已发送',
  approval_state_changed: '审批状态变更',
  approval_submitted: '审批申请已提交',
  asset_deleted: '文件删除',
  asset_restored: '文件恢复',
  asset_purged: '文件彻底删除',
  // 后端 event_type 实际为点号键(assets.py:asset.tag_updated / asset.batch_renamed);
  // 历史行一直按点号落库,这里补点号键修正展示(后端不动,避免历史行跨值)
  'asset.tag_updated': '文件标签更新',  // #151
  'asset.batch_renamed': '文件批量改名',  // PR-1 批量文件名前缀
  asset_tag_updated: '文件标签更新',  // 旧键与后端点号键错位,保留兼容(后端不产此值)
  download: '下载',
  download_denied: '下载被拒',
  folder_created: '文件夹创建',
  folder_deleted: '文件夹删除',
  folder_grant_added: '文件夹权限授予',
  folder_grant_removed: '文件夹权限撤销',
  grant_revoked: '授权撤回',
  grant_template_changed: '权限模板变更',  // 批次三:项目权限模板增删改
  invite_notified: '邀请通知已发送',
  local_login_failed: '本地账号登录失败',
  local_login_success: '本地账号登录',
  notification_sent: '通知已发送',
  password_changed: '修改密码',
  project_created: '项目创建',
  project_member_added: '项目成员添加',
  project_member_removed: '项目成员移除',
  proxy_download: '代理下载',
  sensitive_folder_invited: '敏感目录邀请',
  sensitive_folder_revoked: '敏感目录权限撤销',
  share_link_accessed: '分享链接访问',
  share_link_created: '分享链接创建',
  signed_url_issued: '临时链接签发',
  upload: '上传',
  // #150 本地目录 CRUD(users/groups)
  user_created: '用户创建',
  user_disabled: '用户停用',
  user_enabled: '用户启用',
  user_password_reset: '密码重置',
  group_created: '用户组创建',
  group_updated: '用户组更新',
  group_deleted: '用户组删除',
  group_member_added: '用户组成员添加',
  group_member_removed: '用户组成员移除',
  // ── 百度网盘备份(方案 §8 audit 全集)─────────────────────────────────────
  baidu_bind: '百度网盘绑定',
  baidu_unbind: '百度网盘解绑',
  baidu_task_create: '备份任务创建',
  baidu_task_cancel: '备份任务取消',
  baidu_task_delete: '备份任务删除',
  baidu_task_retry: '备份任务重试',
  baidu_file_retry: '备份文件重试',
  baidu_file_overwrite: '备份文件覆盖导入',
  baidu_file_imported: '备份文件导入',
  baidu_task_auto_finalized: '备份任务自动终态',
};

/** 百度备份任务状态 → Tag 文案(queued 为接口派生显示态,非后端枚举,组件内单独处理)。 */
export const BAIDU_TASK_STATUS_LABEL: Record<string, string> = {
  enumerating: '清单准备中',
  running: '进行中',
  queued: '排队中',
  completed: '已完成',
  cancelled: '已取消',
  failed: '失败',
};

/** 百度备份任务状态 → antd Tag 色。 */
export const BAIDU_TASK_STATUS_COLOR: Record<string, string> = {
  enumerating: 'processing',
  running: 'processing',
  queued: 'gold',
  completed: 'green',
  cancelled: 'default',
  failed: 'red',
};

/** 百度备份 manifest 文件行状态 → Tag 文案。 */
export const BAIDU_FILE_STATUS_LABEL: Record<string, string> = {
  pending: '等待',
  importing: '导入中',
  success: '成功',
  skipped_exists: '跳过(已存在)',
  failed: '失败',
  cancelled: '已取消',
};

/** 百度备份 manifest 文件行状态 → antd Tag 色。 */
export const BAIDU_FILE_STATUS_COLOR: Record<string, string> = {
  pending: 'default',
  importing: 'processing',
  success: 'green',
  skipped_exists: 'cyan',
  failed: 'red',
  cancelled: 'default',
};

/** 任务 fail_reason → 用户可读文案(§4 取值域)。 */
export const BAIDU_FAIL_REASON_LABEL: Record<string, string> = {
  binding_expired: '百度绑定已失效,请重新绑定后重试',
  timeout: '达到单轮 48h 上限,可用「全部重试失败」断点续传',
  file_failed: '部分文件失败',
  enum_rate_limited: '百度接口频控,枚举未完成',
  enum_failed: '枚举源目录失败',
  manifest_too_large: '文件数超过 20,000 上限,请拆分目录后重建任务',
  feature_disabled: '功能已被管理员停用,断点已保留(重新开启后可继续)',
};

/**
 * 任务状态展示态(§3.1 口径):接口派生 queued=true(活动中但无 runner 实际推进)
 * 时,enumerating/running 显示为「排队中」。
 */
interface BaiduTaskStatusLike {
  status: string;
  queued?: boolean;
}

export const baiduTaskDisplayStatus = (
  t: Pick<BaiduTaskStatusLike, 'status' | 'queued'>,
): string =>
  t.queued && (t.status === 'running' || t.status === 'enumerating') ? 'queued' : t.status;

export const ACTION_LABEL: Record<string, string> = {
  access: '访问',
  download: '下载',
};

export const TARGET_TYPE_LABEL: Record<string, string> = {
  asset: '文件',
  folder: '文件夹',
  sensitive_folder: '敏感目录',
  project: '项目',
};

// #153 应用内通知的 kind → 中文标签(通知列表页 chip 用;与后端 KIND_* 同步)
export const NOTIFICATION_KIND_LABEL: Record<string, string> = {
  approval_pending: '审批待办',
  approval_decided: '审批结果',
  folder_invite: '目录邀请',
  share: '资源分享',
};

/** raw token 缺 mapping 时直接回退 token 本身,避免渲染 undefined */
export const tlabel = (token: string, map: Record<string, string>): string =>
  map[token] || token;
