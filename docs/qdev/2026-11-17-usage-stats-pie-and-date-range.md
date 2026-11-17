# 使用统计页展示优化:占比图饼图切换 + 日期范围选择简化

- 日期:2026-11-17
- 状态:已交付(开发+验收+测试闭环;待人工视觉验收/合并/部署,均待指令)
- 分支:`feat/usage-stats-pie-toggle`(自 liuqi 78d2d32 切出)
- 范围:**纯前端**,web 管理后台(`material-storage/web`),无后端/数据库/接口改动
- 交付:UsageDonut.tsx(新,141 行)/ UsageProportion.tsx(新,170 行,替代删除的 UsageStatBars.tsx)/ usage_shared.tsx(BAR_COLOR+PLATFORM_CLASS_LABEL+formatUsageLine 单一正本)/ AdminUsageStatsPage.tsx(view 切换+纯日期)/ UsageStatsTable.tsx(注释 1 行);测试用例 36 条见同日 `-test-cases.md`
- 测试结论:P0=0;P1×1(格式串三处重复)已修复复验关闭;P2 遗留=饼图 caption 措辞与本文 F1.4 字面略异(要点全覆盖,判定通过)、单分类整环发丝缝人工验收留意;33/36 用例静态/脚本通过,3 条纯视觉(compact 布局/图例换行观感)待人工;build/lint 双 0

## 1. 背景与目标

`/admin/usage` 使用统计页(docs/qdev/2026-10-27-usage-analytics.md §3.3)目前:

1. 占比对比(客户端占比+下钻明细、网络环境占比)全部用**自绘横向占比条**展示,用户希望可**切换为饼图**;
2. 时间范围选择桌面端 `RangePicker` 带 `showTime` 时分秒面板,操作繁琐;用户希望**只选日期**,时间自动补 `00:00:00` / `23:59:59`。

现状澄清(与用户原话的出入):用户所说「多个直线图」实为自绘横向占比条(项目**无任何图表库**,
package.json 无 echarts/@ant-design/charts 等,惯例为 inline style + CSS vars 自绘)。

## 2. 功能点明细

### F1 占比图支持条形/饼图切换

- F1.1 控制栏新增全局切换(Segmented「条形图 / 饼图」),一次切换,三处占比展示联动:
  客户端占比主展示(by_platform_class)、客户端下钻明细(by_platform)、网络环境占比(by_network)。
- F1.2 默认视图为**条形图**(保持现状,老用户零感知)。
- F1.3 饼图样式 = **环形甜甜圈**(SVG 自绘,不引图表库):
  - 环形分段颜色沿用现有 `BAR_COLOR` 映射,与条形视图同色一致;
  - 中心显示窗口去重用户总数(`totals.users`)+ 短标签;
  - 右侧(桌面)/下方(compact)图例:色点 + 名称 + `N 人 · M 次 · X%`(数值口径与条形完全一致);
  - 扇区悬浮原生 title 提示(同日趋势条形 `title` 惯例);
  - users=0 的行:不画扇区(0 角度),图例行保留(与条形视图渲染 0 宽条一致)。
- F1.4 饼图角度口径:扇区角度 ∝ 各行 users / Σ(行 users) 归一化;图例与悬浮中的
  百分比仍显示 `行 users / totals.users`(与条形视图同口径)。各节 caption 追加说明:
  「饼图扇区角度按各端数值归一化(占比之和可能大于 100% 时角度仍归满圆)」。
- F1.5 交叉表与日趋势**不参与切换**(表格/时间序列,饼图不适用)。
- F1.6 视图状态仅存内存(不进 URL、不持久化),刷新回到默认条形。

### F2 时间范围选择简化为纯日期

- F2.1 `RangePicker` 移除 `showTime`(桌面与 compact 统一纯日期面板,删除 compact 分支)。
- F2.2 选择后自动对齐:`from = 起始日 startOf('day')`(00:00:00.000),
  `to = 结束日 endOf('day')`(23:59:59.999;后端窗口 [from, to) 独占,endOf 保证末日全天覆盖)。
- F2.3 默认窗口改为 `[today-29d 00:00, today 23:59:59.999]`(整日语义,数据等价:
  未来无事件;窗口回显卡将显示 `00:00 ~ 23:59`,直观体现自动补时)。
- F2.4 序列化不变:`from`/`to` 仍传 tz-aware ISO(`toISOString()`),后端零改动。
- F2.5 汇总卡「统计窗口」格式维持 `MM-DD HH:mm`(回显 00:00/23:59 即补时效果的自证)。

## 3. 组件拆分方案

| 组件/模块 | 文件 | 职责与接口 | 来源 |
|---|---|---|---|
| `UsageDonut` | `src/components/admin/UsageDonut.tsx`(新,~150 行) | 通用环形图:props `{ centerLabel: string; centerValue: number; slices: Array<{ key: string; label: string; users: number; events: number; percent: number; color: string }> }`;SVG stroke-dasharray 分段 + 图例 + 原生 title | 新建 |
| `UsageProportion` | `src/components/admin/UsageProportion.tsx`(新,~150 行) | 三节占比展示容器:props `{ stats: UsageStatsOut; view: 'bar' \| 'pie' }`;内部按 view 为每节渲染 StatRow 列表或 UsageDonut;StatRow 自 UsageStatBars 迁入 | 改造复用(替代 `UsageStatBars.tsx`,后者删除) |
| `BAR_COLOR` | `src/components/admin/usage_shared.tsx`(修改) | 色板映射从 UsageStatBars 迁入共享(饼图/条形两视图共用,单一正本) | 改造复用 |
| `Section` / `PLATFORM_LABEL` / `NETWORK_LABEL` / `PLATFORM_CLASS_LABEL` | `usage_shared.tsx` | 不动(`PLATFORM_CLASS_LABEL` 仍在 UsageProportion 内使用,可一并迁入 usage_shared 收拢) | 复用 |
| `AdminUsageStatsPage` | `src/pages/AdminUsageStatsPage.tsx`(修改) | 新增 `view` state + Segmented;RangePicker 去 showTime + 日期对齐;引用换 UsageProportion | 修改 |

依赖与数据流:`AdminUsageStatsPage(view state)` → `UsageProportion(stats, view)` → `StatRow`(bar)或 `UsageDonut`(pie);标签/色板全部来自 `usage_shared`。api/hooks 不动。

预估文件清单:新 2 / 删 1 / 改 2,全部 ≤500 行。

## 4. 数据库修改方案

不涉及。

## 5. 接口定义

不涉及(前端内部改动;`GET /api/v1/admin/usage/stats` 的 `from`/`to`/`metric`/`daily` 契约不变)。

## 6. 前端改动点

见 §2/§3。后端改动点:不涉及。

## 7. 测试功能点

前端无测试框架(无 vitest/jest,package.json 无 test script,既有惯例 = build+lint+人工验收),
本批写**结构化用例清单**供人工/浏览器验收,自动化门槛 = `pnpm build`(tsc -b)+ `pnpm lint` 全绿:

- T1 切换交互:控制栏出现「条形图/饼图」Segmented,默认条形;切换后三处占比节联动变为环形图;再切回条形恢复原样式。
- T2 饼图内容:扇区颜色与条形同分类同色;中心显示 totals.users;图例行数值 =「N 人 · M 次 · X%」与条形行完全一致;悬浮扇区出现 title 提示。
- T3 饼图口径:构造多端重复计数数据(各行 users 之和 > totals.users)时,扇区角度归一化铺满整圆,caption 含归一化说明;users=0 行不产生扇区但图例保留。
- T4 空态/边界:全空数据仍走 Empty;单分类 100%(仅 web 有数)时饼图为整环;compact 视口图例换行到环形图下方不溢出。
- T5 日期选择:面板无时分秒;选 11-01 ~ 11-10 后请求参数 from=11-01T00:00:00+08:00、to=11-10T23:59:59+08:00(本地时区 ISO);汇总卡「统计窗口」显示 `11-01 00:00 ~ 11-10 23:59`。
- T6 默认窗口:首次打开为近 30 天整日窗口(今天为末日,回显 23:59)。
- T7 回归:metric 切换(活跃用户/登录次数)、日趋势开关、交叉表、MCP 渠道标注、无权用户提示卡、加载骨架屏均不受影响。

## 8. 模糊点与决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 饼图实现方式 | SVG 自绘环形图,不引图表库 | 项目一贯惯例(UsageStatBars/UsageStatsTable 注释明言「不引图表库」);引库代价(包体+维护)与收益不成比例 |
| D2 | 切换粒度 | 全局一个切换(控制栏 Segmented) | 一次点击全局生效最省操作;每节独立切换徒增 UI 噪音(用户未应答 AskUserQuestion,按推荐项拍板) |
| D3 | 默认视图 | 条形图 | 保持现状,老用户零感知(用户未应答,按推荐项拍板) |
| D4 | 饼图样式 | 环形甜甜圈+中心总数 | 中心空间放窗口去重用户总数这一关键数字;现代观感(用户未应答,按推荐项拍板) |
| D5 | 饼图角度口径 | 角度按行 users 归一化,标注仍用 users/totals.users | users 跨分组不可加(同一用户多端重复计数,占比之和可 >100%),饼图几何必须归一;标注口径与条形一致避免两套数字 |
| D6 | 视图状态持久化 | 不持久化(内存态) | 展示偏好轻量,刷新回默认即可,避免新增存储面 |
| D7 | to 用 23:59:59.999 还是 .999-1ms | endOf('day')(23:59:59.999) | 后端窗口 [from, to) 独占,999ms 保证末日全天覆盖;用户语义「23:59:59」即整天 |

## 9. 验收基线

- `pnpm build` / `pnpm lint` 全绿(worktree:`material-storage/web` 下);
- §7 T1-T7 由测试子智能体出清单+PM 抽查;真机/dev 部署视觉验收待合并部署后人工确认。
