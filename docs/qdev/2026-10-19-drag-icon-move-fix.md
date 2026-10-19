# 需求文档:目录树拖拽图标移除 + 批量移动弹窗「幽灵成功」修复

> qdev 需求存档,2026-10-19。**唯一需求依据为已定稿方案**
> `rushes-spec/material-storage/folder-drag-icon-and-batch-move-fix-plan.md`(下称「方案」),
> D1/D2/D3 已由用户拍板落决议(方案 §5),本文不重复论证,只定实施契约。
> 纯前端改动,后端零触碰。

## 背景与目标

六项优化(2899dcd)上线后两项用户反馈:①PC 侧栏目录树每行拖拽把手图标(antd 默认
HolderOutlined)占宽,挤压目录名;②批量移动弹窗在同一页面会话内成功移动过一次后,
再移其他文件会直接显示上一次的「批量移动结果」成功弹窗,本次文件从未提交也未移动
(幽灵成功弹窗,组件状态残留)。目标:藏图标保拖拽、修状态残留,顺带两项体验打磨。

## 功能点明细(逐条可验收)

| # | 功能点 | 验收标准 |
|---|---|---|
| F1 | 拖拽把手图标隐藏(D1) | PC 侧栏目录树节点不再渲染 ⠿ 把手图标(`.ant-tree-draggable-icon` 零残留),目录名左移回收宽度;拖拽换父功能完整保留(抓节点标题拖动),sensitive 三句式 allowDrop 预判与落点确认弹窗行为不变 |
| F2 | 幽灵成功弹窗修复(D2=修法 A) | `BatchMoveAssetsModal` 改为调用方条件挂载(`{batchMoveOpen && …}`);同一会话内完成一次移动后再为其他文件打开移动弹窗,必须出现目标选择视图(标题「移动 N 个文件」),无 result/target 残留(无预选目标目录) |
| F3 | P2-1:0 移动结果降级 warning | 结果视图 `moved_count === 0` 时 Alert type=warning 且 message=「本次未移动任何文件(共提交 N 个)」;`moved_count > 0` 仍 success 绿色;`fga_pending > 0` 的 warning 语义不变 |
| F4 | P2-2:目标树禁选源夹自身 | 批量移动弹窗目标树中当前夹(sourceFolderId)节点 disabled 置灰;其**子夹仍可选**(A 夹文件移入 A/B 子夹可用——级联误伤是红线);既有 `disabledIds` 整子树级联语义(备份目标选择 sensitive 集合等使用点)零变化 |

## 数据库修改方案

**不涉及**(纯 web 层)。

## 接口定义

**不涉及**(零新端点、零入参出参变化;仅消费既有 `POST /api/v1/assets/batch-move`)。

## 前端改动点(3 文件)

1. `material-storage/web/src/components/FolderTree.tsx`
   - `draggable={enableDrag ?? false}` 改 `draggable={enableDrag ? { icon: false } : false}`
     (antd 6.4.2 + @rc-component/tree 1.3.1 已核验:`icon:false` 时整段把手 span 不渲染,
     零残留零 CSS;附注释说明拖拽能力在节点内容 wrapper 上、隐藏把手不影响拖拽);
   - 新增可选 prop `disabledSelfIds?: string[]`:仅禁选命中节点**自身**,不级联子树。
     实现要点:buildTree 把「级联源」与「节点 disabled」拆开——子级联仍只看
     `ancestorDisabled || disabledSet.has(f.id)`,节点自身 disabled 额外 `|| selfSet.has(f.id)`;
     useMemo 依赖同步补;Props 注释写明与 `disabledIds`(整子树级联)的语义区别。
2. `material-storage/web/src/components/BatchMoveAssetsModal.tsx`
   - 新增 prop `sourceFolderId?: string | null`,接到 FolderTree 的 `disabledSelfIds`
     (传 `sourceFolderId ? [sourceFolderId] : undefined`);
   - 结果视图 Alert:`type={pendingCount > 0 || result.moved_count === 0 ? 'warning' : 'success'}`;
     message 在 `moved_count === 0` 时改「本次未移动任何文件(共提交 ${submitted} 个)」,
     对账 description 行不变;
   - `destroyOnHidden` 保留不删(防御未来改回常挂载)。
3. `material-storage/web/src/pages/ProjectDetailPage.tsx`
   - `<BatchMoveAssetsModal open={batchMoveOpen} …>` 常挂载改
     `{batchMoveOpen && (<BatchMoveAssetsModal open … sourceFolderId={activeFolderId} … />)}`
     (与同 modals 片段 RenameFolderModal/MoveFolderModal 模式对齐;onClose/onMoved 回调
     语义不变)。

## 后端改动点

**不涉及**。

## 测试功能点

- T1 静态:三文件 diff 与上文逐条一致,无越界改动;`pnpm lint`、`pnpm build`(含 tsc)
  零错误;build 产物输出路径不跑偏。
- T2 GUI 用例清单(web 层无单测基建,按方案 §3 执行;真机通道归 tester):
  1. PC 侧栏树无 ⠿ 图标、目录名左移、长名省略号不回归;
  2. 抓标题拖到目标夹/gap 均弹确认框;sensitive 源拖不动、sensitive 目标及其子树禁入、
     自身后代禁入(三句式不回归);确认后移动成功、树刷新;
  3. 移动完整流:选 2 文件→移动→选目标→提交→结果计数正确→完成→源夹消失/目标夹可见;
  4. **幽灵弹窗回归(核心)**:完成一次移动后再选其他文件点「移动 N 个文件」→出现
     目标选择视图而非上次结果;取消重开同样干净(无预选目标);
  5. compact 布局(移动端工具栏入口)同验 3/4(modals 单实例两态同愈);
  6. 结果态 X/「完成」走 onMoved 清选中,选择态取消走 onClose 保留选中(语义不回归);
  7. **P2-2 回归(防级联误伤)**:目标树源夹自身置灰;A 夹文件移入 A/B 子夹全流程可用;
     备份目标选择(如百度备份选目标)的 sensitive 整子树禁选照旧;
  8. **P2-1**:全 skip 提交→warning 黄色「本次未移动任何文件」;moved>0 仍绿色;
     fga_pending>0 warning 不回归。

## 模糊点与决策记录

无新增模糊点。D1(保留拖拽只藏图标)/D2(修法 A 条件挂载)/D3(P2 两项带上,其中
P2-2 按方案勘正实现 `disabledSelfIds` 不级联,勿用 `disabledIds`)均已于 2026-10-19
由用户拍板,详见方案 §5 决策表。**实施红线:不得把源夹塞进既有 `disabledIds`**
(会级联禁掉子夹,误伤「A 夹文件移入 A/B 子夹」合法操作)。

## 项目约定

- worktree:`E:/qbb/github_not_me/rushes-lab-feat-drag-icon-move-fix`(分支
  `feat/drag-icon-move-fix`,基线 liuqi cc4aee3),所有改动在 worktree 内进行;
- web 构建:`cd material-storage/web && pnpm install && pnpm lint && pnpm build`
  (产物直接输出到 `../api/app/static/web/`,不要动这个行为);
- 代码风格沿用各文件既有内联样式/注释密度,新增注释只写约束不写叙事;
- 不碰 `api/`、不碰迁移、不碰 FGA、不部署(部署/合并 liuqi 由用户另行拍板)。
