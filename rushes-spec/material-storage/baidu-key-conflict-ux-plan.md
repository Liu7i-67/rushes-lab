# 百度备份 key 冲突体验优化方案：创建时预警 + 冲突自动后缀

- 状态：**已定稿，待实施**（实施等用户指令）
- 日期：2026-10-20
- 背景：dev 实战 4da4b1c1——同源目录备份到第二个项目，根下同名承接夹物理键前缀相同（`灵机备份/`），行级 key_conflict 全拦致任务秒败。处置手册见 `baidu-key-conflict-duplicate-import-runbook.md`；本方案把「事后人工处置」前移为「事前预警 + 可选自动化」。
- 决策依据：全量改造物理编号规则（项目开头）= 2 万对象搬家级，**明确不做**（评估结论 2026-10-20 对话，prod 现状 20,145 资产/876 夹）；本两方案均为 additive、零存储迁移。
- 实施分支建议：`feat/baidu-key-conflict-ux`（基于 liuqi）；两方案相互独立，可同批也可拆批交付。

## 0. 现状锚点（已核实）

| 锚点 | 位置 | 说明 |
|---|---|---|
| 创建时目标解析（承接夹 auto-create） | `api/app/routers/baidu_backup.py:789-839` | 显式目标 / 项目根自动建承接夹，`target_auto_created=True` 于 :839；prefix 此刻已知 |
| 创建响应组装 | 同上 `:882` | `target_auto_created`/`dispatch_seq` 等字段在此拼装 |
| 导入首检 key 占用落败点 | `api/app/workers/baidu_backup.py:1683` 与 `:1727`（`_transfer_and_finalize` :1647 内两分支） | 占用即 `fail_row(..., "key_conflict", format_key_conflict_message(...))` |
| 随机 key 生成纯函数 | `api/app/services/baidu_backup.py:205` `random_suffix_key(canonical_key, rand)` | `txlogo.png → txlogo.{rand}.png` |
| 随机 key 预定 CAS（F2b 既有基建） | 同上 `:810-840` `reserve_random_key` | 写 `reserved_key` 列防并发漂移；**导入路径已支持按 reserved_key 落库** |
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
3. **前端**（`web/src/components/BaiduNewTaskModal.tsx`）：创建成功 toast 后，若响应带 overlap → 追加 `message.warning`：「目标文件夹名与项目「X」下的同名文件夹共用存储编号，同名文件会冲突（任务会失败并要求逐个处理）。建议换一个目标文件夹名，或勾选“同名冲突自动加随机后缀”」。**非阻塞**——文件不同名时冲突根本不会发生，不拦创建。

### 测试功能点
- W1-T1 跨项目同名承接夹（seed 两项目同名根夹）→ 创建响应 overlap=true、names 含对方项目夹名；同项目嵌套同名不置位；无冲突 → false/None。
- W1-T2 前端：overlap 响应触发 warning toast（组件测试或手测清单）。

## 2. 方案 W2：任务级「冲突自动随机后缀」开关

### 动机
把「失败后逐行点【随机后缀导入】」变成创建时可选自动化。语义与既有 F2b 出路完全一致（两处各持独立对象、占用者不动），只是免去人工逐行。

### 改动点

1. **DB 迁移 0018 + tables.py 同批**：`baidu_backup_tasks.auto_suffix_on_conflict boolean NOT NULL DEFAULT false`。downgrade 直接 drop 列，无回滚风险（纯 additive 列，旧行 default false 行为不变）。
2. **API**：`POST /backup/tasks` 入参增 `auto_suffix_on_conflict: bool = false`（`BaiduTaskCreate` additive，不传=旧行为）；`BaiduTaskOut` 回显该字段。
3. **worker（核心，`workers/baidu_backup.py:1683` 与 `:1727` 两个占用分支）**：占用命中且 `task.auto_suffix_on_conflict=true` 时——
   - 循环 ≤3 次：`new_key = random_suffix_key(key, secrets.token_hex(3))` → 复查 `_key_conflict_holders(new_key)`（软删口径与既有预检一致）；空位即出循环；
   - `reserve_random_key(...)` 写 `reserved_key`（既有 CAS 防并发漂移），**以新 key 继续本行导入**（F2b 落库路径已支持 reserved_key，零新机制）；
   - 三次候选仍碰撞（概率 ~2^-48 量级，纯防御）→ 按现状 failed(key_conflict) 兜底，不无限循环；
   - `log.info` 记录「原 key → 后缀 key」供追溯（成功行 last_error 保持为空，reserved_key 列本身即证据）。
4. **前端**（`BaiduNewTaskModal.tsx`）：目标选择区下加 Checkbox「同名冲突自动加随机后缀」（默认不勾）+ 说明一句「冲突文件将以 `文件名.随机码.扩展名` 存入，两处各持独立文件」。

### 语义边界（刻意不做）
- **默认关**：不改变既有默认行为（冲突=失败交人工），开关只是新出路。
- **不与 overwrite 组合**：auto_suffix 行不置 overwrite 标志（语义互斥，覆盖是删占用者）。
- **复活/重试不改口径**：既有三条人工出路（retry/overwrite/random-suffix）原样保留；开关只影响导入期的首次占用命中。
- 不做任务级"已自动后缀 N 个"的响应统计（P2 可后置，先靠 reserved_key 列可查）。

### 测试功能点
- W2-T1 开关开 + 跨项目同 key → 自动后缀落库成功：两资产 id/minio_key 独立、占用者不动、任务 completed、行 reserved_key=后缀 key。
- W2-T2 开关关 → 行为与现状逐字一致（key_conflict failed，W2-T1 的反例）。
- W2-T3 后缀候选碰撞（mock 首两次候选为已占用）→ 第三次成功；三次全撞 → failed 兜底不挂死。
- W2-T4 并发同 key 两行（同任务内同名文件）→ 各自独立后缀，reserved_key CAS 不漂移。
- W2-T5 软删占用行口径：与既有 `_key_conflict_holders` 一致（软删占用同样触发自动后缀）。
- W2-T6 迁移 0018：upgrade 后列形态断言 + 旧行 default false；downgrade drop 无残留。

## 3. 部署注意

1. 顺序：迁移 0018 先行（restart 前）→ 代码 → restart `ms-api`+`ms-worker`；SPA 单独推送。无 FGA、无依赖变更。
2. W1 可单独先发（无迁移）；W2 必须迁移+代码同批。
3. 回滚：代码回滚即可，0018 列对旧代码无感知（additive 列不 drop 也可回滚；彻底回滚再 downgrade）。

## 4. 工作量与交付建议

| 项 | 量级 |
|---|---|
| W1（查询+响应字段+toast+测试） | ~半天 |
| W2（迁移+worker 两分支+开关+测试） | ~1 天 |
| 合计 | 一个 qdev 小周期，两方案同批交付 |

## 5. 决策记录

| # | 决策 | 依据 |
|---|---|---|
| U1 | 不做全量物理编号改造（项目开头） | 2 万对象搬家级代价 vs 低频已有兜底的痛点；编号含项目名则项目改名=再搬家，含 ID 则预签名 URL 可读性受损 |
| U2 | W1 预警非阻塞 | 文件不同名时冲突不会发生，拦截会造成误伤 |
| U3 | W2 默认关 | 不改变既有默认语义；自动化是用户显式选择 |
| U4 | W2 复用 F2b reserved_key 基建 | `reserve_random_key` CAS 与落库路径现成，零新机制 |
