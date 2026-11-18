# 百度备份任务【创建同名文件夹】开关 — 需求文档(qdev 2026-11-18)

## 1. 背景与目标

现状:新建百度备份任务时选一个网盘目录 A 与项目中目标文件夹 B,A 中内容(含子目录结构)全部导入到 `项目/B/` 平铺承接——网盘子目录以 `B/<子目录链>` 形式建出,但 A 本身的名字不出现在落点里。

目标:新建任务时增加开关【创建同名文件夹】(默认不选)。选中后,导入内容落到 `项目/B/文件夹A/`(文件夹A = 网盘目录 A 的末段名),即 `B/<A>/...`。不选时行为与现状完全一致。

两端同步:网页端 BaiduNewTaskModal + Flutter App 新建向导均加开关。

## 2. 现状锚点(代码事实,行号以 liuqi@1e338b6 为准)

| 事实 | 位置 |
| --- | --- |
| `BaiduTaskCreateIn`(source_dir/project_id/target_folder_id) | `api/app/models/__init__.py:565-570` |
| `BaiduTaskOut`(target_folder_id/name/auto_created 等) | `api/app/models/__init__.py:573-603` |
| `BaiduBackupTask` 表(无同名夹语义位) | `api/app/db/tables.py:549-643` |
| create_task 双分支:显式 B(:790-809)/ 项目根自动承接夹(:810-842,承接夹名=source 末段,行为已等价勾选态) | `api/app/routers/baidu_backup.py:716-923` |
| W1 跨项目前缀预警(best-effort,按 `target_prefix` 比较) | `api/app/routers/baidu_backup.py:844-866` |
| `_build_task_outs` 任务出参组装 | `api/app/routers/baidu_backup.py:633-710` |
| files 列表 `_target_path` 两级回退拼装(行级 prefix → 任务级 task_base → None) | `api/app/routers/baidu_backup.py:1004-1012` |
| worker 落点核心:`dir_parts = rel_path 目录段` → `ensure_folder_chain(root=B)` | `api/app/workers/baidu_backup.py:991-1042`(:1000-1038) |
| `ensure_folder_chain` 同名子夹**复用** + 复用前 `_assert_not_sensitive` | `api/app/services/folder_chain.py:226-245`(:240) |
| `ensure_root_folder_at_project` 承接夹复用/创建 | `api/app/services/folder_chain.py:292-334` |
| `source_dir_leaf_name`(末段派生,worker 已 import) | `api/app/services/baidu_backup.py` |
| Admin 任务出参模型/序列化 | `api/app/routers/admin.py:1242-1261 / 1316-1370` |
| migration 实际 head:`20261115_0021`(用户组级授权,2026-11-16 已合并;文档初稿误记 20261031_0020,包 A 实测纠正) | `api/app/db/migrations/versions/2026_11_15_0021_*.py` |
| web 新建任务 Modal(受控 useState,非 antd Form) | `web/src/components/BaiduNewTaskModal.tsx` |
| web 创建 mutation(请求体内联类型) | `web/src/api/hooks.ts:1181-1192` |
| web 任务类型 | `web/src/api/types.ts:511-541`(BaiduBackupTask)、:606-624(AdminBaiduTask)、:639-650(AdminBaiduTaskDetail) |
| web 目标展示三分支(TaskItem) | `web/src/components/BaiduBackupDrawer.tsx:247-251` |
| web 详情目标展示 | `web/src/components/BaiduTaskDetail.tsx:245-248` |
| web admin 列表目标列/详情抽屉 | `web/src/pages/AdminBaiduTasksPage.tsx:177-184 / 427-462` |
| App 创建 API | `app/lib/core/api/baidu_api.dart:124-143` |
| App 任务模型(含 `targetLabel` getter 集中展示) | `app/lib/models/baidu_task.dart:67-180`(:167-171) |
| App 新建向导(状态/提交) | `app/lib/features/baidu/baidu_new_task_page.dart` |
| App 目标步视图 | `app/lib/features/baidu/new_task_step_views.dart`(NewTaskTargetStep) |
| App 目标类型 BaiduTarget.root/folder | `app/lib/features/baidu/baidu_target_picker.dart` |
| 后端测试主战场/fixture 风格(world fixture + 进程内 worker) | `api/tests/test_baidu_integration.py`(fixture 对象可跨文件 import 复用,先例 `test_baidu_folder_browse.py`) |
| schema 断言风格 | `api/tests/test_db_schema.py` |

## 3. 可行性与成本评估(红线闸口结论)

可行,成本小:任务表加一列 + 创建链归一/校验 + worker 落点 dir_parts 前插一处 + 两端各一个开关控件与展示后缀。复用 `ensure_folder_chain` 的建链/同名复用/敏感断言/key 预算全链,无架构改动。不触发红线闸口。

## 4. 功能点明细(逐条可验收)

- **F1** 新建任务请求支持 `create_same_name_folder: bool = False`(默认 false = 现状行为,逐字节不变)。
- **F2** 开关开启 + 显式目标夹 B:文件落点为 `B/<末段名>/...`,网盘子目录结构保留为 `B/<末段名>/<子目录链>/<文件>`;末段名 = `source_dir` 去尾斜杠后的末段。
- **F3** `B` 下已存在同名夹 A → **复用既有夹继续导入**(不报错不新建;与全系统 ensure_folder_chain 同名复用语义一致,用户已拍板)。
- **F4** 开关开启 + 项目根模式(`target_folder_id` 不传)→ **静默归一为 false**,行为与现状(项目根/末段名承接夹)完全一致;后端不报错。前端在该模式下置灰开关并提示。
- **F5** 开关开启 + 显式 B:创建期快速失败两条——末段名 >255 字符 → 400「网盘目录名过长,无法作为目标文件夹名」;B 的直接子夹已有同名**敏感**夹 → 400「目标文件夹名不可用,请改名或另选目标」(文案不含「敏感」,防探测,与 auto 分支同口径)。非敏感同名夹不拦(F3)。
- **F6** 任务出参(BaiduTaskOut/AdminBaiduTaskOut/AdminBaiduTaskDetailOut)回传 `create_same_name_folder`;用户侧列表/详情、admin 列表/详情、App 任务列表/详情的目标展示按口径追加 `/末段名` 后缀(夹已删时维持「(已删除)」,不加后缀)。
- **F7** files 明细 `target_path`:开关开启时,行未落位(行级 folder 为 NULL 回退任务级 task_base)的预计路径显示为 `<task_base>/<末段名>/<rel_path>`;已落位行用行级真实 prefix(天然已含末段名)。
- **F8** W1 跨项目前缀预警:开关开启时比较前缀用 `B 前缀 + /末段名`(实际落点),不再按裸 B 前缀误报/漏报。
- **F9** 断点续传/重试/复活/行级重试:落点由任务行 `create_same_name_folder` 驱动,重试轮仍落 `B/<末段名>`(同一处代码,无额外状态)。
- **F10** web 与 App 新建向导:开关默认不选;项目根模式置灰;提交时项目根模式不上送该字段(或送 false,语义等价)。
- **F11** 审计 `baidu_task_create` details 增加 `create_same_name_folder`(不新增 event_type,labels.ts 计数基线不动)。
- **F12** 迁移:新列 `baidu_backup_tasks.create_same_name_folder boolean NOT NULL DEFAULT false`,存量任务行归 false = 现状行为,零数据迁移。

## 5. 组件拆分方案

### 工作包 A:后端契约与创建链(文件:api 侧 5 个)
职责:`BaiduBackupTask` 加列 + 迁移 0021;`BaiduTaskCreateIn`/`BaiduTaskOut`/`AdminBaiduTaskOut`(+Detail 继承)加字段;create_task 归一/两条快速失败/W1 前缀/审计/插入;`_build_task_outs` 与 admin `_serialize_admin_baidu_tasks` 回传;files `_target_path` 末段插入。
| 文件 | 改动 | 预估 |
| --- | --- | --- |
| `api/app/db/tables.py` | BaiduBackupTask 加 `create_same_name_folder: Mapped[bool]` 列(server_default false) | +3 行 |
| `api/app/db/migrations/versions/2026_11_18_0021_baidu_task_same_name_folder.py` | 新迁移,revision `20261118_0021`,down_revision `20261115_0021`(实测纠正,保单头);upgrade add column,downgrade drop column | 新文件 ~30 行 |
| `api/app/models/__init__.py` | `BaiduTaskCreateIn` + `create_same_name_folder: bool = False`;`BaiduTaskOut` + 同名字段(默认 False) | +4 行 |
| `api/app/routers/baidu_backup.py` | create_task:F4 归一、F5 两条校验、F5 敏感子夹查询、F8 W1 前缀、插入列、审计 details;`_build_task_outs` 回传;`_target_path` F7 | ~35 行 |
| `api/app/routers/admin.py` | `AdminBaiduTaskOut` + 字段;`_serialize_admin_baidu_tasks` 透传 | +3 行 |

### 工作包 B:worker 落点(文件:1 个)
| 文件 | 改动 | 预估 |
| --- | --- | --- |
| `api/app/workers/baidu_backup.py` | `_import_one_file` 步骤 1:`dir_parts` 计算后,`task.create_same_name_folder` 为真则前插 `[source_dir_leaf_name(task.source_dir)]`(其余逻辑零改动;枚举预检 `_ensure_enum_target_folder` 不动) | +5 行 |

契约(由本文档钉死,包 A/B 互不等待):ORM 属性名 `create_same_name_folder`;包 B 直接引用 `task.create_same_name_folder` 与 `source_dir_leaf_name`(worker 文件已有 import)。

### 工作包 C:web 前端(文件:6 个,均存量小改)
| 文件 | 改动 | 预估 |
| --- | --- | --- |
| `web/src/api/types.ts` | `BaiduBackupTask`/`AdminBaiduTask`/`AdminBaiduTaskDetail` + `create_same_name_folder?: boolean`(风格随 `target_auto_created?`) | +3 行 |
| `web/src/api/hooks.ts` | `useBaiduCreateTask` 内联请求体类型 + `create_same_name_folder?: boolean` | +1 行 |
| `web/src/components/BaiduNewTaskModal.tsx` | `sameName` 受控 state;右栏 FolderTree 块后加 Switch 行(antd Switch,参照 TokensSection.tsx:183 / NewFolderModal.tsx:67-71 写法):label「创建同名文件夹」+ 说明文案;`target.kind==='root'` 时 disabled 并提示「项目根模式本身以网盘目录名建承接夹」;提交 `...(target.kind==='folder' && sameName ? { create_same_name_folder: true } : {})`;「已选目标」开关开启且选夹时追加 `/「末段名」`(复用本文件 `dirName`) | +30 行(改后文件 <500) |
| `web/src/components/BaiduBackupDrawer.tsx` | TaskItem `targetLabel`(:247-251 三分支)加口径:`create_same_name_folder && target_folder_id` 且夹名非空 → `${夹名}/${末段名}`;夹已删维持「(已删除)」 | +8 行 |
| `web/src/components/BaiduTaskDetail.tsx` | 目标展示(:245-248)同口径 | +5 行 |
| `web/src/pages/AdminBaiduTasksPage.tsx` | 目标列(:177-184)与详情抽屉(:427-462)同口径后缀 | +10 行 |

### 工作包 D:App 端(文件:4 个)
| 文件 | 改动 | 预估 |
| --- | --- | --- |
| `app/lib/core/api/baidu_api.dart` | `createTask` 加可选参 `bool createSameNameFolder = false`;body 加 `if (createSameNameFolder) 'create_same_name_folder': true`;更新 doc comment | +8 行 |
| `app/lib/models/baidu_task.dart` | `createSameNameFolder` 字段(default false)+ fromJson;`targetLabel`(:167-171):开关开且 `targetFolderName != null` → `'$p / $targetFolderName/${末段(sourceDir)}'`(末段就地小函数,空段过滤) | +12 行 |
| `app/lib/features/baidu/baidu_new_task_page.dart` | `_createSameName` state;传给 NewTaskTargetStep;提交 `createSameNameFolder: !_target.isRoot && _createSameName` | +8 行 |
| `app/lib/features/baidu/new_task_step_views.dart` | `NewTaskTargetStep` 加 `createSameName`/`onCreateSameNameChanged` 参数;目标区渲染开关行(Switch.adaptive + 说明,tk 令牌;项目根模式 disabled);App baidu 目录无现成 Switch 先例,先 grep 全 app 找既有 Switch 用例对齐风格 | +30 行 |

### 工作包 E:后端测试(文件:2 个,本阶段只写不跑)
| 文件 | 改动 |
| --- | --- |
| `api/tests/test_baidu_same_name_folder.py` | 新文件;复用 `test_baidu_integration.py` 的 world fixture 对象(先例 `test_baidu_folder_browse.py` 的 import 复用方式),按 §7 测试点编写可执行集成用例 |
| `api/tests/test_db_schema.py` | 追加 `baidu_backup_tasks.create_same_name_folder` 列断言(boolean/NOT NULL/server_default false) |

### 工作包 F:web 结构化用例文档 + App 测试(文件:2 个,web 文档本阶段只写;App 测试可本地跑)
| 文件 | 改动 |
| --- | --- |
| `docs/qdev/2026-11-18-baidu-samename-folder-testcases.md` | 新文件;web 无自动化测试,按仓内惯例出 UC-xx 结构化用例(静态代码核查/构建核查/真机验收三域,基线行号锚点) |
| `app/test/` 下新测试文件 | 按现有 flutter_test 风格:BaiduTask targetLabel 开关口径 + fromJson 默认 false;新建向导开关(项目根 disabled/夹可选)widget 测试(若现有 harness 支持;先读 `app/test/` 既有用例对齐写法) |

### 复用资产映射
- `ensure_folder_chain`(建链/复用/敏感断言/key 预算)——直接复用,零改动
- `source_dir_leaf_name`——直接复用(worker 已 import;web 端 `dirName` 本地函数已有)
- `_assert_not_sensitive` 行级护栏——直接复用(导入期兜底)
- antd Switch 项目写例(NewFolderModal/TokensSection)、App tk 令牌体系——复用
- 断点/重试/复活状态机——零改动,靠任务行驱动

### 组件间数据流
创建期:前端开关 → `create_same_name_folder` → create_task 归一/校验 → 任务行落列 → 响应/审计回传。
执行期:worker 每行按任务行 `create_same_name_folder` + `source_dir` 末段动态定 root 链(`B` → `B/<末段>`),ensure_folder_chain 逐层复用/创建;行级 `target_folder_id` 写回真实落位夹。展示期:各端按任务行布尔 + source_dir 末段派生后缀,不新增接口。

## 6. 数据库修改方案

- 表:`baidu_backup_tasks`;列:`create_same_name_folder`;类型:`boolean`;约束:`NOT NULL`;默认:`false`(server_default `false`,与 ORM `default=False`/`server_default` 一致)。
- 迁移:`2026_11_18_0021_baidu_task_same_name_folder.py`,单头接 `20261115_0021`(实测纠正);upgrade 加列,downgrade 删列。存量行由 DEFAULT 归 false = 行为不变,零数据迁移。
- 索引/其他表:不涉及。`uq_baidu_task_running` partial index 不受影响。

## 7. 接口定义

### POST /api/v1/baidu/backup/tasks(改动)
入参新增:
| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `create_same_name_folder` | boolean | 否(默认 false) | 开启后导入内容落 `目标文件夹/<网盘目录末段名>`;`target_folder_id` 不传时后端静默归一为 false(F4) |

错误码新增(均 400,仅开关开 + 显式 B 时):
- 末段名 >255:`「网盘目录名过长,无法作为目标文件夹名」`
- B 直接子夹存在同名敏感夹:`「目标文件夹名不可用,请改名或另选目标」`

返回:`BaiduTaskOut` 新增 `create_same_name_folder: boolean`(归一后的生效值;错误码/其余字段不变)。

### GET /api/v1/baidu/backup/tasks、/backup/tasks/{id}(改动)
`BaiduTaskOut` 回传 `create_same_name_folder: boolean`。

### GET /api/v1/baidu/backup/tasks/{id}/files(改动)
行 `target_path` 拼装按 F7(行级 prefix 优先,回退 task_base 时插末段段)。

### admin:GET /api/v1/admin/baidu/tasks、/{id}(改动)
`AdminBaiduTaskOut`/`AdminBaiduTaskDetailOut` 回传 `create_same_name_folder: boolean`。admin 文件明细无 target_path 字段,不涉及。

## 8. 前端改动点(web + App)

见 §5 工作包 C/D 文件清单。统一展示口径:**开关开 ∧ 任务有显式目标夹 ∧ 夹未删 → 目标串追加 `/末段名`;其余分支维持现状**(夹已删「(已删除)」、auto 承接夹模式原样,auto 模式后端恒回 false 不会带后缀)。

## 9. 后端改动点

见 §5 工作包 A/B 文件清单。

## 10. 测试功能点(§7 用例编写与第 4 步执行的对照基线)

后端集成(开关矩阵):
1. 开关关 + 显式 B → 文件落 B(回归,现状不变)
2. 开关开 + 显式 B → 文件落 `B/<末段>`;含网盘子目录时落 `B/<末段>/<子目录链>/文件`(F2)
3. 开关开 + B 下已有同名非敏感夹 → 复用既有夹,不新建(F3)
4. 开关开 + 项目根模式 → 归一 false,落 `项目/<末段>` 承接夹,响应 `create_same_name_folder=false`(F4)
5. 开关开 + 末段名 >255 → 400(F5)
6. 开关开 + B 下同名夹为 sensitive → 400,文案不含「敏感」(F5)
7. 开关开 + B 为 sensitive/祖先 sensitive → 既有 403/400 回归不变
8. 任务出参回传布尔:用户侧列表/详情 + admin 列表/详情(F6)
9. files `target_path`:行未落位 → `<task_base>/<末段>/<rel_path>`;已落位 → 真实 prefix(F7)
10. W1:开关开时重叠判定按 `B/<末段>` 前缀(F8)
11. 断点/重试:开关开任务行复位后重导仍落 `B/<末段>`(F9)
12. 开关开 + B 被删(target_folder_id SET NULL)→ 行 failed `target_deleted` 回归不变
13. schema 断言:列存在/NOT NULL/默认 false
14. 迁移 downgrade 可逆(删列)

App(flutter test):targetLabel 开关口径/默认 false/末段派生;向导开关禁用态。
web:结构化用例文档 UC-xx(静态核查/构建核查/真机)。

## 11. 模糊点与决策记录(用户已拍板)

| 模糊点 | 决策 |
| --- | --- |
| 平台范围 | **两端同步**(web + App);App admin 面展示不改(遗留 P2) |
| 项目根模式 × 开关 | **置灰 + 静默归一 false**(F4);后端不报错 |
| B 下已有同名夹 A | **复用既有夹继续导入**(F3,与全系统语义一致) |
| 文件同名/重复执行 | 维持既有语义(跳过/覆盖/随机后缀 + 行级重试),开关不改冲突语义 |
| 展示口径 | 目标串追加 `/末段名` 后缀;夹已删不加(决策记录,非用户拍板项,PM 定) |

## 12. 工程约束(对全部子智能体生效)

- 单文件 ≤500 行(新增文件一律从零守住;存量超限文件如 `workers/baidu_backup.py` 只做最小插入,严禁顺手重构/重排)。
- 只许改动 §5 清单列出的文件;`analyze`/`ruff`/`mypy`/`eslint` 过再交。
- 代码风格随周边(注释密度/命名/中文文案口径),web 文案禁出现英文报错直塞 message.error(antd v6 铁律)。
- 审计不新增 event_type(labels.ts 计数基线不动);不动 `uq_baidu_task_running`;不动枚举预检 `_ensure_enum_target_folder`。
- 迁移单头:`20261118_0021` 的 down_revision=`20261115_0021`(实测纠正;`alembic heads` 单头已验)。
- **验收口径(实测记录)**:HEAD 基线本身非全绿(ruff 378 / mypy 158 存量,分布于 auth/main/admin 旧行),后端静态检查按「零新增」对账——本次实测 ruff 378=基线、mypy 158=基线(新列反补 worker attr 一条),改动行零报错。
