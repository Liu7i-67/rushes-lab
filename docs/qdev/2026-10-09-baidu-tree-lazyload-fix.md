# 网盘目录树子节点懒加载修复 — 需求文档

日期：2026-10-09 ｜ 流程：qdev ｜ 状态：定稿
分支：`fix/baidu-tree-lazyload`（基于 `feat/baidu-folder-browse` `28a2ed4`，worktree 复用）

## 背景与根因（调查报告结论，勿重新调查）

- 现象（baidutest 真机复现）：新建备份任务弹窗中点开「备份测试」，`GET /backup/netdisk/folders` 返回正确子级（二级目录 + 3 个 txt），**前端树不渲染任何子节点**；再点也不重新请求。根目录节点（含文件行）渲染正常。
- 根因（双重实锤）：
  1. **rc-tree 源码**（`@rc-component/tree@1.3.1` `Tree.js` `onNodeLoad`，703-761 行）：`loadData(treeNode)` 的 promise `.then()` 只做「标记 loadedKeys + 清 loading + resolve()」，**resolve 的返回值从未被使用**——loadData 里 return 的节点数组被直接丢弃；节点被标记已加载 → 展开为空 → 不会再触发加载。
  2. **浏览器复现**（2026-10-09，baidutest：登录→新建备份任务→点击备份测试）：节点 selected 生效、无子节点出现。
- antd 官方懒加载模式要求：**在 loadData 内部把子节点 setTreeData 合并进受控 treeData**，再 resolve。
- 该缺陷自 research 初版即存在（同一写法），解释 007 最初反馈「点开文件夹看不到子文件夹」的一半症状；此前归因于 folders_only 不完整。
- 测试未覆盖原因：后端集成只测 API；前端无浏览器级树交互测试；静态审查只验证了 reject 路径。

## 功能点明细（验收级）

- **F1 子节点正确挂载渲染**：点击目录展开后，该目录的子目录与文件行（沿用上一轮的文件行渲染：灰显不可选+大小）正确出现在树中；可继续逐级展开子目录。
- **F2 失败路径保持**：loadData 失败 → toast 报错 + re-throw，节点保持未展开可重试（rc-tree reject 不置 loadedKeys）；不改上一轮语义。
- **F3 刷新按钮语义不变**：`treeVersion` 重挂载清空已加载状态重新从根拉取。
- **F4 无行为回归**：选中目录（已选来源）、创建任务链路、根目录文件行渲染均不变。

## 数据库修改方案 / 接口定义

不涉及（纯前端修复）。

## 前端改动点（`material-storage/web/src/components/BaiduNewTaskModal.tsx` 单文件为主）

- loadData 改官方模式：fetch 到 `{list, truncated}` 后，**setTreeData 递归合并**——按 `node.key` 找到目标节点，把 `toNetdiskNodes(key, list, truncated)` 挂为其 `children`（整体替换该节点 children），然后 resolve（返回值可不返回）；重复展开已加载节点不重复请求（rc-tree loadedKeys 天然保证）。
- 合并 helper 用纯函数（便于自查）：`attachChildren(treeData, parentKey, children)` 深拷贝式更新，未命中 key 原样返回。
- 注意：树节点是受控 `treeData` state，根目录 useEffect 已有 setTreeData——合并逻辑与根加载共用同一 state。

## 后端改动点

不涉及。

## 测试功能点

1. 〔浏览器〕复现步骤反向验证：baidutest 登录 → 新建备份任务 → 展开「备份测试」→ 出现「二级目录」目录行 + 3 个 txt 文件行（灰显带大小）；再展开「二级目录」→ 出现其子内容。
2. 〔浏览器〕失败路径：断网/错误注入下展开目录 → toast 报错、节点可重试（不强求自动化，人工/PM 浏览器验收）。
3. 〔静态〕`pnpm --dir web build` + `lint` 绿；后端测试零改动零回归。
4. 〔回归〕既有 411 过/3 基线遗留/1 跳不变（本修复不动后端，跑一次全量确认）。

## 模糊点与决策记录

- **D1（PM）**：采用 antd 官方模式（loadData 内 setTreeData 挂 children），不做 expandedKeys 全受控重写——改动最小、与现有 state 结构一致。
- **D2（PM）**：children 整体替换式合并（重复加载同节点以最后一次为准）；不引入增量 diff。
- **D3（PM）**：本轮不处理轮询频率优化（用户未要求；调查报告已说明为设计行为）。
- **D4（PM）**：浏览器级验证由 PM 亲手做（子智能体无浏览器设施），作为本周期验收主证据。
