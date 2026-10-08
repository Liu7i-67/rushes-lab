# 批量文件名前缀 + 组级「新建项目」权限 + 默认模板直通 · 实施方案

> Status: **范围重订(2026-10-10),待盲审**
> 本文件原名「目录导入(百度网盘中转)+ 批量文件名前缀 + 组织级三角色」(2026-09-30 经 16 轮盲审定稿);
> 2026-10-08 并入 liuqi `681af12` 基线复审后按用户决策重订范围(见 §0)。文件名沿用历史,勿据名推断内容。
> 行号基准:本 worktree HEAD(`d4bf80e`,已并 liuqi `1ff517b`)
> 范围:material-storage(后端 `api/` + 前端 `web/`;批次二含 OpenFGA model 加一个 relation)
> 基线事实:project-grant-templates-plan 三批已全部上线 dev/prod——initial_grants、权限模板 CRUD、
> 组管理放开、幸存 tuple 投影、组名解析(`subject_names.py`)、members 主体存在性校验

---

## 0. 背景与范围决策

| 原需求(2026-09-30 调研点) | 决策(2026-10-10 重订) |
|---|---|
| 一:百度网盘内容导入,保持目录结构 | **移出本方案**,由用户自行调研后另立方案(原 §1 全部内容作废,含 uppy relativePath、`ensure_folder_chain`、建夹 NFC 归一化等;git 历史 `0992de3` 版本留档) |
| 二:批量选中文件统一加/去文件名前缀 | **保留**,§1 原样(仅删与三角色方案的联动引注、刷新行号) |
| 三:艺人/运营/组长三角色,组长可新建项目 | **替换实现**:放弃 FGA org 级 operator/leader 派生,改为 ①用户组可选授予「新建项目」权限(§2)②默认模板后端直通(§3.1)+ 管理页「刷新默认权限」按需补存量(§3.2)。艺人 = 现有项目级授权,不变 |
| (新增)新建项目弹窗体验 | 模板与初始权限聚尾、弹窗限高滚动、PC 双栏(§3.3) |

**为什么放弃 org 级派生**:原方案的 operator/leader 派生需要改 model 的 `can_*` 定义、`org_role` 字段贯穿 /me/ProjectOut、前端双源能力闸门、独立管理页与 MyPermissionsPage 适配——一整条管线。而权限模板 + initial_grants 上线后,「组 → 每项目显式授权」走的是现成的 per-project tuple 机制,`my_roles`、项目列表可见性、能力闸门**全部零改动自动生效**。代价:存量项目不自动覆盖——按用户决策**只管未来项目**,存量由管理员用 §3.2「刷新默认权限」按钮按需补,不做自动回填。

**选型细则**:
- 「可新建项目」= FGA `organization#project_creator` relation,subject 含 `group#member`(与 `organization#admin` 同形);授予入口放**用户组管理**(系统 admin 操作,提权面不扩大)。
- 「运营/组长看全部项目」= 把运营组/组长组配进**默认模板**;新项目建 project 时后端自动附加(§3.1),存量项目用刷新按钮补(§3.2)。

---

## 1. 批次一:批量文件名前缀(加/去前缀)

### 1.1 API

`POST /api/v1/assets/batch-prefix`(assets.py 新端点):

```python
class AssetBatchPrefixIn(BaseModel):
    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=1000)
    action: Literal["add", "remove"]
    prefix: str = Field(..., min_length=1, max_length=128)   # 禁 "/"、禁控制字符、strip 后非空;服务端 NFC 归一化
                                                              #(防 macOS 粘贴的 NFD 前缀令 already_prefixed /
                                                              #  remove 按码点比较不命中;NFC 归一可能略增长度,
                                                              #  归一后复检 ≤128)
```

语义(明确写死):

- `add`:`filename = prefix + filename`;**已以该 prefix 开头的跳过**(防重跑叠加双层前缀);结果长 >512 的跳过;
- `remove`:filename **恰好以 prefix 开头**(大小写敏感)才剥离一次,否则跳过(批量清理已加前缀的场景,不匹配=已无前缀,不应整批失败);剥离后为空串的跳过(计 `empty_result`);
- **前缀比较两侧 NFC 归一**:prefix 服务端归一(见字段注释),比较用 `unicodedata.normalize("NFC", asset.filename).startswith(prefix_nfc)`(add/remove/already_prefixed 同一口径)——存量资产 filename 多为 macOS 拖入的 NFD(`assets.py:167` 原样落库,全程无归一化),只归一输入侧会让 remove 报 no_match、already_prefixed 判空 → 重跑叠加视觉相同的双层前缀,恰是要防的事故。**remove 的剥离实现口径**:`remainder = NFC(filename)[len(prefix_nfc):]`,余量落库即 NFC 形式(NFC/NFD 码点数不同,不能对原串按长度切);
- 返回 `{renamed: int, skipped: int, skipped_reasons: {too_long: n, no_match: n, already_prefixed: n, empty_result: n, deleted: n}}`(键固定 ASCII,前端做中文映射;`deleted` 桶语义 =「已删除或已不存在」——软删行与跨页选中期间被彻底清除的 stale id 都归此桶,前端文案不细分)——**尽力而为 + 结果报告**,是批量操作业界常规。

**权限**:按 `folder_id` 分组,每组做一次 `can_upload` check(对齐 `update_asset_meta` 的权限语义,`assets.py:537-542`;敏感夹按 `sensitive_folder` 类型);系统 admin 直通。任一组无权限 → 403 整批不执行,**文案笼统**(「所选部分或全部文件无操作权限」,**不带 folder 名**,对齐既有反探测约定——`assets.py:278` 不暴露 folder 存在性);诚实拒绝避免改一半,本期前端形态是单目录内多选,跨目录混选非预期。

> 敏感夹里仅受邀 downloader(非 admin)也有批量改名能力(sensitive_folder 的 `can_upload = can_download`,store.fga.yaml:104)——与该夹内打标权限同语义,接受;若产品要求收紧到 admin 再议。组级授权(默认模板/手动)落的 uploader 同样具备对应项目的批量改名能力,遵循既有 can_upload 语义,属预期。

**实现**(单事务,写死形态):
0. `asset_ids` 先 `dict.fromkeys()` 去重(SELECT 的 IN 语义天然按集合算,不去重会让「提交数 − 命中数」把重复 id 误计入 deleted);
1. `SELECT a.id, a.filename, a.folder_id, f.is_sensitive ... JOIN folders f WHERE a.id IN (...) AND a.deleted_at IS NULL`(folder_id/is_sensitive 供权限分组);
2. Python 端逐行按上述语义算新名(**两侧 NFC 归一**),得出「应改 / 各原因跳过」清单;`add` 的结果串同样按 `NFC(prefix + NFC(filename))` 落库(与 remove 余量口径一致,库内 filename 逐步收敛为 NFC);
3. 批量 UPDATE 用 Core 语句、**单事务内逐 id UPDATE**(**不用 ORM 脏对象 flush**——后者遇并发 hard purge 抛 StaleDataError 把整批变 500,`assets.py:561-565` 既有处理先例;也不写成单条 `update().WHERE id IN(...) RETURNING`——add 场景每个 id 的新名各不相同,单语句单 SET 表达不了,而 asyncpg 方言的 executemany 又不累积 RETURNING,会让对账全落归因分支;逐 id 最简且天然拿到 rowcount,与 remove 侧「按 id 粒度」统一口径;文件量上限 1000、单事务内逐行 UPDATE 可接受),每条 `WHERE id = :id AND deleted_at IS NULL`;**add 场景谓词再带 `NOT starts_with(normalize(filename, NFC), :prefix)` 二次防线**(并发双提交两侧 SELECT 都判「无前缀」会叠双前缀,谓词拦住后计入 already_prefixed;用 PG `normalize(filename, NFC)` 与 Python 判定同口径——裸 `starts_with(filename, ...)` 对存量 NFD 名字节不匹配拦不住;用 `starts_with()` 而非 `LIKE prefix || '%'`——后者 `_`/`%` 通配符会让 `final_` 误拦 `finalX01.mp4`,如须 LIKE 则转义 `\`/`%`/`_`,仓库先例 `_escape_like` `assets.py:902-904`);**remove 侧 WHERE 同为按 id 粒度、不加字节级 starts_with 谓词**(字节级谓词与两侧 NFC 归一口径不对称,存量 NFD 名会静默不命中;并发窗口的罕见 lost-update 可接受);
4. **对账**:未更新的 ids(逐 id UPDATE 的 rowcount 为 0)追加一次 SELECT 归因——`deleted_at IS NOT NULL` → deleted,`NFC(filename)` 以 prefix 开头 → already_prefixed,**兜底:原始字节 `starts_with(filename, prefix)` 命中 → also already_prefixed**(极端窗口:前缀末字符为可组合基字符时,Python 侧 NFC 判定与谓词的原始字节比较可能不一致,兜底保证任何差额都有归因桶);SELECT 阶段就查不到的 id(提交数 − 命中数)同样计入 deleted。保证 `renamed + skipped` 与提交数严格对账,§1.4 的逐原因断言可写。

403 时写 `access_denied` audit(变更类端点既有先例:`create_upload` `assets.py:79-87`、`update_asset_meta` :544-553 同款,记录「谁试图批量改名」的安全信号)。**MinIO key 不动**(下载文件名由 `assets.filename` 动态生成 Content-Disposition,纯 DB 改名即改变用户看到的文件名;对象 key 保持是既有架构约定,filename 与 minio_key 本就是分离字段)。

**audit**:一条聚合事件 `asset.batch_renamed`(details:`action` / `prefix` / `renamed` / `skipped` / 采样前 50 条 `{id, old, new}`,超出只计数不展开)。`web/src/lib/labels.ts` 补中文映射(「批量重命名」,#124 约定;**映射键与后端 event_type 逐字相等**——现存错位 `asset.tag_updated`(`assets.py:569`)↔ `asset_tag_updated`(`labels.ts:20`)的修法:**labels.ts 补点号键 `asset.tag_updated`,后端 event_type 不动**,避免历史 audit 行按 event_type 过滤时跨两个值)。

### 1.2 前端(`web/src/pages/ProjectDetailPage.tsx`;行号较 0992de3 版 +4,`canUploadProject` :58-60 例外未动)

- **跨页保留选中**(**两处**翻页清空都要删:compact :568 与桌面 :924):antd Table `rowSelection`(:881-884)加 `preserveSelectedRowKeys: true`,compact 卡片模式(:403、:505)选中 state 同规则;**切换 folder 仍清空**(:106 保留)——批量栏计数本身已按 `selectedIds.length` 显示(compact :595、桌面 :838/:845/:864),本项真正要改的只有「翻页不清空」;
- **自绘全选框改为「只增删当前页」**:桌面 actions-bar 与 compact 的自绘全选(:814、:505)现状是 `e.target.checked ? assetItems.map(a => a.id) : []`,preserve 下第 2 页点取消会清空全部页选中。改为对当前页 id 做**并集(勾选)/ 差集(取消)**,勾选态按「当前页 id 是否全在 selectedIds」计算。antd Table **内置**表头全选在 preserve 下天然就是该语义,**不要去改它**。
- **既有三个批量操作同步切换为 `selectedIds` 全量口径**——它们当前消费的 `selectedAssets` 只含当前页(`assetItems.filter`,:115-118),跨页保留选中后会「显示 N、实际只操作当前页」静默漏操作:批量下载(:160)与批量删除(:164)本就是按 id 逐条循环,改遍历 `selectedIds`;**跨页未加载的 id 没有 Asset 对象、取不到 filename**——下载场景**定案:占位名 `asset_<id前8位>.<按 content_type 推断的扩展名>`**(裸 UUID 无扩展名不可读,取不到 content_type 时回落 `.bin`),**403 且无对象时无法弹「申请权限」(需完整 Asset)——计入「需申请」聚合计数提示**,失败 toast 对未加载项**按 id 聚合计数展示**(不再逐文件 `${a.filename}: …`);`handleBulkDelete` 的空尾页回退判定(:172-174 以「当前页行数」为基准)随全量口径同步复核改写;BulkTagModal 提交同理按 id,**但其跨页合并语义必须后端化**——现状是前端用已加载行的 `user_labels` 做客户端合并(:955-967),后端对 user_labels 是整条替换(`assets.py:555-556`);跨页未加载的 id 前端没有旧标签,只发新标签会把旧标签**清掉**。改法:`AssetMetaUpdateIn` 增加 `labels_mode: Literal["merge", "replace"] = "replace"`,merge = 服务端与 DB 现值取并集(**顺序写死:DB 现值在前、新标签追加在后**,前端 chips 展示顺序因此确定),单文件现行为零变化;BulkTagModal 批量路径改传 merge,不再依赖已加载行。BulkTagModal「文件清单」展示改为「已选 N 个(清单为当前页已加载项)」。右栏 `AssetSummaryPanel selected={selectedAssets}`(:938)同为当前页口径,面板标题注明「(当前页)」与批量栏全量计数区分。批量下载跨页放大后加阈值确认(选中 >20 个先提示);zip/打包下载列 §6 留口。
- 批量栏加「批量前缀」按钮(**桌面与 compact 批量栏同加**——compact 现有批量操作栏在 `ProjectDetailPage.tsx:578-619`,组授权用户在移动端用批量前缀是合理场景;**disabled 门控随打标同款 = `folder.my_can_upload`**,桌面 :835-837、compact :600 同口径)→ Modal:action 单选(加前缀/去前缀)+ prefix 输入 + **预览**(基于当前页已加载的选中项取前 5 个文件名算改名前后对照,并明示「预览仅当前页,共已选 N 个」;提交按 `selectedIds` 全量分批,后端按 id 处理,不依赖前端持有文件名)+ 确认;
- 前端类型同步:`web/src/api/types.ts` 与 `hooks.ts` 的 meta update body 加 `labels_mode` 字段(§1.1 后端新增,前端不同步则 TS 拿不到);既有批量操作的失败 toast 对未加载页的 id 取不到 filename,**按 id 聚合计数展示**(不再逐文件 `${a.filename}: …`);
- 提交:选中 >1000 时前端按 1000 分批顺序调用(**任一批失败即中止**,toast 报「已完成 k/n 批」),汇总 toast「已重命名 N 个,跳过 M 个(原因)」;完成后刷新列表并清空选中。

### 1.3 边界与取舍

| 情况 | 处理 |
|---|---|
| 去前缀后与同目录现有文件同名 | 允许(系统本就允许同目录同名,key 不冲突);不额外拦截 |
| 误操作恢复 | 无 undo;`add` 的逆操作即 `remove`(同前缀),方案明示;audit 有采样记录 |
| 盲搜/标签索引 | filename 改动后 GIN trgm 索引由 PG 自动维护,盲搜(`GET /assets/search`)即刻生效 |
| **文件夹前缀** | **不做**——牵动 `minio_prefix` 子树级联与存量 key 迁移,ROADMAP D iter2 已标低优先级;文件名前缀已覆盖需求 |
| 回收站内文件 | `deleted_at IS NOT NULL` 的不在 SELECT 范围,天然跳过 |

### 1.4 测试

新 `tests/test_batch_prefix.py`(容器内,沿用 Evan/outsider fixture):
add 全成功;add 时已带前缀的跳过(already_prefixed);remove 含不匹配(部分 skipped);**NFD 存量文件名 + NFC 前缀两侧归一命中**(防 macOS 场景失效);无权限用户 403;>1000 拒绝(422);空结果名/超长跳过;软删文件跳过(含 SELECT 与 UPDATE 间并发软删);敏感夹文件按 sensitive_folder check;`labels_mode=merge` 并集生效且 replace 默认行为不变。
前端手工冒烟补:跨页勾选后全选/取消全选只影响当前页;翻页后批量操作按全量 selectedIds 生效;跨页批量打标不清空未加载页的旧标签。

---

## 2. 批次二:组级「新建项目」权限

### 2.1 OpenFGA model 改动(`material-storage/poc/openfga/store.fga.yaml`)

```fga
type organization
  relations
    define admin: [user, group#member]
    define member: [user, group#member, department#member]
    define project_creator: [user, group#member]   # 组级「可新建项目」;UI 只写组主体,user 留口
```

- **风险等级:加新 relation,零风险**(CLAUDE.md 约定:不改名、不加 condition,存量 tuple 不受影响)。
- 组成员判定由 FGA 天然承接:`check(user:X, project_creator, organization:<tenant_key>)` 命中组 tuple 时自动展开 `group:<gid>#member`,无需应用层逐组查成员。
- **部署顺序**:`openfga_write_model.sh` **先 push model,再放代码**(代码 check 一个 model 里不存在的 relation 会报错;反向无害——多出的 relation 不影响旧代码)。脚本在 `api/scripts/` 下,默认 HOST=server2 公网且 `ssh root@$HOST` 直连——hh2 内网 dev/prod 各有独立 store 且走跳板反向隧道,须在目标机本地跑或配 ProxyJump。push 后重启对应环境 ms-api/ms-worker。
- yaml 的 tuples/tests 段补 project_creator 用例(`fga model test` 全绿)。

### 2.2 组管理入口(directory.py + AdminGroupsPage)

- `GroupCreateIn`(`directory.py:312`)/ `GroupUpdateIn`(:317)加 `can_create_project: bool = False`;
- create(:372)/update(:403)端点:flag 置位 → 写 `organization#project_creator` 的 `group:<gid>#member` tuple;清除 → 删该 tuple(**删 stale 用 `is_not_exists_error` 吞**,`permissions.py:92-102` 新 helper,组从未有 flag 时幂等)。tuple 读写**封装为 PermissionsService 小方法**(`add_org_relation` / `remove_org_relation`,参数 object=organization:<tenant_key>, relation, subject)——路由不直接摸 `_client`,写法参考 `grant_org_admin.py:72-75` 的 ClientWriteRequest 但收敛到 service 层;
- **组删除时顺手删该 tuple**(组删除后 `group#member` tuple 不回收是既有约定,残留的 project_creator tuple 因组员 tuple 已清而 check 恒 false、无害,但顺手清一行更干净,同样吞 not_exists);
- `AdminGroupsPage` 的 `GroupFormModal`(:208-221,现 name+description 两字段)加 Switch「允许组成员新建项目」+ 说明文案(「勾选后组内所有成员可在项目页新建项目,新建后自动成为该项目管理员」);列表页给带 flag 的组加徽标;
- audit:既有 `group_created` / `group_updated` 的 details 增 `can_create_project` 字段,不新增 event_type;
- **提权面**:该开关仅系统 admin 可操作(directory.py 组 CRUD 本就 `require_system_admin`),与权限模板同级别,不新增授予路径。

### 2.3 守门与弱门放宽

- `api/app/deps.py` 新增(仿 `is_org_admin` 的 check 写法,`permissions.py:444-451`,relation 换 `project_creator`;default org 缺失行为对齐 `deps.py:205-206` / `:229-230`):

  ```python
  async def require_project_creator(...) -> CurrentUser:
      """org admin 或 organization#project_creator 命中(含组展开);403 文案与 require_system_admin 区分。"""

  async def get_is_project_creator(...) -> bool:   # bool 变体,给 /me
  ```

- `create_project`(`projects.py:56` 的 `Depends(require_system_admin)`)换 `require_project_creator`;`admin_user_id` 必填逻辑与 initial_grants 前置校验(:98-138)/直通写(:167-194)全部不动——组长自建时前端默认 `admin_user_id=me.id`(NewProjectModal :53)、`minio_bucket` 默认 ms-dev(:140/:181),无需理解技术字段;
- **弱门并入(两个必改项,否则新组长连表单都填不完)**:
  - `GET /users`(`users.py:40`)、`GET /groups`(`groups.py:37`)现守门 `require_admin` = 系统 admin 或「任一项目 can_admin」——**一个还没建过项目的新组长两者皆无**,SubjectPicker/UserPicker 拿不到候选、连项目管理员都指派不了。改为 `require_admin or is_project_creator`(deps 组一个 `require_admin_or_project_creator`);
  - `GET /api/v1/admin/grant-templates`(`admin.py:317-320`)现 `require_system_admin`——组长打开新建弹窗时模板 Select 直接 403。**读端点**放宽为「系统 admin 或 project creator」,POST/PATCH/DELETE 写端点保持 `require_system_admin`。
- 原 org 派生方案里「组长经 can_admin 派生自动过弱门」的机制不存在了,上述放宽就是替代,验收时勿当越权(仅多放了两个**读**接口给建项目人)。

### 2.4 /me 与前端闸门

- `/me`(`auth.py:120-158`)响应加 `is_project_creator: bool`;`web/src/api/types.ts` 的 `Me` 接口同步;
- 前端闸门(**回落式判定** `me.is_project_creator ?? me.is_system_admin`——旧后端下新字段 undefined(falsy),不回落会连系统管理员的新建按钮一起消失):
  - `ProjectsPage.tsx:62-79` 新建项目入口换字段,提示文案同步;
  - `NewProjectModal.tsx:156` 的 `!me.is_system_admin` 守卫换 `!(me.is_project_creator ?? me.is_system_admin)`;
  - `AppHeader.tsx:109-111` 管理后台菜单**保持 is_system_admin**;移动端 `MobileTabBar.tsx:47-51` 管理四 tab 同吃 is_system_admin,**保持不动**(点名防误改);
- 组长视角无 org_role 概念:项目列表可见性、成员抽屉、能力闸门全走现有 `my_roles`(组长自建的项目自带 admin_user_id → admin),零额外前端改动。

### 2.5 语义边界

- **「最后一个 admin」不变量无交互**:幸存 tuple 投影(`projects.py:632-667`)只数项目直接 admin tuple;组长自建项目自带 admin_user_id,不触发边界;
- **stealth 无泄露面**:建项目入口无 visibility 字段(`ProjectCreateIn` 只有 code/name/description/organization_id/minio_bucket/admin_user_id/initial_grants),stealth 项目只能脚本/DB 造,模板与 flag 均不触及;
- `USER_DIRECT_RELATIONS`(`permissions.py:43-61`)补 `("organization", "project_creator")`——UI 只写组主体,此为防御性兜底(未来若放开直接给 user);该函数对未部署 relation 有 continue 容错(:402-403),model 未 push 也不炸;
- 组 flag 撤销后:成员 /me 即失 is_project_creator(下次请求),其**已建项目不受影响**(admin 是项目级行为)。

### 2.6 测试

- model test:project_creator 组员 check ✓ / 非组员 ✗ / 组员移出组后 ✗;
- 组 CRUD:flag 置位/清除 → tuple 写/删(重复清除幂等);组删除后 tuple 不残留;
- 守门:组员 POST /projects 201(admin_user_id=自己,bootstrap+initial_grants 正常);非组员非 admin 403;org admin 201;
- 弱门:零项目组员 GET /users、GET /groups、GET /admin/grant-templates 200;POST /admin/grant-templates 仍 403;
- /me:组员 is_project_creator=true;移出组后 false;
- 禁用闭环:组员被 disable 后 org tuple 经 USER_DIRECT_RELATIONS 清理(直接 user 主体场景)。

---

## 3. 批次三:默认模板后端直通 + 刷新默认权限 + 新建弹窗 UI

### 3.1 create_project 合并默认模板

**语义(用户例定稿)**:建项目最终授权 = 「payload 的 initial_grants(手选模板预填 + 手动添加行)」∪「当前默认模板 items」,**按 (kind,id) 合并、角色取并集、天然幂等**——
- 选中模板 A(组A 上传+下载)+ 默认 C(用户X 管理+上传+下载)→ 组A 上传下载 + 用户X 管理上传下载;
- 选中默认模板自身(C)→ 结果 = C,不重复;
- 选中 A + 默认 B(组A 管理)→ 组A 管理+上传+下载(同主体角色并集)。

**实现**:payload 的 initial_grants 既有校验与直通写**全部不动**(重复 400、超 50 条 422、stale 主体 400——这些只针对用户显式提交的内容);校验通过后、直通写之前,**读当前 org 的 `is_default` 模板 items 合并进 initial_grants 再统一写**。默认模板无 / items 空 = 现行为完全不变。

- **默认模板条目 stale(user 已删/停用、group 已删)→ 跳过该条 + log.warning,不阻塞创建**——一个过期默认模板不能卡死所有建项目;模板保存时校验过存在性,staleness 是保存后删除产生的;
- **50 上限只拦用户 payload**:合并后最多 50+50=100 条,不拦(串行 FGA 写 ~100 次可接受;拦了会让「payload 满 50 + 有默认模板」的合法创建 422);
- audit:默认模板来源的写入记 `via: "default_template"`(手选/手添仍 `via: "initial_grants"`),溯源可分;幂等跳过分支不写 audit(现状);
- **共享 helper**:新增 `app/services/default_grants.py`:`apply_default_template_grants(db, permissions, audit, *, org_id, project_id, actor_user_id, ctx, already: set[tuple[kind, id, role]] | None) -> {applied, skipped_stale}`——create 侧(§3.1)与刷新侧(§3.2)同一实现,勿写两份。

**前端**(NewProjectModal):删除默认预选逻辑(:69-75 的 `defaultTemplate` / `effectiveTemplateId` 回退 / `effectiveRows` 默认模板预填),模板 Select 默认「不使用模板」;**显式选模板仍逐条预填初始权限区**(该联动保留)。

**原则点名**:project-grant-templates-plan 的「后端不感知模板、模板=纯前端预填」原则被本节打破——**仅默认模板例外**(它必须对 API/脚本直调建项目同样生效,且提交时取最新默认而非弹窗打开时的快照);非默认模板仍是纯前端预填、后端不感知。

### 3.2 管理页「刷新默认权限」(存量项目按需补)

- **UI**(`AdminGrantTemplatesPage.tsx`):头部按钮区(:84 新建模板旁)加「刷新默认权限」;**当前无默认模板 → disabled + tooltip「请先在模板中设为默认」**;点击弹 Modal,内嵌 antd `Transfer`(`showSearch`,dataSource = `useProjects()` 全量,搜索按项目名/编码;项目量小,不分页);确认 → 调 API → 结果弹层按项目展示 `{applied, skipped_stale}`;
- **API**:`POST /api/v1/admin/grant-templates/apply-default`,body `{project_ids: list[uuid](min 1, max 100)}`,`require_system_admin`(管理员批量操作,与页面门控一致)→ 逐项目调 §3.1 的共享 helper → 返回 `{results: [{project_id, applied, skipped_stale}], total_applied, total_skipped}`;
- **语义写死:叠加不删(union-only)**——只补缺失的 (subject, role) tuple,已存在幂等跳过(`is_already_exists_error`);**不移除任何现有授权**。模板改版删掉的角色不会被刷新「收回」,需收回时在成员抽屉手动撤——FGA tuple 无来源标记,无法区分「模板授的」与「项目 admin 手动授的」,对齐式收回必误伤,不做(§6 留口);
- **幂等**:重复点击安全——第二次全命中 already_exists,applied=0;
- 边界:project_ids `dict.fromkeys()` 去重;项目不存在/非本 org → 400 指明第几个;无默认模板 → 400(UI 已 disabled,API 兜底);audit 逐条写 `project_member_added`(via: "default_template",actor=点击的管理员,target_project_id 各项目)——下游按 event_type 过滤的查询现成可用,无需新 event_type;
- 测试:全 cycle(选中 2 项目 → tuple 就位)/幂等二跑 applied=0/默认模板含 stale 条目 → skipped_stale 计数且其余照常/非 admin 403/空选 422/>100 拒 422/无默认 400/audit via 标记正确。

### 3.3 新建项目弹窗 UI 重排(NewProjectModal)

- **PC(`Grid.useBreakpoint` lg+)**:Modal `width≈1040`(antd 默认 520 的两倍),内部两栏布局——**左栏:现有字段**(项目名称/编码/描述/项目管理员/MinIO bucket);**右栏:「权限模板」Select + 「初始权限(可选)」**(两块都是可选项,聚到一起,需求原话);
- **弹窗限高**:Modal body `maxHeight≈70vh + overflowY: auto`(antd Modal `styles.body`);**初始权限的主体行列表自身再加内层 maxHeight 滚动**(它是主要膨胀源,行多时只滚行区、表单不动);
- 表单字段顺序重排:模板 Select 从现在的顶部(:183)移除,并入右栏初始权限区(:260 现位置)上方,两块合成一个「权限(可选)」分组;
- **移动端**(<lg):单栏堆叠,模板+初始权限保持在表单**尾部**(可选项靠后);
- `scrollToFirstError` 在滚动容器内可用,校验体验不受影响;
- 左栏「项目管理员」的 UserPicker 数据源 `useDirectoryUsers` 已在 §2.3 放宽,组长可用。

### 3.4 测试

- create 合并:用户三例逐条断言(选中A+默认C / 选中默认C自身 / 选中A+默认B)/ 默认模板含 stale 条目 → 项目创建成功且该条跳过 / via 标记区分 / payload 50 条 + 默认模板存在 → 不 422 / 无默认模板 = 现行为回归;
- 前端 `pnpm build` + 手工冒烟:PC 双栏、弹窗超高出滚动条、移动端单栏、模板显式选择仍预填、默认不预选。

---

## 4. 实施顺序与验收清单

### 顺序(3 批独立可上线;§2 与 §3 都动 NewProjectModal,量小,建议同批实施或 §3 rebase 于 §2 之后)

| 批次 | 内容 | 部署注意 |
|---|---|---|
| PR-1 | §1 批量前缀(纯代码,无 migration) | 后端代码 rsync 后**必须重启 ms-api 才生效**;**新前端发 `labels_mode=merge` 而旧后端会静默吞掉该字段**(pydantic 默认忽略额外字段)按 replace 执行,跨页打标清空存量标签——发布顺序遵守「两段式发布」(server2 拆 rsync 或排维护横幅;hh2 天然两段式,先后端 `--restart` 再前端分片通道) |
| PR-2 | §2 组级建项目权限 | **push FGA model 先于放代码**;重启 ms-api/ms-worker;无 alembic |
| PR-3 | §3 默认模板直通+刷新+弹窗UI(纯代码,无 migration) | **前后端同批**(新前端去默认预选 + 旧后端无合并 → 默认模板短暂不生效的窗口;同批部署消除。非数据事故,授权少给不越权) |

每批独立走:ruff + mypy(strict)+ 容器内 pytest + `pnpm build/lint` + server2 dev 部署 tester 验证 + `scripts/changelog.md` 记账(AGENTS.md 约定)。

### 用户可见验收清单

1. 文件浏览器勾选多个文件(可翻页续选)→ 批量加/去前缀 → 列表与下载文件名统一变化,toast 报告成功/跳过数。
2. 管理后台编辑用户组勾「允许组成员新建项目」→ 该组成员登录:项目页出现「新建项目」入口,能建成功(默认自己是项目管理员,可顺带选模板/初始权限);**无管理后台入口**(is_system_admin 未变)。
3. 新建项目**不选模板** → 创建完成后成员抽屉里出现默认模板对应的授权(审计事件带 default_template 来源);选模板 A 且默认为 C → A∪C 都在;选中默认模板自身 → 不重复。
4. 管理后台「权限模板」页点「刷新默认权限」→ 穿梭框勾选两个存量项目 → 确认 → 两项目成员抽屉多出默认模板授权;**再次刷新 applied=0**;项目原有的手动授权不受影响。
5. 新建弹窗:PC 双栏(权限模板+初始权限在右)、权限行很多时弹窗自身出滚动条;移动端单栏、权限块在尾部。
6. 艺人账号(项目级授权)行为回归不变;系统 admin 一切能力不变。

---

## 5. 风险与已知取舍

| 风险/取舍 | 说明 |
|---|---|
| 后端感知默认模板 | 打破「模板=纯前端预填」原则,仅默认模板例外(§3.1 点名);模板事后修改仍不影响任何已建项目——刷新是显式管理员动作 |
| 刷新只增不减 | FGA tuple 无来源标记,对齐式收回必误伤手动授权,不做(§3.2);需收回走成员抽屉 |
| 默认模板 stale 条目静默跳过 | 创建/刷新两侧一致(不阻塞主流程);模板编辑页已有 missing 标记引导清理,双通道 |
| 批量前缀无 undo | 逆操作可抵消 add;remove 前建议用户先小范围试(预览 UI 缓解) |
| FGA model push 顺序 | PR-2 先 push 再放代码;回滚纪律:回代码不回 model 无害(多 relation 不伤旧代码),回 model 不回代码会炸(check unknown relation)——**回滚时 model 与代码同批回** |
| is_project_creator 的 FGA check 频次 | /me 与守门各请求各一次 check,与 is_system_admin/org admin 同量级,不做跨请求缓存 |
| 新旧共存窗口 | PR-1 的 labels_mode 窗口按两段式发布消除(§4);PR-3 前后端同批(§4);PR-2 的 model 先行无害 |
| 组 flag 的权限面 | 开关 = 组内**全部成员**可建项目(建后自动 admin);文案明示,仅系统 admin 可操作 |

---

## 6. 明确不做 / 留口

- **目录导入(原需求一)**:整体移出本方案,用户自行调研后另立(原 16 轮盲审定稿的 §1 内容在 git 历史 `0992de3` 留档,含 uppy meta.relativePath、ensure_folder_chain 事务顺序、NFC 归一化等,另立方案时优先复用其结论)。
- **org 级 operator/leader 派生**(原三角色落法):放弃;若未来要「真·存量+未来全项目自动覆盖」再启用,原 model 改动块与 org_role 管线设计见 `0992de3` 版本 §3。
- **AdminOrgRolesPage / org_role 字段与徽章 / MyPermissionsPage org 适配**:随上项一并不做。
- **存量项目自动回填**:不做,§3.2 刷新按钮按需补(用户决策:只管未来项目)。
- **刷新的对齐式收回**:不做(§3.2);若未来 tuple 加来源标记(condition 或独立 relation)再议。
- **直接给单个 user 授「新建项目」**:relation 定义已留 `[user, group#member]`,UI 本期只做组开关;出现需求再在管理页加个体授予入口。
- **zip/打包批量下载**:批量下载仍是前端逐条 presigned 循环(现状),跨页保留选中放大规模后仅加 >20 确认提示;打包下载端点待真需求再立。
- **文件夹改名/前缀**:维持 ROADMAP「低优先级」结论。

---

## 7. 与已落地 project-grant-templates 方案的关系(原「协调节」改为落地基线)

- **基线**:对方三批已全部合入(`681af12`)并部署 dev/prod——initial_grants 前置校验+直通写(`projects.py:98-138/:167-194`)、权限模板 CRUD(`admin.py:317-500`,含 partial unique default)、组管理放开、幸存 tuple 投影(`projects.py:632-667`)、`subject_names.py` 组名解析、members 主体存在性校验、`RoleChipGroup` 公共组件、`is_not_exists_error` helper。
- 本方案修改其**两处行为**:①默认模板从「前端预选」改为「后端直通」(§3.1);②`GET /admin/grant-templates` 读端点放宽到 project creator(§2.3)。其余(initial_grants 语义、模板 CRUD、模板预填联动)不动。
- 原协调表中「store.fga.yaml 双 push」「create_project/NewProjectModal 冲突由后合入者解」「resolve_subject_names 双路径」等条目已随对方落地自然消解——本方案即「后合入者」,直接以 `d4bf80e` 基线实施。
- NewProjectModal 的模板 Select + 初始权限区(每主体一行独立角色)结构保留,仅去默认预选(§3.1)与重排布局(§3.3)。
