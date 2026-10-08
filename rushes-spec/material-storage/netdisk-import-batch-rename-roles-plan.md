# 批量文件名前缀 + 组级「新建项目」权限 + 默认模板直通 · 实施方案

> Status: **范围重订版(2026-10-10),待盲审**。旧版(目录导入+三角色)在 git `0992de3` 留档。
> 范围:material-storage(后端 `api/` + 前端 `web/`;批次二含 FGA model 加一个 relation)
> 基线:`d4bf80e`(= liuqi `681af12`,initial_grants/权限模板已上线 dev+prod);**全文行号以此为准**

---

## 0. 范围决策

- **网盘目录导入:移出**,用户自行调研后另立方案。
- **批量文件名前缀:保留**(§1)。
- **三角色不做 FGA org 级派生**,改为:艺人 = 现有项目级授权;运营/组长的项目可见性 = 把组配进**默认模板**;组长「可新建项目」= 用户组开关(§2)+ 默认模板后端直通(§3.1)。
  - 理由:per-project tuple 机制上线后,`my_roles`/可见性/能力闸门全部现成零改动;org 派生需改 model `can_*` + `org_role` 字段贯穿 + 独立管理页,整条管线不值得。
  - 代价:存量项目不自动覆盖——按用户决策**只管未来项目**,存量由 §3.2 刷新按钮按需补,不做自动回填。

---

## 1. 批次一:批量文件名前缀(加/去前缀)

### 1.1 API:`POST /api/v1/assets/batch-prefix`(assets.py 新端点)

```python
class AssetBatchPrefixIn(BaseModel):
    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=1000)
    action: Literal["add", "remove"]
    prefix: str = Field(..., min_length=1, max_length=128)
    # 禁 "/"、禁控制字符、strip 后非空;服务端 NFC 归一,归一后复检 ≤128
```

语义:

- `add`:`filename = prefix + filename`;已带该前缀跳过(already_prefixed);结果 >512 跳过(too_long);
- `remove`:恰好以 prefix 开头(大小写敏感)剥离一次,否则跳过(no_match);剥离后空串跳过(empty_result);
- **前缀比较两侧 NFC 归一**(存量 filename 多为 macOS 拖入的 NFD 原样落库,只归一输入侧会不命中):比较用 `NFC(filename).startswith(prefix_nfc)`;remove 余量 = `NFC(filename)[len(prefix_nfc):]` 落库(码点数不同,不能按原串长度切);add 结果串按 NFC 落库,库内 filename 逐步收敛 NFC;
- 返回 `{renamed, skipped, skipped_reasons: {too_long, no_match, already_prefixed, empty_result, deleted}}`(键固定 ASCII,前端中文映射;deleted = 已删/不存在,不细分)——尽力而为 + 结果报告。

**权限**:按 folder_id 分组逐组 `can_upload` check(对齐 `update_asset_meta`,`assets.py:537-542`;敏感夹按 sensitive_folder);系统 admin 直通;任一组无权限 → 403 整批不执行,文案笼统不带 folder 名(反探测约定,`assets.py:278`)。敏感夹受邀 downloader 亦有批量改名能力(can_upload = can_download,store.fga.yaml:104),与该夹打标同语义,接受。

**实现**(单事务):

1. `asset_ids` 去重(`dict.fromkeys`,防重复 id 计入 deleted);`SELECT id, filename, folder_id, is_sensitive JOIN folders WHERE id IN (...) AND deleted_at IS NULL`;
2. Python 端按语义算新名(两侧 NFC),分「应改 / 各原因跳过」;
3. Core 语句**逐 id UPDATE**(`WHERE id = :id AND deleted_at IS NULL`):不用 ORM flush(并发 hard purge 抛 StaleDataError,`assets.py:561-565` 先例);不用单条 `IN ... RETURNING`(add 各 id 新名不同、executemany 不累积 RETURNING);add 谓词加 `NOT starts_with(normalize(filename,'NFC'), :prefix)` 二次防线(防并发双提交叠双前缀;PG normalize 与 Python 同口径;用 `starts_with` 不用 LIKE——`_`/`%` 通配符误拦,转义先例 `_escape_like` `assets.py:902-904`);remove 侧不加字节级谓词(与 NFC 口径不对称,存量 NFD 会静默不命中);
4. **对账**:rowcount=0 的 id 补查归因(软删 → deleted;NFC 前缀命中 → already_prefixed;兜底原始字节命中 → already_prefixed);SELECT 查不到的计入 deleted;保证 `renamed + skipped` 与提交数严格对账。

403 写 `access_denied` audit(先例 `assets.py:79-87`)。**MinIO key 不动**(下载文件名由 filename 动态生成 Content-Disposition,纯 DB 改名)。

**audit**:聚合事件 `asset.batch_renamed`(action / prefix / renamed / skipped / 采样前 50 条 `{id, old, new}`);`labels.ts` 补映射,键与 event_type 逐字相等——顺带修现存错位:**labels.ts 补点号键 `asset.tag_updated`**(后端 `assets.py:569` 不动,避免历史行跨值)。

### 1.2 前端(`ProjectDetailPage.tsx`;行号较旧版 +4,`canUploadProject` :58-60 例外)

- **跨页保留选中**:删两处翻页清空(compact :568、桌面 :924);Table `rowSelection`(:881-884)加 `preserveSelectedRowKeys: true`,compact 卡片(:403、:505)同规则;**切 folder 仍清空**(:106);antd 内置表头全选在 preserve 下天然只动当前页,**勿改**;自绘全选(:814、:505)改为当前页 id 并/差集;
- **三个既有批量操作切 `selectedIds` 全量口径**(现 `selectedAssets` 只含当前页 :115-118,跨页后「显示 N 实际只动当前页」):下载(:160)/删除(:164)遍历 id;未加载 id 无 Asset 对象——下载占位名 `asset_<id前8位>.<content_type 推断扩展名>`(回落 `.bin`),403 无对象计入「需申请」聚合计数,失败 toast 按 id 聚合;删除的空尾页回退判定(:172-174)同步改写;
- **BulkTagModal 跨页合并后端化**:现状前端用已加载行合并(:955-967)而 `assets.py:555-556` 是整条替换,跨页未加载 id 的旧标签会被清掉。`AssetMetaUpdateIn` 加 `labels_mode: Literal["merge","replace"] = "replace"`(merge = DB 现值在前取并集,顺序写死);批量路径传 merge;`types.ts`/`hooks.ts` 同步;BulkTagModal 清单标注「已选 N 个(清单为当前页已加载项)」;`AssetSummaryPanel`(:938)仅**桌面批量态**加注「(当前页)」——该组件三处复用(compact 单资产详情 :672、compact 文件夹管理 :686),无条件加注会泄漏到另两态;
- 批量栏加「批量前缀」按钮(桌面+compact,compact 栏在 :578-619):disabled 门控随打标 = `folder.my_can_upload`(:835-837 / :600);Modal = action 单选 + prefix 输入 + **预览**(当前页选中前 5 条改名前后对照,注明「预览仅当前页,共已选 N」)+ 确认;提交按 selectedIds 全量,>1000 前端按批顺序调用(任一批失败即中止),完成后刷新并清空;批量下载跨页 >20 加确认。

### 1.3 边界与取舍

| 情况 | 处理 |
|---|---|
| 去前缀后与现有文件同名 | 允许,不拦截 |
| 误操作恢复 | 无 undo;add 逆操作 = remove;audit 有采样 |
| 盲搜/标签索引 | GIN trgm 由 PG 自动维护,即刻生效 |
| 文件夹前缀 | 不做(minio_prefix 子树级联,ROADMAP 低优先级) |
| 回收站文件 | deleted_at 过滤,天然跳过 |

### 1.4 测试

新 `tests/test_batch_prefix.py`(容器内):add 全成功 / already_prefixed / remove 部分跳过 / **NFD 存量名 + NFC 前缀两侧归一命中** / 无权限 403 / >1000 拒 422 / 空结果与超长跳过 / 软删跳过(含 UPDATE 间并发软删)/ 敏感夹按 sensitive_folder check / `labels_mode=merge` 生效且默认 replace 不变。
前端冒烟:跨页全选只动当前页;翻页后批量操作按全量生效;跨页打标不清旧标签。

---

## 2. 批次二:组级「新建项目」权限

### 2.1 FGA model(`store.fga.yaml`)

```fga
type organization
  relations
    define admin: [user, group#member]
    define member: [user, group#member, department#member]
    define project_creator: [user, group#member]   # UI 只写组主体,user 留口
```

- 加新 relation 零风险(CLAUDE.md 约定:不改名、不加 condition);组员判定由 check 自动展开 `group#member`,无需应用层逐组查;
- **部署:先 push model 再放代码**(代码 check 未部署 relation 会炸;反向无害);`openfga_write_model.sh` 在 `api/scripts/` 下,默认 ssh 直连 server2——hh2 内网须在目标机本地跑(跳板反向隧道);push 后重启 ms-api/ms-worker;
- yaml tuples/tests 段补 project_creator 用例(`fga model test` 全绿)。

### 2.2 组管理入口(directory.py + AdminGroupsPage)

- `GroupCreateIn`(:312)/ `GroupUpdateIn`(:317)加 `can_create_project: bool = False`;create(:372)/update(:403)按 flag 写/删 `organization#project_creator` 的 `group:<gid>#member` tuple——**tuple 读写封装为 PermissionsService 小方法**(add/remove_org_relation),路由不摸 `_client`;删 stale 吞 `is_not_exists_error`(`permissions.py:92-102`);**组删除时顺手删该 tuple**;
- `AdminGroupsPage` 的 `GroupFormModal`(:208-221)加 Switch「允许组成员新建项目」+ 说明文案(建后自动成为该项目管理员);列表加徽标;
- **flag 读回**:组**列表**接口(directory.py 无组详情路由,编辑弹窗数据来自列表行 `AdminGroupsPage.tsx:171`)追加一次 `read(object=organization:<tenant_key>)`、过滤 project_creator tuples,`DirectoryGroupOut` 加 `can_create_project` 字段回显(列表徽标与编辑回显的数据源;组管理页仅系统 admin 访问,一次 FGA read 开销可忽略);
- audit:`group_created` / `group_updated` details 增 `can_create_project`,不新增 event_type;
- 开关仅系统 admin 可操作(组 CRUD 本就 require_system_admin),提权面不扩大。

### 2.3 守门与弱门放宽

- `deps.py` 新增 `require_project_creator` / `get_is_project_creator`——**语义统一为 `is_org_admin ∨ check(project_creator)`**(系统 admin 恒可建项目,不受组 flag 影响;check 写法仿 `is_org_admin` `permissions.py:444-451`;default org 缺失行为对齐 `deps.py:205-206` / `:229-230`);
- `create_project`(`projects.py:56`)守门换 `require_project_creator`;`admin_user_id` 必填与 initial_grants 校验(:98-138)/直通写(:167-194)**不动**——组长自建默认 admin_user_id = me.id(NewProjectModal :53)、bucket 默认 ms-dev;
- **弱门放宽(必改,否则零项目的新组长填不了表单)**:
  - `GET /users`(`users.py:40`)、`GET /groups`(`groups.py:37`)的 require_admin(系统 admin 或任一项目 can_admin)对零项目组长 403 → 并入 is_project_creator(SubjectPicker/UserPicker 候选来源);
  - `GET /admin/grant-templates`(`admin.py:317`)读端点同样放宽;**写端点 POST/PATCH/DELETE 保持 require_system_admin**。

### 2.4 /me 与前端闸门

- `/me`(`auth.py:120-158`)加 `is_project_creator: bool`,**与守门同口径**(is_org_admin ∨ project_creator);查询按 `auth.py:130-141` 现状惯例 try/except 回 False(FGA 抖动 / model 未 push 不致 /me 500);`types.ts` 的 Me 同步;
- 闸门 `me.is_project_creator ?? me.is_system_admin`——新后端字段已含系统 admin,`??` 实际只在旧后端(字段 undefined)时回落:`ProjectsPage.tsx:62-79` 入口、`NewProjectModal.tsx:156` 守卫及其 :156-168 的禁用提示文案(现「只有系统管理员可以创建项目…grant_org_admin 指定」须同步改写);`AppHeader.tsx:109-111` 管理菜单与 `MobileTabBar.tsx:47-51` 管理 tab **保持 is_system_admin 不动**;
- 组长视角无 org_role 概念:可见性/闸门全走现有 `my_roles`(自建项目自带 admin_user_id → admin),零额外前端改动。

### 2.5 边界

- 「最后一个 admin」不变量(幸存 tuple 投影,`projects.py:632-667`)无交互:组长自建自带 admin_user_id;
- 建项目入口无 visibility 字段(`ProjectCreateIn`),无 stealth 泄露面;
- `USER_DIRECT_RELATIONS`(`permissions.py:43-61`)补 `("organization", "project_creator")`——防御性(UI 只写组主体;该函数对未部署 relation 有 continue 容错);
- flag 撤销后组员即失建项目能力(系统 admin 不受影响——守门口径含 org admin),其已建项目不受影响。

### 2.6 测试

model test(组员 ✓ / 非组员 ✗ / 移出组 ✗);组 CRUD flag → tuple 写删(重复清除幂等)/ 组删除后不残留;守门:组员 POST /projects 201(admin_user_id=自己,bootstrap+initial_grants 正常)/ 非组员 403 / org admin 201;弱门:零项目组员 GET /users、/groups、grant-templates 读 200、写 403;/me 字段同守门口径(组员 true、系统 admin true、非组员 false);disable 闭环。

---

## 3. 批次三:默认模板后端直通 + 刷新默认权限 + 弹窗 UI

### 3.1 create_project 合并默认模板

**语义**:最终授权 = payload 的 initial_grants(手选模板预填 + 手动行)∪ 当前默认模板 items,**按 (kind,id) 合并、角色取并集、幂等**——
选中 A(组A 上传+下载)+ 默认 C(用户X 管理+上传+下载)→ 两者都在;选中默认模板自身 → 结果 = C 不重复;选中 A + 默认 B(组A 管理)→ 组A 管理+上传+下载。

**实现**:payload 校验(重复 400 / 超 50 条 422 / stale 主体 400)与直通写**全部不动**;直通写完成后追加调用共享 helper 补默认模板授权(helper 自带 read 差集去重,见下)。无默认模板 / items 空 = 现行为不变。

- 默认模板 stale 条目(user 已删/停用、group 已删)**跳过 + log.warning,不阻塞**——过期默认模板不能卡死建项目;
- **50 上限只拦 payload**(helper 补写不占上限,防合法创建被 422);
- audit:默认模板来源记 `via: "default_template"`(手选仍 initial_grants),幂等跳过不写;
- **共享 helper** `app/services/default_grants.py: apply_default_template_grants(...)`:读默认模板 → 主体存在性过滤(stale 跳过+log)→ `read` 项目现有 tuples **求差集** → **批量写**(OpenFGA 单次 write ≤100 tuple 分块;分块写先例 `revoke_user_completely` `permissions.py:418-422`(BATCH=50)、多 tuple 单写先例 `bootstrap_project` :189-204——刷新场景若逐条写会是万次级 HTTP 调用)→ 逐条 audit。create 侧:直通写完成后调用(read 差集天然排除 payload 已写条目);刷新侧:直接调用。重复调用差集为空、零写入,幂等。本节与 §3.2 同一实现,勿写两份。

**前端**(NewProjectModal):删默认预选(:69-75 的 `defaultTemplate` / `effectiveTemplateId` 回退 / `effectiveRows` 预填),Select 默认「不使用模板」;显式选模板仍逐条预填初始权限区;有默认模板时提交区明示「创建后将自动合并默认模板的授权」(现有「仅预填,不锁定」类文案同步核改)——防「行内显式删掉的角色被默认模板 union 顶回」无感知。

**原则点名**:打破「后端不感知模板」原则,**仅默认模板例外**(须对 API/脚本直调生效、提交时取最新默认);非默认模板仍纯前端预填。

### 3.2 管理页「刷新默认权限」(存量项目按需补)

- **UI**(`AdminGrantTemplatesPage`):头部(:84 旁)加按钮;无默认模板 → disabled + tooltip;点击 Modal 内嵌 antd `Transfer`(showSearch,数据源 = 项目列表**循环分页拉全量**——`GET /projects` 默认 limit=100 会静默截断(`projects.py:280`),且系统 admin 分支每项目一次 FGA 回路填 admins(`projects.py:231-236`),项目数百个时打开变慢、现网量级可接受;按项目名/编码搜);**勾选上限 100(= API 单批上限,超限禁止再勾并提示分批操作)**;确认调 API,结果按项目报 `{applied, skipped_stale}`;
- **API**:`POST /api/v1/admin/grant-templates/apply-default`,body `{project_ids: list[uuid](1..100)}`,`require_system_admin` → 逐项目调 §3.1 helper → `{results: [{project_id, applied, skipped_stale}], total_applied, total_skipped}`;
- **语义写死:叠加不删**——helper read 差集后批量写(见 §3.1),只补缺失 (subject, role),已存在天然跳过;**不移除任何授权**(FGA tuple 无来源标记,对齐式收回必误伤手动授权,不做);模板改版删掉的角色需手动在成员抽屉撤;
- 边界:project_ids 去重;项目不存在/跨 org → 400 指明;无默认模板 → 400(UI 已 disabled,API 兜底);audit 逐条 `project_member_added`(via: "default_template");
- 测试:全 cycle / 幂等二跑 applied=0 / stale 跳过计数 / 非 admin 403 / 空选 422 / >100 拒 / audit via 标记。

### 3.3 弹窗重排(NewProjectModal)

- **PC**(`Grid.useBreakpoint` lg+):`width≈1040`,双栏——左:名称/编码/描述/管理员/bucket;右:模板 Select + 初始权限(模板从顶部 :183 移到初始权限区 :260 上方,合成「权限(可选)」组);
- **限高**:Modal body `maxHeight≈70vh + overflowY`;初始权限主体行列表内层 maxHeight 滚动(主要膨胀源);
- 移动端单栏,权限块在表单尾部;`scrollToFirstError` 在滚动容器可用;
- **名称解析数据源**:UserPicker/GroupPicker 本就走已放宽的 `GET /api/v1/users`、`/groups`(UserPicker.tsx:62),搜索不受影响;但初始权限行的 nameById 现用 `useDirectoryUsers`(NewProjectModal :62,打 `GET /admin/directory/users`,该端点 require_system_admin **未放宽**)——**改走已放宽的 `GET /api/v1/users`**(SubjectPicker 只回传 id,SubjectPicker.tsx:49-52,行名全靠 nameById;不改则组长侧手选用户行退化为短 id 兜底)。

### 3.4 测试

create 合并:用户三例逐条断言 / stale 条目跳过且创建成功 / via 区分 / payload 50 条 + 有默认模板不 422 / 无默认 = 现行为回归。
前端 build + 冒烟:PC 双栏 / 超高出滚动条 / 移动端单栏 / 显式选模板预填 / 默认不预选。

---

## 4. 实施顺序与验收

| 批次 | 内容 | 部署注意 |
|---|---|---|
| PR-1 | §1 批量前缀 | 无 migration;rsync 后须重启 ms-api;新前端发 `labels_mode` 被旧后端静默吞 → 按 replace 清标签,**两段式发布**(server2 拆 rsync 或维护横幅;hh2 先后端 `--restart` 再前端通道) |
| PR-2 | §2 组级建项目 | 无 alembic;**先 push FGA model 再放代码**;重启 ms-api/ms-worker |
| PR-3 | §3 直通+刷新+弹窗 | 无 migration;**前后端同批**(否则默认模板短暂不生效,少给非越权) |

§2 与 §3 都动 NewProjectModal,建议同批实施或 §3 rebase 于 §2 后。每批:ruff + mypy(strict)+ 容器 pytest + `pnpm build/lint` + server2 dev 验证 + `scripts/changelog.md` 记账。

**验收(用户可见)**:

1. 多选(可翻页续选)批量加/去前缀 → 列表与下载文件名统一变化,toast 报告成功/跳过数;
2. 组勾「允许组成员新建项目」→ 组员项目页出现新建入口、建成功(默认自己是管理员,可选模板/初始权限),**无管理后台入口**;
3. 建项目不选模板 → 默认模板授权就位;选 A + 默认 C → A∪C;选默认模板自身 → 不重复;
4. 「刷新默认权限」→ Transfer 选存量项目 → 授权补上;再刷 applied=0;项目原有手动授权不受影响;
5. 弹窗:PC 双栏、权限行多时弹窗自身滚动;移动端单栏、权限块在尾;
6. 艺人(项目级授权)与系统 admin 行为回归不变。

---

## 5. 主要取舍

| 取舍 | 说明 |
|---|---|
| 后端感知默认模板 | 仅默认模板例外(须对 API 直调生效、取提交时最新);模板事后修改仍不影响已建项目,刷新是显式管理员动作 |
| 刷新只增不减 | tuple 无来源标记;收回走成员抽屉 |
| 默认模板 stale 静默跳过 | 创建/刷新一致;模板编辑页已有 missing 标记引导清理 |
| 放弃 org 派生 | 见 §0;存量不自动覆盖,刷新按需补 |
| 批量前缀无 undo | add 逆操作 = remove,预览缓解 |
| model 回滚纪律 | 回代码不回 model 无害;回 model 不回代码会炸(check unknown relation)——**同批回** |

---

## 6. 不做 / 留口

- **目录导入**:移出本方案;另立时优先复用 `0992de3` 旧版结论(uppy meta.relativePath、ensure_folder_chain 事务顺序、NFC 归一化)。
- **org 级 operator/leader 派生及 AdminOrgRolesPage/org_role 全套**:不做(旧版留档同上)。
- **存量自动回填**:不做(只管未来 + 手动刷新)。
- **刷新的对齐式收回**:不做(无来源标记)。
- **直接给单个 user 授「新建项目」**:relation 已留 `[user]`,UI 本期只做组开关。
- **zip/打包批量下载**:仍逐条 presigned 循环,>20 确认;打包端点待真需求。
- **文件夹改名/前缀**:维持 ROADMAP 低优先级。
