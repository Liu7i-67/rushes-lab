# 百度备份并发改造方案：多任务排队 + VIP 分道并发

- 状态：**已定稿（含 VIP 分道增强），待实施**（实施等用户指令）
- 日期：2026-10-16（同日追加 §3.1 VIP 分道）；2026-10-19 修订
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
| 枚举路径 token | `api/app/workers/baidu_backup.py:442-455`（`_current_token`；调用方 `_enum_list_with_retry` :486） | `_current_token` → ensure/force refresh（行锁单飞，并发安全） |
| 准入/批量常量 | `api/app/workers/baidu_backup.py:126-127` | `SWEEP_BATCH=50`、`ADMISSION_LIMIT=2` 硬编码 |
| worker 并发 | `api/app/workers/main.py:678-693`；`api/docker-compose.yml:66-80` | 单进程 `max_jobs=4` 全池（百度+缩略图+cron 同池），baidu job `timeout=3600, max_tries=1` |
| 索引锁死测试 | `api/tests/test_db_schema.py:104-133`、`test_baidu_integration.py:2615-2640` | 断言唯一索引存在 + 互斥行为，须随方案重做 |
| manifest 幂等 | `workers/baidu_backup.py:516-518` | ON CONFLICT (task_id, rel_path)——task 级作用域，跨任务不互踩 |
| 复活派发直写 running | `api/app/services/baidu_backup.py:304-307`（`dispatch_task` mode=revive 的 case 分叉）；路由统一入口 `_revive_and_dispatch`（`routers/baidu_backup.py:1049-1070`，retry-failed `:1073` / 文件 retry `:1114` / overwrite `:1157` / random-suffix `:1218` 四路由共用） | 对 enum_done=true 的复活在 **API 事务内直接置 running**——本方案须改（§2.5），否则撞新唯一索引 |
| 换绑取消 | `routers/baidu_backup.py:217-249` | 已是「多活动任务循环取消」形态，天然兼容 |
| uinfo 调用 | `api/app/services/baidu_client.py:326-340`；`routers/baidu_backup.py:368`（bind/重授权时调） | 已申报六接口之一；现状只解析 uid/nickname，**vip_type 在响应体中但被丢弃** |
| 绑定表 | `api/app/db/tables.py` `BaiduBinding`（uq_baidu_binding_user，1 用户 1 绑定） | 新增 `vip_type` 列的宿主 |

**prod 实证速率（2026-10-16 任务表）**：近期完成任务全程均值 1.3–2.8 MiB/s（会员账号）；非会员 0.08 MiB/s 仅适用于非会员子集，**系统级容量估算必须用混合分布**。`speed_bps` 为检查点差分的滚动窗口速率（认领/接力清零重采 `services/baidu_backup.py:361`，打点 `:910-924`），终态化**不清零**——完成任务保留的是最后一个检查点窗口的滚动值，可近似回查、非全程均值（§6-P2-a）。

## 2. 改动一：解除单活动任务 → 单绑定串行（一跑一排队）

### 2.1 设计不变量（本方案的安全根基）

> **任一时刻，每个绑定至多一个「已被认领（持活租约）的任务」在执行**（枚举或传输都算；认领竞态的瞬态窗口除外——后果由 `uq_baidu_task_running` + §2.4 belt 收容，导入循环级互斥由唯一索引硬保证）。

这条不变量保住了现状全部安全假设：31045 的「单 runner 持绑定」docstring 前提、token 刷新不并发互踢、**同绑定内**任务间的 canonical-key check-then-write 竞态（串行后消失）。注意 `plan.md:225` 竞态①③是**跨绑定（跨用户）**竞态，按绑定串行不触及——仍按 §6 已知边界处理，不宣称已关死。排队中的任务是纯 DB 行、不碰百度 API；唯一周期成本=每个 sweeper 节流窗（默认 10min）一轮「派发→认领→门控退出」churn，由 §2.3 的 sweeper 代表去重压到每绑定每拍 ≤1 job（创建路径即时派发的突发除外，突发上界=软上限 5）——低成本、有界，但非零成本。

### 2.2 DB 迁移（一个 migration，前后兼容）

1. **DROP** `uq_baidu_task_active`（binding_id WHERE active 的 UNIQUE）——否则第二个任务根本建不出来。
2. **CREATE** 弱一级兜底 `uq_baidu_task_running`：`UNIQUE (binding_id) WHERE status = 'running'`——恰好护住最危险的「同绑定双下载循环」；枚举期互斥由准入层负责（枚举走单飞刷新，本身安全）。
3. **新建**非唯一 partial index `idx_baidu_task_active_binding ON (binding_id) WHERE status IN ('enumerating','running')` 供准入查询（现状 tasks 表上不存在任何按 binding_id 的非唯一索引，只有唯一索引与 status/user_id 普通索引）。**`tables.py` 模型元数据同批改**（删旧唯一索引声明、新增两个索引声明）——`test_db_schema` 的断言读的是 `__table__.indexes` 模型元数据而非 DB 内省，只改迁移不改模型则旧断言直接红、新索引无处可断。
4. `baidu_bindings` 新增 `vip_type smallint NULL`（§3.1 分道数据源；存量行 NULL=未知，按非会员处理，随下次 bind/重授权/任务创建/**复活**自然回填（§3.1 保鲜口径，复活四路由同样触发），不做批量回灌）。

### 2.3 准入层按绑定去重（核心改动）

`admission_top_task_ids` 改为两段式（SQL 语义；**这是改动一单独交付时的中间形态**——改动二落地后本函数最终实现为 §3.1 分道 SQL，认领后校验的判定集合随之切换，见 §3.1 接线声明）：

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
- **门控退出统一降级**：`release_for_queueing`（`services/baidu_backup.py:437-450`）现状只清轮钟/租约不改 status——接管后被门控退出的任务会留下「无租约的 status='running' 行」。该行既占 `uq_baidu_task_running` 唯一坑位，又会让更老的 enumerating 兄弟任务在枚举收尾时反复撞索引（belt 回排队→下拍又派它→又撞），形成**绑定级活锁**。修复：release 时把 status='running' 的行同步降为 `enumerating`（`enum_done` 保留）——门控退出**产物**的无租约 running 行就此消灭（崩溃残留的无租约 running 行仍会在租约过期→sweeper 接管前短暂存在，≤~15min 有界，belt 同样兜住），且降级后的行经 §2.5 的 enum_done 短路路径恢复执行，无损。

**配套：sweeper 派发侧代表去重（只作用于派发分支）**。sweeper 对候选集的处理分三支：flag → `cancel_requested` 直终态化（`workers/baidu_backup.py:1834-1837`）→ 48h 判停（`:1838-1843`）→ 派发（`:1846-1857`）。**去重只加在派发分支**——候选处理拆两段：先处理待终态化行（`cancel_requested`/48h 命中，**不去重**，这两支是终态化、不占准入槽，提前处理只会降低竞争；若误把去重加在整个候选查询上，带取消位的非代表行将永远不被选中——取消 API 在任务**恰处认领窗口**（lease_free 为假，`routers:969`）时走 `:982-994` 回落只置 `cancel_requested` 位，该行随后被门控退出清租约，即成「带取消位的休眠行」〔休眠态再取消则用户手动即可经 `:969-979` 直终态化快路径收敛、无需 sweeper；但系统侧若无人再操作，此态只能靠 sweeper cancel 支收敛〕，用户会看到「点了取消却一直排队」直至同绑定前序任务跑完）；再对剩余**派发候选**按 `DISTINCT ON (binding_id)` 取每绑定代表。**候选批量查询（`:1823-1824`）的 ORDER BY 必须与去重步一并换为准入代表序 `round_started_at NULLS LAST, created_at, id`**——只换去重步不够：批量查询现状按 `created_at, id` 排序截 `SWEEP_BATCH=50`，≥50 条创建更早的休眠候选（软上限 5/绑定下 10 个绑定即满）会把创建较晚的崩溃 running 行挡在候选集外，且休眠行每拍「派发→门控退出→10min 后又成候选」持续占位，接管被**无限推迟**。换序后崩溃行 round 非空恒进批量头部，与去重步语义一致。收益：①排队任务的「认领→门控退出」稳态 churn 压到每绑定每拍恰 1 条；②不占满 SWEEP_BATCH 候选位、不推迟其他绑定崩溃任务的接管（崩溃 running 行 round 非空恒压过 NULL 休眠行，接管对象恒优先）；③被挤掉的年轻候选顺延一拍（≤10min），语义无损；带 `cancel_requested` 的休眠行在代表序中排批量尾部、最坏顺延一拍后必被 cancel 支收敛（被派发行的 `dispatched_at` 已刷新、退出下一拍候选集）——如需彻底消除该类行参与排序竞争，可把候选排序加 `cancel_requested DESC` 前缀（实施自选）。

### 2.4 枚举→running 撞兜底索引的 belt 处理

瞬态窗口（两个同绑定任务短暂都被认领）下，年轻任务枚举完成置 running 时可能撞 `uq_baidu_task_running`。处置**顺序有讲究**——PG 约束冲突后事务已中止（25P02），不能在原事务里继续执行 release：

1. 枚举收尾 UPDATE（`workers/baidu_backup.py:630-634`，`WHERE status='enumerating' VALUES(status='running', enum_done=True)`）外层 `except IntegrityError: await db.rollback()`。回滚仅丢弃该 UPDATE 与其后的聚合重算——manifest 行早已逐目录提交（`_insert_manifest_rows` `:516-520` 每次 execute+commit），无损失。**注意 rollback 同样会 expire 会话内全部 ORM 对象**（与 §2.6 同款坑）——后续步骤只做纯 CAS UPDATE 并返回，**不得再读会话内 task 等对象的属性**。
2. 新事务执行回排队：先把该行置 `enum_done=true`（status 保持 enumerating——枚举已完成、manifest 已提交，置位后重派经 §2.5 短路直达收尾 UPDATE，**零 list API 重放**，再次撞 belt 也只是纯 DB churn），再 `release_for_queueing`（清租约/轮钟）+ commit。注意：仅 belt 路径置 enum_done——§2.3 的门控退出路径不置（未完成枚举者必须重枚举）。
3. 返回 "queued"，本轮 runner 结束、**不进导入循环**，等下一拍 sweeper 重派——不得终态化失败。

等价替代：`db.begin_nested()` SAVEPOINT 包住收尾 UPDATE，回滚到 savepoint 后原地继续 release；两法取一，实施时统一。

### 2.5 创建/复活侧改动

- 删 4 处：创建 409 前置（`routers/baidu_backup.py:710-711`）+ 创建 IntegrityError 兜底（:804-807）+ `guard_revival` 前置（`services/baidu_backup.py:594-595`）+ 复活 IntegrityError 兜底（:1065-1067）。删后 `has_active_task`（`services:464-473`）成死代码，顺手删除防后续误用。
- 新增**软上限**前置（防滥用，一次排 20 个目录）：同绑定活动任务 ≥ `baidu_max_active_tasks_per_binding`（默认 **5**，Settings 可调）→ 409「该绑定排队任务已达上限」。**best-effort 语义**：check-then-insert、无 DB 兜底，并发创建窗口可短暂超出若干——防滥用口径下可接受；如需收紧，同事务对 binding 行 `SELECT ... FOR UPDATE` 再计数。
- 复活（四路由：retry-failed / 文件 retry / overwrite / random-suffix）改为同口径：受软上限约束、入队等待，不再因「有活动任务」被拒。
- **复活统一入队漏斗（关键修正）**：现状 `dispatch_task` mode=revive 对 enum_done=true 的任务在 **API 事务内直接写 status='running'**（`services/baidu_backup.py:304-307` case 分叉）。放开限制后「同绑定 A running + 失败任务 B 复活」的 dispatch UPDATE 必撞 `uq_baidu_task_running`，而原 IntegrityError 兜底已删 → 未捕获异常 500；即使保留兜底也是 409，违背「入队等待」承诺。修复：
  1. `dispatch_task` revive 分支去掉 case 分叉，**一律落 `enumerating`**（enum_done 原样保留在行上）；`_revive_and_dispatch` 的返回值（`routers/baidu_backup.py:1070`）随之恒为 `enumerating`——API 响应 status 语义变为「已入队」，前端本就按列表态渲染，零改动。
  2. worker 侧 `_run_claimed`（`workers/baidu_backup.py:265-267`）对 `status='enumerating' 且 enum_done=true` 的任务**跳过重枚举**，直接走枚举收尾路径（聚合 + 空目录判定 + `:630-634` 收尾 UPDATE 置 running）进导入循环——manifest 已在，重枚举纯属冗余 API 调用；该收尾 UPDATE 正是 §2.4 belt 所在。注意：短路路径须保留**目标夹存在性预检**（与 `_enumerate` 前置 `:547-565` 同款：auto_created 重建承接夹写回 / 显式删 → 任务级失败）——排队期间目标夹可能被删（FK SET NULL），不预检则失败口径从任务级 `enum_failed` 漂移为逐行 `target_deleted`。
  3. 由此全系统只剩**一条**置 running 的路径（worker 枚举收尾，belt 覆盖），创建/复活/sweep 接管 enum_done=true 的休眠任务全部先入队、经同一漏斗，幂等。

### 2.6 31045 收敛单飞（顺手项，纵深防御，随本改动一并做）

`_handle_errno_31045` 弃直调 `runner.client.refresh_token`，改走 `force_refresh_access_token`（`services/baidu_backup.py:1029+`），但有**两个前置修正**否则改了等于没改甚至更糟：

1. **force 旁路（必须）**：`force_refresh_access_token` 的 docstring 承诺「不复用现存 token」，但其实现调 `_refresh_locked_once`（`:955-986`）**未带任何 force 语义**——`:965` 新鲜度短路（本地 `expires_at` 未到即 rollback 复用现存 token）在 31045 场景下必然命中（31045 恰是「百度侧拒绝但本地未到期」），返回同一个坏 token、**零次真实刷新**，恢复能力反而被砍。修复：给 `_refresh_locked_once` 加 `force: bool = False` 参数，force=True 跳过 `:965` 短路；`force_refresh_access_token` 透传 force=True。**语义要点**：`:965` 短路本就是「自然过期路径」的单飞去重机制，force 旁路后它不再去重——并发两次 force 会各做一次真实刷新，安全性由**行锁串行化 + 锁内复读轮换后的 refresh_token**保证（第二次 FOR UPDATE 阻塞至第一次提交，解密到的是已轮换的新 refresh_token，刷新照样成功、不互踢），这是刻意的（force 场景宁可多刷不可复用坏 token）。顺带修掉既有隐患——枚举路径 `_current_token` 的 force 分支（`workers/baidu_backup.py:448-454`）现也经 `force_refresh_access_token` 踩着同一短路。
2. **会话隔离（必须，含回写配套）**：`_refresh_locked_once` 短路/失败路径的 `await db.rollback()` 会 expire 会话内全部 ORM 实例（`:968-970` 注释自证；`expire_on_commit=False` 只保护 commit 不保护 rollback）。31045 调用点在 runner 主会话内，回落后继续读任务/文件行（`row.fs_id`、`row.dlink` 等）可能触发 async 下的 MissingGreenlet。修复：刷新调用放**独立 session**（`async with get_sessionmaker()()`），不污染 runner 主会话；**且成功返回后必须对主会话的 binding 实例 `await db.refresh(binding)`**（或与现 `:1054-1058` 同形把新双 token/`access_token_expires_at`/`token_rotated_at` 写回主会话对象）再走回落——否则主会话身份映射缓存的还是旧 token，任务内后续每个文件都会重踩 31045、各做一次真实刷新（token 端点被持续敲打），`_maybe_invalidate_stale_dlink` 读到的 `token_rotated_at` 也是旧值、403 甄别失效。**范围说明**：`_current_token` 的 ensure/force 路径同样以 runner 主会话调刷新、踩同款 rollback-expire 坑——属**既有债**（低频、job 崩溃后 sweeper 接管自愈），本批只修 31045 调用点 + force 旁路，`_current_token` 会话隔离记 §6-P2-d 另批。
3. **异常回落（保留既定语义，注意时序陷阱与重试口径变化）**：`force_refresh_access_token` 的耗尽路径是**先置 binding expired 并 commit、再抛 BaiduTaskError**（`services:1049-1056`）——调用方 `except` 捕获时绑定已被误杀，经包装入口直接换用兑现不了「刷新失败不置 expired」。修复：给包装加 `expire_binding_on_exhaustion: bool = True` 参数（默认语义不变，枚举 `_current_token` force 路径等既有调用不受影响），**31045 调用点传 False**；随后 `except BaiduTaskError: 回落现有 link_expired 重取 dlink 路径`——现处理 docstring（`workers/baidu_backup.py:1031-1032`）的「刷新失败不误杀绑定」语义就此保住。**刻意接受的口径变化**：现状是单次 refresh 失败立即回落（`:1031`「refresh 失败不重试」），改走包装后为 ≤`REFRESH_MAX_ATTEMPTS`(3) 次带退避的真实尝试才回落——31045 场景至多多敲 2 次百度 token 端点，换取对瞬态抖动更强的自愈，接受（T8 断言失败路径真实调用次数 ≤3）。

新不变量下本无并发双跑，但拔掉这颗「依赖单 runner 假设」的雷，未来任何并发化改动都不再踩。

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
  SELECT * FROM (
    SELECT * FROM nrm
    LIMIT GREATEST(:limit - (SELECT count(*) FROM vip), 0)
  ) nrm_pick
) picked ORDER BY round_started_at NULLS LAST, created_at, id;
```

语法红线：**给 UNION 单臂加 LIMIT 必须括号包裹子查询**——裸写 `... UNION ALL SELECT * FROM nrm LIMIT n` 的 LIMIT 作用于整个并集（当会员代表数 ≥ 总限时会把 picked 截到 0，含会员在内谁都不被准入）。实施时可等价改为应用层两步查询（先取 vip 代表、再按剩余额度取非会员），更易单测——语义以本块为准：总 picked ≤ :limit 且其中非会员 ≤ :nonvip_limit。

**接线声明（分道不变量②的成立前提）**：认领后校验（`workers/baidu_backup.py:252-253`，`admission_top_task_ids` 返回集合的成员判定）的判定集合**必须就是本节 picked 集合**——即 `admission_top_task_ids` 的最终实现为本 SQL，§2.3 两段式只是改动一单独交付的中间形态。若 gate 误接无分道 top-N，则「2 非会员 running + 第 3 dormant 非会员」在纯顺序执行下就会击穿不变量②（全局代表共 3 ≤ 4，第 3 条必在无分道 top-4 内）——仅凭「后认领者必见先认领者轮钟」只能推出全局 ≤ 总限，推不出道内 ≤ 非会员限。T11 正是防「接错线」的用例。

**性质（测试钉死）**：运行中任务（round_started_at 非空）在各自道内恒为代表，稳态不丢槽；道内 FIFO；**慢道满时非会员队头被跳过、后到的会员插队准入——这是刻意行为**（队头阻塞根治），代价是跨道不再全局 FIFO，UI 无感知（排队中状态不变）。超限安全性分层看：①**同绑定双跑**由 `uq_baidu_task_running`+§2.4 belt 硬保证，不受任何认领竞态影响；②**准入级超限有两类瞬态窗**，均接受、belt 不因此拆除——(a) 提交乱序窗：排序键是轮钟（认领语句时刻，`claim_task` 的 `now` 在 commit 前采样）而 gate 可见性按提交序，**时钟序≠提交序**，延迟提交可让各自入选后瞬时超限（量级=乱序提交数、毫秒~秒级，随下一次认领/接力复核自愈，与 v1 plan.md:221 ±1 同类同量级）；(b) **跨道置换窗（分道特有，v1 无）**：满载（如 2 非会员+2 会员=4）时新会员认领，vip 臂可容纳它而 `nrm_pick` 的余量收紧把**较年轻的非会员代表挤出 picked**——但被挤者已在 running（gate 只在认领时判定一次、不驱逐已执行者），总执行数瞬时至多 `limit + nonvip_limit`（默认 6），持续至被挤者自己的接力复核（≤55min）经门控退出+§2.3 降级回队才收敛。这是插队语义对运行中任务的隐含代价，刻意接受：被挤的是 0.08 MiB/s 级非会员（带宽影响可忽略）、max_jobs=8 为 6 留有余量、自愈路径确定；③**status 级超限行**（同绑定双认领窗口、崩溃残留行）同前述由唯一索引+belt 收容。测试口径见 T4/T12/T15/T16。

### 3.2 参数化

- `api/app/settings.py` 新增：
  - `baidu_admission_limit: int = Field(4)`（替换 `workers/baidu_backup.py:127` 硬编码；**总数槽**）
  - `baidu_nonvip_admission_limit: int = Field(2)`（**非会员槽上限**；校验 `≤ baidu_admission_limit - 2`，见下条红线）
  - `worker_max_jobs: int = Field(8)`（`workers/main.py` WorkerSettings 读取）
  - `baidu_max_active_tasks_per_binding: int = Field(5)`（§2.5 软上限）
- **校验红线（进既有 `validate_baidu_settings`，`settings.py:160`）**：`1 ≤ baidu_nonvip_admission_limit ≤ baidu_admission_limit - 2`——上限守住 §3.1「会员恒有 ≥2 槽」承诺（若只校验 ≤ 总数，运维配 2/2 会把 VIP 保证静默清零）；**下限 ≥1 防 2/0 把非会员道清零饿死**（排队无超时，round 为 NULL 不受 48h 判停，`services:130-134`）。隐含 `baidu_admission_limit ≥ 3`。另补 `baidu_max_active_tasks_per_binding ≥ 1`（配 0/负值会静默砖死创建与复活、恒 409 无启动报错）。违例启动即报错（api lifespan 与 worker on_startup 双侧都跑校验——坏配置下 worker 也起不来，防护更强）。
- **⚠ 调节通道的坑（deploy-hh2 技能预检 #2）**：这些值走 `.env` 时，改 `.env` 后 `docker compose restart` **不重读 env_file**，必须 `up -d --force-recreate`，且**按消费方分别 recreate**——`baidu_admission_limit`/`baidu_nonvip_admission_limit`/`worker_max_jobs` 的行为消费方只是 ms-worker → `--force-recreate ms-worker`；`baidu_max_active_tasks_per_binding` 消费在 ms-api（创建/复活前置）→ 调它必须 `--force-recreate ms-api`（worker 仅启动校验读该值、不参与行为，不 recreate 无害——但带非法值重启 worker 会被启动断言拦下，属预期防护）。把这句写进部署手册与 DEPLOYED 备注。
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
- T4 枚举→running 撞 `uq_baidu_task_running` → 按 §2.4 处置序回排队（rollback → 置 enum_done=true → 新事务 release → "queued"），不炸 25P02、不终态化、不进导入循环；重派后**零 list 调用**直达收尾 UPDATE。**触发构造钉死为 DB 直 seed**：同绑定 seed 一条 `status='running' AND round_started_at IS NULL` 脏行（旧代码时代残留形态）+ 一条已认领的 enumerating 兄弟（round 非空成为代表）→ 代表过 gate 后收尾 UPDATE 撞索引——勿依赖提交乱序竞态构造（不可重复，易写出永不触发的假绿用例）。
- T5 首任务终态后，同绑定第二任务被准入并执行（可直调 admission 断言排序，不等 sweeper 实时）。
- T5a 门控退出降级：running 任务认领后门控退出 → status 降为 enumerating、enum_done 保留、轮钟/租约清空；再次认领经 enum_done 短路路径恢复导入循环（§2.3）。
- T6 复活在排队语义下通行 + 受软上限约束。
- T7 schema 断言改写：`uq_baidu_task_active` 已删、`uq_baidu_task_running` 存在且谓词正确（`test_db_schema.py:104-133` 重做，断言口径=模型元数据）；两个新索引的谓词断言口径不同——`uq_baidu_task_running` 为 `{'running'}`（ACTIVE_STATUSES 的刻意子集，D3），`idx_baidu_task_active_binding` 沿用**谓词漂移断言**（谓词状态集与 ACTIVE_STATUSES 保持一致，防未来加状态档位两侧漂移）。
- T8 31045 单飞：单次 force 刷新且 token 本地未临期 → **恰 1 次真实 `client.refresh_token`**（force 旁路生效，防「短路零调用也绿」）；并发两次 force → 行锁串行化、各 1 次真实刷新、**第二次用轮换后的 refresh_token 成功不互踢**（共 2 次调用——force 路径刻意不去重）；单飞耗尽抛 BaiduTaskError 时回落 link_expired 路径、**绑定不置 expired**（断言 `expire_binding_on_exhaustion=False` 生效——防耗尽先置 expired 再抛的时序陷阱）；刷新过程用独立 session，runner 主会话对象不失效；**刷新成功后主会话 binding 实例已回写新值**（`db.refresh` 生效，后续文件不重踩 31045）（mock 百度 client）。
- T9 Settings 参数生效：`baidu_admission_limit`/`baidu_nonvip_admission_limit`/`worker_max_jobs`/软上限四参各自生效（含 nonvip 生效专项：调 1→行为随之变）；`nonvip=0`、`nonvip>limit-2`、软上限=0 三向违例均启动报错。
- T10 回归：跨绑定并发照旧、换绑循环取消多任务（`_cancel_active_tasks_of_binding`）、互斥旧测试 `test_baidu_integration.py:2615-2640` **与准入旧测试 `test_admission_three_queued_top2_deterministic`（`:2641-2703`，断言「≥3 排队恰 2 运行」）**均按 4 槽+去重+分道新语义重写、审计/聚合 task 级隔离不回归；`test_admin_baidu_tasks.py:33` docstring 引用旧索引名一并更正。
- T11 分道保留（**防 gate 接错线的必测项**，见 §3.1 接线声明）：2 非会员任务 running → 第 3 个非会员任务（槽位总数未满）不被准入；会员任务同时可进第 3 槽。
- T12 总数上限：4 会员 running → 任何任务不进；2 非会员 + 2 会员 = 4 满（**对同道到达成立**）；跨道置换窗子用例：2 非会员 + 2 会员满载 → 新会员认领**被准入**（总执行 5、较年轻非会员被挤出 picked 但仍在 running）→ 被挤者在接力复核后门控退出+降级回队，最终收敛回 4（§3.1 性质②(b)）；**6 上界钉死**：满载 6 后第 5 个 vip 认领必须被 gate 拒（把 §3.1 瞬态上界从论证升级为回归项）。
- T13 vip_type 未知语义：binding.vip_type NULL 与 uinfo 响应缺 vip_type → 均按非会员道。
- T14 保鲜：任务创建/复活时 uinfo 刷新 binding.vip_type；uinfo 失败沿用旧值且创建不阻塞。
- T15 排序与残留行门控：道内 FIFO；慢道满时会员跨道插队（非会员队头被跳过）；DB 直 seed 超限残留活动行（模拟崩溃/历史脏数据）→ 新认领者门控退出，不产生真实并发超限。
- T16 复活入队漏斗：同绑定 A running 时对 enum_done=true 失败任务 B 走 retry-failed → **202**（非 409/500）、B 落 enumerating 排队；A 终态后 B 被认领、**零 list 调用**（跳过重枚举，断言百度 list API 调用数为 0）、经收尾 UPDATE 置 running 进导入循环；**B 排队期间目标夹被删的子用例**：认领后走预检分支（auto_created 重建承接夹写回 / 显式删 → 任务级 `enum_failed`），不得漂移为逐行 `target_deleted`。
- T17 sweeper 代表去重：同绑定「1 崩溃 running + N 休眠」→ 每拍仅派每绑定最老一条（**按代表序 `round_started_at NULLS LAST, created_at, id`**，崩溃者优先于休眠者——含「休眠创建在前、崩溃创建在后」的反序用例）；**批量边界用例：>SWEEP_BATCH(50) 条候选且崩溃行创建最晚 → 批量查询换序后仍把崩溃行带回头部、接管不被挤掉**；多绑定互不挤占 SWEEP_BATCH；子断言：seed 非代表休眠行 + 置 `cancel_requested` → 下拍被 sweeper cancel 支终态化（不被去重搁置）。
- T18 迁移兼容冒烟：对「每绑定恰 1 条活动行」的存量数据 upgrade 成功且不动数据（新索引/列形态断言归 T7）；downgrade 重建唯一索引的失败路径不自动化，按 §5.4 runbook 口径人工把关。

## 5. 部署注意（dev 先行，prod 择窗）

1. **顺序**：迁移先行（`alembic upgrade head` 于 restart 前——deploy-hh2 预检 #3；本迁移含任务索引改型 + bindings 加列）→ 代码 → restart `ms-api`+`ms-worker`。无 FGA、无依赖变更（纯 .py + 迁移）。**迁移与 restart 同批紧邻执行、窗口内避免并发创建**：「迁移后、restart 前」的旧代码 + 新 schema 窗口里，旧创建 IntegrityError 兜底已随索引 drop 而失效（`routers:804-807` 永不触发），并发双建可产出同绑定双活动行，旧 top-2 准入（无去重）可同时放行 → 枚举收尾撞 `uq_baidu_task_running` 崩 job 循环，直至新代码 restart 后由去重+belt 收敛。
2. 若同批调 `.env` 参数 → worker 必须 `--force-recreate`（§3.2 坑）。
3. prod 窗口：仍建议活动任务清零再发；被打断任务自愈 ≤15 min（租约+sweeper），enumerating 任务会重枚举（幂等）。
4. **回滚钉子（重要）**：**本批新增迁移**的 downgrade 会重建 `uq_baidu_task_active`（原 0013 迁移自身 downgrade 是直接 drop 三张表 `:137-145`，无索引重建问题）——若此时某绑定存在「1 running + 多个 dormant enumerating」多活动行，**建唯一索引直接失败**。回滚顺序必须：**先停 worker / 清理同绑定多余活动任务**——清理走用户侧**逐任务**取消端点 `POST /backup/tasks/{id}/cancel`（`routers/baidu_backup.py:950-1004`，一次一个；停 worker 后 60s 租约过期即满足「无租约→直接终态化」快路径），或经换绑/解绑触发内部循环取消（`:217-249` 是内部 helper 非公开 API）——**用新代码做清理**，切勿先回滚代码再清理：「旧代码 + 新 schema + 多活动行」窗口内旧代码无 belt，同绑定双活动被旧 top-2 准入同时放行时枚举收尾 UPDATE 撞 `uq_baidu_task_running` 直接崩 job、sweeper 反复接管反复崩，且旧创建兜底因索引已删永不触发。清理完 → 回滚代码至旧版 → 再 `alembic downgrade`（顺序的真正原因：downgrade 会 drop `vip_type` 列与新索引，**新代码**在旧 schema 上读写缺列必崩——而非旧代码要求旧索引；§5.1 已论证旧代码在新 schema 上可正常运行，`test_db_schema` 旧断言只在跑测试时生效）。若任务所有者不可达/不配合，DBA 兜底=停 worker 后直接 SQL 把多余活动行终态化（worker 已停、无并发写，安全）。**downgrade 前置 SQL 断言（必做）**：`SELECT binding_id FROM baidu_backup_tasks WHERE status IN ('enumerating','running') GROUP BY binding_id HAVING count(*)>1` 必须返回空——「旧代码 restart 后、downgrade 前」窗口内旧创建兜底已随索引删除失效，并发双建仍可能产出双活动行使 downgrade 重建唯一索引失败，断言把住最后一道闸。把这条写进回滚 runbook。（bindings.vip_type 列 downgrade 直接 drop，无回滚风险。）
5. 部署后观测一两个高峰：任务聚合速率、外网入口延迟、缩略图延迟、**分道分布**（非会员道是否长期 2 满），据此定是否 `.env` 调参。

## 6. 遗留与 P2

- P2-a：完成任务保留的 `speed_bps` 只是最后一个检查点窗口的滚动值（接力清零后若未再打点可能为 0），并非全程均值——如需精确回查可在终态化时回填 `final_speed_bps = done_bytes/耗时`（观测增强，可另周期；「终态被清零不可回查」的旧表述有误，已勘正）。
- P2-b：创建弹窗「将排队」提示文案（前端一行，随本批顺手或另批）。建议口径：「已有任务执行中，新任务将排队，前序完成后约数分钟至一刻钟内自动开始」——排队任务靠 sweeper 重派（节流 `baidu_sweep_throttle_s=600` + cron 5min 周期），交接延迟最长 ~15min，属预期管理。
- P2-c：方案文档 `baidu-netdisk-backup-plan.md` 头部状态过期、频控 10→100 未回写（文档债，顺手修）。
- P2-d：`_current_token` 的 ensure/force 路径以 runner 主会话调 token 刷新，`_refresh_locked_once` rollback-expire 同款 MissingGreenlet 隐患（§2.6.2 范围说明）——既有债，另批统一收敛到独立 session。
- 已知边界：跨用户（不同绑定）同目标夹同名文件的 check-then-write 竞态依旧存在——现状即有、与本改动无关，如需收敛走 plan.md:225 的 advisory lock 预案。

## 7. 决策记录

| # | 决策 | 依据 |
|---|---|---|
| D1 | 放开创建、按绑定串行（一跑一排队） | 用户拍板 2026-10-16；保住「单 runner 持绑定」全部安全假设 |
| D2 | 串行粒度盖住枚举期（持租约即算占用绑定） | 枚举也持 token 调 list API；完全休眠语义最简且与用户「必然排队」表述一致 |
| D3 | DB 兜底降级为 running-only 唯一 + 准入层互斥 | 唯一索引无法表达「带活租约」谓词；双层职责：DB 护下载互斥、准入护执行互斥 |
| D4 | 软上限每绑定 5 个活动任务 | 防滥用；创建频控（100/h）不约束总量 |
| D5 | 准入 4 + max_jobs 8 + 四参数进 Settings（admission/nonvip/worker_max_jobs/软上限，附 nonvip 上下限校验） | 用户拍板；带宽占下行 ~58%（prod 实证 1.3–2.8 MiB/s），必须留不发版回调手段 |
| D6 | 31045 收敛单飞随批实施（force 旁路 + 独立 session + 耗尽不误杀回落） | 拔掉「并发双 runner 直刷 token」的雷；`_refresh_locked_once` 须加 force 旁路（现实现有新鲜度短路，31045 场景零真实刷新——顺带修 `_current_token` 既有 force 路径同病）；force 路径刻意不去重（并发安全=行锁串行+锁内复读轮换 refresh_token）；rollback 会 expire 主会话对象（MissingGreenlet），刷新放独立 session；包装须加 `expire_binding_on_exhaustion` 参数（耗尽**先置 expired 再抛**，31045 调用点传 False + 回落 link_expired，保住「不误杀绑定」）——非等价一行替换 |
| D7 | 速率口径修正：混合人群 2–3 MiB/s（会员），0.08 仅非会员 | prod 任务表实证（徐一 2.53GB/26min=1.63 MiB/s 等 12 例）；纠正 2026-10-16 上午调研报告的全系统 0.16 MiB/s 估算 |
| D8 | VIP 分道：非会员并发上限 2，会员恒有 ≥2 槽 | 用户拍板 2026-10-16；纯扩容 2→4 只降概率（4 个先到非会员仍可占满全池），分道是队头阻塞的结构性根治 |
| D9 | vip_type 取自既有 uinfo 响应（不加 vip_version=v2），NULL/缺失按非会员 | 分道只需二值，新旧语义二值一致；保守归类保护会员槽位；零新增 API 面（合规申报不变） |
| D10 | vip_type 保鲜=创建/复活时 best-effort 刷新，不做 sweeper 批量刷 | 升级会员的场景由下次创建自然纠正；批量刷增加 API 面与失败模式，收益边际 |
| D11 | 复活统一入队漏斗：派发恒落 enumerating + worker 对 enum_done=true 跳过重枚举直走收尾 UPDATE | 现状 revive 对 enum_done=true 在 API 事务直写 running，放开限制后必撞新唯一索引且捕获点已删（500）；统一后全系统仅一条置 running 路径，恰为 §2.4 belt 所在 |
| D12 | 门控退出降级 running→enumerating + sweeper 派发侧按绑定代表去重 | 无租约 running 行会占唯一坑位并致更老枚举中兄弟反复撞索引（绑定级活锁）；去重把排队稳态 churn 压至每绑定每拍 ≤1 job 且不推迟崩溃接管（去重只作用派发分支，cancel/48h 终态化支不去重——否则带取消位的非代表行被搁置；接管对象=崩溃 running 行，round 非空在代表序中恒优先于休眠行） |
