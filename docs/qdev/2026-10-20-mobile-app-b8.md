# 浣花视界 App 完整版 · B8 管理后台需求文档

> 2026-10-20 · qdev 链式第 7 批。上位方案 §8.9(管理后台)/§16 B8。
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B7 后)。
> 交付判据:admin 真机全流程;非 admin 不可见。

## 功能点明细

1. **管理入口(§2/§8.9)**:我的页「管理」区(仅 is_system_admin;**目录模板例外**=
   `is_folder_template_manager ?? is_system_admin` 单独放行,持 flag 非 admin 进 App
   仅见目录模板入口)。子页:用户/组/审计/权限模板/目录模板/备份任务。
2. **用户管理**:列表(搜索/分页)+建用户(**带组**,一次性临时密码回显可复制——读
   web 实况)+编辑(姓名/邮箱/启停)+重置密码(一次性回显)+解锁(读 web 实况:解锁
   条件与端点)。
3. **组管理**:列表+建/编(名称/描述)+成员管理(加/移;读 web 实况)。
4. **审计**:筛选(事件类型/对象/主体/时间——读 web 实况筛选项)+分页列表+
   **CSV 导出**(**dio 带会话下载**→Android media_store_plus 存 Downloads/iOS
   share_plus;禁 url_launcher)。
5. **权限模板**:列表+建模板(主体行×独立角色,50 条上限)+编辑+删除+**应用默认**
   (多项目批量勾选→逐项目刷新,require_system_admin;全 App 唯一应用默认入口)。
6. **目录模板**:列表+建(条目路径校验——读 web 实况)+编辑+删除(闸门
   is_folder_template_manager)。
7. **百度任务(管理)**:全量任务列表(状态筛选)+详情+文件明细分页(读 web
   AdminBaiduTasksPage 实况;含文件级三操作入口或详情内操作——§1 已定纳入:
   重试(non_retryable 置灰)/覆盖导入/随机后缀导入,key_conflict 分流)。
8. **pickers 复用**:B6 widgets/pickers 在建用户/组成员处复用(users 简表 limit=20
   不翻页的 B6 遗留——本批建用户走 UserPicker 时注意,如需更多候选读实况决定
   是否补分页,或保持 web 同款行为)。
9. **架构**:features/admin/(admin_home+六子页+表单拆件);core/api/
   {directory_api,audit_api,admin_baidu_api};单文件 ≤200 目标/300 硬顶;不引新包
   (media_store_plus/share_plus/dio 均在)。

## 数据库/后端改动

不涉及。契约自查(实码):directory.py(用户/组全族:建用户带组入参/临时密码响应/
启停/重置/解锁/组成员);admin.py(audit 筛选参数/export.csv 响应头与流/grant-
templates 全族/apply-default 入参与响应/baidu-backup admin 族);web 对标
AdminUsersPage/AdminGroupsPage/AdminAuditPage/AdminGrantTemplatesPage/
AdminFolderTemplatesPage/AdminBaiduTasksPage+ApplyDefaultModal。

## 测试功能点

1. 用户:建用户带组+一次性密码仅回显一次;启停/重置/解锁入口与确认。
2. 组:CRUD+成员加移。
3. 审计:筛选参数正确;q 筛选联动;CSV=dio 下载(Android Downloads/iOS share),
   禁 url_launcher(静态断言)。
4. 权限模板:建(主体行×角色≤50)/编辑/删/应用默认(多选批量+结果逐项目呈现——
   读 web ApplyDefaultModal 实况)。
5. 目录模板:建(路径校验=web 实况)/编/删;仅 folder_template_manager 闸门。
6. 百度任务:列表状态筛选/详情/文件明细分页/文件级三操作(key_conflict 分流)。
7. 入口:非 admin 不可见;仅 folder_template_manager 者仅见目录模板。
8. 回归:现役 329 用例全绿。

## 决策记录

| # | 决策 | 理出 |
| --- | --- | --- |
| 1 | 管理表单接受「可用不追求等效 PC 效率」(方案 R7) | 移动端简化=分段/chip 筛选 |
| 2 | 建用户/组成员 pickers 沿 B6 组件(users limit=20 维持 web 同款行为,不足记遗留) | 复用优先 |

## 项目约定

同前批。
