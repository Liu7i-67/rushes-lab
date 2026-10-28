# 风控模块 + App 端管理入口(qdev 实施需求)

> 日期:2026-10-28 · 分支 `feat/risk-module`(自 `qplan/risk-module` ec2ce1e 切出,方案文档随分支带入)
> **正本**:`rushes-spec/material-storage/risk-control-module-plan.md`(本 worktree 内,五轮盲审定稿)。
> 功能点、接口契约、组件拆分、测试计划、决策记录 D1-D9 **一律以正本为准**;本文档只做派发拆包、
> 环境约定与交付纪律,不重复正文。派发 prompt 均引用本文档路径 + 正本章节号。

## 工作包拆分(三包并行,文件边界互斥)

### 包 A · api 后端(正本 §3 / §7.1 / §11 / §12)

| 文件 | 动作 |
| --- | --- |
| `material-storage/api/app/routers/risk.py` | 新建:GET /locks + POST /locks/ips/{ip}/unlock |
| `material-storage/api/app/services/local_auth.py` | 追加 `scan_locks` / `lock_details` / `ip_lock_exists` |
| `material-storage/api/app/models/__init__.py` | 追加 RiskLocksOut / RiskUserLock / RiskMatchedUser / RiskIpLock / RiskIpUnlockOut |
| `material-storage/api/app/main.py` | import 块 + include_router(+2 处) |
| `material-storage/api/tests/test_risk_locks.py` | 新建(正本 §7.1 全部用例) |

### 包 B · web(正本 §4 + §3.1/§3.2 契约 + §3.2 审计回补①②④)

| 文件 | 动作 |
| --- | --- |
| `material-storage/web/src/pages/AdminRiskPage.tsx` | 新建(正本 §4.2) |
| `material-storage/web/src/api/hooks.ts` / `api/types.ts` | 追加 useRiskLocks / useUnlockIp 与契约类型 |
| `material-storage/web/src/lib/labels.ts` | 追加 `ip_login_unlocked` 文案 |
| `material-storage/web/src/App.tsx` / `src/components/AppHeader.tsx` | 路由 + 菜单(+~6 行) |
| `material-storage/web/src/pages/AdminAuditPage.tsx` | EVENT_TYPES 全集 + 计数注释(:26 基准「55+全部=56 行」+1) |
| `rushes-spec/material-storage/prod-observability-fix-plan.md` | 附录 A 补 `ip_login_unlocked` 一行(全集核对依据,正本 §3.2 ④) |

### 包 C · app(Flutter,正本 §5 + §7.3)

| 文件 | 动作 |
| --- | --- |
| `material-storage/app/lib/features/admin/admin_risk_page.dart` / `admin_usage_page.dart` | 新建(正本 §5.2 / §5.3) |
| `material-storage/app/lib/core/api/risk_api.dart` / `usage_api.dart` | 新建 + `ms_api.dart` 域注册 |
| `material-storage/app/lib/models/`(risk / usage 模型文件) | 新建,照 me.dart fromJson 容错风格 |
| `material-storage/app/lib/app.dart` / `lib/features/admin/admin_home.dart` | 2 命名路由 + 2 磁贴(`_open` 直推) |
| `material-storage/app/lib/features/admin/audit_labels.dart` | kAuditEventTypes + label map + 计数注释(基准「56 项含『』」+1) |
| `material-storage/app/test/features/admin_pages_test.dart` 等 | 追加两页用例 + risk/usage 契约测试(正本 §7.3) |

## 环境与自测命令(PM 已备)

- **worktree**:`E:\qbb\github_not_me\rushes-lab-feat-risk-module`,全部改动在此,**禁止动主仓与 qplan worktree**。
- **web**:`node_modules` 已 junction 到主仓(PM 建),**禁止 `pnpm install`**;自测 `cd material-storage/web && pnpm lint && pnpm build`(build 产物进 api/app/static/web/,已 gitignore)。
- **api**:本机有 uv;自测 `cd material-storage/api && uv sync && uv run ruff check . && uv run mypy app`(mypy strict)。**pytest 禁止本地跑**(本地 docker 2026-10-20 立规),测试写好即止,由 PM 在 hh2 dev 容器执行(跑前 FLUSHALL 清限流锁)。
- **app**:Flutter SDK `E:\qbb\soft\flutter`(shell PATH 可能没有,`export PATH=/e/qbb/soft/flutter/bin:$PATH`),`JAVA_HOME=E:/qbb/soft/java`;自测 `cd material-storage/app && flutter pub get && flutter analyze && flutter test`(analyze 必须 0 issue,全量测试基线 169 文件须全绿)。

## 交付纪律(三包通用)

1. **禁止 `git commit` / `git add`**,改动留工作区,PM 统一验收后提交。
2. **既有功能不得删、不得改行为**(尤其 local_auth.py / directory.py / auth.py 既有方法、AdminUsersPage W1 解锁、admin_user_row 既有行);只做追加与既有文件点名行内的新增。
3. 只允许创建/修改上表文件;超边界改动一律不做(发现边界外必须改的情况,停下在汇报中说明,不自行扩界)。
4. **单文件 ≤500 行**;新建文件预估超限先拆子组件/子模块。既有集中文件 `hooks.ts` / `types.ts` /
   `models/__init__.py` 按仓库集中惯例**追加**,其超限属既有已知遗留,记录不新开文件。
5. 只 format / organize-imports 自己新建或修改的文件,禁止全仓格式化。
6. 结束时汇报:改动文件清单 + 每处改动一句话说明 + 自测命令与真实输出摘要 + 未决事项。

## PM 验收清单(第 3/4 步,不采信自报)

- `git diff` 逐文件对照正本 §11 改动面;越界 / 删既有功能即打回。
- 亲手复跑:web `pnpm lint` + `pnpm build`;app `flutter analyze`(0)+ `flutter test`(全绿);
  api `ruff` + `mypy`;api pytest 在 hh2 dev 容器跑(docker cp 先 rm 防嵌套,FLUSHALL 后跑)。
- 对照正本 §9 验收清单 8 条逐项打勾(dev 环境真机项在部署后补)。

## 模糊点与决策记录

- 全部模糊点已在正本 §10(D1-D9)拍板,实施期不再新开决策;包内出现新模糊点按正本最接近口径处理并在汇报中标注。
- 可行性:qplan 五轮盲审已核(无迁移、无 FGA、纯增量),成本合理,无需红线问询。
