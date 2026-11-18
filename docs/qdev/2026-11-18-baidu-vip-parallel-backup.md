# 百度网盘备份：同绑定会员多路并发方案（会员 ≤3 路、非会员维持原语义）

- 日期：2026-11-18
- 前置方案：`docs/qdev/2026-10-19-baidu-backup-concurrency.md`（解除单绑定单活动任务 + 全局准入 4 槽 + VIP 分道）
- 状态：方案定稿待实施（qplan 盲审循环产出）

## 1. 背景与目标

### 1.1 背景

2026-10-19 并发方案把准入语义定为「每绑定一个最老代表」（`admission_top_task_ids` 中 `DISTINCT ON (Task.binding_id)`），sweeper 派发段同款每绑定每拍 ≤1 job（`seen_bindings` 去重），并在 DB 层加了 `uq_baidu_task_running` 唯一 partial 索引兜底「同绑定仅 1 个 running」。效果是：**同一用户（=同一绑定，`uq_baidu_binding_user` 保证一用户一绑定）的多个任务被三层机制钉死串行，全局 4 个通道中其余槽位空转**。

2026-11-18 生产实况：14 个活动任务全部来自同一会员绑定（vip_type=2），1 个 running（/讨喜素材 158 文件 84GB）+ 13 个 enumerating 排队（清单都未枚举），4 通道仅用 1。单任务单流实测聚合 ≈8.7 MB/s（近 1 小时完成 33 文件/25GB）。该用户串行跑完全部任务预计按天计。

### 1.2 目标

- 会员绑定（`vip_type ≥ 1`）允许**最多 3 个任务同时执行**；非会员绑定**完全维持现状**（每绑定并发 1，非会员道 ≤2，全局 4 槽）。
- 不动全局准入上限（4）、非会员道上限（2）、worker_max_jobs（8）、创建侧软上限（`baidu_max_active_tasks_per_binding`，prod=50）。
- 并行度 env 可调、**回滚杆 = env 设 1 即恢复现状语义**；**一次 Alembic 迁移**（0022，删除 DB 层 belt 唯一索引，§3.2）、零接口变更、零前端必改项。

### 1.3 非目标（明确不做）

- 不做同绑定任务间的文件级并行（单任务内部仍是单文件顺序流）。
- 不做按百度账号聚合带宽限速/整形（先实测并行聚合吞吐再议，见 §8）。
- 不改创建侧排队语义与 409 文案（2026-11-18 刚闭环）。
- 不改 `BaiduNewTaskModal.tsx:100` 排队预期文案——「已有任务执行中时,新任务将排队,前序完成后约数分钟至一刻钟内自动开始」在 3 路并行下仍成立（槽满时排队；有空槽时更快开始，文案是上界描述，不改以避免冗余发版）。

## 2. 现状依据（代码事实，行号基于 157154d）

| # | 事实 | 位置 |
|---|---|---|
| F1 | 准入 SQL：活跃任务 `DISTINCT ON (Task.binding_id)` 取最老代表，vip/非会员双道括号子查询截流，非会员二次收紧 `GREATEST(limit - vip_count, 0)`；代表序 `round_started_at nulls_last, created_at, id` | `api/app/services/baidu_backup.py:468-558` |
| F2 | 认领后门控：job 认领后校验 `runner.task_id in picked`，否则 `release_for_queueing` 降回 enumerating 交 sweeper 重派；**接线声明：判定集合必须就是 picked 集合**（T11 防接错线） | `api/app/workers/baidu_backup.py:265-277` |
| F3 | sweeper 派发段 `seen_bindings: set` 每绑定每拍只派 1 个 job，非代表行顺延一拍；候选谓词=活动中+租约 NULL/过期+`dispatched_at` NULL/超 `baidu_sweep_throttle_s`(600s)；cron 每 5 分钟一拍 | `api/app/workers/baidu_backup.py:2038-2098`；`api/app/workers/main.py:1153` |
| F4 | 设置默认：`baidu_admission_limit=4`、`baidu_nonvip_admission_limit=2`（assert `1 ≤ nonvip ≤ limit-2`）、`worker_max_jobs=8`；prod env 未设 admission 相关 → 默认值生效；prod `BAIDU_MAX_ACTIVE_TASKS_PER_BINDING=50`（软上限消费方为 ms-api，`routers/baidu_backup.py:760`） | `api/app/settings.py:151-165, 213-225` |
| F5 | token 刷新独立 session + binding 行锁 + 刷新后重读（会话隔离 §2.6.2），并发刷新安全 | `api/app/services/baidu_backup.py:1064-1102` |
| F6 | errno 31045（token 校验未通过，语义待定）归类 link_expired，worker 侧 refresh-first 兜底重试 | `api/app/services/baidu_client.py:71-74`；`api/app/workers/baidu_backup.py:1207+` |
| F7 | key 冲突机制边界：W2 自动后缀**仅当占用者资产全部属于其他项目**（`_auto_suffix_eligible` 要求 `pid != task_project_id`）；同项目同名 → 行级 `key_conflict` 失败（可重试） | `api/app/workers/baidu_backup.py:915-923` |
| F8 | 一用户一绑定：`uq_baidu_binding_user` | `api/app/db/tables.py:545` |
| F9 | 改 env 后 `docker compose restart` 不重读 env_file，须按消费方 `up -d --force-recreate` | `api/app/settings.py:148-152` docblock |
| F10 | **DB 层 belt**：`uq_baidu_task_running` = `UNIQUE(binding_id) WHERE status='running'`（partial 唯一索引），注释明示「恰好护住最危险的『同绑定双下载循环』」——把同绑定 running 数钉死在 1，是 2026-10-19 方案的刻意设计 | `api/app/db/tables.py:628-635` |
| F11 | belt 的创建与守护：迁移 0017 创建（`2026_10_19_0017_baidu_multi_task_concurrency.py:41-45`）；`test_db_schema.py:169-187` 断言索引存在（`:190-204` 另有谓词子集断言测试）；worker 枚举收尾是全系统唯一置 `status='running'` 的点（:600-653），撞索引即 `IntegrityError` → belt 回排队（`enum_done=true` 保留）；T4 用例（`test_baidu_concurrency.py:386-444`）钉死该行为；T18（`test_baidu_concurrency.py:1470-1475`）断言 pg_indexes 中索引存在；迁移 head=**`20261118_0021`**（同名夹开关周期新增，接 `20261115_0021` 用户模块单头；**dev/prod 双端已于 2026-11-18 升至该版**） | 同左 |

**推论**：同绑定串行是**三个点**的叠加——① 准入 SQL 每绑定 1 代表（F1）；② sweeper 每绑定每拍派 1 job（F3）；③ DB 层 running 唯一索引（F10/F11）。**三处必须同步处理**：只改①②不改③，3 个任务都会过门控、各自枚举，但在枚举收尾置 running 时第 2/3 个必撞索引 → belt 回排队 → sweeper ≤600s 重派 → 短路直达收尾 → 再撞 → 无限 churn、并行收益为零。

## 3. 方案设计

### 3.1 新设置项（唯一新增配置）

`api/app/settings.py` 新增：

```python
baidu_vip_parallel_per_binding: int = Field(
    3, description="同绑定会员(vip_type≥1)准入代表数上限,即同绑定并行路数;"
                   "非会员绑定恒为 1(原语义);设 1 = 完全恢复原行为(回滚杆)",
)
```

校验断言（加入 `validate_baidu_settings`）：

- `1 ≤ baidu_vip_parallel_per_binding ≤ baidu_admission_limit - 1`：下限 0/负值会静默砖死会员准入；**上界 = limit-1（默认 3=4-1）**——配满 limit 会令 `GREATEST(limit - vip_count, 0)=0` 配置性饿死全部非会员道且无启动报错，正是既有「nonvip ≤ limit-2」红线要防的同类静默清零（方向相反），断言拦截（与既有 assert 风格一致，启动即报）。
- **启动校验面 = ms-api + ms-worker 双容器**（`app/main.py:74` lifespan 与 `workers/main.py:1160-1164` on_startup 都跑 `validate_baidu_settings`）——非法 env 值会让两侧都启动失败，误配排查时勿只盯 worker。
- **运行时消费 = ms-worker 单容器**（准入门控与 sweeper 均在 worker 进程；创建侧软上限是另一个设置、消费在 ms-api，不受影响）。改 env 须 `docker compose up -d --force-recreate ms-worker`（F9）。

完成标准：settings 字段+断言落地，非法值启动即报错；默认 3 不设 env 时生效。

### 3.2 DB 层 belt 索引移除（迁移 0022，P0 前置）

新增 Alembic 迁移 `2026_11_18_0022_baidu_vip_parallel.py`（`down_revision = "20261118_0021"`；0021 编号已被两代占用——`20261115_0021` 用户模块组级授权、`20261118_0021` 同名夹开关周期（接 20261115_0021 单头，dev/prod 双端已升），head 即 `20261118_0021`）：

- `upgrade`：`DROP INDEX uq_baidu_task_running`。仅此一项，无数据变更，秒级完成。
- `downgrade`：重建该索引（保持可逆；down 后语义 = 回到 0017 时点行为）。**downgrade 前置条件**：库中存在同绑定多条 running 时重建唯一索引会直接失败——runbook：先回滚杆 env=1 或等任务排空，确保每绑定 ≤1 running 再 downgrade；否则先终态化多余 running 行。

**理由**：partial 唯一索引谓词只能引用本表行内列，无法表达「非会员绑定才限 1」（vip_type 在 bindings 表）——保留即钉死会员 1 路。belt 职责移交参数化准入门控（§3.3）。

**残余风险（接受并记录）**：belt 是 defense-in-depth，删除后「同绑定 running 数上限」的唯一防线 = 准入门控 picked 集合（认领时点判定）。若门控逻辑自身出 bug，爆炸半径 = 同绑定并行超预期（带宽挤占、31045 放大），**无数据损坏路径**（任务间状态全部行级隔离，见 §3.5），靠 I1-I6/R12 测试网 + §6 观察项兜底，风险可接受。

**配套处置**：

- worker 枚举收尾的 `IntegrityError` → belt 回排队分支（:600-653）**保留为通用兜底**（防未来其他唯一约束冲突无归处），不再依赖 running 索引触发。
- `test_db_schema.py` 两处：`:169-187` 断言改写为「`uq_baidu_task_running` 不存在」；`:190-204` 谓词子集测试**整体删除**（`indices["uq_baidu_task_running"]` 会 KeyError，无可改写价值）。T7 谓词漂移断言口径同步：模型元数据中删除该 Index 定义（`idx_baidu_task_active_binding` 保留不动）。
- 既有 T4 用例（同绑定第二任务枚举收尾撞索引回排队）**重做**为 §5-R11；T18（:1470-1475，pg_indexes 断言）翻转为「不在 by_name」。
- 三处注释性引用顺手更新（断言本身仍成立、仅语义描述失真）：`test_admin_baidu_tasks.py:33`、`test_baidu_concurrency.py:847`、`:1277`。

**回滚语义**：env=1 回滚杆**不需迁移回退**（索引缺位时每绑定最多 1 running，行为与有索引时等价）；若整包回滚代码，旧代码门控仍限 1 路、无索引也不受影响（仅丢 defense-in-depth），必要时按上方 downgrade 前置条件独立补回。

完成标准：迁移 0022 落地且 dev/prod `alembic upgrade head` 后 R12 断言通过；T4/T18 重做后全绿。

### 3.3 准入 SQL 参数化（F1 改造）

`admission_top_task_ids(db, *, limit, nonvip_limit, vip_par)` 新增 `vip_par` 参数。**`vip_par` 为必选关键字参数、不设默认值**——陈旧调用点直接报错，避免「默认 1 静默走旧语义」掩盖接线遗漏（与接线声明文化一致）。

reps CTE 从 `DISTINCT ON (binding_id)` 改为窗口函数编号：

```python
rn = func.row_number().over(
    partition_by=Task.binding_id,
    order_by=(Task.round_started_at.nulls_last(), Task.created_at, Task.id),
).label("rn")
```

- 代表序与现状完全一致（round 非空的 running 恒排前 → 稳态下每绑定的前 vip_par 个代表 = 正在跑的任务优先占坑，后续按创建序排队）。
- **会员道**：`where is_vip AND rn ≤ vip_par`，仍按代表序截前 `limit` 条（vip_pick 括号子查询语法红线保持——裸写臂级 LIMIT 会作用于整个并集，:477-480 注释原样保留）。
- **非会员道**：`where NOT is_vip AND rn ≤ 1`（硬编码 1 = 原语义，不设 env）。
- 二次收紧 `GREATEST(limit - vip_count, 0)`、UNION ALL、final order **原样不动**。
- docstring 同步改写：删除「单用户多任务只占一个并发坑」，改为「会员绑定至多占 vip_par 坑、非会员绑定恒 1 坑」；接线声明文字保留（本改造不改变"gate 判定集合 = picked 集合"的结构，worker 调用点传同一 settings 值）。

**语义不变量（改造后仍全部成立）**：

| 不变量 | 表述 | 来源 |
|---|---|---|
| I1 | 总 picked ≤ limit(4) | vip_pick/nrm_pick 截流 + 二次收紧 |
| I2 | 非会员代表 ≤ nonvip_limit(2) | nrm_pick LIMIT（rn≤1 只影响每绑定配额） |
| I3 | 非会员绑定每绑定 ≤1 代表 | `rn ≤ 1` |
| I4 | 会员绑定每绑定 ≤ vip_par(3) 代表 | `rn ≤ vip_par` |
| I5 | 会员恒有 ≥2 槽可用 | 由 I2 推出（非会员最多占 2），语义保持 |
| I6 | 接线声明：门控判定集合 = picked 集合 | 同一函数同参返回，结构不变 |

完成标准：SQL 改造落地且 I1-I6 有对应测试用例（§5）。

### 3.4 sweeper 派发预算参数化（F3 改造）

`sweep_stalled_baidu_tasks` 派发段：

- 候选查询 join `BaiduBinding` 带出 `is_vip`（`(coalesce(vip_type,0) >= 1)`，与准入 SQL 同口径）。
- `seen_bindings: set` 改为派发预算 Counter：VIP 绑定预算 = `settings.baidu_vip_parallel_per_binding`，非会员绑定预算 = 1；预算耗尽的绑定，其非代表行照旧顺延一拍（语义无损注释保留）。
- 终态化支（flag/cancel_requested/48h）**全量候选不去重**的现状不动——取消位行不受派发预算压制，用户点取消即刻终态化。
- 排队回填时延：槽位空闲后，下一个排队任务经 sweeper 拾起受两段既有时延约束（释放行 600s 派发节流 + 5min cron 一拍），**最坏 ≈15min 内开始**，与前端文案「数分钟至一刻钟」吻合，不新增代码。3 个空槽一次拍内可全部填满（预算 3 一次派 3 个 job）。

**churn 分析（接受）**：`release_for_queueing` 不复位 `dispatched_at`（`services/baidu_backup.py:439-465`），门控退回行受 600s 节流压制——准确口径为**每行每 600s ≤1 次、每绑定每 cron 拍（5min）≤3 次（≈每 600s ≤6 次）**门控退出 job（现状为每绑定每拍 1 个）。每个 job 成本 = 一次认领 CAS + 一次准入 SELECT + 一次释放 UPDATE，短命常数级，系数 1→3 可接受；瞬态在途 job 上限 = 4 准入 + ≤3 churn + cron（sweep timeout=300），`worker_max_jobs=8` 仍够用（观察期勿把缩略图瞬时延迟误判为回归）；不做「按在跑数扣减预算」的优化（复杂度不值）。

完成标准：预算参数化落地；取消支不受影响有测试；churn 结论以注释形式固化。

### 3.5 并发安全复核（全部复用既有机制，零新增锁）

| 关注点 | 结论 | 依据 |
|---|---|---|
| token 并发刷新 | 安全：独立 session + binding 行锁 + 刷新后重读 | F5 |
| 31045 触发频率 | 同 token 并行下载流会放大触发；worker 侧 refresh-first 兜底已存在；生产观察项见 §6，回滚杆兜底 | F6 |
| 同绑定并行枚举 | **前提修正：并行任务可能同 source_dir**（生产现存重复目录实况）。目录建链安全有硬证据：`uq_folder_project_prefix` 唯一约束 + `ensure_folder_chain` 对 IntegrityError 捕获改查复用。百度 list API 限流有既有退避机制：`rate_limited` 指数退避（worker:515-521），退避耗尽任务终态 `enum_rate_limited`（:527,551-554，可复活重枚举）；3 路并发枚举的限流风险列入 §6 观察项 | tables.py:139；`folder_chain.py:189,253,317`；worker:515-554 |
| 同名文件并发导入（两任务目标夹相同=同项目） | **机制修正：W2 自动后缀不触发**（仅跨项目占用者才走后缀，F7）。实际行为：后到行首检/complete 前二检判 `key_conflict` 行级失败（worker:1785-1797, 1840-1850）→ 可重试 → 重试时被「步骤 2 同名跳过」收敛为 `skipped_exists`（:1048-1058）。无 500、无数据损坏 | worker:1785-1797, 1840-1850, 1048-1058 |
| assets 唯一约束兜底 | **不构成实际兜底**：约束含可空 `minio_version_id`（tables.py:176-178），取值 `head.get("version_id")`（worker:1902）恒 NULL，PG15 默认 NULLS DISTINCT → 同 key 双插不会被拦。窄窗口（check-then-act）可能重复 asset 行 → 接受并记录（§8-L5），重试收敛机制使窗口极小 | tables.py:176-178；worker:1902 |
| skipped_exists 判定竞态 | 同上行口径：两任务同时判「不存在」后并发建同 key，后到方 `key_conflict` 失败重试后收敛 skipped；最坏窄窗口重复 asset（L5） | 上两行合并 |
| MinIO multipart 会话 | 每任务文件三元组独立（task_id 维度），无跨任务共享状态 | tables.py:646+ |
| 租约/接力/48h/审计去重/进度聚合 | 全部 task 行级 CAS 与 task 维度去重（`AUDIT_DEDUP_FMT` worker:138），任务间无耦合；done/total_files 为 task 行级重算 | F2/现状 |
| 会员中途掉 vip | 准入在认领时点判定：已认领任务跑完为止，不回收；新准入按新 vip_type | 现状语义 |

完成标准：本表逐条有对应测试或生产观察项（§5/§6）。

## 4. 改动点清单

| # | 文件 | 改动 | 完成标准 |
|---|---|---|---|
| C0 | `api/app/db/migrations/versions/2026_11_18_0022_baidu_vip_parallel.py`（新增，down_revision=`20261118_0021`） | `DROP INDEX uq_baidu_task_running`；downgrade 重建（runbook 见 §3.2 前置条件）；模型元数据同步删该 Index 定义 | dev/prod upgrade 后 R12 过；可逆 |
| C1 | `api/app/settings.py` | 新增 `baidu_vip_parallel_per_binding=3` + 断言 `1 ≤ x ≤ admission_limit-1`；docblock 注明「运行时消费=ms-worker；启动校验=ms-api+ms-worker 双容器」 | 非法值启动报错；默认 3 生效 |
| C2 | `api/app/services/baidu_backup.py` | `admission_top_task_ids` 加必选参数 `vip_par`（无默认值）；reps 改 `ROW_NUMBER() OVER (PARTITION BY binding_id ...)`；vip 道 `rn ≤ vip_par`、非会员道 `rn ≤ 1`；docstring/红线注释同步 | I1-I6 成立；语法红线注释保留；生产调用点全适配 |
| C3 | `api/app/workers/baidu_backup.py` | `_run_claimed` 调用点传 `vip_par=settings.baidu_vip_parallel_per_binding`；sweeper 候选 join bindings 带出 is_vip；`seen_bindings` → 预算 Counter（VIP=vip_par / 非会员=1）；belt 分支保留为通用兜底；注释更新 | sweeper 派发预算用例过；取消支不变 |
| C4 | 测试适配与新增 | `test_baidu_concurrency.py`（新增 R1-R13 + **T4 重做** + **T18 翻转**（:1470-1475）+ **`_admission` 助手（:278-282）补 `vip_par` 形参（默认 3）** + 三处注释措辞更新（:847/:1277，另 `test_admin_baidu_tasks.py:33`）；T17 系列**不需适配**（三用例均非会员绑定 lanes.add(vip_type=None)，预算=1 与现状逐位等价，「每绑定每拍恰派 1」断言原样成立））；`test_baidu_integration.py`（:2700 等 `admission_top_task_ids` 直呼点补 `vip_par` + **`test_same_binding_multi_task_queue_running_unique_backstop`（:2648-2650）重做**——直插同绑定第二条 running 撞索引的 `pytest.raises(IntegrityError)` 断言改为「可多条 running 直插、行为由准入门控约束」）；`test_db_schema.py`（:169-187 改「不存在」+ :190-204 谓词子集测试删除） | 全量 pytest 绿 |
| C5 | 记账 | `scripts/changelog.md` 当天条目（一句话 + commit hash） | 条目可溯 |

- 一次 DB 迁移（C0）、零接口（router）变更、零前端必改项（§1.3）。
- 工作包划分：C0-C4 同仓同包（改动集中、互锁强，不拆并行包），单人单包交付。

## 5. 测试功能点（全部可自动验收）

既有 `test_baidu_concurrency.py` 风格沿用（staged 准入场景 + 假 client）。新增：

| # | 用例 | 断言 |
|---|---|---|
| R1 | 会员绑定 5 个活动任务 | picked 恰含该绑定最老 3 个（rn 序），其余不在 picked |
| R2 | 会员绑定 3 rep + 另一会员绑定 1 任务 | 总 picked=4，两绑定都入选 |
| R3 | 会员 3 rep + 非会员 2 绑定各 1 | vip_count=3 → 非会员二次收紧到 1，总=4；I2/I5 成立 |
| R4 | 非会员绑定 5 个活动任务 | picked 恰含 1 个（原语义回归） |
| R5 | `vip_par=1` 回归网 | 与 DISTINCT ON 旧实现输出逐一对齐（多绑定多任务矩阵抽样比对） |
| R6 | 同绑定 4 个会员 rep + 第二会员绑定 | 本绑定 3 + 他绑定 1（I4+I1 边界） |
| R7 | 非会员多绑定 ≥3 个 | 仍 ≤2（I2 既有不变量回归） |
| R8 | sweeper 预算 | 会员绑定 5 候选 → 恰派 3，2 条顺延；非会员绑定 3 候选 → 恰派 1 |
| R9 | 预算耗尽 + cancel_requested 行 | 取消支仍立即终态化（不受预算压制） |
| R10 | settings 校验 | vip_par=0、负数、**vip_par=limit（=4）与 limit+1 各一例** → 启动断言报错（覆盖 `≤ limit-1` 两个边界方向） |
| R11 | **同绑定 2/3 任务并发达 running**（T4 重做，迁移 0022 落地后运行） | 断言口径（贴合既有基建：`_claim_and_run` 会把单文件任务一口气跑完，不停留在 running）：① 3 任务逐一驱动，全部通过枚举收尾进入导入循环直至终态，**全程无一返回 queued**（无 belt churn、无 list 重放）；② 并发形态定格仿 T12 DB seed：seed 2 条 running + 驱动第 3 条过枚举收尾后 `_running_ids()` 含 3 条 |
| R12 | schema 断言改写（`test_db_schema.py` + T18 实库口径） | `test_db_schema.py:169-187` 断言 `uq_baidu_task_running` 不存在、`:190-204` 谓词子集测试已删；T18（pg_indexes 实库）翻转为「不在 by_name」；`idx_baidu_task_active_binding` 谓词漂移断言口径不变仍过 |
| R13 | **worker 接线/回滚杆端到端**（仿 `_claim_and_run` + make_settings 风格，:748-763） | make_settings 置 `baidu_vip_parallel_per_binding=1`：会员绑定 3 个候选仅 1 个过门控（其余 queue out）——钉住 worker 调用点真读 settings，兼作回滚杆验收回归网 |

完成标准：R1-R13 全绿 + 既有全量并发/集成/schema 用例绿（隔离栈或 hh2 dev 容器，`pytest -o asyncio_mode=auto`；不在本地跑 docker，遵 CLAUDE.md）。

## 6. 部署与回滚

1. **dev 先行**：**第一步对账 `alembic current` vs head（dev 预期 `20261118_0021`），落后先 `upgrade head`（落 0022）再动代码**；部署 dev（ms-api-dev / ms-worker-dev force-recreate）→ 用 dev 环境（dev FGA=8189 入口）实测同绑定会员 3 路并发：3 任务同时 running、总准入 ≤4、非会员行为不变。
2. **prod**：**第一步必对账 alembic current vs head（prod 预期 `20261118_0021`），落后先 upgrade（落 0022）再 restart**（deploy_lan 无 alembic 步骤，历史已多次人工补，最近一次为同名夹开关周期双端升 20261118_0021）。部署代码（默认 vip_par=3 生效，无需设 env）；force-recreate 顺序 = 先 ms-api 后 ms-worker，若 ms-api 容器 IP 变化则连带 `docker restart poc-nginx`（静态 proxy_pass 持旧解析全站 502 的既有坑）。观察窗口 ≥ 半个任务周期。
3. **观察项**（生产实测，兼作百度限速口径判别）：
   - 同绑定 3 路并行时各任务流内速率：若单流速率 ≈ 并行前的 1/3（≈账号级限速）→ 聚合收益存疑，向用户汇报数据后再定去留；若单流速率基本不变（≈连接级限速）→ 收益成立。
   - 31045 出现频率对比部署前（log/audit 检索 `31045`）：显著放大且伴随重试风暴 → 回滚杆先拉。
   - `enum_rate_limited` 终态出现频率：13 个待枚举任务同绑定 3 路并发枚举可能放大 list 限流（可复活重枚举自愈，但应可观测）。
   - 同绑定 running 计数是否恒 ≤3（准入门控是 belt 移除后的唯一防线，D8）。
4. **回滚杆**：`BAIDU_VIP_PARALLEL_PER_BINDING=1` + `docker compose up -d --force-recreate ms-worker`（F9：restart 不重读 env）。语义完全等价现状，**无需回滚代码与迁移**（§3.2 回滚语义）。
5. 记账：`scripts/changelog.md` 当天条目（一句话 + commit hash）。

## 7. 决策记录

| # | 决策 | 理由 |
|---|---|---|
| D1 | 并行度=3 且 env 可调（`BAIDU_VIP_PARALLEL_PER_BINDING`），非会员硬编码恒 1；断言上界=limit-1（默认 3=4-1） | 用户口径 3；env 化给出零代码回滚杆；非会员语义「保持原本规则」= 不引入新参数面；上界 limit-1 防配满后 `GREATEST(limit-vip_count,0)=0` 配置性饿死非会员道（与既有 nonvip ≤ limit-2 红线同精神） |
| D2 | 全局 4 槽、非会员道 ≤2 不动 | 用户要求非会员维持原样；「会员恒有 ≥2 槽」由 I2 推出，天然保持 |
| D3 | 会员判定 = 准入时点 `binding.vip_type ≥ 1`，跑动中掉会员不回收 | 与现状快照语义一致，避免运行中抖动 |
| D4 | 枚举阶段同绑定并行放行（不做枚举独占） | 准入门控在枚举前统一判定，引入「仅导入阶段并行」会把状态机切两半，复杂度不成比例；同 source_dir 并行枚举由既有退避+复活机制兜底（§3.5），限流风险进观察项 |
| D5 | churn 预算 1→3 接受，不优化 | 每绑定每 cron 拍 ≤3 个门控退出 job（≈每 600s ≤6 个），短命常数级开销；瞬态在途上限仍 ≤ worker_max_jobs=8；优化需引入在跑数统计，复杂度不值 |
| D6 | 前端排队文案不改 | 现文案是上界描述，3 路并行下仍成立 |
| D7 | 同项目同名并发导入不做目标夹互斥、不路由 W2 | W2 语义=跨项目并存（F7），同项目场景 key_conflict 失败+重试收敛 skipped 是现状行为且无损坏；互斥会让「两个重复目录任务」直接报错 |
| D8 | **删除 `uq_baidu_task_running` belt 索引**，唯一防线=参数化准入门控 | partial 唯一谓词无法表达 vip 维度，保留即钉死 1 路；门控 bug 的爆炸半径=并行超预期（无数据损坏路径），测试网+观察项兜底，风险可接受；worker 侧 IntegrityError 分支保留为通用兜底 |
| D9 | `vip_par` 为必选参数不设默认值 | 陈旧调用点直接报错，防「默认 1 静默走旧语义」掩盖接线遗漏 |

## 8. 遗留与风险（不阻塞本计划）

| # | 项 | 处置 |
|---|---|---|
| L1 | 百度按账号 vs 按连接限速未实证 → 并行聚合收益未定量 | §6 观察项 1 生产实测后向用户汇报；回滚杆随时可拉 |
| L2 | 31045 放大风险 | refresh-first 兜底 + §6 观察项 2；若形成重试风暴，回滚杆=env 1 |
| L3 | 生产现存重复源目录任务（两个 /923讨喜胸鼻案例） | 并行时后到行 `key_conflict` 失败重试后收敛 skipped（§3.5），无损坏；产品侧「重复目录提示」另立周期 |
| L4 | 槽位回填最坏 ≈15min（600s 节流 + 5min cron） | 与前端文案一致，接受；如需秒级回填另立周期（完成回调触发派发） |
| L5 | 同 key 重复 asset 窄窗口（check-then-act + 唯一约束 NULLS DISTINCT 不拦） | 接受并记录：窗口极小（重试即收敛）、无损坏路径；如后续实测出现再补 complete 前同 key holders 复查 |
| L6 | belt 移除后门控是唯一防线（D8） | I1-I6/R12 测试网 + §6 观察项 4；异常时回滚杆 env=1 先止血 |
