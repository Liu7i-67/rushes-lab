# 浣花视界 App 完整版 · B7 协作线需求文档

> 2026-10-20 · qdev 链式第 6 批。上位方案 §8.6(审批)/§8.7(通知+我的权限)/§8.8(搜索)/
> §16 B7。worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B6 后)。
> 交付判据:三域 happy path+未读轮询真机过(PC=analyze+test)。

## 功能点明细

1. **审批中心(§8.6)**:我的→审批中心(入口 badge=待审数,**仅 me.is_system_admin 显示
   badge**——scope=all 对任意认证用户放行,非 admin 挂 badge 只见全组织噪声)。
   分段:待我审批(`GET /approvals?scope=all&status=pending`)/我发起的(`scope=self`,
   可按 status 筛选——读 web ApprovalsPage 实况);卡片=申请人+动作(access=访问/
   download=下载)+对象(素材/文件夹/项目,读实况取 target 展示字段)+用途 reason;
   通过/拒绝双按钮(带确认);**决策权由后端 enforce_admin_for_target 守门,非管理者
   403 detail 透传**;决策成功刷新列表。
2. **通知(§8.7)**:列表(时间倒序+未读橙点)+全部已读;**30s 轮询**
   `GET /notifications?limit=1` 取 unread_count(web 同款);轮询生命周期:**仅前台+已登录
   才轮询**,进后台/登出/401 即停,恢复前台立即刷一次再续周期;**单一
   PollingController**(core/,防多页面各起计时器/防重叠请求);驱动=我的 tab badge+
   我的页「通知」入口红点(全局未读,无逐项目口径);通知点击跳转:payload kind 白名单=
   approval_pending/approval_decided→审批中心;folder_invite→对应项目/文件夹(读通知
   实况取可跳转字段,无可跳转字段显通用详情);未知 kind 不崩溃不把任意 URL 交导航器。
3. **我的权限(§8.7)**:数据源=`GET /projects`(取 my_roles)+`GET /approvals?scope=self&
   status=approved`(已批准临时授权);列表=项目角色+临时授权(动作+对象+**到期倒计时**
   GrantCountdown 同款,读 web 实况);**勿按逐夹 grants 拼凑**(后端无聚合端点)。
4. **搜索(§8.8)**:tab2 替换占位:聚焦搜索框+**防抖 ~300ms+取消过期请求**(防旧结果
   覆盖新输入);结果列表=缩略图+文件名命中高亮+归属(项目/文件夹,读实况字段)+类型
   徽标;点击→push 预览(结果序列做胶片条);**50 截断提示**(web 同款文案);空态/无结果
   态;搜索端点=GET /assets/search(参数读实码)。
5. **数据新鲜度**:审批决策成功→通知 badge 下轮刷新;mark-read 成功→红点即时更新。
6. **架构**:features/{approvals/(approvals_page,approval_card),notifications/
   (notifications_page,notification_row),permissions/(my_permissions_page,grant_row),
   search/(search_page,result_row)};core/polling_controller.dart;core/api/
   {approvals_ops_api(决策),notifications_api,search 并入 assets_api};models 补
   {approval,notification};单文件 ≤200 目标/300 硬顶;不引新包。

## 数据库/后端改动

不涉及。契约自查(实码):approvals.py(列表筛选参数/卡片字段/approve/reject 端点与
入参);notifications.py(列表/mark-read/已读语义);assets.py search(参数/响应/截断);
web 对标 ApprovalsPage/NotificationsPage/MyPermissionsPage/SearchPage/GrantCountdown。

## 测试功能点

1. 审批:scope 口径(待审=all&pending/发起=self);badge 仅 admin;决策确认+403 透传;
   决策后刷新。
2. 通知:轮询生命周期(前台+登录起/后台/登出/401 停/恢复前台立即刷);badge/红点驱动;
   全部已读;kind 白名单跳转三分支。
3. 我的权限:双数据源合并;倒计时格式(GrantCountdown 同款);永久/到期展示。
4. 搜索:防抖(300ms 内多次输入只发末次);取消过期请求(旧响应不覆盖新输入);高亮;
   50 截断提示;结果序列进预览。
5. PollingController:单一实例;防重叠(上轮未完不发下轮);恢复前台立即刷。
6. 回归:现役 295 用例全绿。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 通知点击跳转字段以 notifications 实码为准(无 link 字段则 kind 白名单+通用详情) | 后端实况优先 |

## 项目约定

同前批。
