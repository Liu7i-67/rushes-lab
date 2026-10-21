# 浣花视界 App 完整版 · B6 文件夹+项目管理需求文档

> 2026-10-20 · qdev 链式第 5 批。上位方案 §8.4(文件夹管理)/§8.5(项目管理)/§16 B6。
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B5 后)。
> 交付判据:管理动作全量;权限闸门正确。

## 功能点明细

1. **文件夹管理(§8.4,点亮 B5 的 ⋯ 菜单占位)**:
   - 新建子夹(名称+敏感开关);重命名;移动(MoveFolder 同款选择器=项目内夹树,
     目标不含自身子树);删除(**仅空夹硬删**——非空 409 detail 透传「请先删除其中
     所有文件/回收站内还有已删除文件」,勿做软删暗示;确认文案明示不可恢复);
   - **敏感夹邀请**(邀请(**含有效期预设**——读 web FolderInvitePanel 实况档位)+
     撤销+成员列表);
   - **授权管理**(grants 列表+添加(选人/组+多 level viewer/downloader/uploader)+
     撤销;**无有效期/倒计时**(后端只收 levels+主体恒永久);**入口仅普通一级夹
     显示**(后端三端点强制 level-1,敏感夹 400 指引 invite/members,子夹无此入口));
   - 入口显隐读 web AssetSummaryPanel 实况对齐(0 选+敏感→invite;0 选+普通一级→
     grants;管理动作 my_can_admin)。
2. **新建项目(§8.5,ProjectCreateIn 实况)**:名称/code(小写字母数字连字符,前端
   pattern 同后端)/描述+**项目管理员(必填,默认=创建者,选人器)**+**minio_bucket
   (必填,默认 'ms-dev',收进高级折叠)**+权限模板(**模板条目展开为 initial_grants
   行**提交,可增删改,50 条上限;后端无模板 id 入参——模板列表读 admin grant-templates
   读端点,project creator 可读)+目录模板预填(folder_template_id)+**艺人账号可选
   开通**(闸门 is_artist_account_creator;登录名停顿预检 GET /users/username-available;
   成功回显一次性密码可复制仅此一次);**无「可见性」字段**;总闸门 is_project_creator。
3. **项目成员管理**:成员列表+添加(**SubjectPicker 用户/组+RoleChipGroup 角色**)+
   移除+grants(读 web ProjectMembersDrawer 实况:端点/角色枚举/移除确认)。
4. **已删除项目**:列表+恢复;入口=我的→回收站(项目),**仅 is_project_deleter 可见**
   (B1 我的页骨架已有占位入口,点亮)。
5. **选人/组组件(§9)**:`widgets/pickers/`(SubjectPicker/UserPicker 移动版,搜索+
   用户/组分段;三处复用=项目成员/夹授权/B8 建用户;本批建,B8 复用)。
6. **数据新鲜度**:夹/项目写操作成功→invalidate folders/projects scope。
7. **架构**:features/folders/{folder_form_sheet,move_folder_sheet,folder_invite_sheet,
   folder_grants_sheet};features/projects/{new_project_sheet,project_members_sheet,
   deleted_projects_page};core/api/{folders_ops_api,projects_ops_api,admin_templates_api,
   users_api(简表+username-available)};单文件 ≤200 目标/300 硬顶;不引新包。

## 数据库/后端改动

不涉及。契约自查(实码):folders.py create/patch(move=PATCH parent)/delete/invite/
members/grants;projects.py create(ProjectCreateIn 全字段)/members 族/deleted/restore;
admin.py grant-templates 读端点+folder-templates 读端点(新建项目模板预填拉列表);
users.py 简表+username-available;web 对标 FolderInvitePanel/FolderGrantsPanel/
NewProjectModal/ProjectMembersDrawer/RoleChipGroup/SubjectPicker/UserPicker。

## 测试功能点

1. 夹 CRUD:新建(敏感开关)/重命名/移动(目标不含自身子树)/删除(空夹 204,非空 409
   detail 透传,确认文案含不可恢复)。
2. 敏感夹邀请:有效期预设档位=web 实况;邀请+撤销;仅敏感夹显示。
3. 授权管理:添加(主体 user/group+多 level)/撤销;仅普通一级夹显示;无有效期控件。
4. 新建项目:必填校验(bucket/admin)/code pattern/initial_grants 展开(模板选择→行
   展开→增删改→≤50)/目录模板选择/艺人账号(闸门+预检+一次性密码回显)/成功进项目
   列表刷新。
5. 成员管理:列表+添加(用户/组×角色)+移除;角色枚举=web 实况。
6. 已删除项目:列表+恢复;非 is_project_deleter 不可见。
7. pickers:搜索+用户/组分段;选中回显。
8. 回归:现役 232 用例全绿。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 有效期档位/角色枚举/模板交互以 web 组件实码为准 | 「与 web 同款」口径 |
| 2 | minio_bucket 高级折叠默认 ms-dev | web 同款默认,防普通用户困惑 |

## 项目约定

同前批。
