# qdev 需求文档：百度备份并发改造（多任务排队 + VIP 分道）实施

- 日期：2026-10-19
- 状态：执行中
- **需求正本**：`rushes-spec/material-storage/baidu-backup-multi-task-concurrency-plan.md`（qplan 10 轮盲审定稿，本 worktree 内 commit 7c1d09c）。**该方案是唯一需求依据，与任何口头描述冲突时以方案为准**；方案 §2/§3/§4/§5 的全部「钉子」（qplan 修订出的实施级约束）逐条必须落地，禁止以「简化」为由绕过。
- 分支：`feat/baidu-backup-concurrency`（基于 liuqi 8c7d463 + 方案 cherry-pick 7c1d09c）；worktree：`E:\qbb\github_not_me\rushes-lab-feat-baidu-backup-concurrency`

## 1. 背景与目标

见方案 §0：解除「单绑定单活动任务」限制（同绑定一跑一排队）+ 全局准入 2→4 + VIP 分道（非会员 ≤2、会员恒有 ≥2 槽）+ 参数化 + max_jobs 4→8。业务代码改动全部在 `material-storage/api/`，前端仅一行文案。

## 2. 工作包拆分与边界（三包并行，文件互斥）

| 工作包 | 允许改动 | 禁止触碰 | 对应方案章节 |
|---|---|---|---|
| 后端包 | `material-storage/api/app/**`（db/tables.py、db/migrations/versions/ 新迁移、services/baidu_backup.py、services/baidu_client.py、routers/baidu_backup.py、workers/baidu_backup.py、workers/main.py、settings.py） | `api/tests/**`、`web/**`、`rushes-spec/**`、既有迁移文件 | §2 全部、§3.1、§3.2、§3.3 |
| 前端包 | `material-storage/web/src/**` 中百度创建成功文案一处 | 其余一切 | §2.7 / §6-P2-b |
| 测试用例包 | `material-storage/api/tests/**`（新文件 + 指定的旧文件重写） | `api/app/**`、`web/**` | §4 T1–T18 + T10 重写清单 |

## 3. 数据库修改方案（后端包）

按方案 §2.2 执行四件事 + **tables.py 模型元数据同批改**（§2.2 第 3 条，test_db_schema 断言读模型元数据）：

1. DROP `uq_baidu_task_active`；2. CREATE `uq_baidu_task_running`（UNIQUE(binding_id) WHERE status='running'）；3. CREATE 非唯一 partial `idx_baidu_task_active_binding ON (binding_id) WHERE status IN ('enumerating','running')`；4. `baidu_bindings` 加 `vip_type smallint NULL`。
5. 新迁移文件：`api/app/db/migrations/versions/2026_10_19_0017_baidu_multi_task_concurrency.py`（顺序号接 0016；downgrade 按方案 §5.4：重建 `uq_baidu_task_active` + drop 新索引 + drop vip_type 列）。

## 4. 接口定义变更（后端包）

- `POST /api/v1/baidu/backup/tasks`：删「同绑定已有活动任务」409 前置与 IntegrityError 兜底；新增软上限前置——同绑定活动任务数 ≥ `baidu_max_active_tasks_per_binding`(默认 5) → 409「该绑定排队任务已达上限」；创建时 best-effort 刷 vip_type（uinfo 失败静默沿用旧值，绝不阻塞创建，方案 §3.1 保鲜）。
- 四个复活路由（retry-failed / files/{id}/retry / files/{id}/overwrite / files/{id}/random-suffix）：同口径受软上限约束；`_revive_and_dispatch` 返回值恒为 `enumerating`（**复活统一入队漏斗，方案 §2.5 关键修正，原 P0**：dispatch_task revive 分支去掉 case 分叉一律落 enumerating）。
- `POST /backup/binding`（及重授权）：uinfo 响应多解析 `vip_type`（缺失→None）写库；`BaiduUserInfo` 增 `vip_type: int | None`（方案 §3.1）。

## 5. 后端改动点清单（后端包，全部来自方案钉子，逐条对照实施）

1. **准入 SQL**（§2.3+§3.1）：`admission_top_task_ids` 最终实现=分道 SQL（reps 按绑定 DISTINCT ON 代表 + vip/nrm 双道，UNION 臂 LIMIT 括号包裹语法红线）；**认领后校验（workers gate）判定集合必须就是该 picked 集合**（接线声明）。参数 `limit`/`nonvip_limit` 来自 Settings。
2. **门控退出降级**（§2.3）：`release_for_queueing` 对 status='running' 的行同步降为 enumerating（enum_done 保留）。
3. **sweeper**（§2.3 配套）：候选**批量查询排序键**换 `round_started_at NULLS LAST, created_at, id`；**去重只加派发分支**（终态化支 cancel/48h 不去重），派发候选按 DISTINCT ON(binding_id) 取代表。
4. **belt**（§2.4）：枚举收尾 UPDATE（workers:630-634 一带）捕获 IntegrityError → rollback（不得再读会话内 ORM 属性）→ 新事务置 enum_done=true + release_for_queueing → 返回 "queued" 不进导入循环。
5. **复活漏斗短路**（§2.5）：`_run_claimed` 对 `status='enumerating' 且 enum_done=true` 跳过重枚举，先做目标夹存在性预检（同 `_enumerate` :547-565 形态：auto_created 重建写回 / 显式删→任务级失败），再走聚合+空目录判定+收尾 UPDATE 进导入循环。
6. **31045 四件套**（§2.6）：`_refresh_locked_once` 加 `force` 旁路（跳过新鲜度短路；force 路径刻意不去重，并发安全=行锁+轮换 token 复读）；刷新调独立 session 且成功后 `db.refresh` 主会话 binding；`force_refresh_access_token` 加 `expire_binding_on_exhaustion: bool = True`，31045 调用点传 False；耗尽异常回落 link_expired 重取 dlink。
7. **Settings**（§3.2）：新增 `baidu_admission_limit=4` / `baidu_nonvip_admission_limit=2` / `worker_max_jobs=8` / `baidu_max_active_tasks_per_binding=5`；`validate_baidu_settings` 加红线 `1 ≤ nonvip ≤ admission-2`（隐含 admission≥3）+ 软上限 ≥1；workers/main.py `max_jobs` 改读 Settings。
8. **死代码**：删 `has_active_task`（services:464-473）。
9. ADMISSION_LIMIT 常量由 Settings 取代（保留 SWEEP_BATCH）。

## 6. 前端改动点（前端包）

创建任务成功文案（方案 §6-P2-b）：在既有成功提示中补「已有任务执行中，新任务将排队，前序完成后约数分钟至一刻钟内自动开始」语义（措辞可微调，量化口径「数分钟至一刻钟」保留）。仅此一处；禁改任何其他逻辑/样式。

## 7. 测试功能点（测试用例包）

方案 §4 T1–T18 逐条（含 T5a；T4 的 DB 直 seed 构造、T8 的四断言、T12 的跨道置换+6 上界、T16 的零 list 调用+目标夹预检子用例、T17 的批量边界+cancel 支子断言），外加 T10 指定的旧测试重写：`test_db_schema.py:104-133`、`test_baidu_integration.py:2614-2638`（互斥）与 `:2641-2703`（test_admission_three_queued_top2_deterministic）按 4 槽+去重+分道语义重写、`test_admin_baidu_tasks.py:33` docstring 更正。本阶段**只写不跑**。

## 8. 项目约定

- 后端 Python：FastAPI + SQLAlchemy async；依赖 pin 锁死（本批**零新增依赖**）；新迁移接 alembic 链。
- 测试跑法（验收阶段由 PM 在隔离栈执行）：`docker compose -f api/docker-compose.feat-ms.yml` 起栈 → alembic upgrade + dev_bootstrap + seed_demo_data + FGA 推 model → 容器内 pytest；MSYS_NO_PATHCONV=1。
- 子智能体**不执行 git commit**，改动留在工作区由 PM 验收后统一提交。
- 代码风格与注释密度贴既有文件（中文注释、钉子处注明方案章节号）。

## 9. 模糊点与决策记录

- 方案 D1–D12 及 qplan 全部修订=已拍板决策，直接执行，不再询问。
- PM 补充拍板：①P2-b 文案纳入本批（方案允许「顺手」）；②P2-c（旧方案文档状态回写）由 PM 收尾时顺手修，不派发；③P2-d（`_current_token` 会话隔离）按方案明确**不做**（另批）；④部署（dev/prod）不在本批范围，交付后待用户指令；⑤测试一律进隔离栈跑，不动 hh2。
