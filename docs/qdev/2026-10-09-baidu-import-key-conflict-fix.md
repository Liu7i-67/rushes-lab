# 百度网盘导入 key 冲突修复（批量前缀残留场景）— 需求文档

日期：2026-10-09 ｜ 流程：qdev ｜ 状态：定稿（3 项用户决策已拍板）
分支：`fix/baidu-import-key-conflict`（基于 liuqi tip `3a5a075`，已 merge `research/baidu-netdisk-import`（`7d52603`）为 `2e4116b`）

## 背景与根因

007 在 hh2 dev 实测百度网盘导入（账号 007，任务 `fa4578c0`）：向项目夹 `11/`（prefix `11/`）导入 `/备份测试`（一级 3 个 txt + 子文件夹 2 个 txt）。子文件夹 2 个文件成功、子文件夹正常创建；**一级 3 个 txt 全部失败**，错误 `overwrite_ambiguous: 同 key 对象被其他文件(可能位于回收站)引用`。

根因链（dev 库实测取证）：

1. 2026-10-08 Evan 用普通上传造了 1.txt/2.txt/3.txt（key=`11/1.txt` 等），随后用**批量前缀功能**加前缀 `est_` → 现存资产 `est_1.txt` 的 filename 是 `est_1.txt`，**minio_key 仍是 `11/1.txt`**（批量前缀只改 filename 不改 key，audit upload 事件 key=`11/1.txt` 为证）。
2. 导入循环（`api/app/workers/baidu_backup.py` `_transfer_and_finalize`）对普通导入也做跨资产 key 预检 `_cross_key_count(bucket, key, exclude=None)`：新文件 `1.txt` 的 canonical key `11/1.txt` 被 `est_1.txt` 行引用 → 计数>0 → 行失败。子文件夹文件 key `11/二级目录/4.txt` 无碰撞 → 成功。
3. 该预检本身是**数据安全正确**的（写该 key 会覆盖 est_1.txt 指向的对象）。产品缺陷在于：a) 错误信息不点名占用者，用户无从处置；b) 没有行级出路；c) 批量前缀持续制造 filename≠key 残留，让这个碰撞常态化。

**附带发现（已修）**：research 分支基于 liuqi `1ff517b` 切出，不含其后合入的三需求（65a264f）与 UserPicker 修复（dd3e930）——2026-10-09 上午的 dev 部署把它们回滚了。本分支已通过 merge 修复血缘（部署环节将恢复 dev 全量）。

**遗留登记（不在本周期）**：普通上传 complete 无跨引用检查，同场景同名重传会静默覆盖残留对象并产生两行共用 key（liuqi 存量数据完整性缺陷，prod 同样存在）。用户拍板：另立周期修。

## 功能点明细（验收级）

- **F1 错误信息点名占用者**：非覆盖导入遇跨资产 key 引用失败时，`last_error` 格式为 `key_conflict: <key> 已被 <filename>[、<filename>…]占用`（占用者软删时 filename 后附`(回收站)`；多占用者全列，512 截断）。该失败保持可重试（non_retryable=false）。
- **F2 失败行手动处置**（两个动作，均作用于 `failed` 且 `last_error` 以 `key_conflict:` 开头的行）：
  - **F2a 覆盖**（复用现有 `POST /api/v1/baidu/backup/tasks/{task_id}/files/{file_id}/overwrite`，扩展现准入）：行复位 pending 且 `overwrite=true`；worker 导入时对每个同 key 占用行做权限复查（操作者对占用资产 `can_admin`，或 org admin/系统 admin；目标夹 sensitive 一律拒绝）→ 通过则物理清除占用行（复用 `purge_active_asset` 业务流）→ 按 canonical key 落库新文件；任一占用行无权限 → 行失败 `overwrite_forbidden_for_holder`（信息点名无权限的占用者）。既有「skipped(已存在)行的覆盖」语义不变。
  - **F2b 随机后缀**（新端点 `POST .../files/{file_id}/random-suffix`）：路由侧生成不冲突 key（形态 `{stem}.{8 位随机}[.{ext}]`，`_cross_key_count=0` 校验，冲突重生成 ≤5 次）预写到行；行复位 pending（overwrite=false）；worker 按预定 key 落库，**filename 保持网盘原文件名**。幂等：行已有预定 key 时复用不再新生成（中断重试不漂移）。
- **F3 批量前缀同步迁移 key（根治）**：`POST /api/v1/assets/batch-prefix` 对每个将改名的活跃资产行：新 filename 确定后新 key=`{folder.minio_prefix}{新 filename}`（与 complete_upload 同规则）；新 key 被其他行引用（排除自身）→ 该文件 skip，`skipped_reasons` 新增 `key_conflict`；否则 MinIO copy_object(旧 key→新 key) → UPDATE 行（filename+minio_key）→ **commit 后** delete 旧对象（delete 失败仅记日志留孤儿，不损数据）。copy 失败 → 该文件 skip(`key_copy_failed`)，行不动。既有 NFC 归一/already_prefixed/逐 id 谓词/审计语义全部不变；软删行不参与（维持现状）。audit `batch_renamed` details 增记 `key_moved: true/false`。
- **F4 分支血缘**：本分支 = liuqi tip + research 全量（已 merge，`2e4116b`）。验收时确认三需求功能（batch-prefix/组级建项目/模板）与 baidu 功能共存、基线测试绿。

## 数据库修改方案

- **migration `2026_10_09_0014_baidu_reserved_key.py`**：`baidu_backup_task_files` 加列 `reserved_key varchar(1024) NULL`（F2b 预定目标 key；NULL=未预定，走 canonical key）。不复用 `minio_key` 列——它承担断点续传会话寻址语义，耦合易错。
- `tests/test_db_schema.py` 断言同步（列存在 + 三表约束断言沿用）。
- 无其他表/索引变更；无存量数据迁移要求（列可空）。

## 接口定义

| 方法+路径 | 变更 | 入参 | 返回 | 错误码 |
| --- | --- | --- | --- | --- |
| `POST /backup/tasks/{tid}/files/{fid}/retry` | 不变 | — | 202 `BaiduReviveOut` | 沿用（409 行不可重试/任务非 failed 等） |
| `POST /backup/tasks/{tid}/files/{fid}/overwrite` | **扩展准入**：failed+`key_conflict:` 行也可调用（原来仅 skipped） | — | 202 `BaiduReviveOut` | 409 行状态不满足；403 任务非本人 |
| `POST /backup/tasks/{tid}/files/{fid}/random-suffix` | **新增** | — | 202 `BaiduReviveOut`（`reserved_key` 生效复位 pending） | 404 任务/文件不存在；409 行非 failed+key_conflict；403 任务非本人 |
| `POST /assets/batch-prefix` | 行为增强（入参出参不变） | 沿用 | 沿用（`skipped_reasons` 可能新增 `key_conflict`/`key_copy_failed`） | 沿用 |

- 前缀 `/api/v1/baidu`；鉴权/频控/审计沿用同文件既有模式（`baidu_file_overwrite` 审计事件 details 增 `action_reason: "key_conflict"`；random-suffix 新审计事件 `baidu_file_random_suffix`）。
- `BaiduTaskFileOut` 无新字段（`last_error` 已透出，前端按前缀解析）。

## 前端改动点（`material-storage/web/`）

- 任务详情文件列表：`failed` 行且 `last_error` 以 `key_conflict:` 开头 → 行操作显示【覆盖导入】【随机后缀导入】（覆盖需 Popconfirm，文案含占用者文件名，从 last_error 解析）；其余 failed 行维持既有【重试】；skipped_exists 行既有覆盖按钮不变。
- `key_conflict`/`key_copy_failed`/`overwrite_forbidden_for_holder` 的 `labels.ts` 中文映射。
- hooks：新增 `useBaiduFileRandomSuffix`；扩展既有 overwrite hook 的可用行判断（如按行状态过滤在前端做的部分）。

## 后端改动点（`material-storage/api/`）

- `app/workers/baidu_backup.py`：`_cross_key_count` 失败分支（`_transfer_and_finalize` 首检+complete 前复检、`_overwrite_precheck_and_purge` 同款分支）改为取占用行明细生成 F1 格式 `last_error`；`overwrite=true` 行遇占用行 → 权限复查+purge 占用行（F2a，含敏感夹拒绝/点名无权占用者）；`reserved_key` 非空行用预定 key（F2b，注意 dlink/md5 head 快捷/断点续传均按最终 key）。
- `app/routers/baidu_backup.py`：`overwrite` 端点放宽准入（failed+key_conflict）；新增 `random-suffix` 端点（生成/复用 reserved_key+复位+派发+审计）。
- `app/services/baidu_backup.py`：复位 helper 扩展（`reset_failed_row_for_overwrite`/`reserve_random_key`——保留既有 reset 的字段清理语义，勿清 reserved_key 除非语义要求）。
- `app/routers/assets.py` batch-prefix：F3 key 迁移（presign/boto copy+delete，事务边界如功能点所述）。
- migration 0014 + `test_db_schema.py` 断言。

## 测试功能点（集成层为主，〔集成〕标注必须跑容器栈）

1. 〔集成〕**回归直拍**：造 `est_1.txt`(key=`11/1.txt`) → 导入含 `1.txt` → 行 failed、`last_error` 点名 `est_1.txt`、可重试。
2. 〔集成〕F2a 覆盖成功：有权限者对上述行 overwrite → 202 → 行 success、canonical key 对象内容为新文件、`est_1.txt` 行已物理清除（含 FGA/audit 收尾）。
3. 〔集成〕F2a 无权限：操作者对占用者无 can_admin → 行 failed `overwrite_forbidden_for_holder` 点名。
4. 〔集成〕F2b 随机后缀：random-suffix → 202 → 行 success、filename=`1.txt`、key=`11/1.{rand}.txt` 不与任何行冲突、原 `est_1.txt` 完好。
5. 〔集成〕F2b 幂等：预留后中断（模拟）再次 random-suffix → 复用同一 reserved_key。
6. 〔集成〕回收站占用：软删 `1.txt`(key=`11/1.txt`) → 导入 `1.txt` → failed `key_conflict` 点名`(回收站)`；random-suffix 成功且软删行不受影响。
7. 〔集成〕同名活行回归：目标夹已有同名活跃文件 → 默认仍 skip（不因本次改动走 key_conflict）。
8. 〔集成〕F3 add 前缀：批量加前缀后 filename 与 key 末段一致、新对象在位（head 新 key 200/size 不变）、旧对象已删（head 旧 key 404）；remove 同。
9. 〔集成〕F3 新 key 被占：skip `key_conflict`、原文件 filename/key 不动。
10. 〔集成〕F3 copy 失败（注入 copy_object 异常）：skip `key_copy_failed`、行不动。
11. 既有 66 集成用例回归全绿 + 本地单测回归 + ruff/mypy/lint/build 基线不升。

## 模糊点与决策记录

- **D1（用户）**：非覆盖导入遇 key 占用默认失败+点名（不做自动换 key），行级提供手动【覆盖】/【随机后缀】。
- **D2（用户）**：批量前缀须同步迁移 key，根治残留产生源。
- **D3（用户）**：普通上传 complete 的跨引用检查为遗留项，本周期不动（PM 备注：prod 存在数据完整性风险，建议尽快另立周期）。
- **D4（PM）**：F2a 权限口径=对占用资产 can_admin 或 org/系统 admin，与既有覆盖清除流一致；purge 在 worker 侧执行（与现有同名覆盖同构）。
- **D5（PM）**：随机后缀 key 形态 `{stem}.{8 位随机}.{ext}`（无扩展名则 `{stem}.{rand8}`），filename 不变。
- **D6（PM）**：F2b 预定 key 落 `reserved_key` 新列（migration 0014），不复用 `minio_key`（断点续传语义耦合）。
- **D7（PM）**：分支血缘修复=fix 分支 merge research（`2e4116b`），dev 部署随本周期恢复全量功能。
