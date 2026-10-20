# 需求文档：百度备份 key 冲突体验优化（W1 创建时预警 + W2 冲突自动随机后缀）

- 日期：2026-10-20
- 状态：qdev 实施中
- **权威方案**：`rushes-spec/material-storage/baidu-key-conflict-ux-plan.md`（qplan 3 轮盲审定稿，a9bf583）——本文档为实施拆解，冲突时以方案为准。
- 实施位置：worktree `rushes-lab-qplan-baidu-key-conflict-ux`，分支 `qplan/baidu-key-conflict-ux`（用户指定沿用当前 worktree，偏离方案的 feat 分支建议）。

## 背景与目标

dev 实战 4da4b1c1：同源目录备份到第二个项目，根下同名承接夹物理键前缀相同（`灵机备份/`），行级 key_conflict 全拦致任务秒败。本需求交付两件事：

- **W1 创建时跨项目路径预警（非阻塞）**：创建任务时检测目标前缀是否与其他项目文件夹重叠，命中则在创建响应中带提示字段，前端 toast 预警。
- **W2 导入期 key 冲突自动随机后缀（默认行为，无开关）**：非 overwrite 行遇 key 占用且占用者全部属于其他项目时，自动生成随机后缀 key 完成导入；同项目占用维持现状失败语义。

## 功能点明细（逐条可验收）

### W1

1. W1-F1 创建任务（POST /backup/tasks）时，若目标前缀与其他项目文件夹重叠（rtrim 归一比较，不过滤归档/软删项目，LIMIT 3），创建响应 `cross_project_prefix_overlap=true` 且 `overlap_project_names` 含对方**项目名**；否则 `false`/`null`。
2. W1-F2 前端创建成功 toast 后，overlap 命中时追加 `message.warning`（文案见方案 §1 改动点 3，含混合占用限定句）；不阻塞创建。
3. W1-F3 列表/详情侧响应字段保持默认值（不回填，后置）。

### W2

4. W2-F1 触发判别：非 overwrite 行 + key 占用 + **占用者全部属于其他项目** → 自动后缀；任一占用者属于本任务项目、或归属无法判定（folder 缺失，防御分支）→ 维持现状 key_conflict 失败。
5. W2-F2 候选生成：`random_suffix_key(key, secrets.token_hex(4))`，循环 ≤5 次，复查复用既有 `random_key_taken`；KEY 护栏超限直接 fail-fast 兜底。
6. W2-F3 统一重启机制（首检/二检两分支共用）：abort 在途会话先行 → **单条** owned 守卫 UPDATE（`WHERE id AND owned_row_predicate() AND reserved_key IS NULL`，`SET reserved_key=候选, 清 (minio_bucket, minio_key, minio_upload_id, bytes_done), last_error=NULL`）→ `db.refresh(row)` → 以新 key 重进传输步骤；rowcount=0 → `_fail_row(key_conflict)`（失去所有权自然退化为 lost）。
7. W2-F4 换 key 重试不烧 attempt、不重新认领行；守卫谓词保证每行至多换一次。
8. W2-F5 语义边界：overwrite 行走既有 F2a；手工 F2b 已预定的行不被改写；存量 failed 行三条人工出路不变；size=0 直传无二检（既有行为不动）。

## 数据库修改方案

**不涉及**。无迁移、无新列、无索引变更（`reserved_key` 等列均已存在）。

## 接口定义

- `POST /backup/tasks` 响应（additive，其余字段不变）：
  - `cross_project_prefix_overlap: boolean`（默认 false）
  - `overlap_project_names: string[] | null`（默认 null；命中时 ≤3 个对方项目名）
- W2 无任何 API 变更。
- 错误码：无新增。

## 前端改动点

`web/src/components/BaiduNewTaskModal.tsx`（toast 逻辑）+ `web/src/api/types.ts`（`BaiduBackupTask` 接口 additive 两字段）+ `web/src/api/hooks.ts`（类型同步，如需）。文案与逻辑细节以方案 §1 改动点 3 为准。

## 后端改动点

- W1：`api/app/routers/baidu_backup.py`（overlap 查询+handler 对 `outs[0]` 后赋值）、`api/app/models/__init__.py`（`BaiduTaskOut` 增两字段带默认值）。SQL、归一化、不过滤口径以方案 §1 改动点 1/2 为准。
- W2：仅 `api/app/workers/baidu_backup.py`（`_key_conflict_holders` 增带占用者 project_id、两占用分支接自动后缀、统一重启机制、`secrets` 补 import）。全部实现纪律与反例后果见方案 §2 改动点 1（同条 UPDATE/abort 先行/refresh/不烧 attempt 等均为硬约束）。

## 测试功能点

以方案 §1「测试功能点」与 §2「测试功能点」为准（W1-T1/T2；W2-T1/T2/T3/T4/T5/T6/T7/T8/T9），其中 W2-T4 为机制单测+守卫兜底单测（禁止造假同任务同名集成用例）、W2-T2 的 folder 缺失分支仅 mock 层可覆盖。

## 模糊点与决策记录

| # | 决策 | 依据 |
|---|---|---|
| D1 | 沿用 qplan worktree/分支，不另切 feat 分支 | 用户指令「直接在当前 worktree」 |
| D2 | 其余决策全部沿用方案 §5（U1-U4）及 qplan 三轮审查结论 | 方案已定稿，无新模糊点 |
| D3 | W1 文案采用方案定稿版（含混合占用限定句），W1/W2 同批交付 | 方案 §1/§3；避免文案临时态 |

## 部署注意（交付后）

无迁移；W1 需 restart ms-api，W2 需 restart ms-worker；SPA 单独推送。无 FGA、无依赖变更。
