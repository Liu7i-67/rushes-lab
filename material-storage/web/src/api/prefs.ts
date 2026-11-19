/**
 * 用户偏好(2026-11-19 settings-mcp-collapse 方案 §6;web-B 按此固定契约 import)。
 * GET/PUT /api/v1/me/preferences —— 服务端单行 JSONB 偏好,Web/App 双端共用一份;
 * PUT 为部分更新(仅显式传入的键覆盖,其余保持原值),响应恒为合并后的全集。
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { UseMutationResult } from '@tanstack/react-query';
import { http } from './client';

/** 偏好全集(GET/PUT 响应;后端缺省补默认值,字段只增不减)。 */
export interface UserPrefs { folder_tree_default_collapsed: boolean }

/** PUT body:部分更新;undefined 经 JSON 序列化自动省略 = 不动该键。 */
export type PreferenceUpdate = Partial<UserPrefs>;

const PREFS_QUERY_KEY = ['me', 'preferences'] as const;
const PREFS_URL = '/api/v1/me/preferences';

// 无偏好行用户 GET 由后端补默认 false;乐观更新时缓存可能还没有行,以此兜底合并
const DEFAULT_PREFS: UserPrefs = { folder_tree_default_collapsed: false };

/** GET 当前用户偏好。
 *  - FolderTree 4 处使用方共享 react-query 缓存(同 queryKey),只发一次请求;
 *  - retry 关闭(useMe 同款):isError 直出,调用方按 false 兜底继续,不因重试拖住树挂载;
 *  - toast 归调用方(errorMessage 惯例),本 hook 不弹。 */
export function useUserPreferences(): {
  prefs: UserPrefs | undefined;
  isLoading: boolean;
  isError: boolean;
} {
  const query = useQuery({
    queryKey: PREFS_QUERY_KEY,
    queryFn: async () => (await http.get<UserPrefs>(PREFS_URL)).data,
    retry: false,
  });
  return { prefs: query.data, isLoading: query.isLoading, isError: query.isError };
}

/** PUT 更新偏好:乐观更新 + 失败回滚 + onSettled 失效重取(以服务端合并全集为准)。
 *  错误原样抛给调用方 Toast(errorMessage 惯例),本 hook 不吞。 */
export function useUpdateUserPreferences(): UseMutationResult<
  UserPrefs, Error, Partial<UserPrefs>
> {
  const qc = useQueryClient();
  return useMutation<UserPrefs, Error, PreferenceUpdate, { prev: UserPrefs | undefined }>({
    mutationFn: async (patch) => (await http.put<UserPrefs>(PREFS_URL, patch)).data,
    // 乐观写入缓存:无旧行时以 DEFAULT_PREFS 为底合并,开关立即可见(切换对下一次挂载生效)
    onMutate: async (patch) => {
      await qc.cancelQueries({ queryKey: PREFS_QUERY_KEY });
      const prev = qc.getQueryData<UserPrefs>(PREFS_QUERY_KEY);
      qc.setQueryData<UserPrefs>(
        PREFS_QUERY_KEY,
        (old) => ({ ...(old ?? DEFAULT_PREFS), ...patch }),
      );
      return { prev };
    },
    // 失败回滚到 onMutate 前的快照,再由 onSettled 失效重取纠偏
    onError: (_err, _patch, ctx) => {
      if (ctx?.prev !== undefined) qc.setQueryData<UserPrefs>(PREFS_QUERY_KEY, ctx.prev);
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: PREFS_QUERY_KEY });
    },
  });
}
