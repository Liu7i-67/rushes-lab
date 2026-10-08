/** react-query hooks — 包 ms-api endpoints。*/
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback } from 'react';
import { http } from './client';
import type {
  Approval,
  ApprovalAction,
  ApprovalTargetType,
  Asset,
  AssetList,
  BaiduBackupTask,
  BaiduBinding,
  BaiduNetdiskFolder,
  BaiduTaskFilesPage,
  BaiduTasksPage,
  DirectoryGroup,
  DirectoryGroupMember,
  DirectoryUser,
  DirectoryUserCreateOut,
  DownloadLink,
  Folder,
  GrantEntry,
  GrantTemplate,
  Me,
  NotificationsList,
  Project,
  SearchResult,
  ShareCreateOut,
  ShareResolve,
  TrashAssets,
} from './types';

// ─── auth ──────────────────────────────────────────────────────────────────
export const useMe = () =>
  useQuery({
    queryKey: ['me'],
    queryFn: async () => (await http.get<Me>('/api/v1/auth/me')).data,
    retry: false,
  });

// #149: 本地账号密码登录(成功置 cookie;must_change_password=true 时前端强制改密)
export const useLocalLogin = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: { username: string; password: string }) =>
      (await http.post<{
        status: string;
        user_id: string;
        name: string;
        must_change_password: boolean;
      }>('/api/v1/auth/local/login', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['me'] }),
  });
};

// #149: 修改密码(旧密码 + 新密码;新密码需过服务端策略)
export const useChangePassword = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: { old_password: string; new_password: string }) =>
      (await http.post<{ status: string }>('/api/v1/auth/change-password', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['me'] }),
  });
};

// ─── projects ──────────────────────────────────────────────────────────────
export const useProjects = () =>
  useQuery({
    queryKey: ['projects'],
    queryFn: async () => (await http.get<Project[]>('/api/v1/projects')).data,
  });

export const useProject = (id: string | undefined) =>
  useQuery({
    queryKey: ['project', id],
    queryFn: async () => (await http.get<Project>(`/api/v1/projects/${id}`)).data,
    enabled: !!id,
  });

export const useCreateProject = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: {
      code: string;
      name: string;
      description?: string;
      organization_id?: string;
      minio_bucket: string;
      admin_user_id: string;   // 必填:指派项目 admin(可以是自己;users.id UUID)
      initial_grants?: GrantEntry[];   // 可选:创建时同时授权(方案 §3;不传/空 = 现行为)
    }) => {
      const { organization_id, initial_grants, ...rest } = body;
      const payload = {
        ...rest,
        ...(organization_id ? { organization_id } : {}),
        ...(initial_grants && initial_grants.length > 0 ? { initial_grants } : {}),
      };
      return (await http.post<Project>('/api/v1/projects', payload)).data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['projects'] }),
  });
};

// ─── folders ───────────────────────────────────────────────────────────────
export const useCreateFolder = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: {
      project_id: string;
      parent_folder_id?: string;
      name: string;
      is_sensitive?: boolean;
      minio_prefix?: string;
    }) => (await http.post<Folder>('/api/v1/folders', body)).data,
    onSuccess: (_d, vars) => qc.invalidateQueries({ queryKey: ['folders', vars.project_id] }),
  });
};

export const useFolders = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['folders', projectId],
    queryFn: async () =>
      (await http.get<Folder[]>('/api/v1/folders', { params: { project_id: projectId } })).data,
    enabled: !!projectId,
  });

// 删除文件夹(仅空文件夹;后端 enforce can_admin + 无子夹/无文件)
// 注意:不 invalidate ['folder', id] —— 删除成功瞬间该 query 的 observer 还挂在
// 已删 folder 上,失效/移除会立刻触发一次注定 404 的 GET;导航走后缓存自然无人引用
export const useDeleteFolder = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { folder_id: string; project_id: string }) => {
      await http.delete(`/api/v1/folders/${args.folder_id}`);
    },
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['folders', vars.project_id] });
    },
  });
};

export const useFolder = (folderId: string | undefined) =>
  useQuery({
    queryKey: ['folder', folderId],
    queryFn: async () => (await http.get<Folder>(`/api/v1/folders/${folderId}`)).data,
    enabled: !!folderId,
  });

export const useInviteFolder = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: {
      folder_id: string;
      user_id?: string;      // users.id UUID(#148 起)
      group_id?: string;
      level: 'viewer' | 'downloader';
      duration_seconds?: number;
    }) => {
      const { folder_id, ...body } = args;
      await http.post(`/api/v1/folders/${folder_id}/invite`, body);
    },
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: ['folder', vars.folder_id] });
      qc.invalidateQueries({ queryKey: ['folder-members', vars.folder_id] });
    },
  });
};

export const useRevokeFolder = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: {
      folder_id: string;
      subject: string;             // 完整 "user:xxx" / "group:xxx#member"
      level: 'viewer' | 'downloader';
      permanent: boolean;
    }) => {
      await http.delete(`/api/v1/folders/${args.folder_id}/invite`, {
        params: {
          subject: args.subject,
          level: args.level,
          permanent: args.permanent,
        },
      });
    },
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: ['folder', vars.folder_id] });
      qc.invalidateQueries({ queryKey: ['folder-members', vars.folder_id] });
    },
  });
};

// ─── assets ────────────────────────────────────────────────────────────────
// 服务端分页(page/pageSize 进 queryKey,各页独立缓存);上传/删除等失效走
// ['assets'] 前缀,天然命中所有页。placeholderData 保旧页,翻页不白屏。
export const ASSETS_PAGE_SIZE = 30;
export const useAssets = (
  folderId: string | undefined,
  page = 1,
  pageSize: number = ASSETS_PAGE_SIZE,
) =>
  useQuery({
    queryKey: ['assets', folderId, page, pageSize],
    queryFn: async () =>
      (await http.get<AssetList>('/api/v1/assets', {
        params: { folder_id: folderId, limit: pageSize, offset: (page - 1) * pageSize },
      })).data,
    enabled: !!folderId,
    placeholderData: keepPreviousData,
  });

// §3.5:可选 as_attachment —— 移动端直连系统下载器时签 attachment 头(后端可选 body,
// 响应结构不变)。传 assetId 字符串(既有调用)或不传 as_attachment,语义均为内联,零影响。
export const useDownloadLink = () =>
  useMutation({
    mutationFn: async (vars: string | { assetId: string; as_attachment?: boolean }) => {
      const assetId = typeof vars === 'string' ? vars : vars.assetId;
      const body = typeof vars === 'object' && vars.as_attachment ? { as_attachment: true } : {};
      return (await http.post<DownloadLink>(`/api/v1/assets/${assetId}/download-link`, body)).data;
    },
  });

export const useDeleteAsset = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (assetId: string) => {
      await http.delete(`/api/v1/assets/${assetId}`);
    },
    // 软删也进回收站:角标计数(assets-trash)必须一起失效,否则「回收站 N」不更新
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['assets'] });
      qc.invalidateQueries({ queryKey: ['assets-trash'] });
    },
  });
};

// ─── 回收站(软删列表 / 恢复 / 彻底删除)────────────────────────────────────
export const useTrashAssets = (folderId: string | undefined, enabled = true) =>
  useQuery({
    queryKey: ['assets-trash', folderId],
    queryFn: async () =>
      (await http.get<TrashAssets>('/api/v1/assets/trash', { params: { folder_id: folderId } }))
        .data,
    enabled: !!folderId && enabled,
  });

export const useRestoreAsset = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (assetId: string) => {
      await http.post(`/api/v1/assets/${assetId}/restore`);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['assets-trash'] });
      qc.invalidateQueries({ queryKey: ['assets'] });
    },
  });
};

// 彻底删除:仅对已软删的文件(后端 enforce 两步制)
export const usePurgeAsset = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (assetId: string) => {
      await http.delete(`/api/v1/assets/${assetId}`, { params: { hard: true } });
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['assets-trash'] });
      qc.invalidateQueries({ queryKey: ['assets'] });
    },
  });
};

// #151: 跨 folder 盲搜(文件名 / 标签 / 备注;后端已按 can_view 过滤)
export const useSearchAssets = (q: string | null) =>
  useQuery({
    queryKey: ['asset-search', q],
    queryFn: async () =>
      (await http.get<SearchResult[]>('/api/v1/assets/search', { params: { q } })).data,
    enabled: !!q && q.trim().length > 0,
  });

// #151: 写 user_labels / notes(user_labels 显式传空数组 = 清空)
export const useUpdateAssetMeta = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { asset_id: string; user_labels?: string[]; notes?: string }) =>
      (await http.patch<Asset>(`/api/v1/assets/${args.asset_id}/meta`, {
        user_labels: args.user_labels,
        notes: args.notes,
      })).data,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['assets'] });
      qc.invalidateQueries({ queryKey: ['asset-search'] });
    },
  });
};

// ─── approvals ─────────────────────────────────────────────────────────────
export const useApprovals = (scope: 'self' | 'all', status?: string) =>
  useQuery({
    queryKey: ['approvals', scope, status],
    queryFn: async () =>
      (await http.get<Approval[]>('/api/v1/approvals', { params: { scope, status } })).data,
  });

export const useCreateApproval = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: {
      target_type: ApprovalTargetType;
      target_id: string;
      action: ApprovalAction;
      duration_seconds?: number;
      reason: string;
      // #112 PR-2: 来自 request-link 落地页时附带 token,backend enforce
      via_link?: string;
    }) => {
      const { via_link, ...rest } = body;
      const params = via_link ? { via_link } : undefined;
      return (await http.post<Approval>('/api/v1/approvals', rest, { params })).data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['approvals'] }),
  });
};

// ─── request-links (#112) ──────────────────────────────────────────────────
export interface RequestLinkResolve {
  token: string;
  target_type: 'sensitive_folder' | 'asset' | 'project' | 'folder';
  target_id: string;
  target_name: string | null;
  allowed_actions: ('access' | 'download')[];
  expires_at: string;
  inviter_name: string | null;
  receiver_restricted: boolean;
  receiver_match: boolean;
}

export interface RequestLinkCreateOut {
  token: string;
  landing_url: string;
  expires_at: string;
  allowed_actions: string[];
}

export const useCreateRequestLink = () =>
  useMutation({
    mutationFn: async (body: {
      // #129: 加 folder 支持(全链路接通后)
      target_type: 'sensitive_folder' | 'asset' | 'project' | 'folder';
      target_id: string;
      allowed_actions: ('access' | 'download')[];
      receiver_user_id?: string;   // users.id UUID(#148 起)
      ttl_seconds?: number;
    }) => (await http.post<RequestLinkCreateOut>('/api/v1/request-links', body)).data,
  });

export const useResolveRequestLink = (token: string | undefined) =>
  useQuery({
    queryKey: ['request-link', token],
    queryFn: async () =>
      (await http.get<RequestLinkResolve>(`/api/v1/request-links/${token}`)).data,
    enabled: !!token,
    retry: false,
  });

export const useApproveApproval = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { id: string; decision_note?: string }) =>
      (await http.post<Approval>(`/api/v1/approvals/${args.id}/approve`, {
        decision_note: args.decision_note,
      })).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['approvals'] }),
  });
};

export const useRejectApproval = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { id: string; decision_note?: string }) =>
      (await http.post<Approval>(`/api/v1/approvals/${args.id}/reject`, {
        decision_note: args.decision_note,
      })).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['approvals'] }),
  });
};

// ─── share(iter3;#154:飞书 IM 推送下线,纯链接分享)──────────────────────────
export const useShareAsset = () =>
  useMutation({
    mutationFn: async (args: {
      asset_id: string;
      expires_in_seconds: number;
      requires_login?: boolean;
    }) => {
      const { asset_id, ...body } = args;
      return (await http.post<ShareCreateOut>(`/api/v1/share/assets/${asset_id}`, body)).data;
    },
  });

export const useShareFolder = () =>
  useMutation({
    mutationFn: async (args: {
      folder_id: string;
      expires_in_seconds: number;
      requires_login?: boolean;
    }) => {
      const { folder_id, ...body } = args;
      return (await http.post<ShareCreateOut>(`/api/v1/share/folders/${folder_id}`, body)).data;
    },
  });

export const useResolveShare = (token: string | undefined) =>
  useQuery({
    queryKey: ['share', token],
    queryFn: async () => (await http.get<ShareResolve>(`/api/v1/share/${token}`)).data,
    enabled: !!token,
    retry: false,
  });

// ─── directory(#150 本地用户/组管理,admin only)────────────────────────────
// params 传 null = 不启用(挂载但不取数;新建项目弹窗关闭期间不白打请求)
export const useDirectoryUsers = (
  params: { q?: string; is_active?: boolean; limit?: number } | null = {},
) =>
  useQuery({
    queryKey: ['directory-users', params],
    queryFn: async () =>
      (await http.get<DirectoryUser[]>('/api/v1/admin/directory/users', { params: params ?? {} }))
        .data,
    enabled: params !== null,
  });

export const useCreateUser = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: { username: string; name: string; email?: string }) =>
      (await http.post<DirectoryUserCreateOut>('/api/v1/admin/directory/users', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-users'] }),
  });
};

export const useDisableUser = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (userId: string) =>
      (await http.post<DirectoryUser>(`/api/v1/admin/directory/users/${userId}/disable`)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-users'] }),
  });
};

export const useEnableUser = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (userId: string) =>
      (await http.post<DirectoryUser>(`/api/v1/admin/directory/users/${userId}/enable`)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-users'] }),
  });
};

export const useResetUserPassword = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (userId: string) =>
      (await http.post<{ temporary_password: string }>(
        `/api/v1/admin/directory/users/${userId}/reset-password`,
      )).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-users'] }),
  });
};

export const useDirectoryGroups = (q = '') =>
  useQuery({
    queryKey: ['directory-groups', q],
    queryFn: async () =>
      (await http.get<DirectoryGroup[]>('/api/v1/admin/directory/groups', { params: { q } })).data,
  });

export const useCreateGroup = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: { name: string; description?: string }) =>
      (await http.post<DirectoryGroup>('/api/v1/admin/directory/groups', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-groups'] }),
  });
};

export const useUpdateGroup = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { groupId: string; name?: string; description?: string }) => {
      const { groupId, ...body } = args;
      return (await http.patch<DirectoryGroup>(`/api/v1/admin/directory/groups/${groupId}`, body)).data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-groups'] }),
  });
};

export const useDeleteGroup = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (groupId: string) => {
      await http.delete(`/api/v1/admin/directory/groups/${groupId}`);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['directory-groups'] }),
  });
};

export const useGroupMembers = (groupId: string | undefined) =>
  useQuery({
    queryKey: ['directory-group-members', groupId],
    queryFn: async () =>
      (await http.get<DirectoryGroupMember[]>(
        `/api/v1/admin/directory/groups/${groupId}/members`,
      )).data,
    enabled: !!groupId,
  });

export const useAddGroupMember = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { groupId: string; user_id: string }) =>
      (await http.post<DirectoryGroupMember>(
        `/api/v1/admin/directory/groups/${args.groupId}/members`,
        { user_id: args.user_id },
      )).data,
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['directory-group-members', vars.groupId] });
      qc.invalidateQueries({ queryKey: ['directory-groups'] });
    },
  });
};

export const useRemoveGroupMember = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: { groupId: string; userId: string }) => {
      await http.delete(`/api/v1/admin/directory/groups/${args.groupId}/members/${args.userId}`);
    },
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['directory-group-members', vars.groupId] });
      qc.invalidateQueries({ queryKey: ['directory-groups'] });
    },
  });
};

// ─── 项目权限模板(方案 §4;require_system_admin)────────────────────────────
// 列表(含 items + 解析后的主体名)。非系统 admin 403 由全局 queryCache 静默跳过;
// 调用方(权限模板 Select)对 undefined 数据自行降级为只有「不使用模板」。
// enabled:NewProjectModal 对全员挂载,关闭态不取数。
export const useGrantTemplates = (enabled = true) =>
  useQuery({
    queryKey: ['grant-templates'],
    queryFn: async () => (await http.get<GrantTemplate[]>('/api/v1/admin/grant-templates')).data,
    enabled,
  });

export const useCreateGrantTemplate = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: {
      name: string;
      description?: string;
      is_default?: boolean;
      items: GrantEntry[];
    }) => (await http.post<GrantTemplate>('/api/v1/admin/grant-templates', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['grant-templates'] }),
  });
};

// PATCH:均可选;items 传即全量替换
export const useUpdateGrantTemplate = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (args: {
      templateId: string;
      name?: string;
      description?: string | null;
      is_default?: boolean;
      items?: GrantEntry[];
    }) => {
      const { templateId, ...body } = args;
      return (await http.patch<GrantTemplate>(
        `/api/v1/admin/grant-templates/${templateId}`, body,
      )).data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['grant-templates'] }),
  });
};

export const useDeleteGrantTemplate = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (templateId: string) => {
      await http.delete(`/api/v1/admin/grant-templates/${templateId}`);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['grant-templates'] }),
  });
};

// ─── notifications(#153)— 轮询即可,不做 WebSocket ─────────────────────────
/** 未读计数 — Bell badge 轮询用(30s;页面聚焦时由 refetchOnWindowFocus 兜底)。 */
export const useNotificationsUnread = () =>
  useQuery({
    queryKey: ['notifications', 'unread'],
    queryFn: async () =>
      (await http.get<NotificationsList>('/api/v1/notifications', { params: { limit: 1 } })).data
        .unread_count,
    refetchInterval: 30_000,
    retry: false,
  });

/** 通知列表页(分页)。 */
export const useNotifications = (limit: number, offset: number) =>
  useQuery({
    queryKey: ['notifications', 'list', limit, offset],
    queryFn: async () =>
      (await http.get<NotificationsList>('/api/v1/notifications', { params: { limit, offset } }))
        .data,
    retry: false,
  });

/** 标记已读(ids 或 all);成功后失效 unread + list。 */
export const useMarkNotificationsRead = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: { ids?: string[]; all?: boolean }) =>
      (await http.post<{ updated: number }>('/api/v1/notifications/mark-read', body)).data,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['notifications'] });
    },
  });
};

// ─── 百度网盘备份(方案 §5.2;路由挂 /api/v1/baidu)──────────────────────────
// 开关未启用时后端统一 404;前端菜单显隐已由 me.baidu_backup_enabled 门控,
// 抽屉关闭时 query 不发请求(enabled)。
export const BAIDU_BACKUP_BASE = '/api/v1/baidu/backup';

/** 方案 §5.2:netdisk folders 前端单独放宽 timeout —— 频控退避 + 后端多页聚合
 *  可能超过 client.ts 全局 30s,该请求单独放宽到 120s。 */
export const BAIDU_FOLDERS_TIMEOUT_MS = 120_000;

/** 任务/文件轮询节奏(§7):有进行中(含清单准备中)任务 5s,否则 15s。 */
const baiduTaskActive = (t: Pick<BaiduBackupTask, 'status'>) =>
  t.status === 'enumerating' || t.status === 'running';
const baiduPollMs = (data?: BaiduTasksPage) =>
  data && data.items.some(baiduTaskActive) ? 5_000 : 15_000;

/** GET /backup/binding — 绑定状态(enabled=false 不发请求,抽屉关闭不轮询)。 */
export const useBaiduBinding = (enabled = true) =>
  useQuery({
    queryKey: ['baidu-binding'],
    queryFn: async () => (await http.get<BaiduBinding>(`${BAIDU_BACKUP_BASE}/binding`)).data,
    enabled,
  });

/** POST /backup/binding/authorize-url — 生成 oob 授权链接。 */
export const useBaiduAuthorizeUrl = () =>
  useMutation({
    mutationFn: async () =>
      (await http.post<{ url: string }>(`${BAIDU_BACKUP_BASE}/binding/authorize-url`)).data,
  });

/** POST /backup/binding — 授权码换 token 落库(含重新授权/切换账号,覆盖同一行)。 */
export const useBaiduBind = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (code: string) =>
      (await http.post<{ bound: boolean }>(`${BAIDU_BACKUP_BASE}/binding`, { code })).data,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['baidu-binding'] });
      qc.invalidateQueries({ queryKey: ['baidu-tasks'] });
    },
  });
};

/** DELETE /backup/binding — 软解绑(名下活动中任务取消 + 断点作废)。 */
export const useBaiduUnbind = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async () => {
      await http.delete(`${BAIDU_BACKUP_BASE}/binding`);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['baidu-binding'] });
      qc.invalidateQueries({ queryKey: ['baidu-tasks'] });
    },
  });
};

/** GET /backup/netdisk/folders?path= — 网盘目录树懒加载取数器。
 *  走 queryClient.fetchQuery:同 path 结果缓存复用(后端另有 60s Redis 缓存),
 *  antd Tree loadData 直接 await 该函数。 */
export const useBaiduNetdiskFolders = () => {
  const qc = useQueryClient();
  return useCallback(
    async (path: string): Promise<BaiduNetdiskFolder[]> =>
      qc.fetchQuery({
        queryKey: ['baidu-netdisk-folders', path],
        queryFn: async () =>
          (await http.get<{ list: BaiduNetdiskFolder[] }>(
            `${BAIDU_BACKUP_BASE}/netdisk/folders`,
            { params: { path }, timeout: BAIDU_FOLDERS_TIMEOUT_MS },
          )).data.list,
        staleTime: 60_000,
        gcTime: 5 * 60_000,
      }),
    [qc],
  );
};

/** POST /backup/tasks — 创建备份任务(status=enumerating)。 */
export const useBaiduCreateTask = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: {
      source_dir: string;
      project_id: string;
      target_folder_id?: string;   // 不传 = 项目根(自动创建承接夹)
    }) => (await http.post<BaiduBackupTask>(`${BAIDU_BACKUP_BASE}/tasks`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['baidu-tasks'] }),
  });
};

/** GET /backup/tasks — 仅本人任务分页(带进度/ETA;轮询 5s/15s)。 */
export const useBaiduTasks = (limit: number, offset: number, enabled = true) =>
  useQuery({
    queryKey: ['baidu-tasks', limit, offset],
    queryFn: async () =>
      (await http.get<BaiduTasksPage>(`${BAIDU_BACKUP_BASE}/tasks`, {
        params: { limit, offset },
      })).data,
    enabled,
    placeholderData: keepPreviousData,
    refetchInterval: (query) => baiduPollMs(query.state.data),
  });

/** GET /backup/tasks/{id} — 单任务详情(进度/ETA 轮询同列表口径)。 */
export const useBaiduTask = (taskId: string | undefined) =>
  useQuery({
    queryKey: ['baidu-task', taskId],
    queryFn: async () =>
      (await http.get<BaiduBackupTask>(`${BAIDU_BACKUP_BASE}/tasks/${taskId}`)).data,
    enabled: !!taskId,
    refetchInterval: (query) =>
      query.state.data && baiduTaskActive(query.state.data) ? 5_000 : 15_000,
  });

/** GET /backup/tasks/{id}/files — manifest 分页(status 筛选;active 时 5s 轮询)。 */
export const useBaiduTaskFiles = (
  taskId: string | undefined,
  status: string | undefined,
  limit: number,
  offset: number,
  active = false,
) =>
  useQuery({
    queryKey: ['baidu-task-files', taskId, status ?? 'all', limit, offset],
    queryFn: async () =>
      (await http.get<BaiduTaskFilesPage>(`${BAIDU_BACKUP_BASE}/tasks/${taskId}/files`, {
        params: { ...(status ? { status } : {}), limit, offset },
      })).data,
    enabled: !!taskId,
    placeholderData: keepPreviousData,
    refetchInterval: active ? 5_000 : false,
  });

/** 任务动作成功后的缓存失效(列表 + 全部详情 + 全部 manifest 筛选页)。 */
const useInvalidateBaiduTasks = () => {
  const qc = useQueryClient();
  return useCallback(() => {
    qc.invalidateQueries({ queryKey: ['baidu-tasks'] });
    qc.invalidateQueries({ queryKey: ['baidu-task'] });
    qc.invalidateQueries({ queryKey: ['baidu-task-files'] });
  }, [qc]);
};

/** POST /backup/tasks/{id}/cancel — 202 {finalized}(true=已终态化,false=交 worker 消费)。 */
export const useBaiduCancelTask = () => {
  const invalidate = useInvalidateBaiduTasks();
  return useMutation({
    mutationFn: async (taskId: string) =>
      (await http.post<{ finalized: boolean }>(
        `${BAIDU_BACKUP_BASE}/tasks/${taskId}/cancel`,
      )).data,
    onSuccess: () => invalidate(),
  });
};

/** DELETE /backup/tasks/{id} — 仅终态任务可删(204)。 */
export const useBaiduDeleteTask = () => {
  const invalidate = useInvalidateBaiduTasks();
  return useMutation({
    mutationFn: async (taskId: string) => {
      await http.delete(`${BAIDU_BACKUP_BASE}/tasks/${taskId}`);
    },
    onSuccess: () => invalidate(),
  });
};

/** POST /backup/tasks/{id}/retry-failed — 全部重试失败(仅 failed 任务;复活型)。 */
export const useBaiduRetryTaskFailed = () => {
  const invalidate = useInvalidateBaiduTasks();
  return useMutation({
    mutationFn: async (taskId: string) => {
      await http.post(`${BAIDU_BACKUP_BASE}/tasks/${taskId}/retry-failed`);
    },
    onSuccess: () => invalidate(),
  });
};

/** POST /backup/tasks/{id}/files/{fid}/retry — 单文件重试(仅 failed 任务失败行)。 */
export const useBaiduRetryFile = () => {
  const invalidate = useInvalidateBaiduTasks();
  return useMutation({
    mutationFn: async (args: { taskId: string; fileId: string }) => {
      await http.post(
        `${BAIDU_BACKUP_BASE}/tasks/${args.taskId}/files/${args.fileId}/retry`,
      );
    },
    onSuccess: () => invalidate(),
  });
};

/** POST /backup/tasks/{id}/files/{fid}/overwrite — 覆盖导入(failed/completed 任务跳过行;
 *  清除-再导入,需对原 asset 有 can_admin)。 */
export const useBaiduOverwriteFile = () => {
  const invalidate = useInvalidateBaiduTasks();
  return useMutation({
    mutationFn: async (args: { taskId: string; fileId: string }) => {
      await http.post(
        `${BAIDU_BACKUP_BASE}/tasks/${args.taskId}/files/${args.fileId}/overwrite`,
      );
    },
    onSuccess: () => invalidate(),
  });
};
