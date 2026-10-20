# 百度备份 key 冲突体验优化方案：创建时预警 + 冲突自动后缀

- 状态：**已定稿（2026-10-20 修订版），待实施**（实施等用户指令）
- 日期：2026-10-20（同日修订，见决策 U3）
- 修订记录：2026-10-20 用户拍板——W2 由「任务级 Checkbox 开关（默认关）」改为「冲突自动随机后缀（默认行为，无开关）」，触发限定占用者全跨项目；按旧开关设计实施的 WIP（feat/baidu-key-conflict-ux worktree，未提交）已整体弃置清理，未合入任何代码。
- 背景：dev 实战 4da4b1c1——同源目录备份到第二个项目，根下同名承接夹物理键前缀相同（`灵机备份/`），行级 key_conflict 全拦致任务秒败。处置手册见 `baidu-key-conflict-duplicate-import-runbook.md`；本方案把「事后人工处置」前移为「事前预警 + 可选自动化」。
- 决策依据：全量改造物理编号规则（项目开头）= 2 万对象搬家级，**明确不做**（评估结论 2026-10-20 对话，prod 现状 20,145 资产/876 夹）；本两方案均为 additive、零存储迁移。
- 实施分支建议：`feat/baidu-key-conflict-ux`（基于 liuqi）；两方案相互独立，可同批也可拆批交付。

## 0. 现状锚点（已核实）

| 锚点 | 位置 | 说明 |
|---|---|---|
| 创建时目标解析（承接夹 auto-create） | `api/app/routers/baidu_backup.py:808-839` | 显式目标 / 项目根自动建承接夹，`target_auto_created=True` 于 :839；prefix 此刻已知 |
| 创建响应组装 | 同上 `:889`（`_build_task_outs` 调用，定义 `:633`） | 响应统一在 `_build_task_outs` 构造并 `return outs[0]`；该函数只从已持久化 task 行派生，创建时刻的 overlap 须在 handler 对 `outs[0]` 后赋值覆盖（`:882` 是审计写入 details，勿混淆） |
| 导入首检 key 占用落败点 | `api/app/workers/baidu_backup.py:1682` 与 `:1726`（`_transfer_and_finalize` :1647 内两分支） | 占用即 `fail_row(..., "key_conflict", format_key_conflict_message(...))` |
| 随机 key 生成纯函数 | `api/app/services/baidu_backup.py:205` `random_suffix_key(canonical_key, rand)` | `txlogo.png → txlogo.{rand}.png` |
| 随机 key 预定 CAS（F2b 既有基建） | 同上 `:810-842` `reserve_random_key` | 写 `reserved_key` 列防并发漂移；**导入路径已支持按 reserved_key 落库**；注意其 CAS 前提=行 status∈(failed,pending) 并复位 attempts/overwrite，**在途 importing 行不可复用**（见 §2 改动点） |
| 跨项目同前缀判据 | `folders.minio_prefix`（两项目同名承接夹前缀逐字相同，实测 04ec3379/af548b62 均 `灵机备份/`） | 物理编号不含项目名是既有规则，本方案不改 |

## 1. 方案 W1：创建时跨项目路径预警（非阻塞）

### 动机
把「任务跑完才失败」变成「创建前就知道」。承接夹是按源目录名自动建的，用户无从知道另一个项目已有同名路径。

### 改动点

1. **后端查询**（`routers/baidu_backup.py`，目标解析完成后 :839、插行之前）：
   ```sql
   SELECT p.name FROM folders f JOIN projects p ON p.id = f.project_id
   WHERE rtrim(f.minio_prefix, '/') = rtrim(:prefix, '/')
     AND f.project_id != :this_project
   LIMIT 3
   ```
   命中即存在跨项目同前缀文件夹；**取回的是项目名**（与 `overlap_project_names` 语义对齐——只查 `folders.name` 会把夹名当项目名，本场景两者同名纯属巧合，勿依赖）。`rtrim('/')` 归一化防御：`minio_prefix` 理论规范形为 `<name>/`（folder_chain 生成侧），但 `FolderCreateIn` 允许客户端自传且无归一化（`routers/folders.py` 仅缺省补尾斜杠）、物理 key 构建统一 `rstrip('/')`——裸等值比较会漏报「`灵机备份` vs `灵机备份/`」形态。**不过滤项目 `is_archived`/`deleted_at`**：项目逻辑删除后数据与桶全不动、物理 key 占用仍在，过滤会让预警失效；口径=点名可含已删除项目（对上传者属可接受的轻度信息暴露，在此写明）。
2. **响应字段（additive）**：`BaiduTaskOut` 增 `cross_project_prefix_overlap: bool = False` 与 `overlap_project_names: list[str] | None = None`。`_build_task_outs` 只从持久化 task 行派生、感知不到创建时刻 overlap——首批实现=创建 handler 对 `outs[0]` 直接后赋值覆盖（pydantic 支持后赋值）；列表侧回填可后置。
3. **前端**（`web/src/components/BaiduNewTaskModal.tsx`，配套 additive：`web/src/api/types.ts` 的 `BaiduBackupTask` 接口与 `web/src/api/hooks.ts` 类型同步）：创建成功 toast 后，若响应带 overlap → 追加 `message.warning`：「目标文件夹名与项目「X」下的同名文件夹共用存储编号：同名文件将自动加随机后缀存储（两处各持独立文件，互不覆盖）；目标目录内已存在同名文件（含回收站）时该文件仍会失败并保留人工处理出路，如需同键替换请换一个目标文件夹名」（后半句限定=W1 预警条件「任一跨项目同前缀」宽于 W2 触发条件「占用者全跨项目」，混合占用时预告与实际行为须一致）。**非阻塞**——文件不同名时冲突根本不会发生，不拦创建。文案按 W2 落地后的行为撰写；若分批发版且 W1 先行，文案暂用旧口径（「同名文件会冲突导致任务失败，需逐个处理」），W2 合入时同步替换。

### 测试功能点
- W1-T1 跨项目同名承接夹（seed 两项目同名根夹）→ 创建响应 overlap=true、names 含对方**项目名**（只断言包含，不断言顺序——LIMIT 3 无 ORDER BY）；显式 `target_folder_id` 目标同样覆盖（prefix 取自 `folder.minio_prefix`，与 auto-create 分支来源不同）；同项目嵌套同名不置位；无冲突 → false/None。
- W1-T2 前端：overlap 响应触发 warning toast（组件测试或手测清单）。

## 2. 方案 W2：导入期 key 冲突自动随机后缀（默认行为，无开关）

### 动机
把「失败后逐行点【随机后缀导入】」变成默认自动化，无需事前 opt-in、无需人工介入。语义与既有 F2b 出路完全一致（两处各持独立对象、占用者不动）。2026-10-20 修订：原「任务级 Checkbox（默认不勾）」设计取消——跨项目冲突的推荐处置本就是随机后缀（runbook A），自动化不需要用户显式选择，也就不需要开关、DB 列、迁移与前端改动。

### 触发口径（关键判别）
**占用者全部属于其他项目（跨项目同键）→ 自动后缀；任一占用者属于本任务项目（或归属无法判定）→ 维持现状 key_conflict 失败。**
- 依据：跨项目占用（4da4b1c1 场景）用户无意替换他项目资产，自动后缀无损且正是推荐处置；同项目占用是「重导入→失败→复活带 overwrite 覆盖导入」替换流的既有入口，自动后缀会把替换静默变成重复副本。
- 口径注记：同项目重导入的常见路径其实是「同名跳过」（目标夹存在同名**活**资产 → 行 skip，`workers/baidu_backup.py:952-962`；reserved_key 行豁免该跳过）而非 key_conflict；能走到 key_conflict 的同项目占用主要是软删同名/异夹占键等形态——复活覆盖对这些形态仍是既有替换入口，判别口径不变。
- 实现：`_key_conflict_holders`（`workers/baidu_backup.py:874`）现返回 Asset 行，Asset 无 project_id 直连（只有 folder_id）→ 需 join folders 增带占用者 project_id；folder 已删等归属不明 → 保守按「非跨项目」走现状失败。

### 改动点（仅 worker 一个文件）
1. **`workers/baidu_backup.py` 首检分支（`:1682`）与 complete 前二检分支（`:1726`）**：非 overwrite 行遇 key 占用且占用者全跨项目时——
   - 循环 ≤5 次（与手工路径 `_RANDOM_KEY_ATTEMPTS=5` 同款）：`new_key = random_suffix_key(key, secrets.token_hex(4))`（8 位 hex，对齐手工路径，勿用 3 字节缩水）→ 复查**复用既有 `random_key_taken(db, bucket, key, task_id, exclude_file_id)`**（含软删 Asset + 同任务其他行 reserved_key，与手工随机后缀路由口径逐字一致；跨任务 reserved_key 互不可见为 F2b 手工路径既有窄竞态，W2 持平非新增）；空位即出循环；
   - KEY 长度护栏（`KEY_MAX_CHARS`/`KEY_MAX_BYTES`）：候选增量恒定，一个超限则全部超限 → **直接跳出循环走 failed(key_conflict) 兜底**（fail-fast，与手工路径 409 直败同款），不做无效重试；
   - **守卫写 `reserved_key`**：`UPDATE task_files ... WHERE TaskFile.id = :row_id AND runner.owned_row_predicate() AND reserved_key IS NULL`——**必须带所有权谓词**（本 worker 行级写的硬性纪律，`workers/baidu_backup.py:174` 定义、既有四处在用），否则租约被接管/取消后陈旧 runner 仍可污染行；`statement_rowcount=0` 不区分「失去所有权」与「已被并发预定」两种语义，统一走 `_fail_row(..., "key_conflict")`（其内部重查所有权谓词，失去所有权自然退化为 "lost"，两语义均安全收口）。**勿复用 `reserve_random_key`**——其 CAS 要求行 status∈(failed,pending) 并复位 attempts/overwrite（`services/baidu_backup.py:810`），对在途 importing 行语义不符。该 UPDATE 即上方重启机制中的「单条语句」（内容=写候选 key+清四元组+last_error=None）；
   - **两分支共用同一重启机制（关键，首检勿例外）**：首检与二检命中都走「读行上陈旧三元组（failed 行保留断点，`_fail_row` 语义）→ 有则先 `abort_multipart_upload` → **单条** owned 守卫 UPDATE 同时置 `reserved_key=候选`、清 `(minio_bucket, minio_key, minio_upload_id, bytes_done)`、置 `last_error=None`（对齐手工 F2b 清场口径，防 retry 行残留 transport 错误文案）→ `db.refresh(row)` → 以新 key 重进传输步骤（行上 reserved_key 非空时后续全程按其落库，`workers:943-947` 既有）」。**「abort 先行；清四元组与写 reserved_key 必须同一条 UPDATE」为实现纪律**：拆成两条且中途崩溃 → 恢复后按存活旧三元组 list_parts 命中 → 新 key 配旧 upload_id `upload_part` 抛裸 ClientError（不在重试循环任何捕获类别内）→ job 崩溃、sweeper 接管循环直至判停，比 NoSuchUpload 形态更恶劣。完全不清陈旧会话同样致命——`_resume_or_create_session` 按行上三元组而非传入 key 寻址（`:1427`），新 key 配旧 upload_id complete → NoSuchUpload → `_UploadSessionLost` 逐轮烧 attempt 耗尽成误导性 rate_limited，且 reserved_key 已固化、`reset_failed_rows` 不清该列（`services:710-717`）→ 每次 retry 原点打转，行级永久卡死。`db.execute` 的 UPDATE 不回写 ORM 属性，不 refresh 则 stale attrs 毒化会话恢复寻址。F2b 手工路径存在同型隐患（`reserve_random_key` 不清会话三元组），统一重启机制可一并收敛（非本方案义务，注记备查）；
   - 换 key 重试**不烧 attempt**（attempt 预算留给传输重试）：**不得借既有异常重试通道续跑**——该通道每次 `continue` 都 `attempt += 1`；须在 `_import_one_file` 内以上述重启机制直接重进传输步骤，也不得重新认领行。守卫谓词保证每行至多换一次，续跑后新 key 仍被占 → failed(key_conflict) 兜底，不无限循环；
   - `log.info` 记录「原 key → 后缀 key」供追溯（成功行 last_error 已由守卫 UPDATE 清空，reserved_key 列本身即证据）。实施琐碎项：`secrets` 当前未在 worker 导入，需补 import。
2. **DB / API / 前端：零改动**。无开关即无状态——不加列、无迁移、无入参出参变更、无 UI。

### 语义边界（刻意不做）
- **无任务级开关、无 opt-out**（取代原「默认关」决策）：冲突自动化是安全默认——非破坏、两处各持独立文件。
- **同项目占用不自动后缀**：保留「失败→复活覆盖导入」替换流；与 runbook C 红线同源（覆盖删物理对象，跨项目禁用）。
- **不与 overwrite 组合**：overwrite 行遇占用仍走既有 F2a 清除路径，不进自动后缀。
- **存量 failed 行不改口径**：历史 key_conflict 行的三条人工出路（retry/overwrite/random-suffix）原样保留，runbook 处置手册对存量行仍有效。
- **手工 F2b 已预定的行不被改写**：行已有 reserved_key（人工随机后缀出路已介入）→ 守卫谓词不命中，按现状 failed 兜底，两条出路互不干扰。
- **既有例外注记（W2 不改变）**：size=0 空文件走 `put_object` 直传、无 complete 前二检——该窗口内「自动后缀」不生效，「无损」叙述不覆盖此既有盲区。
- **极端终态注记**：换 key 后新 key 再被占的 failed 行，reserved_key 已固化且手工 random-suffix 幂等复用同 key → retry/随机后缀两条出路原点打转，唯一有效出路=覆盖导入（8 位 hex 碰撞概率天文级，仅注记不设专门交互）。
- 不做任务级"已自动后缀 N 个"的响应统计（P2 可后置，先靠 reserved_key 列可查）。

### 测试功能点
- W2-T1 跨项目占用（seed 两项目同前缀同 key）→ 自动后缀落库成功：两资产 id/minio_key 独立、占用者不动、任务 completed、行 reserved_key=后缀 key。
- W2-T2 同项目占用 → 行为与现状逐字一致（key_conflict failed，复活覆盖流保留）；混合占用（同项目+跨项目并存）→ 同样不自动后缀。（「folder 缺失归属不明」为防御分支：`Asset.folder_id` 外键 RESTRICT、资产存活期 folder 删不掉，DB seed 无法构造，仅 mock 查询层可覆盖。）
- W2-T3 后缀候选碰撞（mock 首四次候选为已占用）→ 第五次成功；五次全撞 / 候选超 KEY 护栏 → 直接 failed 兜底不挂死（护栏超限=fail-fast 不重试）。
- W2-T4 同任务防双写=机制单测：直测 `random_key_taken` 候选撞同任务其他行 reserved_key → 换下一候选。**集成侧勿造假用例**：同任务同名行受 `uq_baidu_task_file_relpath`（`tables.py:656`）约束天然不存在，直 seed 构造也会先命中目标夹同名活资产「同名跳过」（`workers:952-962`）到不了冲突分支（单 runner 串行，无行级并发真实面）。守卫兜底单测保留：行预置 reserved_key（含手工 F2b 已预定）再触发自动后缀分支 → rowcount=0 → failed(key_conflict) 兜底、原 reserved_key 不被改写。
- W2-T5 二检窗口换 key：首检过后传输窗口内出现跨项目占用 → 会话作废、按新 key 从头续跑、对象 complete 到新 key、无孤儿残留。
- W2-T6 软删占用行口径：与既有 `_key_conflict_holders` 一致（软删占用同样参与判别与触发）。
- W2-T7 带陈旧会话的 retry 行首检换 key：行携带存活三元组 failed → 跨项目占用出现 → retry 后首检命中 → 陈旧会话被作废、按新 key 一次落库成功（防「新 key 配旧 upload_id」烧穿 attempt 的永久卡死回路）。
- W2-T8 overwrite 行 + 跨项目占用 → 走既有 F2a 清除路径不进自动后缀（语义边界「不与 overwrite 组合」的回归钉）。
- W2-T9 守卫写后、重进传输前崩溃 → sweeper 接管 → 行按 reserved_key 一次落库成功（默认开方案的安全性承重路径，依赖 `workers:943-947` 既有落库逻辑）。

## 3. 部署注意

1. 修订后两方案均**无迁移、无 DB 变更**：W1 改 routers（restart `ms-api`），W2 只改 worker（restart `ms-worker`）；SPA 单独推送。无 FGA、无依赖变更。
2. W1 可单独先发（注意 §1 文案与 W2 行为的联动口径）；推荐两方案同批发版，文案零临时态。
3. 回滚：代码回滚即恢复「冲突=失败」现状，无持久化状态残留（reserved_key 仅自动后缀**介入过**的行持有——含介入后仍 failed 兜底的行；旧代码本就按该列落库，语义自洽）。

## 4. 工作量与交付建议

| 项 | 量级 |
|---|---|
| W1（查询+响应字段+toast+测试） | ~半天 |
| W2（worker 两分支+跨项目判别+测试；修订后无迁移/无 API/无前端） | ~1 天 |
| 合计 | 一个 qdev 小周期，两方案同批交付 |

## 5. 决策记录

| # | 决策 | 依据 |
|---|---|---|
| U1 | 不做全量物理编号改造（项目开头） | 2 万对象搬家级代价 vs 低频已有兜底的痛点；编号含项目名则项目改名=再搬家，含 ID 则预签名 URL 可读性受损 |
| U2 | W1 预警非阻塞 | 文件不同名时冲突不会发生，拦截会造成误伤 |
| U3 | （2026-10-20 修订，推翻原「W2 默认关」）W2 取消任务级开关，冲突自动后缀为默认行为；限定占用者**全跨项目**才触发 | 用户拍板：自动化不应要求事前 opt-in；同项目占用是「失败→复活覆盖导入」替换流的既有入口，自动后缀会把重导入静默变成重复副本，故保留现状失败语义 |
| U4 | W2 复用 F2b reserved_key 基建 | `reserve_random_key` CAS 与落库路径现成，零新机制 |
