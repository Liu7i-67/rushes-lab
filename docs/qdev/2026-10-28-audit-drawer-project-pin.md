# 需求:App 审计筛选侧边抽屉 + 项目置顶(qdev 执行稿)

> 2026-10-28 · PM:主进程 · 基线:liuqi aff1bfd · worktree 分支 qplan/audit-login-pin
> **唯一需求依据**:`rushes-spec/material-storage/audit-drawer-project-pin-plan.md`(qplan 五轮盲审定稿,下称「方案」)。本稿在其上补工作包拆分、组件签名钉死、测试命令与环境钉子;与方案冲突时以方案为准。

## 背景与目标

两项需求:①App 端审计日志页 4 个精细筛选控件收拢右侧抽屉(endDrawer),释放列表垂直空间;②项目置顶——任意用户可对任意数量可见项目置顶/取消,置顶项目排列表最前(置顶之间按 created_at desc),用户私有偏好互相独立。原始三需求中的「登录记住账号密码」已被用户撤销,不在本批。

**决策记录(方案 §5 已定,不再复议)**:D1 快捷 chip 轨保留在页面;D2 抽屉交互=即时生效;D3 置顶不记 audit_events;D4 app 置顶入口=长按菜单扩展(对所有用户开放,admin 项仍闸门)。

## 功能点明细(逐条可验收)

### A. 审计筛选抽屉(app)
- A1 页面平铺区移除筛选卡,只留 PageHeader+chip 轨+列表;Scaffold 挂 endDrawer。
- A2 PageHeader actions「导出 CSV」左侧新增「筛选」IconButton(Icons.tune,tooltip「筛选」,key=`audit_filter_btn`);生效筛选数>0 时 Material Badge 显示计数(eventType≠''/projectId≠''/actor≠null/day≠null 四项计数;注意用 Material 3 Badge 而非 app/lib/widgets/badge.dart 自研同名件)。
- A3 抽屉宽 min(屏宽×0.85,400);标题「筛选」+右上「重置」TextButton+4 控件(复用原 PickerField/UserPickerField/日期按钮,取值回调签名不变)+底部「完成」FilledButton(内部 Navigator.pop 关抽屉);整段包 SingleChildScrollView。
- A4 即时生效:抽屉内改动即 _reload();重置=四值清空+reload;chip 轨行为不变(与抽屉事件类型联动同现值)。

### B. 项目置顶
- B1 新表 user_project_pins(复合主键 user_id+project_id,CASCADE,created_at server_default now)+迁移 0019(revision=20261028_0019,down=20261027_0018;docstring 注明存量迁移无/降级弃偏好)。
- B2 POST/DELETE /api/v1/projects/{id}/pin → 204 幂等(pg insert on_conflict_do_nothing/删不存在行=目标态);守门:不存在/已逻辑删除(deleted_at 非空,对所有人含 admin)/不可见 → 404;归档放行;is_system_admin 直过,否则 FGA check(can_view) 或 visibility=public。
- B3 GET /projects 两分支排序改 `(exists pin).desc(), created_at.desc()`;ProjectOut 加 `is_pinned: bool=False`;列表与详情 GET /projects/{id} 均批量回填(照 _fill_project_admins 模式,projects.py:563)。
- B4 web:types+hooks(usePinProject/useUnpinProject,成功 invalidate ['projects']+['projects-all'])+ProjectsPage 卡片底部 meta 行置顶按钮(已置顶=Pin 实心金 --ms-accent/未置顶=PinOff 灰,tooltip 置顶到列表最前/取消置顶)+已置顶标题行金色 Pin 小图标(12px,title 已置顶);直接渲染后端顺序不前端排。
- B5 app:Project.isPinned(project.dart,缺省 false)+projects_api pin/unpin+长按菜单对所有用户开放(首项置顶/取消置顶 push_pin_outlined;成员管理/请求链接仍仅 canAdmin)+菜单标题统一改「${p.name} · 项目操作」+已置顶卡片标题旁金色图钉(push_pin 14px tk.gold)+成功 _reload()/失败 toast。

## 组件拆分与工作包(互不依赖,全部并行;文件清单=各包改动边界,越界即打回)

| 包 | 域 | 文件(新建★/改) |
|---|---|---|
| B1 | api 实现 | ★api/app/db/migrations/versions/2026_10_28_0019_user_project_pins.py;api/app/db/tables.py(追加 UserProjectPin);api/app/models/__init__.py(ProjectOut.is_pinned);api/app/routers/projects.py(pin/unpin 路由+list 排序+两处回填+import:sqlalchemy exists、dialects.postgresql insert、tables UserProjectPin) |
| B2 | api 测试 | ★api/tests/test_project_pins.py(方案 §4.1 全部 7 组);api/tests/test_db_schema.py(18 表→19,加 user_project_pins) |
| F1 | app 审计抽屉 | app/lib/features/admin/audit_filter_bar.dart(AuditFilterBar→AuditFilterDrawer,保留 AuditQuickChips);app/lib/features/admin/admin_audit_page.dart(挂 endDrawer+筛选按钮+Badge 计数) |
| F2 | app 项目置顶 | app/lib/models/project.dart;app/lib/core/api/projects_api.dart;app/lib/features/projects/projects_page.dart |
| W1 | web 置顶 | web/src/api/types.ts;web/src/api/hooks.ts;web/src/pages/ProjectsPage.tsx |
| F3 | app 测试(第二波,依赖 F1/F2 产出) | 见下「F3 测试包」 |

**签名钉死**(F1/F3 契约):`AuditFilterDrawer` 构造参数 = 原 AuditFilterBar 全部参数 + `onReset: VoidCallback`(四值清空由页面执行后 reload;抽屉自身不持状态)。「完成」按钮内部 `Navigator.pop(context)`,无 onDone 参数。页面筛选按钮 key=`audit_filter_btn`。

**单文件约束**:默认 ≤500 行。ProjectsPage.tsx 现状 452 行,+置顶约 35 行临界——若超限把 ProjectCard 连同置顶逻辑拆到 web/src/components/ProjectCard.tsx(MyRolesBadge 导出不动)。既有大文件(projects.py 等)按原结构追加不强制拆。

## 数据库修改方案

方案 §2.2:新表 user_project_pins(user_id UUID FK users.id CASCADE PK,project_id UUID FK projects.id CASCADE PK,created_at timestamptz server_default now());无额外索引;残留行不清扫(孤儿 pin 无害定性见方案 §2.2.3)。

## 接口定义

方案 §3 契约表:POST/DELETE /api/v1/projects/{id}/pin → 204(幂等;不可见/已删除 404 与 pin 同口径);GET /projects 排序=置顶优先+created_at desc;is_pinned 列表+详情两处回填;ProjectCreatedOut(继承 ProjectOut)的 is_pinned 恒默认 false 属预期。

## 测试功能点

方案 §4.1(api 7 组,含 system admin 分支与已删除 404)、§4.2(app 两组)、§4.3(web 人工)、§4.4(真机清单,发版后)。F3 测试包内容:
- 迁移既有:4 个直构 AuditFilterBar 用例改构 AuditFilterDrawer(app/test/features/admin_polish_test.dart:27-34、audit_filter_actor_test.dart、forms_polish2_test.dart:45、probe_p2_test.dart:635,补 onReset);projects_page_ux_test.dart:244 标题断言「项目A · 管理」→「项目A · 项目操作」。
- 新增:抽屉交互(页面级 tap `audit_filter_btn` 开抽屉→4 控件可见→改筛选触发重查→重置清空→Badge 计数 0/1/2);置顶(Project.isPinned 解析含缺省;长按菜单非 admin 仅置顶项/admin 全量;pin/unpin 后 _reload 与顺序;图钉标识显隐)。
- 基建:app/test/helpers/api_harness.dart:507-519 FakeProjectsApi 补 pin/unpin 假实现+调用记录(否则走真实 dio 报错)。

## 模糊点与决策记录

无新模糊点;D1-D4 沿用方案 §5。登录记住账号密码已撤销(用户 2026-10-28)。

## 测试命令与环境钉子(PM 验收用)

- flutter:`export PATH=/e/qbb/soft/flutter/bin:$PATH; export JAVA_HOME=E:/qbb/soft/java`;worktree app/ 下 `flutter analyze`(0 issue)+`flutter test`(全量绿)。只 format 自己改的文件。
- api:hh2 dev 容器跑(本地 docker 立规禁止):rsync 改动文件进容器→容器内手动 `alembic upgrade head`(0019)→restart→docker cp tests(先 rm 防嵌套)→容器内 pytest 相关文件(跑前 FLUSHALL 清限流);dev 全量 12 条固有非绿勿再排查。
- web:无测试基建;worktree 只跑 lint(node_modules 钉子:web 依赖必用主仓,勿在 worktree npm install)。
- 派发通用:既有功能不得删;注释密度与命名跟随项目(中文注释);改完自己 format 自己文件;汇报=改动文件清单+每处说明+自测结果。
