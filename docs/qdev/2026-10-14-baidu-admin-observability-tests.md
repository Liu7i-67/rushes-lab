# 测试用例清单:审计过滤补全 + 管理员备份任务视图 + livp 失败文案(T10-T16)

> qdev 测试角色存档,2026-10-14。需求依据:`docs/qdev/2026-10-14-baidu-admin-observability.md`
> 「测试功能点」T10-T16;上游方案:`rushes-spec/material-storage/prod-observability-fix-plan.md`
> §2(W2)/§1.4(W1-B)/§3.2-3.3(W3)。
> 后端可执行用例(T1-T9)见 `material-storage/api/tests/test_admin_baidu_tasks.py`(本文件不重复)。

## 执行环境约定

- **除 T10 的 build/tsc 步骤可本地或 CI 执行外,其余全部为「dev 真机/部署后人工执行」**:
  按 deploy-hh2 惯例部署到 dev(ms-api 容器重启 + SPA 分片替换)后在浏览器人工走查。
- 账号:Evan(系统 admin,`is_system_admin=true`,本地密码登录)/ Outsider(无任何权限的普通账号)。
- 浏览器:Chrome 最新稳定版(开发者工具开 Console + Network 面板)。

## 公共前置(数据准备,一次性)

- P1 dev 环境部署本分支(`feat/baidu-admin-observability`):后端含 F7-F9 三端点,SPA 为本分支构建产物;
- P2 dev 库存在百度备份任务存量数据,至少覆盖:两个不同用户的任务(其一为活动任务
  running 或 enumerating)、一条 failed 任务(fail_reason 长文本)、目标夹健在的任务;
  可经用户侧真实流程(绑定 + 建任务)或 SQL 直插 `baidu_backup_tasks`/`baidu_backup_task_files` 构造
  (后端集成测试 `test_admin_baidu_tasks.py` 的 world 数据会自清理,不留存);
- P3 dev 库存在一条 livp 资产且 `tags.thumbnail_failed` 非空(W1 backfill 后的存量失败资产;
  如无,可 SQL 手工将该资产 `tags` 内补 `thumbnail_failed` 键),另备一条等待生成中与一条
  正常的 livp 资产;
- P4 dev 库 audit_events 有「备份文件导入」(`baidu_file_imported`)与「授权撤回」(`grant_revoked`)
  历史事件各 ≥1 条(无则造一条)。

---

## T10 构建产物与 Console 抽查(build 绿、新指纹产出、无 Console 错误)

- **前置**:本分支代码工作区干净;node/pnpm 环境就绪。
- **步骤**:
  1. `cd material-storage && pnpm --dir web install && pnpm --dir web build`;
  2. 核对 `web/dist/assets/` 指纹文件名相对上一版本有更新(新增 AdminBaiduTasksPage chunk);
  3. 部署 dev 后打开 `/admin/baidu-tasks`、`/admin/audit`、任一 livp 资产预览,抽查 Console。
- **预期**:build/tsc 零错误;dist 产出新指纹;三处页面 Console 无 error(红字);
  Network 无 4xx/5xx(除 T12 故意触发的 403)。
- **涉及文件**:`material-storage/web`(全量构建);`web/src/pages/AdminBaiduTasksPage.tsx`(新)。
- **执行方式**:步骤 1-2 本地/CI 可执行;步骤 3 **dev 真机/部署后人工执行**。

## T11 审计事件类型下拉补全 33 项(/admin/audit)

- **前置**:T10 完成;公共前置 P4。
- **步骤**:
  1. Evan 打开 `/admin/audit`,展开「事件类型」下拉,数行数、找关键项;
  2. 选中「备份文件导入」(`baidu_file_imported`)后看列表;
  3. 点 CSV 导出,打开文件核对 event_type 列;
  4. 搜索框输入 `审批`,确认下拉中搜不到「审批通知已发送」(approval_notified)、
     「邀请通知已发送」(invite_notified);
  5. 任选一个 `baidu_*` 项(如「备份任务创建」)看其选项圆点颜色,与其他分组(如文件类)对比;
  6. 回归:选一个原有项(如「文件删除」)过滤、清空回「全部」。
- **预期**:
  1. 下拉命名选项 55 项 + 「全部」= 56 行;含「备份文件导入」「授权撤回」等全部 33 新项
     (附录 A 分组:备份 11 / 文件 8 / 用户组 7 / 登录通知 3 / 权限模板目录授权 4);
  2. 选「备份文件导入」后列表仅剩该类事件,计数与库一致;
  3. CSV 导出同口径(仅该 event_type);
  4. 两死项(approval_notified / invite_notified)不再出现在下拉;
  5. `baidu_*` 11 项为同一分组色(非默认灰),风格与既有分组一致;
  6. 原有项过滤零回归,「全部」恢复全量。
- **涉及文件**:`web/src/pages/AdminAuditPage.tsx`(EVENT_TYPES :46-83、eventColor :349-353);
  `web/src/lib/labels.ts`(:9 注释、:14 approval_card_updated 注释,不改行为)。
- **执行方式**:**dev 真机/部署后人工执行**。

## T12 非 admin 账号不见「备份任务」chip、直连路由被 403 拦

- **前置**:T10 完成;Outsider 可登录。
- **步骤**:
  1. Outsider 登录,看顶栏 AppHeader 的导航 chip;
  2. Outsider 地址栏直连 `/admin/baidu-tasks`;
  3. 打开 Network 面板看对 `/api/v1/admin/baidu-backup/tasks` 的请求。
- **预期**:
  1. Outsider 的顶栏**没有**「备份任务」chip(与「用户」「用户组」「权限模板」同级、同样仅
     `me.is_system_admin` 显示);
  2. 直连路由时页面不白屏不崩溃:列表请求返回 403,页面呈现空态/无权限提示;
  3. Evan 登录同路径则 chip 可见、列表正常(与 T13 衔接)。
- **涉及文件**:`web/src/components/AppHeader.tsx`(导航 chip 组 :100-121);
  `web/src/App.tsx`(/admin/baidu-tasks 路由 :69-73 处);`web/src/pages/AdminBaiduTasksPage.tsx`。
- **执行方式**:**dev 真机/部署后人工执行**。

## T13 admin 列表页:渲染 / 过滤 / 分页 / labels 映射 / 轮询

- **前置**:T10 完成;公共前置 P2(含至少一个活动任务)。
- **步骤**:
  1. Evan 打开 `/admin/baidu-tasks`,核对列表列:用户 / 状态 Tag / 进度条 / 失败数 / 源目录 /
     目标(项目名/夹名)/ 创建时间 / 失败原因;
  2. 找一条 running 任务核对进度条数值 =(done+skipped+cancelled)/total;找一条
     enumerating 任务看进度条区域;
  3. 找一条 failed_files>0 的任务看失败数颜色;hover 源目录看 ellipsis+tooltip;
  4. 状态 Select 依次选「运行中」「已完成」,看列表与 Network 请求参数;
  5. 搜索框分别输入:某任务属主的用户名片段 / 姓名片段 / 源目录片段,看结果;
  6. 翻页,看 Network 请求的 limit/offset 变化;
  7. 存在活动任务时停留页面 ≥30s,看 Network 中列表请求的间隔;把活动任务等到终态(或换
     无活动任务的过滤条件)再观察 30s;
  8. 对照后端原始数据核对:状态/失败原因文案与颜色是否与 `labels.ts` 的
     BAIDU_TASK_STATUS_LABEL/COLOR(:81/:91)、BAIDU_FAIL_REASON_LABEL(:121)一致;
     失败原因是 7 个固定 token 的中文映射,非裸串;status 展示后端原始值,不出现
     `baiduTaskDisplayStatus`(:151)派生的「排队中」。
- **预期**:8 列齐全;enumerating 行**不渲染**进度条(改进:用户侧是 0% 条);失败数>0 红色;
  状态/搜索/分页均为服务端行为(每次操作发新请求、total 随过滤变化);活动任务存在时
  15s 自动刷新,无活动任务时停止;文案颜色全部命中 labels 映射。
- **涉及文件**:`web/src/pages/AdminBaiduTasksPage.tsx`(新);`web/src/api/hooks.ts`
  (F11,基址 `/api/v1/admin/baidu-backup`);`web/src/lib/labels.ts`;`web/src/api/types.ts`。
- **执行方式**:**dev 真机/部署后人工执行**。

## T14 行点击抽屉:详情字段 + 文件明细(分页 / 状态过滤 / last_error)

- **前置**:T13 通过;公共前置 P2 中含一个文件行数 >50 的任务(如无,SQL 补造文件行)且
  其中有 failed 行(last_error 为长文本)。
- **步骤**:
  1. 点击任一列表行开抽屉,核对详情字段:状态 / 源目录 / 项目 / 目标夹 / 各聚合计数 /
     bound_baidu_uid / binding(百度 uid 与状态)/ cancel_reason / retry_count 等调度观测字段;
  2. 看文件明细表:翻页,看 Network 请求 limit/offset(服务端分页,默认 50);
  3. 文件状态过滤下拉逐项选(只应有 6 个合法项),看结果与请求参数;
  4. 展开一条 failed 行看 last_error;与库内原文对比长度;
  5. 对一条目标夹已删的任务(公共前置 P2 如有)看目标展示。
- **预期**:详情字段齐全与接口定义②一致;文件明细服务端分页 + 状态过滤生效;
  last_error 完整展示(超 200 字符为后端截断后的值);文件状态文案/颜色走
  BAIDU_FILE_STATUS_LABEL/COLOR(:101/:111);目标夹已删显示空/「已删除」而非报错。
- **涉及文件**:`web/src/pages/AdminBaiduTasksPage.tsx`(抽屉部分);`web/src/api/hooks.ts`。
- **执行方式**:**dev 真机/部署后人工执行**。

## T15 livp 预览失败文案区分(thumbnail_failed 非空 → 失败卡)

- **前置**:公共前置 P3(失败 livp / 等待中 livp / 正常 livp 各一)。
- **步骤**:
  1. 打开 `tags.thumbnail_failed` 非空的 livp 资产预览弹窗,读文案;
  2. 打开等待生成中(thumbnail_failed 为空、缩略图未出)的 livp,读文案;
  3. 打开正常的 livp:静态图与实况短片播放;若有下载入口,点下载。
- **预期**:
  1. 失败 livp 显示明确失败卡:「预览生成失败(原因标记:{thumbnail_failed 值}),可下载原片
     查看,恢复请联系管理员」,**不再**出现「还在生成(或生成失败),请稍后刷新重试」;
  2. 等待中 livp 维持原「还在生成,请稍后刷新重试」文案(该分支不变);
  3. 正常 livp 展示与现状一致(静态图 + 实况可播);失败卡提供下载原片入口或明确下载指引。
- **涉及文件**:`web/src/components/AssetPreviewModal.tsx`(livp 分支 :232-250)。
- **执行方式**:**dev 真机/部署后人工执行**。

## T16 回归:用户侧备份抽屉零影响 + /admin/audit 原行为不变

- **前置**:T10-T11 完成;一个已绑定百度网盘的普通用户账号。
- **步骤**:
  1. 普通用户走用户侧全链路:绑定(或已绑)→ 打开 BaiduBackupDrawer → 建任务 → 看进度 →
     取消 / 失败重试 / 文件明细 → 解绑再绑;
  2. `git diff liuqi -- web/src/components/BaiduBackupDrawer.tsx web/src/components/BaiduTaskDetail.tsx`
     确认零改动(静态佐证);
  3. Evan 打开 `/admin/audit`:时间范围过滤、操作者过滤、翻页、CSV 导出各走一遍;
  4. 抽查 `labels.ts` 其余键(非百度域)在用户侧各页的中文展示无变化。
- **预期**:用户侧备份抽屉行为与 liuqi 完全一致(两文件 diff 为空);`/admin/audit` 原有
  过滤/导出行为不变;labels.ts 仅注释与既有映射,无行为回归。
- **涉及文件**:`web/src/components/BaiduBackupDrawer.tsx`、`web/src/components/BaiduTaskDetail.tsx`
  (应零改动);`web/src/pages/AdminAuditPage.tsx`;`web/src/lib/labels.ts`。
- **执行方式**:步骤 2 静态核对可本地执行;步骤 1/3/4 **dev 真机/部署后人工执行**。
