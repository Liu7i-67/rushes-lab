# 需求文档：百度网盘备份导入（qdev 存档）

> 日期：2026-10-09 ｜ 分支/worktree：`research/baidu-netdisk-import`（沿用，方案提交 `51e1b6c`）
> **唯一需求依据**：[`rushes-spec/material-storage/baidu-netdisk-backup-plan.md`](../../rushes-spec/material-storage/baidu-netdisk-backup-plan.md)（qplan 35 轮盲审定稿，下称「方案」）。本文档为 qdev 流程桥接存档：一切细节以方案为准，冲突时以方案为最高权威。

## 背景与目标

用户在系统内绑定自己的百度网盘账号（oob 授权码复制流程），选择网盘目录与系统内项目目标目录后创建**一次性手动导入任务**；服务端（arq worker）直连百度下载、MinIO multipart 断点续传、逐文件落库为 asset，全程异步可查进度，支持失败重试/覆盖导入/取消/删除。方案 §1-§3。

## 功能点明细（验收级，摘自方案 §1/§3/§5/§6）

1. 用户菜单「修改密码」下方（`me.password_set` 条件块**外**）新增「百度网盘备份」→ 抽屉；菜单显隐读 `/auth/me` 新增扁平字段 `baidu_backup_enabled`。
2. 绑定：授权链接生成（oob）→ 用户粘贴授权码 → 后端换 token（Fernet 加密落库 + uinfo 身份 NOT NULL）；切换账号走同流程（同 uid 豁免断点作废）；软解绑。
3. 新建任务：未绑定禁用；网盘目录树懒加载（folder=1、后端聚合分页）；项目选择（is_system_admin/我可上传过滤）+ FolderTree（sensitive 及其子树禁选、选择模式扩展）；目标解析（显式目录 / 项目根自动承接夹 ≤255 字符）；同绑定活动互斥（partial unique index 兜底 409）。
4. 任务执行：manifest 枚举（listall 优先退化 list、ON CONFLICT(task_id, rel_path) 幂等、enum_done 标记）→ 导入循环（仅 pending 行；建链先行含 FGA tuple+memoize；权限复查 is_org_admin 直通；skip/overwrite 清除-再导入含跨资产 key 预检；multipart 断点/死会话自愈/head 快捷路径；asset 落库含完整谓词与预检；缩略图三分派）。
5. 租约/接力/接管/sweeper：方案 §6 全部 CAS 与谓词、55min 接力、48h runner 自判+sweeper 兜底、确定性准入 ≤2、急停 flag 感知。
6. 进度与操作：抽屉列表（状态 Tag 含排队中、ETA）、明细表（重试/覆盖导入行级操作）；cancel（CAS 直终态化 `{finalized}`）、DELETE（终态 CAS + abort helper）、retry-failed/单文件 retry/overwrite（复活型统一前置）。
7. 上线前置与运维（§11）：BAIDU_BACKUP_ENABLED 默认 false、bucket lifecycle 30d、部署/回滚顺序。

## 数据库修改方案（方案 §4 为准）

migration `2026_10_08_0013_baidu_backup.py`（基于 head `2026_09_30_0012`）一次建三表：`baidu_bindings`（token 双列加密、baidu_uid NOT NULL、last_authorized_at/token_rotated_at、软解绑 status）、`baidu_backup_tasks`（租约/接力/轮起点/计数/取消语义全套列、`uq_baidu_task_active` partial unique index）、`baidu_backup_task_files`（manifest、断点三元组、UNIQUE(task_id, rel_path)、长度护栏）。同步更新 `tests/test_db_schema.py` 表名全集断言并补三表约束断言。

## 接口定义（方案 §5.2 表格为准，共 14 路由）

`/api/v1/baidu/backup/*`：binding 四路由、netdisk/folders、tasks CRUD + cancel + retry-failed + file retry/overwrite；分页 limit/offset、`ORDER BY created_at DESC, id DESC`；未启用开关统一 404；错误码语义（409 binding_inactive/活动互斥/终态封口、403+access_denied 权限与敏感）按方案。

## 前端改动点（方案 §7）：入口 + 四新组件 + FolderTree/BaiduNewTaskModal 扩展 + hooks + labels.ts 映射。
## 后端改动点（方案 §5/§6）：services（baidu_client/token_crypto/baidu_backup/ensure_folder_chain/资产清除业务流）+ routers/baidu_backup.py + workers 模块（arq func 注册、aioboto3 multipart 封装、sweeper cron）+ settings 常量（时延/part_size 可注入）+ pyproject 显式 cryptography。

## 测试功能点（方案 §10 批次 5 清单为准，~60 条）

纯逻辑单测（错误映射/加密/长度护栏/退避/脱敏/白名单）+ DB 容器集成（状态机/CAS/接管/断点/覆盖/门控等，P0 档=租约 CAS、接管续跑、回摆并发、kill -9 恢复四类必过）+ 收口门槛 ruff/mypy(strict) 零新增 + pnpm lint/build + test_db_schema 全绿。

## 模糊点与决策记录

无待决模糊点——全部决策已在方案定稿（用户四项拍板：跳过+手动覆盖/仅创建者可见/重试取消删/一次性；qplan 35 轮盲审含防死循环一次拍板）。派发层分工按方案 §10 批次映射：批次 1（后端基建）∥ 批次 4（前端）∥ 测试用例包 → 批次 2+3（任务域+worker，同后端代理保集成一致）→ PM 验收 → 专职测试。

**WP5 验收期 PM 决策（2026-10-09）**：
1. 枚举期「显式目标夹被删」落任务级 `failed('enum_failed')`（方案 fail_reason 值域无 target_deleted 的任务级形态）——**接受**；行级 `failed('target_deleted')` 语义保留给导入循环（§6 步骤 1）。
2. md5 旁证来源：manifest 无 md5 列，head 命中时现场调 filemetas(dlink=0) 取 md5——**接受**（罕见路径多一次调用，schema 免改）。
3. sweeper 分支顺序 flag 优先于 cancel_requested——**接受**（急停收敛优先，开关关闭时取消任务同样保留断点）。
4. listall 未实现、直接走 list_dir 递归（方案自带退化路径）——**接受**，批次 1 真机验证 listall 后可增补切换。
5. ruff/mypy 验收口径：PM 以 PATH ruff 0.16.10 + 主仓 venv 复跑为准；新文件 ruff 仅存量同型 RUF100（已派清理）、mypy 新模块零错误（17 条报错全在存量文件）。
6. `is_sensitive` 过时注释更正与 RUF100 清理已派后端小修；测试命名对齐已派测试小修（实跑单测至绿）。

## 工作包与进度

| 工作包 | 角色 | 状态 |
|---|---|---|
| WP1 后端基建（批次 1） | 后端 A | 执行中 |
| WP2 前端（批次 4） | 前端 | 已交付待验收（pnpm lint 0 problems / build ✓） |
| WP3 测试用例编写 | 测试 | 执行中 |
| WP4 任务域+worker（批次 2+3） | 后端 B | 阻塞于 WP1 |
| WP5 PM 验收 | PM | — |
| WP6 全方位+回归测试 | 测试（新派发） | — |

## WP2 前端契约对齐补充（WP4 后端必须对齐的响应字段）

前端已按以下自拟字段实现（均可选、缺失有兜底），**WP4 后端落库/序列化时按此对齐**：
1. `GET /backup/binding` 返回可含 `nickname`/`baidu_uid`（uinfo 身份，UI 显示绑定账号）。
2. `GET /backup/tasks` 任务对象可含：`queued: bool`（派生态：running 且 speed_bps=0 且无 importing 行/枚举超时未认领，且 runner_id IS NULL 或租约过期）、`eta_seconds: number|null`（speed_bps≤0 时 null）、`retryable_failed_files: number`（failed 且 non_retryable=false 行数，用于"全部重试失败"按钮显隐）、`cancelled_files`、`project_name`、`target_folder_name`、`target_auto_created`。
3. `GET /backup/tasks/{id}/files` 行对象可含 `target_path: string|null`（预计导入路径，行级 folder 为 NULL 回退任务级+rel_path，皆 NULL 时 null→前端显示源路径+"(目标已删除)"）。
4. `POST /backup/tasks/{id}/cancel` 202 响应体 `{finalized: bool}`（已实现区分文案）。
5. BaiduBindModal 两步流程文案、NewTaskModal 含「项目根(自动承接夹)」伪节点；抽屉含「解绑」danger 入口（对应 DELETE /backup/binding）。
