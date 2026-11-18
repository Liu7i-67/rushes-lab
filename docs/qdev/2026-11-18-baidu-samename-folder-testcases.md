# 百度备份任务【创建同名文件夹】开关 · web 端结构化测试用例清单

- 日期:2026-11-18
- 依据:`docs/qdev/2026-11-18-baidu-backup-same-name-folder.md`(需求文档为唯一依据,本清单负责 §10 web 部分:Modal 开关 / 展示口径 / 契约字段 / 构建 / 真机验收)
- 被测 worktree:`E:\qbb\github_not_me\rushes-lab-feat-baidu-samename-folder`(分支 `feat/baidu-backup-samename-folder`,基线 1e338b6)
- 用例编写时的代码状态:基线 1e338b6、工作区无代码 diff(包 A~D 开发可能尚未合入)。所有「基线锚点」行号以 1e338b6 为准(已逐一读实际文件核对):
  - `web/src/components/BaiduNewTaskModal.tsx` 389 行:Props :18-22;`Target` 类型 :24;组件 :28;网盘树左栏 :133-192;目标项目 Select :200-212;项目根行 :216-232;`FolderTree` 调用 :238-248;「已选目标」:252-254;`target` state :47;`targetLabel` :80-82;`submit` :84-113(`create.mutateAsync` body :94-98、`target_folder_id` 条件展开 :97);`destroyOnHidden` :120;`dirName` :375-380;`FieldLabel` :382-389
  - `web/src/api/hooks.ts` 1621 行:`useBaiduCreateTask` :1181-1192(mutationFn 内联 body 类型 :1185-1188、POST :1189、onSuccess invalidate `'baidu-tasks'` :1190)
  - `web/src/api/types.ts` 811 行:`BaiduBackupTask` :511-541(`target_auto_created?` :514);`AdminBaiduTask` :606-624(`target_folder` :612);`AdminBaiduTaskDetail extends AdminBaiduTask` :639-650
  - `web/src/components/BaiduBackupDrawer.tsx` 340 行:TaskItem `targetLabel` 三分支 :247-251;展示处 `→ {targetLabel}` :296
  - `web/src/components/BaiduTaskDetail.tsx` 395 行:目标行三分支 :245-248
  - `web/src/pages/AdminBaiduTasksPage.tsx` 552 行:列表「目标」列 :172-189(`title :173`、render :177-188、文本拼接 :179);详情抽屉 `<Field label="目标">` :439-441
- 环境事实(已实证,写死进用例,免得执行人重查):
  - web 依赖为主仓 junction(`material-storage/web/node_modules` 可读),**勿 install**;antd 锁 6.4.2
  - `package.json` scripts::8 `build = tsc -b && vite build`、:9 `lint = eslint .`;vite base `/ms-static/web/`,build 输出 `../api/app/static/web`
  - antd Switch 既有写例(需求 §5 C 点名参照):`components/settings/TokensSection.tsx:183`(`<Switch size="small" checked={includeRevoked} onChange={setIncludeRevoked} />`)、`components/NewFolderModal.tsx`(:1 import,:70 `<Switch />`)
  - 末段派生口径正本:web `BaiduNewTaskModal.tsx` `dirName`(:375-380,先 `replace(/\/+$/,'')` 去尾斜杠再取 `lastIndexOf('/')` 末段);App 侧同口径(就地小函数、空段过滤)
- App 端自动化(不在本清单执行,随开发合入):`material-storage/app/test/models/baidu_task_test.dart`(模型:fromJson 缺省 false / targetLabel 后缀 / 末段派生 / 已删不加)+ `test/features/baidu_new_task_same_name_test.dart`(向导:默认不选 / root 禁用 / 选夹可勾 / 提交体),本地 `flutter test` 可跑,覆盖需求 §10 App 行。

## 用例域索引

| 域 | 内容 | 用例 |
|---|---|---|
| a | 契约字段(types.ts / hooks.ts) | UC-01 ~ UC-02 |
| b | Modal 开关交互(BaiduNewTaskModal) | UC-03 ~ UC-08 |
| c | 任务目标后缀展示口径(Drawer / Detail / Admin) | UC-09 ~ UC-12 |
| d | 越界核查(文件集合 / 行数红线) | UC-13 ~ UC-14 |
| e | 构建(lint / build) | UC-15 ~ UC-16 |
| f | 真机验收(两种模式 × 开关两态 + 列表展示) | UC-17 ~ UC-20 |

共 **20** 条。域 a/b/c/d/e 为代码/构建核查(可交测试子智能体直接执行),域 f 供 PM/用户真机验收(需求 §10 web 行)。

命令约定:以下 git/npm 命令均在 worktree 根 `E:\qbb\github_not_me\rushes-lab-feat-baidu-samename-folder` 执行(npm 命令在 `material-storage/web` 下);路径用 `/` 正斜杠(Git Bash)。

统一展示口径(需求 §8,全清单判定基准):**开关开 ∧ 任务有显式目标夹 ∧ 夹未删 → 目标串追加 `/末段名`;其余分支维持现状**(夹已删「(已删除)」、auto 承接夹模式原样——auto 模式后端恒回 false,不会带后缀;root 提交模式后端静默归一 false,同样不带)。

---

## 域 a — 契约字段(types.ts / hooks.ts)

### UC-01 types.ts 三个任务类型补 `create_same_name_folder?`

- **类型**:代码核查(静态)
- **前置**:包 C 已合入 worktree;基线锚点见文首。
- **操作**:
  1. `grep -n "create_same_name_folder" material-storage/web/src/api/types.ts`:预期 ≥2 处声明命中——
     - `BaiduBackupTask`(基线 :511-541):新增 `create_same_name_folder?: boolean;`,带一句注释,**风格随 `target_auto_created?`**(基线 :514,optional + `?? false` 兜底语义);
     - `AdminBaiduTask`(基线 :606-624):同名字段同风格;
     - `AdminBaiduTaskDetail`(基线 :639-650):`extends AdminBaiduTask` 天然继承即可;若显式重声明,类型必须仍是 `boolean | undefined` 兼容写法(TS 不允许 extends 下不兼容重声明,tsc 过即等价)。
  2. `git diff -- material-storage/web/src/api/types.ts`:预期仅上述新增行(±注释),不删除、不改名、不改类型任何既有字段;`BaiduTasksPage`(:543)等其余接口零改动。
- **预期**:三类型出参契约齐备且全部 optional(后端归一后恒回布尔,前端 optional 兼容旧响应);既有字段零破坏。
- **证据采集**:types.ts diff 片段 + grep 输出原样粘贴进测试记录。

### UC-02 hooks.ts 创建 mutation 请求体类型补字段

- **类型**:代码核查(静态)
- **前置**:同 UC-01。
- **操作**:
  1. `git diff -U3 -- material-storage/web/src/api/hooks.ts` 定位 `useBaiduCreateTask`(基线 :1181-1192):mutationFn 内联 body 类型(基线 :1185-1188,`source_dir` / `project_id` / `target_folder_id?`)新增 `create_same_name_folder?: boolean;`(不传 = 关;类型只收 optional 布尔)。
  2. 既有语义核查:POST 路径 `${BAIDU_BACKUP_BASE}/tasks`(:1189)、`onSuccess` invalidate `['baidu-tasks']`(:1190)、返回类型 `BaiduBackupTask` 均不变。
  3. 范围断言:`grep -n "create_same_name_folder" material-storage/web/src/api/hooks.ts` → 预期**仅** `useBaiduCreateTask` 内 1 处类型命中(hooks 不做展示派生,其它 hook 出现即越界)。
- **预期**:仅请求体类型放宽,mutation 行为零变化(是否携带该字段由 Modal 的条件展开决定,归 UC-06)。
- **证据采集**:hooks.ts diff 片段 + grep 输出。

---

## 域 b — Modal 开关交互(BaiduNewTaskModal)

### UC-03 开关行存在且受控

- **类型**:代码核查(静态)
- **前置**:包 C 已合入;基线锚点 `BaiduNewTaskModal.tsx`。
- **操作**:
  1. `grep -n "Switch" material-storage/web/src/components/BaiduNewTaskModal.tsx`:预期 import 行(基线 :9 antd import 列表)新增 `Switch`,且 JSX 中出现 `<Switch`(antd Switch,写法对齐 TokensSection.tsx:183 / NewFolderModal.tsx 先例)。
  2. 开关行位置:右栏 `FolderTree` 块(基线 :238-248)之后、「已选目标」(:252-254)之前的目标区内;行内含 label「创建同名文件夹」+ 一句说明文案(grep `创建同名文件夹` 命中,中文文案,无英文报错直塞)。
  3. 受控判定:Switch 同时接线 `checked`(或等价受控 prop)与 `onChange`;不允许 `defaultChecked` 非受控写法。对应受控 state(如 `const [sameName, setSameName] = useState(false)`)声明在组件体内。
- **预期**:开关存在、受控、位置在目标区、文案中文齐全。
- **证据采集**:Switch 相关 diff 片段 + grep 输出。

### UC-04 默认不选 + 重开复位

- **类型**:代码核查(静态)
- **前置**:同 UC-03。
- **操作**:
  1. state 初始值断言:`grep -n -A1 "sameName" material-storage/web/src/components/BaiduNewTaskModal.tsx`(state 名允许按代码习惯微调,语义 = 创建同名文件夹勾选态):预期 `useState(false)` 或等价 falsy 初值;全文件无 `useState(true)` 挂到该语义、无 `defaultChecked`、无任何 effect 将其初始化为 true。
  2. 复位机制核查:Modal `destroyOnHidden`(基线 :120)未删——关闭即卸载,受控 state 随卸载销毁,重开必回 false;diff 不得引入绕过卸载的持久化(localStorage/全局 store)或 `destroyOnHidden` 移除。
- **预期**:默认不选;每次打开 Modal 勾选态都从 false 开始(运行时复核归 UC-20)。
- **证据采集**:state 声明 diff 片段 + `destroyOnHidden` 未动的确认记录。

### UC-05 项目根模式置灰 + 提示

- **类型**:代码核查(静态)
- **前置**:同 UC-03;基线锚点 `target` state :47(`{ kind: 'root' } | { kind: 'folder'; id; name }`)。
- **操作**:
  1. 禁用表达式:Switch(或其包裹层)存在 `disabled={target.kind === 'root'}` 或等价三元;允许的实现形态——直接 disabled prop / 包裹层 pointer-events+灰显样式 / 行级条件渲染 root 提示替身。凡 root 模式下用户可改变勾选态的写法即 FAIL(需求 F4:置灰,防止发出会被后端静默归一的误导交互)。
  2. 提示文案:root 模式下该行呈现说明(需求 §5 C 点名口径:「项目根模式本身以网盘目录名建承接夹」);文案中文,`grep -n "承接夹\|项目根" material-storage/web/src/components/BaiduNewTaskModal.tsx` 新增命中处人工核对语义。
  3. 选夹后可用:确认 disabled 条件只在 `kind === 'root'` 为真——`kind === 'folder'` 时无 disabled(或为 false)。
- **预期**:root 置灰 + 提示;选夹后可勾选(运行时复核归 UC-17/UC-20)。
- **证据采集**:disabled 表达式 diff 片段 + 提示文案行。

### UC-06 提交条件:root 不送字段,folder+勾选送 true

- **类型**:代码核查(diff 审查)
- **前置**:同 UC-03;基线锚点 `submit` :84-113。
- **操作**:
  1. `git diff -U3 -- material-storage/web/src/components/BaiduNewTaskModal.tsx` 中 `submit` → `create.mutateAsync({...})`(基线 :94-98):预期新增条件展开,形如
     `...(target.kind === 'folder' && sameName ? { create_same_name_folder: true } : {})`。
     判定要点:①条件必须同时含「显式夹」与「勾选态」两因子;②只送 `true`,不送 `false`(送 false 语义等价、不算 FAIL,但需求 §5 C 预期为条件展开形态,两种形态需在记录中注明实际采用哪种)。
  2. 三态矩阵逐格核对代码路径:
     - root 模式(无论勾选态内部值)→ 对象无 `create_same_name_folder` 键;
     - folder + 未勾 → 无键;
     - folder + 勾 → `create_same_name_folder: true`。
  3. 既有入参零破坏:`source_dir: sourceDir`、`project_id: projectId`、`...(target.kind === 'folder' ? { target_folder_id: target.id } : {})`(基线 :95-97)表达式不变;校验分支(:85-92,sourceDir/projectId 两道 warning)不变。
- **预期**:提交体字段完全由「显式夹 ∧ 勾选」决定;root 模式永不携带该字段(后端 F4 静默归一不可能被触发)。
- **证据采集**:mutateAsync 块 diff 片段 + 三态矩阵核对表。

### UC-07 「已选目标」后缀预览(开关开 ∧ 选夹)

- **类型**:代码核查(静态)
- **前置**:同 UC-03;基线锚点 `targetLabel` :80-82、「已选目标」:252-254。
- **操作**:
  1. `git diff` 中 `targetLabel`(基线 :80-82 两分支)新增第三态:开关开 ∧ `target.kind === 'folder'` → `目录「${target.name}」/${dirName(sourceDir)}`(或等价:文件夹名 + `/` + 「末段名」);`sourceDir` 为 null(未选源)时不得出现 `undefined`/`null` 字样进串(实现可先判 sourceDir 或复用「未选择」分支,形态不限,运行时归 UC-17)。
  2. 不追加分支核对:开关关(无论 root/folder)→ targetLabel 与基线逐字符同款;root 模式(无论开关)→ 维持基线 `项目根(自动创建承接文件夹…)` 款式。
  3. 「已选目标:」渲染行(:252-254)本体不变,仍消费 targetLabel。
- **预期**:预览与提交口径一致(勾选 + 选夹才加 `/末段名`),防「预览加了、提交没带」或反向的口径漂移。
- **证据采集**:targetLabel diff 片段 + 四态(root/folder × 开/关)核对表。

### UC-08 末段派生复用 dirName 且 dirName 本体零改动

- **类型**:代码核查(grep 断言)
- **前置**:同 UC-03;基线锚点 `dirName` :375-380。
- **操作**:
  1. `git diff -- material-storage/web/src/components/BaiduNewTaskModal.tsx | grep -E "^[+-].*dirName"`:预期仅「新增调用点」命中,`dirName` 函数本体(:375-380)无 `-`/`+` 行(rstrip `/+` → lastIndexOf 末段的口径不许动)。
  2. 派生口径抽查(心算对照函数体):`/旅行/照片` → `照片`;`/旅行/照片/` → `照片`;`/照片///` → `照片`(正则 `\/+$` 全吃);`/` → 空串(整盘根不会被选作源,防御分支不追加分号)。
  3. 若 Drawer/Admin 展示侧各自新写了末段小函数,记录其实现并与 `dirName` 逐语义比对(两侧口径必须一致;见 UC-09 步骤 3)。
- **预期**:末段口径单一正本,展示侧要么复用要么语义逐字等价。
- **证据采集**:dirName 零改动确认 + 各侧末段函数实现摘录。

---

## 域 c — 任务目标后缀展示口径(Drawer / Detail / Admin)

判定基准(需求 §8):`create_same_name_folder === true && target_folder(_name) 非空(未删)` → 追加 `/末段(source_dir)`;其余分支维持基线。末段函数口径同 UC-08。

### UC-09 BaiduBackupDrawer TaskItem targetLabel 四态

- **类型**:代码核查(diff 审查)
- **前置**:包 C 已合入;基线锚点 :247-251(三分支)、展示处 :296。
- **操作**:
  1. `git diff -U3 -- material-storage/web/src/components/BaiduBackupDrawer.tsx` 定位 `targetLabel`(基线 :247-251):预期在第一分支(`t.target_folder_name` 非空)内再按 `t.create_same_name_folder` 分叉——真 → `` `${p} / ${t.target_folder_name}/${末段(t.source_dir)}` ``;假 → 基线原样 `` `${p} / ${t.target_folder_name}` ``。
  2. 回退两分支不变断言:`target_auto_created` 分支(基线 :249-250,「项目根(自动创建承接夹)」)与「(已删除)」分支(基线 :251)**逐字符不变**——夹已删时不加后缀(末段无从谈起也不该加),auto 模式后端恒回 false 天然不进新分支。
  3. 末段小函数核查:本文件新增的 `source_dir` 末段派生(若有)与 `dirName` 语义一致(UC-08 步骤 3);`source_dir` 异常值(空串/`/`)不得让 label 产出悬挂 `/`(空段过滤,防御分支)。
  4. 展示处 :296(`→ {targetLabel}`)与 TaskItem 其余逻辑(状态 Tag / 重试可用性 :240-243 / 进度 :244-246)零改动。
- **预期**:用户侧列表目标串四态正确(开∧夹∧未删加后缀;关、已删、auto 各维持基线)。
- **证据采集**:targetLabel hunk diff + 四态核对表。

### UC-10 BaiduTaskDetail 目标行同口径

- **类型**:代码核查(diff 审查)
- **前置**:同 UC-09;基线锚点 :245-248。
- **操作**:
  1. `git diff` 中目标行(基线 :245-248,`目标:{project_name ?? project_id}` + 三元拼接):`target_folder_name` 非空且 `task.create_same_name_folder` 为真 → `` ` / ${task.target_folder_name}/${末段(task.source_dir)}` ``;其余(开关关、已删回退、auto 回退)与基线逐字符同款。
  2. 详情页其余区块(进度条 :249-257、统计 Space :258 起)零改动。
- **预期**:详情与列表口径完全一致,同一任务两处展示串逐字符相同。
- **证据采集**:目标行 diff 片段。

### UC-11 AdminBaiduTasksPage 列表「目标」列同口径

- **类型**:代码核查(diff 审查)
- **前置**:同 UC-09;基线锚点 :172-189。
- **操作**:
  1. `git diff` 中目标列 render(基线 :177-188):`row.target_folder` 非空且 `row.create_same_name_folder` 为真 → text 追加 `/${末段(row.source_dir)}`;已删(`target_folder` null)维持基线「已删」文案 + `var(--ms-amber)` 高亮(:184)**不加后缀**。
  2. Tooltip(:181)消费同一 text 变量(全名可见性不回归);列定义其余(width 200 / ellipsis / fontSize)零改动。
- **预期**:admin 列表目标列与用户侧同口径;「已删」高亮语义不变。
- **证据采集**:目标列 render diff 片段。

### UC-12 AdminBaiduTasksPage 详情抽屉 Field「目标」同口径

- **类型**:代码核查(diff 审查)
- **前置**:同 UC-09;基线锚点 :439-441。
- **操作**:
  1. `git diff` 中 `<Field label="目标">`(基线 :439-441):`task.target_folder` 非空且 `task.create_same_name_folder` 为真 → 追加 `/${末段(task.source_dir)}`;已删维持「已删」;其余字段区(用户/失败原因/取消原因/绑定,基线 :436-462)零改动。
  2. admin 契约对齐备注:`AdminBaiduTaskDetail extends AdminBaiduTask`(types.ts :639),字段在父接口声明(UC-01),详情无需单独读取。
- **预期**:admin 列表与详情两处口径一致,且与用户侧一致。
- **证据采集**:Field 目标 diff 片段。

---

## 域 d — 越界核查

### UC-13 web diff 触及文件集合恰为 §5 C 六文件

- **类型**:代码核查(git 审计)
- **前置**:包 C 完成、UC-15/16 已过。
- **操作**:
  1. `git status --short` + `git diff --name-only` + `git diff --cached --name-only`(若有 staged)。
  2. 集合断言:web 侧代码文件集合 ⊆ { `web/src/api/types.ts`, `web/src/api/hooks.ts`, `web/src/components/BaiduNewTaskModal.tsx`, `web/src/components/BaiduBackupDrawer.tsx`, `web/src/components/BaiduTaskDetail.tsx`, `web/src/pages/AdminBaiduTasksPage.tsx` },不多不少。允许的非代码条目仅限 `.md` 文档(需求文档 / 本用例文件)与 `scripts/changelog.md` 记账(出现需在报告单列,不算代码越界)。
  3. 边界文件专项反断言(出现即 FAIL):`web/src/components/FolderTree.tsx`、`web/src/lib/labels.ts`(审计基线不动)、`vite.config.ts`、`package.json`、`package-lock.json`、`src/styles/tokens.css`、web `src/` 下其它任何文件;`api/` 与 `app/` 侧改动归包 A/B/D,不在本清单判定(报告单列即可)。
- **预期**:无越界改动。
- **证据采集**:三条 git 命令完整输出。

### UC-14 行数红线(BaiduNewTaskModal ≤500)

- **类型**:代码核查(度量)
- **前置**:同 UC-13。
- **操作**:
  1. `wc -l material-storage/web/src/components/BaiduNewTaskModal.tsx` → **≤500 为硬红线**(工程约束);基线 389,预估 +30 → ~420:介于 421-500 记「红线内、超预估」,需开发说明膨胀原因,不自动 FAIL。
  2. `git diff --numstat` 对六文件逐一记录,与 §5 C 预估对照:types +3 / hooks +1 / Modal +30 / Drawer +8 / Detail +5 / Admin +10;单文件偏离预估 2 倍以上需逐行说明用途。
- **预期**:Modal ≤500;增量与预估同量级。
- **证据采集**:wc -l 输出 + 六条 numstat 输出 + 判定结论。

---

## 域 e — 构建

### UC-15 lint 通过(0 error)

- **类型**:构建核查
- **前置**:node_modules junction 完好(**勿 install**);命令在 worktree 的 `material-storage/web` 下执行。
- **操作**:`npm run lint`(即 `eslint .`)。
- **预期**:退出码 0,**0 error**;warning 允许存量但需记录条数与归属文件;凡出现**其他文件**的 lint 报错判 FAIL(不得以「无关存量」放行本次引入的报错)。
- **证据采集**:完整 stdout/stderr + 退出码;若非零,附报错全文。

### UC-16 build 成功

- **类型**:构建核查
- **前置**:同 UC-15;UC-15 已通过。
- **操作**:`npm run build`(即 `tsc -b && vite build`)。
- **预期**:tsc 无类型错误(UC-01 的 optional 布尔契约在此复核:`create_same_name_folder` 读取点全部 `?.`/真值判定,无对 optional 字段直接非空断言滥用的类型告警);vite build 成功(输出含 `✓ built in …`);产物写出至 `material-storage/api/app/static/web/` 且含 `index.html` 与 `assets/`;chunk 划分正常(manualChunks 未被改动——该文件不在允许触碰集合)。
- **证据采集**:build 输出尾部(含产物清单与体积表)+ `ls material-storage/api/app/static/web` 结果。

---

## 域 f — 真机验收(供 PM/用户人工执行)

环境前置(与先例一致):dev 验证机(docker compose 全栈,shserver / hh2 / server2 均可;**本地开发机 docker 栈默认禁止**,见 CLAUDE.md);登录账号需:已绑定百度网盘(binding active)、至少一个 `my_roles` 含 admin/uploader 的项目、项目内至少一个普通夹 B(另备一个敏感夹观察禁选)。网盘源目录建议选**多段子目录**(如 `/照片备份/2026/婚礼精修`,末段 `婚礼精修`,天然验证末段派生)。构建产物环境:UC-16 完成后走部署或 `npm run preview`(4173,代理 /api → 8200;验收以构建产物为准)。

### UC-17 真机:夹模式 × 开关两态

- **类型**:运行时(人工)
- **前置**:环境前置齐备;源目录选定多段子目录 A。
- **操作**(逐项留痕,Network 面板对照):
  - a. **夹 + 不勾**(现状回归):选项目 + 夹 B → 开关保持不勾 → 「已选目标」预览**无** `/末段` 后缀 → 开始备份 → Network `POST /api/v1/baidu/backup/tasks` 请求体**不含** `create_same_name_folder` → 任务列表该任务目标串 `项目 / B`(无后缀)。
  - b. **夹 + 勾选**:重开 Modal → 选同一 A + 夹 B → 勾「创建同名文件夹」→ 预览变 `目录「B」/婚礼精修`(开关开 ∧ 显式夹才追加,UC-07 的运行时复核)→ 开始备份 → 请求体含 `"create_same_name_folder": true` → 任务列表目标串 `项目 / B/婚礼精修`。
  - c. **实际落点**(需任务跑完,目录文件数少些):网盘 A 内含子目录结构时,项目 B 下出现 `B/婚礼精修/<A 的子目录链>/<文件>`;A 本身名出现在落点第一层。
  - d. **同名复用**(F3,可选):同一 A + B 再建一次勾选任务 → 不报错,复用 `B/婚礼精修` 继续导(文件同名跳过语义不受开关影响)。
- **预期**:两态请求体与展示串严格分叉;勾选态落点第一层为末段名。
- **证据采集**:两张任务列表截图(有/无后缀)+ 两张 Network 请求体截图;落点目录树截图。

### UC-18 真机:项目根模式 × 开关两态

- **类型**:运行时(人工)
- **前置**:同 UC-17。
- **操作**:
  - a. **置灰 + 提示**:选项目、目标保持「项目根」→ 开关**置灰不可点**(点按无响应/禁用样式)+ 行上呈现「项目根模式本身以网盘目录名建承接夹」类提示(UC-05 运行时复核)。
  - b. **提交不带字段**:开始备份 → 请求体不含 `create_same_name_folder`(也不含 `target_folder_id`)→ 列表目标串 `项目 / 项目根(自动创建承接夹)` 原样、**无** `/末段` 后缀。
  - c. **行为不变回归**:任务完成后落点为 `项目/<源目录末段>` 承接夹(与改造前项目根行为逐字节一致,开关对 root 模式零影响)。
- **预期**:root 模式开关全程不可用、请求与展示与基线一致。
- **证据采集**:置灰态截图 + 请求体截图 + 承接夹截图。

### UC-19 真机:任务列表/详情/admin 展示回归矩阵

- **类型**:运行时(人工)
- **前置**:UC-17/18 已产生四种存量任务(夹+勾 / 夹+不勾 / root 模式;再备一个目标夹已删的任务与一个 auto 承接夹任务——夹可建后删除制造)。
- **操作**(逐格核对,用户侧 Drawer + 详情 + admin 列表 + admin 详情四处):
  | 任务形态 | 用户侧列表/详情 | admin 列表/详情 |
  |---|---|---|
  | 夹 + 勾(未删) | `项目 / B/末段` | `项目 / B/末段` |
  | 夹 + 不勾(未删) | `项目 / B` | `项目 / B` |
  | root 模式 | `项目 / 项目根(自动创建承接夹)` | `项目 / <承接夹名>` |
  | 目标夹已删 | `项目 / (已删除)`(无后缀) | `项目 / 已删`(amber,无后缀) |
  - 复核末段正确性:同一项目内两个不同源目录(末段不同)各建勾选任务 → 两任务后缀各自取自己的末段,不串。
- **预期**:矩阵逐格命中;四处展示同任务逐字符一致。
- **证据采集**:矩阵核对表 + 每行 1 张截图(至少覆盖勾选态与已删态)。

### UC-20 真机:Modal 状态复位与 root↔folder 切换

- **类型**:运行时(人工)
- **前置**:同 UC-17。
- **操作**:
  - a. **重开复位**:勾选开关后不提交,取消关 Modal → 重开 → 开关回到**不勾**、目标回到项目根(destroyOnHidden 卸载语义)。
  - b. **root→folder**:root 模式(置灰)下选夹 → 开关变可用,可勾选。
  - c. **folder→root**:选夹并勾选后切回项目根 → 开关回置灰(或提交路径不再携带字段)→ 此时直接开始备份 → 请求体不含 `create_same_name_folder`(这是「勾选态残留但 root 不送」的口径兜底,UC-06 的运行时复核;若实现为切 root 即清勾选态,同样算 PASS,记录实际形态)。
  - d. **切换项目**:换目标项目(Select onChange)→ 目标复位项目根 → 开关随 root 置灰,不残留勾选。
- **预期**:开关状态机无残留路径,任何序列下提交体口径都不会错带字段。
- **证据采集**:每子项 1 张截图;异常序列录屏更佳。

---

## 用例 ↔ 需求功能点映射(验收对照表)

| 需求条目 | 覆盖用例 |
|---|---|
| §4 F1/F10 开关默认不选 + 提交字段 | UC-01、UC-02、UC-04、UC-06(代码)+ UC-17a/17b、UC-18b(真机) |
| §4 F4 root 置灰 + 静默归一前端侧 | UC-05(代码)+ UC-18a/18b、UC-20c(真机) |
| §4 F2 末段派生 + 落点(展示口径) | UC-07、UC-08(代码)+ UC-17b/17c(真机) |
| §4 F6 出参回传 + 各端展示口径 | UC-09 ~ UC-12(代码)+ UC-19(真机) |
| §4 F3 同名复用(真机可选) | UC-17d |
| §2 锚点 / §5 C 契约字段 | UC-01、UC-02 |
| §8 统一口径 | UC-06(提交)、UC-07(预览)、UC-09 ~ UC-12(展示) |
| 工程约束(文件集合 / 行数 / lint / build) | UC-13、UC-14、UC-15、UC-16 |
| §10 web 行 真机验收 | UC-17 ~ UC-20 |
| App 自动化(§10 App 行,flutter test) | 见文首「App 端自动化」:`app/test/models/baidu_task_test.dart` + `app/test/features/baidu_new_task_same_name_test.dart` |

## 执行顺序建议

1. 合入后先跑 **UC-13**(越界)→ 不满足直接打回,后续免做;
2. **UC-01 ~ UC-12、UC-14**(代码核查,静态)→ **UC-15、UC-16**(构建);
3. 构建产物部署/preview 后执行 **UC-17**(夹模式两态)→ **UC-18**(root 模式)→ **UC-19**(展示矩阵)→ **UC-20**(状态机,预计 30~45 分钟);
4. 汇总判定:全部 PASS = 验收通过;UC-14 红线内超预估、UC-17c/17d 需真实任务跑完的弱前置项,均需在报告中注明后由 PM 裁量。
