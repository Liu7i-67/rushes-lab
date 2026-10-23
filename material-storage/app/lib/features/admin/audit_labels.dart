/// 审计展示常量(B8;web AdminAuditPage EVENT_TYPES / labels.ts 映射对齐):
/// 事件类型筛选全集(56 项,后端任意字符串精确匹配无白名单——新增写入点须回补)
/// 与粗分类配色(details 键中文 label 桌面已有,移动端仅挑高频键,缺省回落裸键)。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';

/// event_type 过滤全集(web AdminAuditPage 同款,含首位 '' = 全部)。
const kAuditEventTypes = <String>[
  '', 'upload', 'download', 'signed_url_issued',
  'approval_submitted', 'approval_state_changed',
  'access_denied',
  'project_created', 'project_deleted', 'project_restored',
  'project_member_added', 'project_member_removed',
  'user_created', 'user_updated',
  'group_member_added', 'group_member_removed',
  'folder_created', 'sensitive_folder_invited', 'sensitive_folder_revoked',
  'folder_template_changed', 'folder_template_applied',
  'share_link_created', 'share_link_accessed',
  // 备份类(11)
  'baidu_bind', 'baidu_unbind', 'baidu_task_create', 'baidu_task_cancel',
  'baidu_task_delete', 'baidu_task_retry', 'baidu_file_retry',
  'baidu_file_overwrite', 'baidu_file_random_suffix', 'baidu_file_imported',
  'baidu_task_auto_finalized',
  // 文件类(8)
  'asset_deleted', 'asset_restored', 'asset_purged',
  'asset.tag_updated', 'asset.batch_renamed',
  'download_denied', 'proxy_download', 'folder_deleted',
  // 用户/组(7)
  'user_disabled', 'user_enabled', 'user_password_reset',
  'group_created', 'group_updated', 'group_deleted', 'password_changed',
  // 登录/通知(3)
  'local_login_success', 'local_login_failed', 'notification_sent',
  // 权限模板/目录/授权(4)
  'folder_grant_added', 'folder_grant_removed', 'grant_template_changed',
  'grant_revoked',
  // 六项优化(2026-10-17)与后续批次回填
  'user_login_unlocked', 'local_login_locked',
  'folder_renamed', 'folder_moved', 'asset_batch_moved',
];

/// event_type → 中文 label(app-polish F7;web labels.ts EVENT_TYPE_LABEL 同
/// 映射对齐,覆盖 kAuditEventTypes 全集)。筛选下拉/事件卡等 UI 只换展示,
/// 底层数据流(契约/CSV/details)仍用 raw token;缺 key 回落原文不报错
/// (后端新增写入点未回补映射时同款约定)。
const kAuditEventLabels = <String, String>{
  'access_denied': '访问被拒',
  'approval_submitted': '审批申请已提交',
  'approval_state_changed': '审批状态变更',
  'asset_batch_moved': '批量移动资产',
  'asset_deleted': '文件删除',
  'asset_restored': '文件恢复',
  'asset_purged': '文件彻底删除',
  'asset.tag_updated': '文件标签更新',
  'asset.batch_renamed': '文件批量改名',
  'download': '下载',
  'download_denied': '下载被拒',
  'folder_created': '文件夹创建',
  'folder_deleted': '文件夹删除',
  'folder_grant_added': '文件夹权限授予',
  'folder_grant_removed': '文件夹权限撤销',
  'folder_moved': '目录移动',
  'folder_renamed': '目录改名',
  'folder_template_applied': '目录模板应用',
  'folder_template_changed': '目录模板变更',
  'grant_revoked': '授权撤回',
  'grant_template_changed': '权限模板变更',
  'local_login_failed': '本地账号登录失败',
  'local_login_success': '本地账号登录',
  'local_login_locked': '触发登录锁定',
  'notification_sent': '通知已发送',
  'password_changed': '修改密码',
  'project_created': '项目创建',
  'project_deleted': '项目删除',
  'project_restored': '项目恢复',
  'project_member_added': '项目成员添加',
  'project_member_removed': '项目成员移除',
  'proxy_download': '代理下载',
  'sensitive_folder_invited': '敏感目录邀请',
  'sensitive_folder_revoked': '敏感目录权限撤销',
  'share_link_accessed': '分享链接访问',
  'share_link_created': '分享链接创建',
  'signed_url_issued': '临时链接签发',
  'upload': '上传',
  'user_created': '用户创建',
  'user_updated': '用户更新',
  'user_disabled': '用户停用',
  'user_enabled': '用户启用',
  'user_login_unlocked': '解除登录锁定',
  'user_password_reset': '密码重置',
  'group_created': '用户组创建',
  'group_updated': '用户组更新',
  'group_deleted': '用户组删除',
  'group_member_added': '用户组成员添加',
  'group_member_removed': '用户组成员移除',
  // 百度网盘备份(方案 §8 audit 全集)
  'baidu_bind': '百度网盘绑定',
  'baidu_unbind': '百度网盘解绑',
  'baidu_task_create': '备份任务创建',
  'baidu_task_cancel': '备份任务取消',
  'baidu_task_delete': '备份任务删除',
  'baidu_task_retry': '备份任务重试',
  'baidu_file_retry': '备份文件重试',
  'baidu_file_overwrite': '备份文件覆盖导入',
  'baidu_file_random_suffix': '备份文件随机后缀导入',
  'baidu_file_imported': '备份文件导入',
  'baidu_task_auto_finalized': '备份任务自动终态',
};

/// event_type → 展示文案(F7 接入点共用):缺 key 回落 raw token。
String auditEventLabel(String eventType) =>
    kAuditEventLabels[eventType] ?? eventType;

/// details 高频键 → 中文 label(C 包白名单制,缺 key 回落裸键,不会错)。
const kAuditDetailKeyLabels = <String, String>{
  'folder_id': '目录',
  'target_folder_id': '目标目录',
  'parent_folder_id': '父目录',
  'old_parent_folder_id': '原父目录',
  'new_parent_folder_id': '新父目录',
  'group_id': '用户组',
  'user_id': '用户',
  'sharer_user_id': '分享者',
  'subject': '主体',
  'role': '角色',
  'task_id': '任务',
  'file_id': '备份文件',
  'source_dir': '源目录',
  'reason': '原因',
  'username': '登录名',
  'name': '名称',
  'old_name': '原名称',
  'new_name': '新名称',
  'action': '动作',
  'filename': '文件名',
  'changes': '变更内容',
  'status': '状态',
  'fail_reason': '失败原因',
  'email': '邮箱',
  'via': '来源',
};

/// event_type → 粗分类色(web eventColor 同规则;颜色随主题令牌)。
Color auditEventColor(BuildContext context, String eventType) {
  final tk = context.tk;
  if (eventType.startsWith('access_denied')) return tk.danger;
  if (eventType.startsWith('baidu_')) return tk.ok;
  if (eventType.contains('approval')) return tk.warn;
  if (eventType.startsWith('share') || eventType.startsWith('signed_url')) {
    return tk.ok;
  }
  if (eventType.startsWith('upload') || eventType.startsWith('download')) {
    return tk.gold;
  }
  if (eventType.contains('project') ||
      eventType.contains('folder') ||
      eventType.contains('invite')) {
    return tk.ink;
  }
  return tk.ink2;
}
