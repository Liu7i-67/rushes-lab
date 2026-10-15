# Folders 侧栏「子树含文件」标记 · 需求文档

> qdev 实施文档(2026-10-15)。**权威技术方案**:`rushes-spec/material-storage/folder-subtree-file-badge-plan.md`
> (qplan 5 轮盲审定稿 `fd5edf7`,第 5 轮 P0/P1 清零)——本文档只做契约抽取与工作包划分,
> 实现细节(孤儿口径论证、回累伪代码、失效点清单)一律以方案为准,两者冲突时以方案为准。
> 分支 `feat/folder-subtree-file-badge`(自 qplan 分支 `fd5edf7` 切出,含方案文档),worktree
> `rushes-lab-qdev-folder-badge`。

## 背景与目标

公司要求每个项目初始(经目录模板)批量创建多层文件夹,实际使用中用户无法分辨哪些文件夹
里有文件,只能逐夹点进去看(文件列表按夹分页)。目标:Folders 侧栏对「整棵子树内存在
活跃文件」的文件夹以**实心填充的文件夹图标**标识,空文件夹保持空心图标。不显示数字、
不加 tooltip。

## 已拍板决策(记录,无需再问)

| 决策点 | 结论 | 依据 |
|---|---|---|
| 语义 | 整棵子树含活跃文件(`deleted_at IS NULL`)即标记;软删不计 | 用户拍板 2026-10-15 |
| D1 视觉 | 仅实心填充文件夹图标(fill),无数字无 tooltip | 用户拍板 2026-10-15 |
| D2 详情页头部计数文字 | **不做** | 默认(用户未开启) |
| D3 接口字段 | 只加 `subtree_file_count: int` 单字段;`file_count` 不暴露 | 用户授权按建议默认 |
| 孤儿口径 | 受众信任边界三态(方案 §6.3/§6.4):孤儿行 0/可见敏感根下回填/public 少报 | 方案定稿 |

## 功能点明细(逐条可验收)

### 后端
1. `GET /api/v1/folders?project_id=`(既有)出参每夹新增 `subtree_file_count: int`(默认 0):
   = 该夹整棵子树(含自身直接子文件)活跃文件数;权限过滤**之后**对可见夹聚合
   (一条 `GROUP BY folder_id` 查询,仅统计 `deleted_at IS NULL`)。
2. 子树回累:Python 侧建 children 映射,**只从真根**(`parent_folder_id is None`)后序
   遍历累加;回填必须 `subtree.get(f.id, 0)`,禁止 `subtree[f.id]`;visited 集合防环。
3. 孤儿口径:不可见敏感父下的普通子夹(及其后代)`subtree_file_count=0`(真根遍历
   不可达,缺键默认 0);可见敏感根(被邀请者视角)下的子夹正常回填。
4. `GET /api/v1/folders/{id}` 单条与 `POST /api/v1/folders` 201 响应:`subtree_file_count`
   恒为默认 0(不回填);FolderOut 字段注释写明「仅 list 端点回填」。
5. 子树口径必须走 `parent_folder_id` 结构链,**禁用 `minio_prefix` 前缀匹配**
   (minio_prefix 可客户端自拟,name 未禁 `/`)。

### 前端
6. `web/src/api/types.ts` Folder 增 `subtree_file_count?: number`。
7. `FolderTree.tsx` `buildTree`:`(f.subtree_file_count ?? 0) > 0` 时当前图标分支
   (sensitive→accent Folder/有子夹→FolderOpen/叶子→Folder)加 `fill` 实心
   (建议 `fill: 'currentColor'`;lucide-react ^1.16.0 透传须实机确认,不生效兜底
   `style={{ fill: 'currentColor' }}`);空夹保持 `fill='none'`。
8. 缓存失效补点(前缀匹配,不必透传 projectId):
   - `upload-store.tsx` upload-success 2s 防抖后(:138 附近)与批次 complete(:152 附近):
     追加 `qc.invalidateQueries({ queryKey: ['folders'] })`;
   - `hooks.ts` `useDeleteAsset`、`useRestoreAsset` onSuccess:追加同款;
   - **不改**:usePurgeAsset、FolderTrashModal 一键清空(purge 族,活跃计数不变)、
     批量前缀/meta/标签、百度导入。

### 明确不做
- 无 DB 迁移、无 FGA/权限模型改动、无新端点、无 constraints 变更。
- D2 详情页头部计数文字(不做);`file_count` 字段(不暴露)。

## 数据库修改方案

**不涉及**——无表/字段/索引变更、无 alembic 迁移。

## 接口定义(契约,前后端以此为准)

| 方法+路径 | 入参 | 返回 | 错误 |
|---|---|---|---|
| GET /api/v1/folders(既有) | 不变 | `FolderOut[]` 每项增 `subtree_file_count: int`(默认 0;仅此端点回填真实值) | 不变 |
| GET /api/v1/folders/{id}(既有) | 不变 | `FolderOut` 含 `subtree_file_count`(恒 0) | 不变 |
| POST /api/v1/folders(既有) | 不变 | 201 `FolderOut` 含 `subtree_file_count`(恒 0) | 不变 |

## 前端改动点 / 后端改动点(工作包文件边界)

- **WP-B 后端**:`api/app/models/__init__.py`(仅 FolderOut 加字段+注释)、
  `api/app/routers/folders.py`(仅 list_folders 加聚合+回累)。
- **WP-F 前端**:`web/src/api/types.ts`、`web/src/components/FolderTree.tsx`、
  `web/src/lib/upload-store.tsx`、`web/src/api/hooks.ts`(仅 useDeleteAsset/
  useRestoreAsset 两个 onSuccess)。
- **WP-T 测试**:`api/tests/test_folder_file_counts.py`(新)。

## 测试功能点(T1-T8,方案 §8)

- T1 子树计数精确:多夹多文件,各夹 subtree = 自身直接 + 全部后代之和;
- T2 深层回累:三层嵌套文件只在最深层,三层祖先全部计入(爷爷=爸爸=最深层=1);
- T3 软删排除:软删后计数减,恢复后加;
- T4 空模板项目:全夹 0;
- T5 不可见 sensitive 夹文件不计入任何可见节点;被邀请者视角 sensitive 夹自身计数正确;
- T6 get_folder 单条 = 默认 0(契约钉死);
- T7 自拟 minio_prefix 与结构不一致时,口径仍按 parent_folder_id(防退化为前缀匹配);
- T8 孤儿结构三变体:私有(普通成员孤儿行=0+被邀请者视角正常回填)/public(同为 0=
  接受少报)/邀请过期(原回填回落 0);另含链断回归断言(被邀请者对子夹 GET /assets
  403,锚住方案 §6.6 前提)。造数:子夹 can_upload 链断,文件须系统 admin 上传
  (X-User-Id 通道,参照 test_v4_permissions.py)或直写 DB。

前端门槛:web build 绿;真机抽测留部署阶段(图标实心/空心三分支、上传/删除即时变化、
百度备份目标树、移动端 Drawer)。

## 模糊点与决策记录

无遗留模糊点(语义/D1-D3 均已拍板,见上表)。lucide fill 透传为实施期一验即知项,
兜底 style.fill 已写入 WP-F。
