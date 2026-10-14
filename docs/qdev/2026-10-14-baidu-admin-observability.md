# 需求文档:审计过滤补全 + 管理员备份任务视图 + livp 失败文案(W2 / W3 / W1-B)

> qdev 需求存档,2026-10-14。**唯一需求依据的上游方案**:`rushes-spec/material-storage/prod-observability-fix-plan.md`(qplan 5 轮盲审定稿,aaede7e)——本文档按其实施口径整理,冲突时以上游方案为准。
> 范围:**W2(审计事件过滤补全)+ W3(管理员备份任务视图)+ W1-B(livp 失败文案)**。W1(装 pillow-heif+backfill)为纯运维,不在本代码周期。

## 背景与目标

生产环境三个观测面缺口(详见上游方案 §0):审计模块存在「备份文件导入」事件但过滤下拉没有该项;管理员无任何途径查看全系统百度备份任务;livp 预览失败时前端误导性地提示"还在生成"。本周期交付对应的代码修复/新功能,后端审计查询与用户侧备份功能零回归。

## 决策记录(上游方案 D1-D4 已按建议采纳)

| 决策 | 取值 | 依据 |
|------|------|------|
| D1 W2 范围 | 补全全部 33 项 + 删 2 死项(approval_notified/invite_notified) | 方案 §6 D1 建议 |
| D2 W3 明细/门控 | 含文件明细端点;**不随** `baidu_backup_enabled` 门控(管理观测面看存量事实) | 方案 §6 D2 建议 |
| D4 W1-B | 并入本周期 | 方案 §6 D4 建议 |
| eventColor 分组色 | **做**(方案标可选,采纳:baidu_* 11 项一组色) | PM 拍板 |
| admin 端点落点 | `routers/admin.py`(挂既有 `/api/v1/admin` 前缀 + `require_system_admin`) | 既有惯例 |
| `q` 匹配范围 | users.username OR users.name OR source_dir(ilike) | 方案 §3.1① |
| `active_only` 语义 | status IN ('enumerating','running') | 方案 §3.1① |
| 轮询 | 列表存在活动任务时 15s 自动刷新,否则停 | BaiduBackupDrawer 惯例 |
| 截断 | fail_reason / last_error 序列化前截 200 字符 | 方案 §3.1 |

## 功能点明细(逐条可验收)

### W2 审计过滤补全(纯前端,后端零改动)

- **F1**:`web/src/pages/AdminAuditPage.tsx` 的 `EVENT_TYPES`(:39-50)追加上游方案**附录 A 全部 33 项**(含 `baidu_file_imported`、`grant_revoked` 等;分组与顺序见附录 A);
- **F2**:同数组删除 2 个后端从不写入的死选项 `approval_notified`、`invite_notified`;
- **F3**:修正同文件 :36-38 过时注释(Select 无 tags 模式,「可以输自定义」实际不可用);
- **F4**:`web/src/lib/labels.ts` 修正 :9 过时注释(「共 22 种 2026-05-18」→ 以后端写入点全集 55 种为准);给 :14 `approval_card_updated` 加「后端不产出该键」注释(:25 `asset_tag_updated` 已有注释勿动);
- **F5**:`AdminAuditPage.tsx` 的 `eventColor()`(:329-337)为 `baidu_*` 11 项加一个分组色(风格与既有分组一致)。

### W1-B livp 失败文案(纯前端)

- **F6**:`web/src/components/AssetPreviewModal.tsx` livp 分支:当 `asset.tags?.thumbnail_failed` 非空时,不再显示「实况照片预览还在生成(或生成失败),请稍后刷新重试。」(:232-239 现文案),改显示明确失败卡:「预览生成失败(原因标记:{thumbnail_failed}),可下载原片查看,恢复请联系管理员」;`thumbnail_failed` 为空时维持现文案(等待生成)。下载入口复用 livp 现有下载链路(如有)或仅文案提示。

### W3 管理员备份任务视图(后端 + 前端)

- **F7**:`GET /api/v1/admin/baidu-backup/tasks`(列表,见接口定义①);
- **F8**:`GET /api/v1/admin/baidu-backup/tasks/{task_id}`(详情,见②);
- **F9**:`GET /api/v1/admin/baidu-backup/tasks/{task_id}/files`(文件明细,见③);
- **F10**:前端新页 `web/src/pages/AdminBaiduTasksPage.tsx` + 路由 `/admin/baidu-tasks`(App.tsx admin 路由组)+ AppHeader「备份任务」chip(仅 `me.is_system_admin` 显示);
- **F11**:`web/src/api/hooks.ts` 新增 hooks,基址 `/api/v1/admin/baidu-backup`;
- **F12**:列表交互:状态 Select 过滤 + 搜索框(后端 q)+ 服务端分页;列 = 用户 / 状态 Tag / 进度条 / 失败数 / 源目录 / 目标 / 创建时间 / 失败原因;存在活动任务时 15s 轮询;
- **F13**:行点击 → 抽屉:任务详情字段 + 文件明细表(服务端分页 + 状态过滤,失败行展示 last_error);
- **F14**:状态/失败原因文案与颜色**复用 labels.ts 现成映射**(BAIDU_TASK_STATUS_LABEL/COLOR :79-96、BAIDU_FILE_STATUS_LABEL/COLOR :99-116、BAIDU_FAIL_REASON_LABEL :119-127);展示后端**原始 status**,不做 `baiduTaskDisplayStatus` 的 queued 派生;进度条 enumerating 时不渲染(用户侧现状渲染 0% 条,admin 改不渲染属改进)。

## 数据库修改方案

**不涉及**——无表/字段/索引变更、无 alembic 迁移、无 FGA model 变更(复用 `organization#admin`)。

## 接口定义(全部 `Depends(require_system_admin)`,非 org admin 403;不随 baidu_backup_enabled 门控)

### ① `GET /api/v1/admin/baidu-backup/tasks`

Query:
- `status: str|None` —— enumerating/running/completed/cancelled/failed,**白名单校验,非法值 400**;
- `user_id: UUID|None`;
- `q: str|None` —— username/name/source_dir ilike 模糊;
- `active_only: bool = False` —— true 时 status IN (enumerating, running);
- `limit: int = 20(1..100)`、`offset: int = 0(>=0)`;
- 排序固定 `created_at DESC, id DESC`。

200 → `{ "items": TaskItem[], "total": int }`:

```jsonc
{
  "id": "uuid",
  "user": { "id": "uuid", "username": "…|null", "name": "…" },   // username 可空;name NOT NULL
  "status": "running",
  "source_dir": "/蕾蕾/图文素材",
  "project": { "id": "uuid", "name": "…" },      // join projects;项目行总在(FK)
  "target_folder": { "id": "uuid", "name": "…" }, // 夹已删 → null(target_folder_id SET NULL)
  "total_files": 100, "done_files": 80, "failed_files": 3,
  "skipped_files": 1, "cancelled_files": 0,       // 均可空(tables.py:546-550),序列化 0 兜底
  "total_bytes": 0, "done_bytes": 0,              // total_bytes 可空兜 0;done_bytes NOT NULL default 0
  "created_at": "…", "updated_at": "…",
  "fail_reason": null,                            // 截 200 字符
  "cancel_requested": false
}
```

### ② `GET /api/v1/admin/baidu-backup/tasks/{task_id}`

200 → TaskItem + `bound_baidu_uid`(任务表快照列,可 null)+ `binding: {id, baidu_uid, status}|null`(BaiduBinding 行)+ `cancel_reason`(user_cancel/binding_replaced,可 null)+ `retry_count / enum_done / dispatched_at / round_started_at / lease_until / runner_id`。404 = 不存在。

### ③ `GET /api/v1/admin/baidu-backup/tasks/{task_id}/files`

Query:`status: str|None`(pending/skipped_exists/importing/success/failed/cancelled,白名单非法 400)、`limit: int = 50(1..200)`、`offset`;排序 `rel_path, id`。

200 → `{ "items": FileItem[], "total": int }`,FileItem:

```jsonc
{ "id": "uuid", "source_path": "…", "rel_path": "…", "status": "success",
  "bytes_done": 0, "attempts": 1, "non_retryable": false,
  "last_error": null, "asset_id": "uuid|null", "updated_at": "…" }   // last_error 截 200
```

## 前端改动点

| 文件 | 改动 |
|------|------|
| `web/src/pages/AdminAuditPage.tsx` | F1/F2/F3/F5 |
| `web/src/lib/labels.ts` | F4 |
| `web/src/components/AssetPreviewModal.tsx` | F6 |
| `web/src/pages/AdminBaiduTasksPage.tsx`(新) | F10/F12/F13/F14 |
| `web/src/App.tsx` | /admin/baidu-tasks 路由 |
| `web/src/components/AppHeader.tsx` | 「备份任务」chip(is_system_admin) |
| `web/src/api/hooks.ts` | F11 |
| `web/src/api/types.ts` | 新响应类型(如项目惯例需要) |

## 后端改动点

| 文件 | 改动 |
|------|------|
| `api/app/routers/admin.py` | F7/F8/F9 三端点 + 响应模型(join users/projects/folders;截断;白名单;排序) |
| `api/tests/test_admin_baidu_tasks.py`(新) | 见测试功能点 |

## 测试功能点

### 后端(容器内 pytest,仿 `tests/test_grant_templates.py` 的 ASGI + Evan/outsider 模式)

- T1 非 org admin(outsider X-User-Id)访问三端点 → 403;
- T2 org admin(Evan)列表 200,跨用户可见(构造/引用两用户的任务数据);
- T3 列表分页/排序(created_at DESC, id DESC);
- T4 status 白名单:非法 status → 400;合法 status 过滤生效;active_only=true 只回活动任务;
- T5 user_id / q(username、name、source_dir 三路模糊)过滤;
- T6 不存在 task_id → 404(列表/文件两形态);
- T7 files:status 过滤 + 白名单 400 + 分页 + rel_path 排序;
- T8 fail_reason / last_error 超 200 字符被截断;聚合列 NULL 序列化为 0;username null 透传;
- T9 端点不随 baidu_backup_enabled=False 404(与用户侧 router 语义区分)。

### 前端(tsc/build 必绿 + 结构化用例)

- T10 build 绿、新指纹产出;无 Console 错误(抽查);
- T11 `/admin/audit` 下拉含「备份文件导入」「授权撤回」等全部 33 新项;命名选项 55 + 「全部」= 56 行;两死项不再出现;选中「备份文件导入」过滤生效;
- T12 非 admin 账号不见「备份任务」chip、直连 /admin/baidu-tasks 被后端 403 拦;
- T13 admin 打开页面:列表渲染/过滤/分页;状态/失败原因走 labels 映射;enumerating 无进度条;活动任务 15s 轮询(refetch);
- T14 抽屉:详情字段齐 + 文件明细分页/状态过滤/last_error 展示;
- T15 livp 失败资产(thumbnail_failed 非空)弹窗显示失败卡;正常 livp/等待中 livp 文案不变;
- T16 回归:用户侧备份抽屉(BaiduBackupDrawer/BaiduTaskDetail)零改动零影响;/admin/audit 原有过滤行为不变。

## 项目约定(子智能体必读)

- 后端检查:`cd material-storage/api && uv run ruff check . && uv run mypy app`(零新增告警);
- 前端构建:`cd material-storage && pnpm --dir web install && pnpm --dir web build`;
- 集成测试跑法:`docker exec ms-api pytest tests/… -v`(容器内;本地隔离栈见 `api/docker-compose.feat-ms.yml`,本周期由测试角色/PM 决定执行环境);
- 代码风格对齐各文件既有惯例(中文注释、审计写点、FastAPI DI noqa 标注);
- 主分支是 liuqi;本周期分支 `feat/baidu-admin-observability`,**不动主仓工作区**。
