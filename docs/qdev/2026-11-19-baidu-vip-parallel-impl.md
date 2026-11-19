# qdev 需求文档：百度网盘会员同绑定 3 路并发备份（实施包）

- 日期：2026-11-19
- **设计正本：`docs/qdev/2026-11-18-baidu-vip-parallel-backup.md`**（qplan 三轮盲审定稿，本仓 liuqi 已入库 @ 7568664）。本文件只做实施层拆包与派发边界约定，设计内容以正本为准，两文档冲突时以正本为准并回报 PM。
- 需求口径：会员绑定（vip_type≥1）同绑定最多 3 个任务同时执行；非会员完全维持原语义；回滚杆 = env 1。

## 背景与目标

见正本 §1（三层串行点定位 + 生产实况）。实施目标 = 正本 §4 改动点清单 C0-C5 的 C0-C4（C5 记账由 PM 收尾时做）。

## 功能点明细（可验收）

逐条 = 正本 §5 R1-R13 + §3.1-§3.4 各「完成标准」。概要：

1. 迁移 0022 删 `uq_baidu_task_running`（可逆，downgrade 重建，runbook 见正本 §3.2）。
2. `baidu_vip_parallel_per_binding=3` + 断言 `1 ≤ x ≤ limit-1`；非法值启动报错（api+worker 双容器校验面）。
3. 准入 SQL：`ROW_NUMBER() OVER (PARTITION BY binding_id ...)`，会员道 `rn≤vip_par`、非会员道 `rn≤1`；I1-I6 不变量成立。
4. sweeper 派发预算 Counter：VIP=vip_par / 非会员=1；终态化支不受预算影响。
5. 测试网 R1-R13 全绿 + 既有全量用例绿。

## 组件拆分方案（两包并行，文件互斥）

### 包 A · 后端实现（C0+C1+C2+C3）

| 文件 | 改动 | 预估行数变化 |
|---|---|---|
| `api/app/db/migrations/versions/2026_11_18_0022_baidu_vip_parallel.py`（新增） | DROP INDEX uq_baidu_task_running；downgrade 重建（定义照抄 0017 upgrade 内原文） | +25 |
| `api/app/db/tables.py` | 删 `uq_baidu_task_running` Index 定义（**保留 `idx_baidu_task_active_binding`**）；注释同步 | -10 |
| `api/app/settings.py` | 新增 `baidu_vip_parallel_per_binding` 字段 + 校验断言 + docblock（运行时消费=ms-worker；启动校验=api+worker 双容器） | +15 |
| `api/app/services/baidu_backup.py` | `admission_top_task_ids` 加必选 kwarg `vip_par`；reps CTE 改 ROW_NUMBER；会员道 `rn≤vip_par`/非会员道 `rn≤1`；docstring 改写（保留括号子查询语法红线注释） | ±40 |
| `api/app/workers/baidu_backup.py` | `_run_claimed` 调用点传 `vip_par=settings.baidu_vip_parallel_per_binding`；sweeper 候选 join `BaiduBinding` 带出 is_vip、`seen_bindings`→预算 Counter；belt IntegrityError 分支保留为通用兜底；注释更新 | ±35 |

互锁强（vip_par 签名贯穿 3 文件），**单人单包**。既有大文件（services 1224 行/workers 2154 行）延续现状不拆——项目约定优先于 500 行默认上限（记档）。

### 包 B · 测试适配与新增（C4）

| 文件 | 改动 |
|---|---|
| `api/tests/test_baidu_concurrency.py` | `_admission` 助手补 `vip_par` 形参（默认 3）；**T4 重做为 R11**；T18（@1440）断言翻转为「不在 by_name」；三处注释措辞更新（:847/:1277/`test_admin_baidu_tasks.py:33`）；T17 三用例**不需适配**（非会员绑定，语义等价）；新增 R1-R10、R12/R13 |
| `api/tests/test_db_schema.py` | :169-187 断言改「不存在」；:190-204 谓词子集测试删除 |
| `api/tests/test_baidu_integration.py` | `admission_top_task_ids` 直呼点补 `vip_par`（依赖「每绑定 1 代表」旧语义的用例传 `vip_par=1` 保断言有效）；`test_same_binding_multi_task_queue_running_unique_backstop`（@2631）重做为「可多条 running 直插、行为由准入门控约束」 |

包 A/B 文件零交集，契约以正本 §3.3/§3.4 为准，可并行。

## 数据库修改方案

= 正本 §3.2。仅删索引，无数据变更；模型元数据同步。

## 接口定义

不涉及（零 router 变更）。

## 前端改动点

不涉及（正本 §1.3/D6）。

## 后端改动点

= 组件拆分方案表 + 正本 §3.1-§3.4 设计细节（SQL 形态/断言文案/sweeper 预算/churn 注释口径）。

## 测试功能点

= 正本 §5 R1-R13 矩阵（逐条断言口径以正本为准）。执行环境：hh2 dev 容器（`pytest -o asyncio_mode=auto`），不在本地跑 docker。

## 模糊点与决策记录

1. **红线评估**：qplan 三轮盲审已确认可行且成本可控（一迁移+三文件+测试网），用户已下令实施——无需再问。
2. 设计决策 D1-D9 全部沿用正本 §7，实施中不再重开。
3. 单文件行数：既有超长文件（services/workers/测试文件）延续现状不拆（项目约定优先），新增文件保持精简。
4. 直呼 `admission_top_task_ids` 的存量用例传参口径：语义依赖「每绑定 1 代表」的传 `vip_par=1`；验证新语义的用例传 3 或读 settings。
5. 行号漂移对账（2026-11-19 已核，实施以实码为准）：`_run_claimed` 调用点 @265、running 写点 @630、`_auto_suffix_eligible` @915、`_apply_key_conflict_auto_suffix` @926、31045 处理 @1217/1225、sweeper @2026、`seen_bindings` @2086、`_admission` @280、T4 @386、T17 @1341/1368/1393、T18 @1440（pg_indexes 断言 @1462）、test_db_schema @170-187/:190-204、integration backstop @2631/IntegrityError @2650/直呼 @2700、admin 测试注释 @33。
