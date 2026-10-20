# 浣花视界 App 完整版 · B5 素材操作线需求文档

> 2026-10-20 · qdev 链式第 4 批。上位方案 §8.2(详情打标)/§8.3(操作栏)/§8.4(回收站)/
> §16 B5。worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B4 后)。
> 交付判据:批量操作全对标 web;403 边界文案正确。

## 功能点明细

1. **操作栏全量(§8.3,在 B4 操作栏壳上点亮)**:四键+溢出菜单:
   - **分享**(**仅恰好单选可用**,多选置灰;有效期四档(同 web:1 天/7 天/30 天/自定义?)——
     以 web ShareModal 实况为准读代码;requires_login 恒 true 不做开关;创建→复制链接+
     可选 url_launcher 浏览器打开;表单无提取码/下载开关);
   - **移动**(BatchMove 移动版:**仅文件夹一级选择,项目固定=所选资产所属项目**——后端
     一期断言整批同项目,目标夹选择器=当前项目的夹列表(含树缩进);混批多项目时整批
     禁用并提示);
   - **删除**(确认弹窗;软删;403/409 detail 透传);
   - **下载**(B4 已亮,不动);
   - ⋯ 菜单:**批量打标**(user_labels≤50+notes;模式选择 merge/replace,默认 merge=web
     批量实况;逐 id PATCH)、**批量前缀**(add/remove 两模式,前缀文本校验——读 web
     BatchPrefixModal 实况)、**申请权限**(**仅恰好单选可用**;RequestAccess 移动版:
     动作=访问 access(仅 target_type=sensitive_folder 可选)/下载 download(必填
     duration_seconds 有效期预设)+用途说明 reason 必填 ≥4 字;后端无「编辑」动作勿做)。
2. **回收站(§8.4)**:文件夹 ⋯ 菜单点亮「回收站」项:软删资产列表(GET /assets/trash,
   参数以实码为准)+恢复(POST restore)+分页;入口显隐=普通夹 folder admin 或删除
   授权者(读 web canSeeTrash 口径:my_can_admin 或 my_delete_grant;sensitive 夹仅
   系统 admin)。
3. **详情打标(§8.2)**:预览页元数据卡「编辑」点亮:AssetTagEditor 移动版(user_labels
   ≤50+notes;labels_mode 单条默认 replace 不传,web 实况);保存后 invalidate。
4. **预览页分享/申请钮点亮**:分享=单资产 ShareModal 同款;申请=my_can_download==false
   时「申请权限」入口可点(同款表单)。
5. **数据新鲜度**:删除/移动/打标/前缀/恢复成功→invalidate assets+folders scope。
6. **架构(§9)**:features/assets/{batch_tag_sheet,batch_prefix_sheet,batch_move_sheet,
   share 相关};features/share/(share_create_sheet);features/preview/ 申请入口;
   widgets/pickers/(§9 三处复用选人组件 B6 才需要,本批不做);单文件 ≤200 目标/300
   硬顶;不引新包。

## 数据库/后端改动

不涉及。契约自查(实码为准,方案钉子):share.py ShareCreateIn/ShareCreateOut;
assets.py batch-prefix/batch-move/meta/trash/restore;approvals.py ApprovalCreateIn。

## 测试功能点

1. 分享表单:四档有效期为 web 实况口径;仅单选可用;创建后复制到剪贴板。
2. 移动:项目固定/目标夹树/混批多项目禁用;成功 invalidate。
3. 批量打标:merge/replace 入参正确(labels_mode 字段);≤50 校验。
4. 批量前缀:add/remove 入参;空文本校验(读 web 实况对齐)。
5. 申请权限:access 仅敏感夹可选;download 必填 duration;reason≥4 前端校验+后端
   422 透传;仅单选。
6. 回收站:列表+恢复+入口显隐三态(普通夹 admin/删除授权/敏感夹系统 admin)。
7. 删除:确认+403/409 detail 透传文案。
8. 回归:现役 189 用例全绿。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 有效期档位/前缀校验规则以 web 组件实码为准 | 方案口径「与 web 同款」 |

## 项目约定

同前批。
