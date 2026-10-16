# 百度备份并发改造方案：多任务排队 + VIP 分道并发

- 状态：**已定稿（含 VIP 分道增强），待实施**（实施等用户指令）
- 日期：2026-10-16（同日追加 §3.3 VIP 分道）
- 作者：qdev PM（调研依据：Explore 子智能体只读调研 2026-10-16 + prod 任务表实证 + 用户四轮拍板）
- 实施分支建议：`feat/baidu-backup-concurrency`（基于 liuqi）

## 0. 背景与目标

现状两个约束限制了备份吞吐与易用性：

1. **单绑定单活动任务**（`uq_baidu_task_active` 唯一索引 + 4 处应用层前置）：用户想备份多个目录必须串行手动创建，前一个完成后才能建下一个。
2. **全局准入并发 = 2**（`ADMISSION_LIMIT=2` 硬编码，纯 FIFO）：**队头阻塞**——若 2 个非会员任务先创建（0.08 MiB/s 级），它们占满全部槽位直至跑完，后到的会员任务（1.3–2.8 MiB/s 级）只能干等，极端场景下整个备份管线被慢账号卡死。

目标（用户已拍板，2026-10-16）：

- **改动一**：放开创建限制——同一用户可同时创建多个任务，但**按绑定串行执行**（同一时间最多一个任务在跑，其余排队）。
- **改动二**：全局准入并发 2→**4** + **VIP 分道**（非会员并发上限 2，会员恒有 ≥2 槽可用）+ **参数化**（env 可调，不改代码）。

> 为什么 2→4 不够、必须分道：纯 FIFO 扩到 4 后，先到的 4 个非会员任务仍可占满全部 4 槽，会员照样饿死——扩容只是降低概率；分道把「非会员占槽上限」钉死在 2，是结构性根治。

## 1. 现状锚点（调研已核实，路径相对 `material-storage/`）

| 锚点 | 位置 | 现状 |
|---|---|---|
| DB 唯一索引 | `api/app/db/tables.py:576-582`；迁移 `migrations/versions/2026_10_08_0013_baidu_backup.py:96-101` | `uq_baidu_task_active`：binding_id WHERE status IN ('enumerating','running')，UNIQUE |
| 创建 409 前置 | `api/app/routers/baidu_backup.py:710-711` | `has_active_task` → 409 |
| 创建 IntegrityError 兜底 | 同上 `:804-807` | 撞索引转 409 |
| 复活前置 | `api/app/services/baidu_backup.py:594-595`（`guard_revival`） | 同上 |
| 复活 IntegrityError 兜底 | `routers/baidu_backup.py:1065-1067` | 同上 |
| 准入排序 | `api/app/services/baidu_backup.py:453-461` | `ORDER BY round_started_at NULLS LAST, created_at, id LIMIT N`，**无按绑定去重** |
| 认领/门控退出 | `api/app/workers/baidu_backup.py:236-266` | 认领后校验 `admission_top_task_ids`，不在前 N → `release_for_queueing` 安静退出 |
| 31045 绕锁刷新 | `api/app/workers/baidu_backup.py:1026-1063` | 直调 `runner.client.refresh_token` 覆盖双 token，安全性依赖「单任务单 runner 持有绑定」（docstring :1035）；**仅下载路径可达**（`_handle_baidu_error` 只被 `_import_one_file` 调用 :901/:950） |
| 枚举路径 token | `api/app/workers/baidu_backup.py:473-506` | `_current_token` → ensure/force refresh（行锁单飞，并发安全） |
| 准入/批量常量 | `api/app/workers/baidu_backup.py:126-127` | `SWEEP_BATCH=50`、`ADMISSION_LIMIT=2` 硬编码 |
| worker 并发 | `api/app/workers/main.py:678-693`；`api/docker-compose.yml:66-80` | 单进程 `max_jobs=4` 全池（百度+缩略图+cron 同池），baidu job `timeout=3600, max_tries=1` |
| 索引锁死测试 | `api/tests/test_db_schema.py:104-133`、`test_baidu_integration.py:2615-2640` | 断言唯一索引存在 + 互斥行为，须随方案重做 |
| manifest 幂等 | `workers/baidu_backup.py:516-518` | ON CONFLICT (task_id, rel_path)——task 级作用域，跨任务不互踩 |
| 换绑取消 | `routers/baidu_backup.py:217-249` | 已是「多活动任务循环取消」形态，天然兼容 |
| uinfo 调用 | `api/app/services/baidu_client.py:326-340`；`routers/baidu_backup.py:368`（bind/重授权时调） | 已申报六接口之一；现状只解析 uid/nickname，**vip_type 在响应体中但被丢弃** |
| 绑定表 | `api/app/db/tables.py` `BaiduBinding`（uq_baidu_binding_user，1 用户 1 绑定） | 新增 `vip_type` 列的宿主 |

**prod 实证速率（2026-10-16 任务表）**：近期完成任务全程均值 1.3–2.8 MiB/s（会员账号）；非会员 0.08 MiB/s 仅适用于非会员子集，**系统级容量估算必须用混合分布**。`speed_bps` 在终态被清零，完成任务纯传输速率不可回查（本方案顺带修，见 §6-P2）。

## 2. 改动一：解除单活动任务 → 单绑定串行（一跑一排队）

### 2.1 设计不变量（本方案的安全根基）

> **任一时刻，每个绑定至多一个「已被认领（持活租约）的任务」在执行**（枚举或传输都算）。

这条不变量保住了现状全部安全假设：31045 的「单 runner 持绑定」docstring 前提、token 刷新不并发互踢、同用户任务的 canonical-key check-then-write 竞态（串行后消失，`plan.md:225` 竞态①③被结构性关死）。排队中的任务是纯 DB 行（不碰百度 API、不占 worker 槽），排队零成本。

### 2.2 DB 迁移（一个 migration，前后兼容）

1. **DROP** `uq_baidu_task_active`（binding_id WHERE active 的 UNIQUE）——否则第二个任务根本建不出来。
2. **CREATE** 弱一级兜底 `uq_baidu_task_running`：`UNIQUE (binding_id) WHERE status = 'running'`——恰好护住最危险的「同绑定双下载循环」；枚举期互斥由准入层负责（枚举走单飞刷新，本身安全）。
3. 保留/新建**非唯一** partial index `idx_baidu_task_active_binding ON (binding_id) WHERE status IN ('enumerating','running')` 供准入查询。
4. `baidu_bindings` 新增 `vip_type smallint NULL`（§3.1 分道数据源；存量行 NULL=未知，按非会员处理，随下次 bind/重授权/任务创建自然回填，不做批量回灌）。

### 2.3 准入层按绑定去重（核心改动）

`admission_top_task_ids` 改为两段式（SQL 语义）：

```sql
SELECT id FROM (
  SELECT DISTINCT ON (binding_id) id, binding_id, round_started_at, created_at
  FROM baidu_backup_tasks
  WHERE status IN ('enumerating','running')
  ORDER BY binding_id, round_started_at NULLS LAST, created_at, id
) t
ORDER BY round_started_at NULLS LAST, created_at, id
LIMIT :limit;
```

性质（实施时用测试钉死）：

- 每绑定只推**最老一条**代表；running 任务（round_started_at 非空）恒为该绑定代表 → 稳态下槽位=不同绑定。
- **单用户多任务只占一个并发坑**——天然公平，不挤占他人。
- 槽满（前 N 全是 running）时 dormant 任务不进前 N → 认领后门控退出，行为与现状排队一致。

### 2.4 枚举→running 撞兜底索引的 belt 处理

瞬态窗口（两个同绑定任务短暂都被认领）下，年轻任务枚举完成置 running 时可能撞 `uq_baidu_task_running`。处置：该 UPDATE 捕获 UniqueViolation → **`release_for_queueing` 回排队**（清租约/轮钟，等下一拍 sweeper 重派），**不得终态化失败**。锚点：`workers/baidu_backup.py` 枚举收尾的 `UPDATE ... VALUES(status='running', enum_done=True)`（:637-643 一带）。

### 2.5 创建/复活侧改动

- 删 4 处：创建 409 前置（`routers/baidu_backup.py:710-711`）+ 创建 IntegrityError 兜底（:804-807）+ `guard_revival` 前置（`services/baidu_backup.py:594-595`）+ 复活 IntegrityError 兜底（:1065-1067）。
- 新增**软上限**前置（防滥用，一次排 20 个目录）：同绑定活动任务 ≥ `baidu_max_active_tasks_per_binding`（默认 **5**，Settings 可调）→ 409「该绑定排队任务已达上限」。
- 复活（retry-failed）改为同口径：受软上限约束、入队等待，不再因「有活动任务」被拒。

### 2.6 31045 收敛单飞（顺手项，纵深防御，随本改动一并做）

`_handle_errno_31045` 弃直调 `runner.client.refresh_token`，改走 `force_refresh_access_token`（行锁单飞，`services/baidu_backup.py:1029+`）。新不变量下本无并发双跑，但拔掉这颗「依赖单 runner 假设」的雷，未来任何并发化改动都不再踩。

### 2.7 前端

**零改动**（列表/轮询/创建按钮本就是多任务形态；`disabled={!bound}` 与活动任务无关）。可选 P2：创建成功文案补一句「已有任务执行中，新任务将排队」。

## 3. 改动二：准入 4 槽 + VIP 分道 + 参数化 + max_jobs 配套

### 3.1 VIP 分道（核心新增，2026-10-16 用户拍板）

**语义**：准入集合须同时满足 ①总数 ≤ `baidu_admission_limit`(4)；②**非会员（vip_type=0/NULL）任务数 ≤ `baidu_nonvip_admission_limit`(2)**。⇒ 会员任务恒有 ≥2 槽可用，非会员永不占满全池。

**vip_type 数据源（已核实可得）**：

- uinfo（`xpan/nas?method=uinfo`）**已在调用**（bind/重授权，`baidu_client.py:326`），且属已申报六接口——**从既有响应多取一个字段，零新增 API 面**。
- 旧版语义 0=普通用户 / 1=普通会员 / 2=超级会员；`vip_version=v2` 时 0/1/2=普通/会员VIP/SVIP。**分道只需二值（会员=1或2 / 非会员=0），新旧语义在二值上完全一致——不加 `vip_version` 参数，默认调用即可**（未来要细分 SVIP 再加）。
- 落库：`baidu_bindings` 新增 `vip_type: smallint | NULL`（NULL=未知，**按非会员处理**——保守值保护会员槽位，宁可慢道误纳会员也不让非会员占快道）。迁移与 §2.2 同批。
- 解析：`BaiduUserInfo` 增 `vip_type: int | None`，`uinfo()` 取 `body.get("vip_type")`（缺失→None）；bind/重授权时写库。
- **保鲜策略**（防"绑定后升级会员"滞后）：任务创建与复活时 best-effort 调一次 uinfo 刷新该绑定 vip_type（失败静默沿用旧值，**绝不阻塞创建**）。sweeper 批量刷新为 P2 不做。

**准入 SQL（在 §2.3 按绑定去重的基础上叠分道，语义草样）**：

```sql
WITH reps AS (  -- §2.3 每绑定最老代表 + join bindings 带 is_vip = (vip_type >= 1)
  SELECT DISTINCT ON (t.binding_id) t.id, t.binding_id, t.round_started_at, t.created_at,
         COALESCE(b.vip_type, 0) >= 1 AS is_vip
  FROM baidu_backup_tasks t JOIN baidu_bindings b ON b.id = t.binding_id
  WHERE t.status IN ('enumerating','running')
  ORDER BY t.binding_id, t.round_started_at NULLS LAST, t.created_at, t.id
),
vip AS (SELECT * FROM reps WHERE is_vip     ORDER BY round_started_at NULLS LAST, created_at, id LIMIT :limit),
nrm AS (SELECT * FROM reps WHERE NOT is_vip ORDER BY round_started_at NULLS LAST, created_at, id LIMIT :nonvip_limit)
SELECT id FROM (
  SELECT * FROM vip
  UNION ALL
  SELECT * FROM nrm LIMIT GREATEST(:limit - (SELECT count(*) FROM vip), 0)
) picked ORDER BY round_started_at NULLS LAST, created_at, id;
```

**性质（测试钉死）**：运行中任务（round_started_at 非空）在各自道内恒为代表，稳态不丢槽；道内 FIFO；**慢道满时非会员队头被跳过、后到的会员插队准入——这是刻意行为**（队头阻塞根治），代价是跨道不再全局 FIFO，UI 无感知（排队中状态不变）。瞬时 ±1 超限（plan.md:221 窗口）可能出现 3 个非会员同跑，认领后校验会释放最年轻者，兜底索引不受影响。

### 3.2 参数化

- `api/app/settings.py` 新增：
  - `baidu_admission_limit: int = Field(4)`（替换 `workers/baidu_backup.py:127` 硬编码；**总数槽**）
  - `baidu_nonvip_admission_limit: int = Field(2)`（**非会员槽上限**；恒 ≤ 总数，Settings 校验）
  - `worker_max_jobs: int = Field(8)`（`workers/main.py` WorkerSettings 读取）
  - `baidu_max_active_tasks_per_binding: int = Field(5)`（§2.5 软上限）
- **⚠ 调节通道的坑（deploy-hh2 技能预检 #2）**：这些值走 `.env` 时，改 `.env` 后 `docker compose restart` **不重读 env_file**，必须 `up -d --force-recreate ms-worker`（ms-api 不读这些参数，可不 recreate）。把这句写进部署手册与 DEPLOYED 备注。
- 调参示例：会员占比高+外网空闲 → 4/2；外网大流量期 → `BAIDU_ADMISSION_LIMIT=3, BAIDU_NONVIP_ADMISSION_LIMIT=1` 收紧。

### 3.3 max_jobs 4→8（硬前提）

百度任务与缩略图/cron 同池共 4 槽（方案文档刻意给后者留 ≥2 槽）。并发升 4 而不动 `max_jobs` 会把缩略图挤饿。8 = 4 百度槽 + 4 缩略图/cron 槽（≥现状 2）。

### 3.4 容量账（prod 实证口径）

| 项 | 数值 | 结论 |
|---|---|---|
| 4 会员账号并发入流（最坏全 VIP 道） | 4×3 MiB/s ≈ 100 Mbps | hh2 公网下行 173 Mbps 的 ~58%，**可行但非零头** |
| 分道混合最坏（2 非会员 + 2 会员） | ≈6.2 MiB/s ≈ 52 Mbps | 低于全 VIP 上限，分道不放大带宽 |
| 现状 2 并发实测高峰 | ≈4–5 MiB/s（~40 Mbps） | 无异常 |
| CPU/MinIO 写/DB/Redis | ≤12 MiB/s 聚合 | 非瓶颈 |

带宽与外网入口（47.108.196.211:8080 presigned 流量）共用同一条公网链路——参数化做成硬要求的原因：出现更高速率账号或外网大流量并发时，改 `.env` 降参 + force-recreate 即可，不发版。

### 3.5 明确不做

- 不区分 SVIP/VIP 分级道（二值已解队头阻塞；细分需求出现再加 `vip_version=v2`）。
- 不引入优先级字段/加急插队（分道已是所需的全部排序语义）。
- 不做聚合带宽动态限流（观测驱动，先参数化静态值）。
- sweeper 批量 vip_type 刷新（P2；创建/复活时刷新已够新鲜）。
- 百度任务独立 worker 进程/队列（`plan.md:221` 预案）**暂不做**——max_jobs=8 已解挤饿；若未来缩略图延迟显著再启用该预案。

## 4. 测试功能点（pytest，容器内，照 test_baidu_integration.py 惯例）

- T1 同绑定创建第 2 个任务 201 + 状态 enumerating（dormant）；第 6 个撞软上限 409。
- T2 准入去重：同绑定两条活跃只取最老；跨绑定两条都取；running 恒为代表。
- T3 槽满时 dormant 不进前 N（门控退出路径不回归）。
- T4 枚举→running 撞 `uq_baidu_task_running` → 回排队不终态化（§2.4 belt）。
- T5 首任务终态后，同绑定第二任务被准入并执行（可直调 admission 断言排序，不等 sweeper 实时）。
- T6 复活在排队语义下通行 + 受软上限约束。
- T7 schema 断言改写：`uq_baidu_task_active` 已删、`uq_baidu_task_running` 存在且谓词正确（`test_db_schema.py:104-133` 重做）。
- T8 31045 单飞：并发两 runner 触发 31045 只刷新一次、不互踢（mock 百度 client）。
- T9 Settings 参数生效：`baidu_admission_limit`/`worker_max_jobs`/软上限三参各自生效。
- T10 回归：跨绑定并发照旧、换绑循环取消多任务（`_cancel_active_tasks_of_binding`）、互斥旧测试 `test_baidu_integration.py:2615-2640` 按新语义重写、审计/聚合 task 级隔离不回归。
- T11 分道保留：2 非会员任务 running → 第 3 个非会员任务（槽位总数未满）不被准入；会员任务同时可进第 3 槽。
- T12 总数上限：4 会员 running → 任何任务不进；2 非会员 + 2 会员 = 4 满。
- T13 vip_type 未知语义：binding.vip_type NULL 与 uinfo 响应缺 vip_type → 均按非会员道。
- T14 保鲜：任务创建/复活时 uinfo 刷新 binding.vip_type；uinfo 失败沿用旧值且创建不阻塞。
- T15 排序语义：道内 FIFO；慢道满时会员跨道插队（非会员队头被跳过）；瞬时 ±1 超限后认领校验释放最年轻非会员。

## 5. 部署注意（dev 先行，prod 择窗）

1. **顺序**：迁移先行（`alembic upgrade head` 于 restart 前——deploy-hh2 预检 #3；本迁移含任务索引改型 + bindings 加列）→ 代码 → restart `ms-api`+`ms-worker`。无 FGA、无依赖变更（纯 .py + 迁移）。
2. 若同批调 `.env` 参数 → worker 必须 `--force-recreate`（§3.2 坑）。
3. prod 窗口：仍建议活动任务清零再发；被打断任务自愈 ≤15 min（租约+sweeper），enumerating 任务会重枚举（幂等）。
4. **回滚钉子（重要）**：downgrade 迁移会重建 `uq_baidu_task_active`——若此时某绑定存在「1 running + 多个 dormant enumerating」多活动行，**建索引直接失败**。回滚顺序必须：先取消/终态同绑定多余活动任务 → 再 `alembic downgrade`。把这条写进回滚 runbook。（bindings.vip_type 列 downgrade 直接 drop，无回滚风险。）
5. 部署后观测一两个高峰：任务聚合速率、外网入口延迟、缩略图延迟、**分道分布**（非会员道是否长期 2 满），据此定是否 `.env` 调参。

## 6. 遗留与 P2

- P2-a：`speed_bps` 终态清零致完成速率不可回查——建议终态化时把最后滚动值挪到 `final_speed_bps` 一列（观测用，可另周期）。
- P2-b：创建弹窗「将排队」提示文案（前端一行，随本批顺手或另批）。
- P2-c：方案文档 `baidu-netdisk-backup-plan.md` 头部状态过期、频控 10→100 未回写（文档债，顺手修）。
- 已知边界：跨用户（不同绑定）同目标夹同名文件的 check-then-write 竞态依旧存在——现状即有、与本改动无关，如需收敛走 plan.md:225 的 advisory lock 预案。

## 7. 决策记录

| # | 决策 | 依据 |
|---|---|---|
| D1 | 放开创建、按绑定串行（一跑一排队） | 用户拍板 2026-10-16；保住「单 runner 持绑定」全部安全假设 |
| D2 | 串行粒度盖住枚举期（持租约即算占用绑定） | 枚举也持 token 调 list API；完全休眠语义最简且与用户「必然排队」表述一致 |
| D3 | DB 兜底降级为 running-only 唯一 + 准入层互斥 | 唯一索引无法表达「带活租约」谓词；双层职责：DB 护下载互斥、准入护执行互斥 |
| D4 | 软上限每绑定 5 个活动任务 | 防滥用；创建频控（100/h）不约束总量 |
| D5 | 准入 4 + max_jobs 8 + 三参数进 Settings | 用户拍板；带宽占下行 ~58%（prod 实证 1.3–2.8 MiB/s），必须留不发版回调手段 |
| D6 | 31045 收敛单飞随批实施 | 拔雷成本一行调用替换，收益=未来任何并发化不再踩 |
| D7 | 速率口径修正：混合人群 2–3 MiB/s（会员），0.08 仅非会员 | prod 任务表实证（徐一 2.53GB/26min=1.63 MiB/s 等 12 例）；纠正 2026-10-16 上午调研报告的全系统 0.16 MiB/s 估算 |
| D8 | VIP 分道：非会员并发上限 2，会员恒有 ≥2 槽 | 用户拍板 2026-10-16；纯扩容 2→4 只降概率（4 个先到非会员仍可占满全池），分道是队头阻塞的结构性根治 |
| D9 | vip_type 取自既有 uinfo 响应（不加 vip_version=v2），NULL/缺失按非会员 | 分道只需二值，新旧语义二值一致；保守归类保护会员槽位；零新增 API 面（合规申报不变） |
| D10 | vip_type 保鲜=创建/复活时 best-effort 刷新，不做 sweeper 批量刷 | 升级会员的场景由下次创建自然纠正；批量刷增加 API 面与失败模式，收益边际 |
