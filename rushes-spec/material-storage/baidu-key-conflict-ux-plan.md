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
| 创建响应组装 | 同上 `:882` | `target_auto_created`/`dispatch_seq` 等字段在此拼装 |
| 导入首检 key 占用落败点 | `api/app/workers/baidu_backup.py:1682` 与 `:1726`（`_transfer_and_finalize` :1647 内两分支） | 占用即 `fail_row(..., "key_conflict", format_key_conflict_message(...))` |
| 随机 key 生成纯函数 | `api/app/services/baidu_backup.py:205` `random_suffix_key(canonical_key, rand)` | `txlogo.png → txlogo.{rand}.png` |
| 随机 key 预定 CAS（F2b 既有基建） | 同上 `:810-840` `reserve_random_key` | 写 `reserved_key` 列防并发漂移；**导入路径已支持按 reserved_key 落库**；注意其 CAS 前提=行 status∈(failed,pending) 并复位 attempts/overwrite，**在途 importing 行不可复用**（见 §2 改动点） |
| 跨项目同前缀判据 | `folders.minio_prefix`（两项目同名承接夹前缀逐字相同，实测 04ec3379/af548b62 均 `灵机备份/`） | 物理编号不含项目名是既有规则，本方案不改 |

## 1. 方案 W1：创建时跨项目路径预警（非阻塞）

### 动机
把「任务跑完才失败」变成「创建前就知道」。承接夹是按源目录名自动建的，用户无从知道另一个项目已有同名路径。

### 改动点

1. **后端查询**（`routers/baidu_backup.py`，目标解析完成后 :839、插行之前）：
   ```sql
   SELECT name FROM folders
   WHERE minio_prefix = :prefix AND project_id != :this_project
   LIMIT 3
   ```
   命中即存在跨项目同前缀文件夹（含名称，供提示点名）。
2. **响应字段（additive）**：`BaiduTaskOut` 增 `cross_project_prefix_overlap: bool = False` 与 `overlap_project_names: list[str] | None = None`（创建/列表均可回填；列表侧可后置，首批只做创建响应）。
3. **前端**（`web/src/components/BaiduNewTaskModal.tsx`）：创建成功 toast 后，若响应带 overlap → 追加 `message.warning`：「目标文件夹名与项目「X」下的同名文件夹共用存储编号：同名文件将自动加随机后缀存储（两处各持独立文件，互不覆盖）；若希望同键替换，请换一个目标文件夹名」。**非阻塞**——文件不同名时冲突根本不会发生，不拦创建。文案按 W2 落地后的行为撰写；若分批发版且 W1 先行，文案暂用旧口径（「同名文件会冲突导致任务失败，需逐个处理」），W2 合入时同步替换。

### 测试功能点
- W1-T1 跨项目同名承接夹（seed 两项目同名根夹）→ 创建响应 overlap=true、names 含对方项目夹名；同项目嵌套同名不置位；无冲突 → false/None。
- W1-T2 前端：overlap 响应触发 warning toast（组件测试或手测清单）。

## 2. 方案 W2：导入期 key 冲突自动随机后缀（默认行为，无开关）

### 动机
把「失败后逐行点【随机后缀导入】」变成默认自动化，无需事前 opt-in、无需人工介入。语义与既有 F2b 出路完全一致（两处各持独立对象、占用者不动）。2026-10-20 修订：原「任务级 Checkbox（默认不勾）」设计取消——跨项目冲突的推荐处置本就是随机后缀（runbook A），自动化不需要用户显式选择，也就不需要开关、DB 列、迁移与前端改动。

### 触发口径（关键判别）
**占用者全部属于其他项目（跨项目同键）→ 自动后缀；任一占用者属于本任务项目（或归属无法判定）→ 维持现状 key_conflict 失败。**
- 依据：跨项目占用（4da4b1c1 场景）用户无意替换他项目资产，自动后缀无损且正是推荐处置；同项目占用是「重导入→失败→复活带 overwrite 覆盖导入」替换流的既有入口，自动后缀会把替换静默变成重复副本。
- 实现：`_key_conflict_holders`（`workers/baidu_backup.py:874`）现返回 Asset 行，Asset 无 project_id 直连（只有 folder_id）→ 需 join folders 增带占用者 project_id；folder 已删等归属不明 → 保守按「非跨项目」走现状失败。

### 改动点（仅 worker 一个文件）
1. **`workers/baidu_backup.py` 首检分支（`:1682`）与 complete 前二检分支（`:1726`）**：非 overwrite 行遇 key 占用且占用者全跨项目时——
   - 循环 ≤3 次：`new_key = random_suffix_key(key, secrets.token_hex(3))` → 复查占用（软删口径与既有预检一致）+ KEY 长度护栏（`KEY_MAX_CHARS`/`KEY_MAX_BYTES`，加后缀超限视为撞车跳过）；空位即出循环；
   - **守卫写 `reserved_key`**：`UPDATE task_files ... WHERE reserved_key IS NULL`，`statement_rowcount=0` 即已被并发预定 → 按现状 failed(key_conflict) 兜底，防 key 双写漂移。**勿复用 `reserve_random_key`**——其 CAS 要求行 status∈(failed,pending) 并复位 attempts/overwrite（`services/baidu_backup.py:810`），对在途 importing 行语义不符；
   - **首检命中**：换 key 后以新 key 走完本行全程（F2b 落库路径已支持按 reserved_key 落库，零新机制）；**二检命中**：先 abort 在途 multipart 会话并清行上 `(minio_bucket, minio_key, minio_upload_id, bytes_done)` 再换 key 从头续跑——不清则新 key 传完仍 complete 老 key 产出孤儿对象；`db.execute` 的 UPDATE 不回写 ORM 属性，换 key 后须 `db.refresh(row)`，否则 stale attrs 毒化会话恢复寻址（`_resume_or_create_session` 按行上三元组而非传入 key 寻址）；
   - 换 key 重试**不烧 attempt**（attempt 预算留给传输重试）；守卫谓词保证每行至多换一次，续跑后新 key 仍被占 → failed(key_conflict) 兜底，不无限循环；
   - `log.info` 记录「原 key → 后缀 key」供追溯（成功行 last_error 保持为空，reserved_key 列本身即证据）。
2. **DB / API / 前端：零改动**。无开关即无状态——不加列、无迁移、无入参出参变更、无 UI。

### 语义边界（刻意不做）
- **无任务级开关、无 opt-out**（取代原「默认关」决策）：冲突自动化是安全默认——非破坏、两处各持独立文件。
- **同项目占用不自动后缀**：保留「失败→复活覆盖导入」替换流；与 runbook C 红线同源（覆盖删物理对象，跨项目禁用）。
- **不与 overwrite 组合**：overwrite 行遇占用仍走既有 F2a 清除路径，不进自动后缀。
- **存量 failed 行不改口径**：历史 key_conflict 行的三条人工出路（retry/overwrite/random-suffix）原样保留，runbook 处置手册对存量行仍有效。
- 不做任务级"已自动后缀 N 个"的响应统计（P2 可后置，先靠 reserved_key 列可查）。

### 测试功能点
- W2-T1 跨项目占用（seed 两项目同前缀同 key）→ 自动后缀落库成功：两资产 id/minio_key 独立、占用者不动、任务 completed、行 reserved_key=后缀 key。
- W2-T2 同项目占用 → 行为与现状逐字一致（key_conflict failed，复活覆盖流保留）；混合占用（同项目+跨项目并存）/占用者 folder 缺失归属不明 → 同样不自动后缀。
- W2-T3 后缀候选碰撞（mock 首两次候选为已占用）→ 第三次成功；三次全撞（或候选超 KEY 护栏）→ failed 兜底不挂死。
- W2-T4 并发同 key 两行（同任务内同名文件）→ 各自独立后缀，守卫谓词防 key 双写漂移。
- W2-T5 二检窗口换 key：首检过后传输窗口内出现跨项目占用 → 会话作废、按新 key 从头续跑、对象 complete 到新 key、无孤儿残留。
- W2-T6 软删占用行口径：与既有 `_key_conflict_holders` 一致（软删占用同样参与判别与触发）。

## 3. 部署注意

1. 修订后两方案均**无迁移、无 DB 变更**：W1 改 routers（restart `ms-api`），W2 只改 worker（restart `ms-worker`）；SPA 单独推送。无 FGA、无依赖变更。
2. W1 可单独先发（注意 §1 文案与 W2 行为的联动口径）；推荐两方案同批发版，文案零临时态。
3. 回滚：代码回滚即恢复「冲突=失败」现状，无持久化状态残留（reserved_key 仅自动后缀成功行持有，语义自洽）。

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
