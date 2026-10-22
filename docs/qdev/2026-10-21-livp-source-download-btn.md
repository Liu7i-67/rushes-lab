# 需求文档:PC 单文件详情面板「下载源文件」按钮

> 日期:2026-10-21 · 分支:`feat/livp-source-download-btn`(基线 liuqi ba227b9)

## 背景与目标

livp 下载默认交付服务端解包 zip(含全分辨率 jpg+mp4);部分极限场景用户需要 **livp 源文件本身**(如回传 iPhone)。预览弹窗已有文字级「下载原始 .livp」入口(上期 F14),但**单文件选中的详情面板(右栏 AssetSummaryPanel)没有**——本期在该面板下载按钮旁新增「下载源文件」按钮,并统一两处文案。

## 功能点明细

- **F1** `AssetSummaryPanel`(右栏文件详情面板):livp 资产的 QuickActions 区「下载」旁新增「下载源文件」action,调 `downloadAsset(deps, a, { forceOriginal: true })`(既有链路,零后端改动);403 处理与「下载」同款(现有 catch 分支)。
- **F2** 门控:仅 livp 资产显示(非 livp 源文件=本体,按钮无意义);无下载权限时与「下载」走同一门控(现有 `canDownload`/QuickAction 显隐逻辑,不新增语义)。
- **F3** 文案统一:预览弹窗(AssetPreviewModal)既有「下载原始 .livp」文字次选项更名「下载源文件」,行为不变。

## 数据库修改方案

不涉及(零后端:variant=original 原始链路既有)。

## 接口定义

不涉及(复用 `POST /assets/{id}/download-link` 不带 variant = 原始 livp)。

## 前端改动点 / 后端改动点

- 前端:`components/AssetSummaryPanel.tsx`(QuickActions + 处理函数)、`components/AssetPreviewModal.tsx`(仅文案)。
- 后端:不涉及。

## 测试功能点(前端无 test runner → 结构化手测清单 + lint/build)

1. 详情面板选中 livp → 出现「下载源文件」;点击 → 保存框文件名为 `原名.livp`,下载内容为原始 livp(非 zip)。
2. 详情面板选中非 livp(jpg/mp4)→ 不出现该按钮。
3. 无下载权限资产的详情面板 → 「下载源文件」与「下载」同门控(同显隐/禁用)。
4. 预览弹窗「下载源文件」(原「下载原始 .livp」)→ 行为不回归(forceOriginal 原始下载)。
5. 回归:四入口正常下载、livp 默认解包 zip 下载、批量下载均不受影响;`npm run lint`/`npm run build` 绿。

## 模糊点与决策记录

| # | 决策 | 理由 |
|---|------|------|
| D-1 | 「详情界面」= 右栏 AssetSummaryPanel(单文件选中详情);预览弹窗已有等价入口,仅统一文案 | 用户原话"单个文件选中的详情界面的下载按钮旁";预览弹窗为 F14 已交付能力,避免重复造入口 |
| D-2 | 仅 livp 显示;权限门控复用「下载」现有逻辑 | 非 livp 源文件=本体无意义;不引入新权限语义 |
| D-3 | 按钮形态跟随现有 QuickAction 惯例(icon+label) | 与面板内「下载/预览/申请下载」视觉一致 |
| D-4 | 自行拍板(小需求,无高价值分歧点):用户措辞已明确落点与行为 | qdev 第 1 步裁量 |
