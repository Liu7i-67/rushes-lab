# 设置页 MCP 收拢二级页 + 「默认收拢全部文件夹」配置(Web + App + 后端)

- 日期:2026-11-19
- 分支:`feat/settings-mcp-collapse`(基于 liuqi @ 0b19e86)
- worktree:`E:\qbb\github_not_me\rushes-lab-settings-mcp-collapse`
- 需求来源(用户原话):
  1. 将PC端设置界面的 MCP相关内容收拢到一个全新的二级页面,在设置界面仅展示入口即可
  2. 在PC端设置界面新增一个配置项,【默认收拢全部文件夹】,用户如果激活了这个开关,则在进入项目时不再默认展开所有的文件夹
  3. 将MCP相关内容和本次的配置项界面同步新增到APP端,【默认收拢全部文件夹】同样作用于APP端

## 1. 背景与目标

Web 端「设置」页(`/settings`)当前唯一内容就是 MCP PAT 令牌管理(`SettingsPage.tsx` 27 行,全部渲染 `TokensSection`)。目标:

1. 把 MCP 令牌管理收拢到独立二级页 `/settings/mcp`,设置页改为「入口面板 + 偏好配置」形态;
2. 新增用户级配置【默认收拢全部文件夹】,**服务端存储、Web/App 双端同步读写**;
3. App 端新建设置页承载同样的配置项与 MCP 令牌管理入口,文件夹页同样吃该配置。

可行性红线评估:可行,成本中等。用户已拍板「服务端同步」,故本周期包含后端新表+迁移+两枚端点。无不可行项。

## 2. 现状调研结论(复用资产地图)

### Web(`material-storage/web/src`,React 19 + antd v6 + react-router v7,路由 basename `/ms-static/web`)

- `pages/SettingsPage.tsx`(27 行):页头 + `<TokensSection />`,无区块抽象。
- MCP 四件套(自包含、无页面耦合,**全部原封不动复用**):
  - `components/settings/TokensSection.tsx`(264 行,列表 Table/吊销/`?include_revoked=1`/上限 5/风险文案)
  - `components/settings/CreateTokenModal.tsx`(133 行)
  - `components/settings/TokenCreatedModal.tsx`(136 行,一次性明文 + `buildMcpGuide` 端点说明)
  - `components/settings/token-status.ts`(31 行;⚠ `components/admin/mcp/AdminTokensTable.tsx:33` 以相对路径引用它,**不得移动/重命名**)
- 入口面板先例:`pages/AdminStatsPanelPage.tsx:45-114`(模块卡片数组 + 整卡 button + `navigate(m.to)`)——设置页改造照抄此模式。
- 路由:`App.tsx` 扁平 `<Routes>`;`/settings` 在 `App.tsx:108`(lazy import 行 43 附近)。二级页先例:`/admin/stats` → `/admin/usage` 整页跳转。
- 入口文案:`AppHeader.tsx:187` title「设置 / 访问令牌」;`UserMenu.tsx:101-102`、`MobileTabBar.tsx:49-50`。
- 文件夹树:`components/FolderTree.tsx`(372 行)
  - **默认展开唯一开关点 `:336`** `defaultExpandAll={tree.length < 30}`;`:337` `defaultExpanded={defaultExpanded}` = activeFolderId 祖先链(`:205-218` useMemo,**必须保留**,深链定位依赖它);
  - 展开为**非受控**,Tree 在 `treeData` 就绪后才挂载(`:293-328` 提前 return),`defaultExpandAll` 挂载时一次性求值;
  - 复用方 4 处:PC `ProjectDetailPage.tsx:1153`(Sider)、移动 Drawer `:1055`、`BatchMoveAssetsModal.tsx:118`、`MoveFolderModal.tsx:120`、`BaiduNewTaskModal.tsx:246`(选择模式同样吃 defaultExpandAll)。
- 本地持久化:localStorage 仅 `api/client.ts:9-16`(`ms_` 前缀 + try/catch);**无服务端用户偏好**(users 表无 preferences 列,routers 无偏好端点)。
- Web **无前端测试框架**(package.json 无 test script),验证 = `npm run lint` + `npm run build` + 人工用例。

### App(`material-storage/app`,Flutter,包名 ms_app)

- 设置现状:「我的」页(`features/me/me_page.dart`,偏好分组含「外观」行)→「外观」= 底部弹层 `features/me/settings_sheet.dart`(主题三段)。**不是页面**。
- 行/分组组件:`AppRow`(`widgets/app_row.dart:13`)、`MeGroup`(`me_sections.dart:23`)、`SectionCard`(`widgets/app_card.dart:63`)、`SectionLabel`;开关直接用 Material `SwitchListTile`(现有 5 处先例)。
- 持久化范式:`theme/theme_controller.dart`(ChangeNotifier 单例)+ `theme_store.dart`(path_provider 文件,可注入 read/write,全静默降级),`main.dart:62` 启动 load。**无 shared_preferences**。本周期偏好是服务端存储,App 端不需要新本地 store。
- 文件夹树:`features/folders/folders_page.dart`(300 行)
  - `:55` `final _collapsed = <String>{}` — **黑名单语义,默认全展开**;`_visibleRows` `:117-130` 按 `_collapsed` 下钻;`FolderRow` 受控(`folder_row.dart:26-40`,`:11` 注释「默认全展开」);无展开全部/收拢全部按钮;每次路由进入重建 State(默认行为每次重新生效);
  - **App 无祖先链展开场景**(无 folderId 深链,搜索跳素材页不经过树页)→ 不存在需豁免的定位展开路径;
  - 选择器 `move_folder_sheet.dart` 恒全展开(无展开状态)、`netdisk_tree_sheet.dart` 独立懒加载网盘树 — 均不在本配置作用域(见决策 D2)。
- API:`core/api/ms_api.dart`(MsApi, Dio,cookie 会话 PersistCookieJar;401 统一钩子);域类注册 `:208-227`(`late final xxx = XxxApi(this)`);薄域类先例 `notifications_api.dart`(45 行)。**App 端 PAT/MCP 零封装**。
- 后端 PAT 三端点已存在且 session-only(`api/app/routers/auth_tokens.py`:`POST/GET /api/v1/auth/tokens`、`DELETE /api/v1/auth/tokens/{id}`;`TokenCreateIn{name 1..128, expires_in_days 1..365 默认90}`、`TokenCreatedOut` 明文只回一次、每用户活跃上限 5、吊销幂等 204)→ App 现有 cookie 通道直接可用,**零后端改动**。
- 可复用:`CopyButton`、`EmptyState`、`ListSkeleton`、`Toast`、`AppTextField`、`showAppConfirm`、`PageHeader`、`PasswordField`。

## 3. 功能点明细(逐条可验收)

| # | 端 | 功能点 | 验收口径 |
|---|---|---|---|
| F1 | Web | `/settings` 改造 | 不再直接渲染令牌管理;结构 = 页头「设置」+「偏好」区块(【默认收拢全部文件夹】开关)+「MCP / AI 接入」区块(入口卡片「访问令牌(Personal Access Token)」→ navigate `/settings/mcp`);卡片样式照 AdminStatsPanelPage 模块卡片 |
| F2 | Web | 新二级页 `/settings/mcp` | 承载现有 TokensSection(创建/列表/吊销/include_revoked/一次性明文/MCP 使用说明)**功能零变化**;`components/settings/` 四件套不改逻辑不挪位 |
| F3 | Web | 【默认收拢全部文件夹】开关 | antd Switch,读写 `GET/PUT /api/v1/me/preferences`;未登录态不存在(页面本身在登录壳内);开关文案 + 一句说明;保存中 loading/失败 Toast 报错并回弹 |
| F4 | Web | 收拢生效范围 | FolderTree **所有使用处**生效:项目主树(PC Sider+移动 Drawer)+ 批量移动 + 移动文件夹 + 百度建任务 3 弹窗;`defaultExpandAll` 变为 `tree.length < 30 && !collapsed`;`:205-218`/`:337` 祖先链定位展开**保留不变**;prefs 未加载完成前 Tree 不挂载(沿用加载早退分支);请求失败按 false(现状)兜底 |
| F5 | Web | 生效时机 | 开关切换对**下一次挂载**生效(非受控树的既有语义):重进项目/重开弹窗后可见;切换本身即时持久化到服务端 |
| F6 | Web | 入口文案 | `AppHeader` title「设置 / 访问令牌」→「设置」;UserMenu/MobileTabBar 标签核对保持「设置」 |
| F7 | App | 设置页 | 「我的」页「偏好」分组新增「设置」行(AppRow,chevron)→ 新命名路由 `/settings`;设置页 =「偏好」分组(SwitchListTile【默认收拢全部文件夹】+ 说明文字)+「MCP / AI 接入」分组(AppRow「访问令牌」→ `/mcp-tokens`);**现有「外观」行与外观弹层原地保留不动** |
| F8 | App | MCP 令牌页 `/mcp-tokens` | 对齐 Web 能力:令牌列表(名称/前缀/创建/最后使用/过期/状态)、创建(名称+有效期,App 端给常用档位)、一次性明文展示+复制、吊销(showAppConfirm 确认)、显示已吊销/已过期开关、活跃上限 5 到顶禁用创建并提示、MCP 端点说明段(基于当前服务器地址 origin + `/mcp` 生成,可整段复制);空态用 EmptyState,加载用 ListSkeleton |
| F9 | App | 收拢生效 | FoldersPage 进入时并行取 folders + preferences;开关开启 → 建树后把**所有含子级的节点 id 预填 `_collapsed`**(默认全收拢,点箭头逐层展开);关闭 → 现状全展开;开关切换对下一次进入项目生效;`move_folder_sheet`/`netdisk_tree_sheet` 不受影响 |
| F10 | 后端 | user_prefs 表 + 两枚端点 | 见 §5/§6;session 鉴权;GET 返回含默认值全集;PUT 部分更新合并返回全集 |
| F11 | 后端 | 兼容性 | 无偏好行用户 GET 返回默认 false;不产生审计事件(UI 偏好,非管理操作);不影响现有 FGA/model |

## 4. 组件拆分方案(文件清单,单文件 ≤500 行硬上限)

### 后端 `material-storage/api`(相对 worktree)

| 文件 | 动作 | 预估 | 职责边界 |
|---|---|---|---|
| `app/routers/user_preferences.py` | 新建 | ~110 行 | GET/PUT `/api/v1/me/preferences`;DEFAULT_PREFS 常量;行级 upsert(SELECT FOR UPDATE → merge → upsert);session 鉴权复用既有 deps |
| `app/db/tables.py` | 追加 | ~12 行 | `user_prefs` 表定义(照既有 Table 风格) |
| `app/db/migrations/versions/0023_user_prefs.py` | 新建 | ~45 行 | 建表迁移;**先核对当前 head(现为 0022)再定 revision id** |
| `app/models/__init__.py` | 追加 | ~30 行 | `PreferenceUpdateIn(folder_tree_default_collapsed: bool | None)`、`PreferencesOut(folder_tree_default_collapsed: bool)` |
| 路由注册处(`app/main.py` 或既有注册文件) | 追加 | ~3 行 | include_router,照既有模式 |
| `tests/test_user_preferences.py` | 新建 | ~200 行 | 见 §9 测试功能点 |

⚠ 迁移只写不跑;若存在 schema 表数断言测试(如 test_db_schema),同步更新表清单。

### Web `material-storage/web/src`

| 文件 | 动作 | 预估 | 职责边界 |
|---|---|---|---|
| `api/prefs.ts` | 新建 | ~90 行 | 类型 `UserPrefs`/`PreferenceUpdate`;react-query hooks:`useUserPreferences()`(查询 key `['me','preferences']`)+ `useUpdateUserPreferences()`(PUT,乐观更新+失败回滚);**契约固定见 §6,web-B 按此 import** |
| `components/FolderTree.tsx` | 修改 | ~20 行 diff | `:336` 接入 prefs;prefs isLoading 并入早退分支;仅动默认展开,不动祖先链/拖拽/菜单/选择模式 |
| `pages/SettingsMcpPage.tsx` | 新建 | ~40 行 | 页头「MCP 访问令牌」+ `<TokensSection />` |
| `pages/SettingsPage.tsx` | 重写 | ~130 行 | 入口卡片面板 + 偏好 Switch 区块(照 AdminStatsPanelPage 模式);读 prefs.ts 契约 |
| `App.tsx` | 追加 | ~4 行 | lazy import SettingsMcpPage + `<Route path="/settings/mcp">`;本文件**只归 web-B 动** |
| `components/AppHeader.tsx` | 修改 | ~2 行 | title 文案;本文件只归 web-B 动 |

### App `material-storage/app/lib`

| 文件 | 动作 | 预估 | 职责边界 |
|---|---|---|---|
| `core/api/tokens_api.dart` | 新建 | ~80 行 | `TokensApi`:list({includeRevoked})/create(name, expiresInDays)/revoke(id);照 notifications_api 薄封装模式;`_api.err` 中文报错 |
| `models/pat_token.dart` | 新建 | ~110 行 | `PatToken`/`PatTokenCreated`/fromJson;字段与后端 `models/__init__.py:438-474` 逐一对齐(id 类型以实际为准) |
| `core/api/prefs_api.dart` | 新建 | ~60 行 | `PrefsApi`:getPrefs()/updatePrefs(folderTreeDefaultCollapsed);`models/user_prefs.dart`(~35 行)或同类内;**契约固定见 §6,app-B 的设置页/文件夹页按此调用** |
| `core/api/ms_api.dart` | 追加 | ~3 行 | 注册 `late final tokens = TokensApi(this);` + `late final prefs = PrefsApi(this);`;本文件**只归 app-A 动** |
| `features/settings/mcp_tokens_page.dart` | 新建 | ~280 行 | 令牌页主体(列表/状态/吊销/include_revoked/端点说明);超 350 行须把「创建+明文结果」拆出 |
| `features/settings/mcp_token_create_sheet.dart` | 新建(按需) | ~200 行 | 创建表单 sheet + 一次性明文结果(含复制/端点说明) |
| `features/settings/settings_page.dart` | 新建 | ~170 行 | App 设置页;**契约:导出 `SettingsPage`(无参构造),app-B 注册路由** |
| `app.dart` | 追加 | ~12 行 | 注册 `/settings` 与 `/mcp-tokens` 两 case;**本文件只归 app-B 动**(app-A 不得碰) |
| `features/me/me_sections.dart` | 修改 | ~15 行 | 偏好分组新增「设置」行;**只归 app-B 动** |
| `features/folders/folders_page.dart` | 修改 | ~35 行 diff | initState 并行取 prefs;建树后按开关预填 `_collapsed`;只归 app-B 动 |
| `features/folders/folder_row.dart` | 修改 | ~3 行 | `:11` 注释同步语义 |

依赖关系:web-B import `api/prefs.ts`(web-A 产出)、app-B import `settings_page.dart`(app-A 产出)——**按 §6 契约并行开发,不互相等待**,最终构建由 PM 统一验收兜底。app.dart/me_sections/ms_api.dart 等**共享文件的编辑权已唯一化**避免同文件并发写。

## 5. 数据库修改方案

- 新表 `user_prefs`:
  - `user_id` UUID,PK,FK → `users.id` ON DELETE CASCADE
  - `prefs` JSONB,NOT NULL,DEFAULT `'{}'::jsonb`
  - `updated_at` TIMESTAMPTZ,NOT NULL,DEFAULT now()(upsert 时刷新)
- 迁移:新 alembic revision(核对当前 head 后编号,现为 0022 → 新 0023),仅 upgrade 建表 + downgrade drop table;**迁移冒烟只允许对临时库执行,严禁对任何 live 库 downgrade**。
- 存量数据:无需迁移(全部用户隐式默认 false);首写时 upsert 建行。

## 6. 接口定义

### 后端新端点(session cookie 鉴权,与 `/auth/me` 同源)

**GET `/api/v1/me/preferences`**
- 入参:无
- 返回 200:`{ "folder_tree_default_collapsed": false }`(永远返回全字段,缺省补默认值 false)
- 错误:401 未登录(复用既有 401 语义)

**PUT `/api/v1/me/preferences`**
- 入参 JSON body:`{ "folder_tree_default_collapsed": true }`(字段类型 bool,非必传;仅传该键时其余键保持原值;未知键处理照既有 pydantic 模型惯例)
- 返回 200:同 GET(合并后的全集)
- 错误:401 未登录;422 body 非法

### Web 契约(`api/prefs.ts`,web-A 产出、web-B 消费,签名固定)

```ts
export interface UserPrefs { folder_tree_default_collapsed: boolean }
export function useUserPreferences(): {
  prefs: UserPrefs | undefined; isLoading: boolean; isError: boolean;
}
export function useUpdateUserPreferences(): UseMutationResult<
  UserPrefs, Error, Partial<UserPrefs>
>  // 乐观更新,失败回滚并抛错(调用方 Toast)
```

### App 契约(`core/api/prefs_api.dart` + `models/user_prefs.dart`,app-A 产出、app-B 消费)

```dart
class UserPrefs { final bool folderTreeDefaultCollapsed; ...factory fromJson }
class PrefsApi {
  Future<UserPrefs> getPrefs();     // GET /api/v1/me/preferences,非 200 → _api.err 中文文案
  Future<UserPrefs> updatePrefs({bool? folderTreeDefaultCollapsed}); // PUT,同上
}
// ms_api.dart 注册:late final prefs = PrefsApi(this);
```

### App PAT 契约(`core/api/tokens_api.dart` + `models/pat_token.dart`,app-A 自产自销)

```dart
class TokensApi {
  Future<List<PatToken>> listTokens({bool includeRevoked = false}); // GET ?include_revoked=1
  Future<PatTokenCreated> createToken({required String name, int expiresInDays = 90}); // POST
  Future<void> revokeToken({required Object id}); // DELETE,204 幂等;id 类型以后端 models 为准
}
```

## 7. 前端改动点(Web)汇总

见 §4 Web 清单;视觉遵循现有页面惯例(页头 h1+副标题、卡片、antd Switch);不新增依赖。

## 8. App 改动点汇总

见 §4 App 清单;UI 全部走既有组件(AppRow/MeGroup/SectionCard/SwitchListTile/CopyButton/EmptyState/ListSkeleton/Toast/AppTextField/showAppConfirm/PageHeader);中文文案;不新增 pubspec 依赖。

## 9. 测试功能点

后端(pytest,`-o asyncio_mode=auto`):
1. 未登录 GET/PUT → 401
2. 无偏好行用户 GET → 200 且 `folder_tree_default_collapsed=false`
3. PUT `{true}` → 200 返回 true;再 GET → true(持久化)
4. PUT 部分 update 语义:重复 PUT 不丢键
5. 用户间隔离:A 开关不影响 B
6. 422:body 非法/类型错误
7. upsert 幂等:连续 PUT 同值不重复建行
8. 迁移文件存在且 revision 链接到当前 head(静态检查)

Web(无框架,结构化人工用例,见测试用例包产出):
1. `/settings` 不再出现令牌表格;有偏好开关与 MCP 入口卡片
2. 点入口 → `/settings/mcp`,创建/列表/吊销/include_revoked 全链与改造前一致
3. 开关默认关;打开→PUT 成功→重进 `/settings` 仍开(服务端持久化)
4. 开关开:进项目主树默认收拢、点箭头可展开;批量移动/移动文件夹/百度建任务弹窗树默认收拢
5. 开关开:深链 `/projects/:id/folders/:fid` 仍展开该夹祖先链(定位保留)
6. 开关关:行为与改造前一致(根 <30 全展开,≥30 仅祖先链)
7. 关闭开关后重进项目恢复展开;浏览器直连 API 改值双端一致(App 读同值)
8. AppHeader title=「设置」;三处设置入口可达

App(flutter test 可执行 + 结构化用例):
1. prefs 开:进入 FoldersPage 全部含子级节点收拢(顶层可见、子级行不渲染),点箭头展开子级,再点收拢
2. prefs 关:默认全展开(回归现状)
3. prefs 接口异常:文件夹页正常渲染且按未收拢兜底
4. 设置页开关初值来自 GET;切换调 PUT(失败 Toast 不误报成功)
5. TokensApi 模型 fromJson 对齐后端字段;创建返回明文字段解析正确
6. 令牌页:空态/加载骨架/上限 5 禁用创建/吊销确认弹层
7. 回归:folders 既有测试(folders_polish2_test 等)不破;me 页「设置」行可达;「外观」行不受影响

## 10. 模糊点与决策记录

- **D1 配置存储**:用户拍板「服务端同步」→ 新表 `user_prefs` + GET/PUT `/api/v1/me/preferences`;Web/App 双端读写同一份。
- **D2 Web 作用范围**:用户拍板「所有文件夹树」→ FolderTree 全部 4 处使用处生效(项目主树+3 弹窗)。App 端作用域 = 项目文件夹页;`move_folder_sheet`(恒全展开、无展开状态)与 `netdisk_tree_sheet`(网盘域独立树)不纳入,避免为选择器强加展开状态管理 — 属合理边界,非用户点名的范围。
- **D3 App 设置形态**:用户拍板「新建设置页」→ `/settings` 独立页;**现有「外观」行与弹层原地保留不动**(保守,不推翻存量交互),设置页只承载本周期两项新内容。
- **D4 切换生效时机**:非受控树/App State 每次进入重建的既有语义 → 切换对下一次挂载生效,不做即时重排;文案中说明。
- **D5 祖先链定位展开**:Web `defaultExpanded` 祖先链逻辑保留 — 开关语义是「不再默认展开**所有**文件夹」,深链/当前选中夹的定位展开不属于「默认展开全部」,保留。
- **D6 不做审计事件**:用户级 UI 偏好非管理操作,不写 audit_events。
- **D7 推翻旧决策备案**:`SettingsPage.tsx:2` 注释「令牌管理只做 Web」被本周期推翻(App 端新增 PAT 管理),该注释随改造删除;后端 PAT 端点 session-only 语义对 App cookie 通道天然兼容,零后端改动。
- **D8 红线评估**:可行、成本中等(用户选服务端同步使周期扩为三端),无需再问询。
