# 方案:App 审计筛选侧边抽屉 + 项目置顶

> 2026-10-28 · 两项需求合一方案(qplan 盲审定稿)
> 需求来源:①App 端审计日志页搜索项收拢侧边抽屉(当前平铺占太多显示区域) ②项目置顶(任意用户可置顶/取消任意数量项目,置顶项目排列表最前)
> 注:原始三需求中的「登录页记住账号密码」已于 2026-10-28 由用户撤销——现代做法是保持登录,当前系统已实现(app cookie 落盘重启免登录、web session cookie),本方案不含该项。

## 0. 背景与现状

### 0.1 App 审计日志页现状

- 页面 `app/lib/features/admin/admin_audit_page.dart:210-256`:Scaffold > Column 平铺 = PageHeader(:213) + 快捷 chip 横轨 `AuditQuickChips`(:231,高 52) + 筛选卡 `AuditFilterBar`(:232) + Expanded 列表(:254)。
- 筛选卡 `app/lib/features/admin/audit_filter_bar.dart:103-158`:AppCard 内 Column 逐行平铺 4 控件——事件类型 PickerField / 按项目筛选 PickerField / 按操作者 UserPickerField / 单日日期 OutlinedButton。整卡约 300px+,是列表区域被挤压的主因。
- 筛选值全部由页面 State 持有(`admin_audit_page.dart:34-37`),`AuditFilterBar` 受控无状态,变更回调页面 setState + `_reload()`。eventType 同时受 chip 轨与筛选卡 PickerField 控制(同值联动)。
- **app 全库无 `Drawer`/`endDrawer` 用法**;筛选收拢的既有主流模式是 `showModalBottomSheet` + `SheetScaffold`(`app/lib/widgets/sheet_scaffold.dart:27-41`)。
- 数据接口 `GET /api/v1/admin/audit`(参数 event_type/actor_user_id/project_id/from/to + limit/offset),本需求不改后端。

### 0.2 项目列表与置顶可行性现状

- 后端 `api/app/routers/projects.py:595-651` `GET /api/v1/projects`:系统 admin 见全部 active;普通用户 = OpenFGA `list_objects(can_view, project)` UNION `visibility=public`;两分支均滤 `is_archived=False` + `deleted_at IS NULL`,排序恒 `created_at desc`,limit=100 默认 + offset 分页。
- `ProjectOut`(`api/app/models/__init__.py:78-91`):id/code/name/description/organization_id/minio_bucket/visibility/is_archived/created_at/admins/my_roles。
- DB **无任何用户偏好表**(user_settings/favorites/pinned 均 grep 零命中);用户↔资源关联表先例=`group_memberships`(复合主键,`api/app/db/tables.py:341-353`)。项目成员关系只存 OpenFGA tuple。
- Alembic HEAD = `20261027_0018`(audit_event_time_index)。
- web `web/src/pages/ProjectsPage.tsx`:卡片网格(useProjects 单页拉取,无排序控件无分页 UI,直接渲染后端顺序);app `app/lib/features/projects/projects_page.dart`:SearchField 客户端过滤 + ListView + ProjectCard,长按管理菜单**仅 project admin 可进**(:93-95 canAdmin gate),RefreshBus 'projects' 失效重拉。
- 生产环境 41 个可见项目 << 默认 limit 100,两端 UI 均单页拉取无感分页。

## 1. 需求 A:App 审计筛选收拢侧边抽屉

### 1.1 目标

4 个精细筛选控件从页面平铺区移除,收入**右侧滑出抽屉**(endDrawer),把垂直空间还给审计列表;筛选能力与数据流不变。

### 1.2 设计

1. **承载**:页面自身 Scaffold 挂 `endDrawer`。抽屉宽度 `min(屏宽×0.85, 400)`;内容=标题行「筛选」+ 右上「重置」TextButton + 4 个筛选控件(事件类型/项目/操作者/日期,复用现有 PickerField/UserPickerField/日期按钮,回调签名不变,**整段包 SingleChildScrollView** 防小屏/大字号溢出)+ 底部「完成」FilledButton(`Navigator.pop(context)` 关抽屉)。
2. **入口**:PageHeader actions 在「导出 CSV」左侧加「筛选」IconButton(Icons.tune;PageHeader 是自绘组件,actions 为通用 Widget 列表,IconButton 可直接放入)。**有生效筛选时按钮带计数 Badge**(用 Material 3 `Badge(label: Text('$n'))`,注意非 `app/lib/widgets/badge.dart` 自研同名件;生效数=eventType≠'' + projectId≠'' + actor≠null + day≠null 四项计数;0 项不显示 Badge)。注意 eventType 由 chip 轨与抽屉共用——chip 轨点击也计入该计数。
3. **快捷 chip 轨保留**(决策 D1):高度仅 52px、高频快捷操作(全部/下载/上传/分享),不收拢;只收 4 控件筛选卡。页面平铺区从「PageHeader+chip 轨+筛选卡+列表」变为「PageHeader+chip 轨+列表」。
4. **交互模式=即时生效**(决策 D2):抽屉内改动任一筛选即触发 `_reload()`(与现网行为一致,受控无状态数据流零改动);「重置」=四值清空(''/''/null/null)+ reload;「完成」仅关闭抽屉不触发请求。
5. **组件改造**:`audit_filter_bar.dart` 的 `AuditFilterBar` 重构为 `AuditFilterDrawer`(Drawer 内容 widget,同一文件改造,保留 AuditQuickChips 导出);`admin_audit_page.dart` 移除平铺卡挂 endDrawer,State 增加 openDrawer 回调。「回调签名不变」仅指 4 个筛选控件的取值回调;抽屉化会新增「重置/完成」两个回调参数。既有测试迁移分两类(决策依据:实际测试形态):①`admin_polish_test.dart:27-34`、`audit_filter_actor_test.dart`、`forms_polish2_test.dart:45`、`probe_p2_test.dart:635` 均为**直接构造 AuditFilterBar widget** 的用例——改为构造 AuditFilterDrawer(补新回调参数),断言逻辑基本原样;②页面级断言才需要先 `Scaffold.openEndDrawer()`(测试 tap 筛选按钮)再 find。`admin_pages_test.dart:454` pump 整页但不涉筛选卡断言,列为回归观察点(重构后应仍绿)。
6. **空态联动**:列表空态文案「无匹配记录」保留;抽屉打开状态下结果变化可见(抽屉半遮列表,可接受,业界同款)。

### 1.3 边界与风险

- endDrawer 会启用右侧边缘滑动手势打开抽屉,系统 back 键先关抽屉再退页面(Material 默认行为,符合预期);抽屉内控件均为纵排,无手势冲突。唯一例外:页面顶部 52px chip 轨是通栏横向 ListView,自右缘落在 chip 轨上的横滑会被手势竞技场判给 chip 滚动而非开抽屉——属 Material 默认行为,预期内无需处理。
- Badge 计数与 chip 轨联动:chip 轨选择「下载」时筛选按钮也显示 1——口径见 §1.2.2,是「当前生效筛选总数」而非「仅抽屉内筛选数」,避免用户误解(抽屉里事件类型=下载是事实生效的筛选)。
- 本需求零后端改动、零迁移。

## 2. 需求 B:项目置顶

### 2.1 目标

任意用户可对**任意数量**的可见项目标记置顶/取消置顶;项目列表中置顶项目排在最前,多个置顶项目之间及全部置顶时按原排序(created_at desc)排列。置顶是**用户私有偏好**,每人各自独立。

### 2.2 数据库

1. 新表(照 group_memberships 复合主键风格,`api/app/db/tables.py` 追加):

```python
class UserProjectPin(Base):
    """user ↔ project 置顶标记(用户私有偏好;复合主键,只增删无更新)。"""
    __tablename__ = "user_project_pins"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    project_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), primary_key=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
```

2. 迁移 `2026_10_28_0019_user_project_pins.py`(revision=`20261028_0019`,down_revision=`20261027_0018`):create_table + 复合主键;无额外索引(复合主键 (user_id, project_id) 已覆盖「按 user 查」前缀)。docstring 注明(照 0015/0018 惯例):存量数据迁移=无;downgrade drop_table 即弃全部用户置顶偏好(纯偏好数据,可接受)。
3. 残留语义:项目归档/删除后 pin 行保留;**项目恢复/取消归档后置顶自动重新生效**(正向特性)。用户删除由 CASCADE 兜底。**授权被收回的孤儿 pin 同样定性为无害保留**:失去 can_view 后列表不可见、unpin 走守门 404 无法自清(行残留),重新授权后 pin 复活——列表本就看不见该行,不产生任何可观测影响,勿当 bug 提单。不主动清扫(表量级=用户数×置顶数,极小)。deleted 与 archived 的守门差别见 §2.3.3。

### 2.3 后端接口

1. `POST /api/v1/projects/{project_id}/pin` → **204 No Content**
   - 幂等:已置顶再置顶仍 204(实现:`pg insert ... on_conflict_do_nothing`,并发安全由复合主键兜底)。
2. `DELETE /api/v1/projects/{project_id}/pin` → **204 No Content**
   - 幂等:未置顶删除也 204(行不存在=目标态达成)。
3. **可见性守门**(两端点同口径):项目不存在、已逻辑删除(deleted_at IS NOT NULL)、或对当前用户不可见 → 404。判定复用列表口径:is_system_admin 直接过;否则 OpenFGA `check(can_view)` 通过或 `visibility=='public'`(不可见项目不允许置顶,防止通过置顶行为探测私有项目存在性)。**deleted 与 archived 差别处理**:已删除项目对所有人(含 system admin)404——与详情端点 F6.4 深隐藏语义一致(软删时 FGA tuple 残留,仅按 can_view 判定会让原成员对已删项目 pin 成功,等于把「已删除」变成可探测);已归档项目**放行**(pin 行残留语义见 §2.2.3,恢复后置顶自动生效)。注:不可见私有项目的详情端点既有语义是 403(projects.py:853),pin 端点统一 404 为有意更严(反探测),两者差异属设计选择不在本方案改动面。
4. **不记 audit_events**(决策 D3):置顶是用户私有 UI 偏好,非业务关键操作,与「关键操作留痕」语义不符;不产生跨用户影响。
5. 实现位置:`projects.py` 新增两个路由函数(内联,与既有路由同级);无需动 FGA。**import 增量**:`from sqlalchemy import` 补 `exists`(现仅 func/or_/select,projects.py:26);§2.3.1 的 `on_conflict_do_nothing` 需 `from sqlalchemy.dialects.postgresql import insert`(pg 方言 insert,勿用顶层 insert 否则无 on_conflict);tables 侧新表类同文件追加;`UserProjectPin` 导入 projects.py。

### 2.4 列表接口改造

1. **排序**:两分支(admin/普通用户)的 stmt 末尾 `.order_by(...)` 统一替换为置顶优先:

```python
pin_exists = exists(
    select(1).where(
        UserProjectPin.user_id == user.id,
        UserProjectPin.project_id == Project.id,
    )
)
# 两分支均改为:
.order_by(pin_exists.desc(), Project.created_at.desc())
```

(user.id 为 UUID,`api/app/deps.py:29`;exists 谓词对每用户参数化,同请求内稳定。)

2. **契约**:`ProjectOut` 加 `is_pinned: bool = False`(字段注释写明「user 私有置顶标记」);回填照 `_fill_project_admins` 批量模式(`projects.py:563` 的 `User.id.in_(user_uuids)` 同款)——一次 `select(UserProjectPin.project_id).where(user_id==user.id, project_id.in_([r.id for r in rows]))` 取集合(rows 为 ORM 对象,须传 id 列表),set 回填,无 N+1。**详情端点 `GET /projects/{id}` 同样回填**(get_project 已有 `_fill_project_admins([project])` 同款结构,projects.py:856-862,补同段约 3 行)——消除「列表有值详情恒 False」的说谎字段,消费方语义一致。
3. 分页安全:置顶谓词参与 ORDER BY,limit/offset 跨页语义正确(置顶恒在前);排序稳定性=既有语义(created_at desc 本无 id tiebreaker,不因本改动恶化;置顶集合变更瞬间同翻页窗口漂移属既有类问题)。
4. 其他消费方(全量枚举):web 侧 `['projects']` 另有 AppHeader ⌘K 搜索(`AppHeader.tsx:314`)、MyPermissionsPage(`:65`)、BaiduNewTaskModal(`:40`)消费;`['projects-all']`(useAllProjects)另有 ApplyDefaultModal(`ApplyDefaultModal.tsx:34`)、AdminAuditPage(`AdminAuditPage.tsx:121`)消费;app 侧 `projects.list()/listPaged` 另有 folders/notifications/my_permissions/baidu_new_task 等 6 处。均为选择器/搜索/分组场景,置顶排序变化对其无语义影响(选项顺序改变不改变结果正确性),不做适配;⌘K 与各下拉中置顶项目排前列属预期行为,列入 §4.4 真机验收观察。

### 2.5 web 端改动

1. `web/src/api/types.ts` Project 加 `is_pinned?: boolean`。
2. `hooks.ts` 加 `usePinProject`/`useUnpinProject`(POST/DELETE → 成功 invalidate `['projects']` 与 `['projects-all']` 两 key)。
3. `ProjectsPage.tsx` ProjectCard:
   - 底部 meta 行(申请链接/删除项目同排)加置顶 IconButton:**已置顶=lucide `Pin` 实心金色 `--ms-accent`,未置顶=`PinOff` 灰色**(两态一对,与 app 侧 §2.6.4 图钉方案对称)。点击乐观不做(直接 mutation + invalidate 重取,项目数 41 量级无性能问题)。
   - 已置顶卡片标题行加金色 Pin 小图标(12px,`title="已置顶"`),列表无需分区标题。
   - 排序:直接渲染后端返回顺序,前端不再排。
   - Tooltip:未置顶「置顶到列表最前」/已置顶「取消置顶」。
4. 移动 web(compact viewport)同款渲染,无媒体查询分支(按钮在 meta 行内自适应)。

### 2.6 app 端改动

1. `app/lib/models/project.dart` 的 Project 加 `isPinned`(解析 is_pinned,缺省 false 兼容旧后端;经 models.dart 桶文件导出,既有 import 不变)。
2. `projects_api.dart` 加 `pin(projectId)` / `unpin(projectId)`(POST/DELETE,204 无 body)。
3. **入口=长按菜单扩展**(决策 D4):`_showRowMenu` 去掉「非 admin 直接 return」闸门,改为菜单内容分级——首项「置顶到最前/取消置顶」(Icons.push_pin_outlined,所有用户可见);「成员管理/请求链接」仍仅 canAdmin 时加入菜单。长按对普通用户从无反应变为可置顶,交互模式不变(showModalBottomSheet + AppRow)。菜单标题现恒为「${p.name} · 管理」(:101),普通用户仅见置顶项时「管理」语义偏——统一改为「${p.name} · 项目操作」。**既有测试迁移**:`projects_page_ux_test.dart:244` 断言 `find.text('项目A · 管理')`,标题改名后同步改为「项目A · 项目操作」(或并入新用例)。
4. 已置顶卡片标题旁金色图钉标识(Icons.push_pin,14px,tk.gold);置顶/取消成功后 `_reload()`(RefreshBus 'projects' 语义等价,直接重拉本页);**失败走 toast**(照本页 `_reload` 的 errorMessage 兜底模式,ApiException 透传 detail)。
5. 搜索过滤(_filteredProjects)保持对已排序列表过滤,不动顺序。

### 2.7 边界与风险

- 置顶数量无上限(需求明示「任意数量」):全部置顶=排序退化为 created_at desc 原序,符合需求表述「都是置顶项目的时候根据原排序逻辑排列」。
- 置顶数超过单页 limit(>100)时:后端排序保证置顶在前,但两端 UI 均单页拉取,需换全量拉取才能见全部置顶——当前 41 项目量级无感;若未来项目数逼近 100,web ProjectsPage 改用 useAllProjects、app 用 listPaged 循环(既有基建),此处仅留边界提示不实施。
- 迁移 0019 部署:dev 容器需手动 alembic upgrade(既有部署钉子照走),先迁移后发版(新表查询在旧库会 500)。
- `GET /projects/{id}` 详情端点同样回填 is_pinned(§2.4.2),列表与详情字段语义一致;`ProjectCreatedOut` 继承 ProjectOut,POST /projects 201 响应的 is_pinned 恒默认 false(新建即置顶无意义,消费方勿依赖)。

## 3. 接口契约汇总

| 方法 | 路径 | 入参 | 返回 | 说明 |
|---|---|---|---|---|
| POST | /api/v1/projects/{id}/pin | path id | 204 | 幂等;不可见/已删除 404 |
| DELETE | /api/v1/projects/{id}/pin | path id | 204 | 幂等;不可见/已删除 404(与 pin 同口径) |
| GET | /api/v1/projects(改造) | limit/offset | ProjectOut[] (+is_pinned) | 排序=置顶优先+created_at desc |

注:is_pinned 在列表与详情(`GET /projects/{id}`)两处均回填(§2.4.2);`ProjectCreatedOut` 继承 `ProjectOut`(`models/__init__.py:104`),POST /projects 201 响应的 is_pinned 恒默认 false(新建即置顶无意义,消费方勿依赖)。

## 4. 测试功能点

### 4.1 api(新增 `api/tests/test_project_pins.py`,表驱动+既有 fixture 风格)

1. pin:普通用户对可见(private 授权/public)项目 204;重复 pin 幂等 204 且表内仅一行。
2. unpin:已置顶 204;未置顶 204;表内无残留。
3. 守门:对不可见 private 项目 pin/unpin 均 404;不存在 id 404;**对已逻辑删除项目(deleted_at 非空,含 public/原成员场景)pin/unpin 均 404**(§2.3.3 深隐藏语义);对已归档项目放行 204(项目无归档 API,归档态经 DB 直改 is_archived,照 `test_default_template.py:246,705` 先例取数)。**system admin 分支**:admin 对非成员 private 项目 pin/unpin 均 204(§2.3.3 直过口径);admin 对已删除项目仍 404(与 F6.4 对齐)。
4. 排序:置顶项目恒在列表最前;多个置顶按 created_at desc;全置顶=原序;未置顶部分 created_at desc。created_at 为 server_default now(),快速连建可并列——断言容忍并列,或测试内 DB 直改 created_at 拉开间隔(防偶发不稳定)。
5. is_pinned 回填:自己置顶的 true、他人置顶的 false(用户隔离);system admin 走 admin 分支的回填同样正确;详情端点 `GET /projects/{id}` 的 is_pinned 与列表一致(§2.4.2 两处回填)。
6. 迁移 upgrade/downgrade 冒烟。
7. **更新既有 `api/tests/test_db_schema.py`**:`test_all_tables_in_metadata`(:18-39)对 `Base.metadata.tables` 做 18 表精确相等断言,新表 `user_project_pins` 入表集合(+1=19)。

### 4.2 app(flutter test,既有目录结构)

1. 审计抽屉:筛选按钮存在;页面级用例 tap 筛选按钮 openEndDrawer 后 4 控件可见;组件级用例直接构造 AuditFilterDrawer(§1.2.5 两类迁移);改筛选即触发重查(mock api);重置清空四值;Badge 计数(0/1/2 项);`admin_pages_test.dart` 整页用例回归仍绿。
2. 项目置顶:Project.isPinned 解析(含缺省);长按菜单非 admin 仅见置顶项、admin 全量(`projects_page_ux_test.dart:244` 标题断言同步改);置顶/取消后列表刷新与顺序断言(mock 按新排序返回);卡片图钉标识显隐。测试基建:`app/test/helpers/api_harness.dart:507-519` 的 `FakeProjectsApi` 仅覆写 `list()`,基类新增 pin/unpin 后须补假实现+调用记录,否则走真实 dio 报错。

### 4.3 web

无测试基建(package.json 无 test script,仓库现状),不新增自动化;人工验收清单:置顶按钮两端态、置顶排序、列表刷新正确性。

### 4.4 真机验收(tester 清单,发版后)

1. App 审计页:抽屉开关手感、边缘滑动、back 关抽屉、Badge 计数、重置、CSV 导出不回归。
2. App/web 项目:置顶/取消置顶、排序、普通用户长按菜单、图钉标识、搜索+置顶并存;⌘K 搜索与各项目下拉(百度导入/我的权限/审计筛选)中置顶项目排前列的预期行为观察。

### 4.5 交付记账

两项均为用户可感知更新,交付批次收尾时按 AGENTS.md 约定在 `scripts/changelog.md` 当天分节逐项记账。

## 5. 决策点(已定取向,可被推翻)

| # | 决策 | 取向 | 理由 |
|---|---|---|---|
| D1 | 快捷 chip 轨是否一并收拢 | **保留在页面** | 52px 低占用高频操作,收拢反而增加一步 |
| D2 | 抽屉交互模式 | **即时生效** | 数据流零改动(受控无状态回调不变),与现网一致 |
| D3 | 置顶是否记审计 | **不记** | 用户私有 UI 偏好,非关键操作 |
| D4 | app 置顶入口 | **长按菜单扩展**(对所有用户开放,admin 项仍闸门) | 对齐既有交互模式,不加常驻按钮 |

## 6. 风险与遗留

1. 项目数逼近 100 时两端需切全量拉取(§2.7)——边界提示,不实施。
2. created_at desc 无 id tiebreaker 的翻页窗口稳定性为既有语义,本方案不引入新风险也不顺手修(改动面控制)。
3. web 无测试基建,web 侧改动靠人工验收兜底(仓库现状)。
