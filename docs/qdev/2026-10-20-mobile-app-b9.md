# 浣花视界 App 完整版 · B9 百度用户侧+收尾需求文档

> 2026-10-20 · qdev 链式第 8 批(终批)。上位方案 §8.10(百度用户侧)/§8.11(请求链接)/
> §8.12(维护横幅)/§16 B9。worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`。
> 交付判据:绑定闭环真机过;§1 矩阵逐行勾检。

## 功能点明细

1. **百度备份用户侧完整页(§8.10)**:我的→网盘备份(baidu_backup_enabled 显隐):
   - 绑定:B0 bind_code_page 平移挂入(oob 流程不变);
   - 网盘目录树懒加载(GET /baidu/backup/netdisk/folders,参数读实码;懒加载=展开
     拉子级,loading/空/错误态);
   - 新建任务向导:选项目+承接夹(项目内夹树,含新建承接夹?——读 web
     BaiduNewTaskModal 实况)+源目录(网盘树选定)→POST tasks(同名默认跳过,向导
     无覆盖选项——覆盖是任务详情逐文件后置操作);
   - 任务列表(用户视角,自己的任务):状态/进度+取消/重试失败/删除+任务详情
     (文件明细+文件级三操作:重试(non_retryable 置灰)/覆盖导入/随机后缀导入,
     key_conflict 分流——复用 B8 baidu_file_actions);
   - 频控与 key 冲突语义透传后端文案。
2. **请求链接(§8.11)**:项目页菜单+项目内页(文件夹页)菜单「请求链接」
   (RequestLinkCreateModal 移动版;**入口闸门同 web**:项目页=my_roles 含 admin,
   项目内=folder admin(my_can_admin);非 admin 不露出);创建即复制(+可选浏览器
   打开落地页);POST /request-links 入参读实码。
3. **维护横幅(§8.12)**:GET /maintenance/banner **前台即轮询不分登录态**(与通知
   轮询共用 PollingController 节拍但门控不同);active=true 立即弹**不可关闭**全局
   提示;active true→false 显「升级完成」数秒自动关;网络错误不误判完成
   (lastKnownActive 兜底);登录页(未登录)同样轮询展示。
4. **错误边界**:全局 ErrorWidget.builder 兜底(渲染异常→友好页+日志,不白屏);
   RunZonedGuarded 已有(AppLog)核对。
5. **全周期遗留清偿(测试者挂账)**:
   - 通知分页(B7):列表加载更多(offset)+全部已读按钮恒显(不依赖前 100 条);
   - **全 API 层 5xx 统一兜底**(B5 技术债):MsApi 层面统一 guard(方案:所有域
     API 的 5xx DioException→ApiException 中文 fallback)——评估最小实现(如
     Dio 拦截器统一转,或各域包 guard5xx),按工程最简落地;
   - 对象型 detail 渲染(B2 P2-6):extractDetail 对 Map 型 detail 取
     message/code 字段拼友好文案,不再裸 toString;
   - changePassword 后 me 刷新吞异常(B0 批):刷新失败不吞(至少日志+会话标脏,
     下次 me() 兜底)。
6. **架构**:features/baidu/(baidu_page/netdisk_tree_sheet/new_task_sheet/
   task_detail_page——bind_code_page 已有);features/share/request_link_sheet;
   core/maintenance/(banner_controller);单文件 ≤200 目标/300 硬顶;不引新包。

## 数据库/后端改动

不涉及。契约自查(实码):baidu_backup.py 用户侧族(netdisk folders/tasks 列表
详情/文件分页/cancel/retry-failed/删除/文件三操作);request_links.py(创建入参/
响应);maintenance.py(banner 响应形态)。

## 测试功能点

1. 网盘树懒加载(展开拉子级/叶子无展开/错误态重试)。
2. 新建任务向导(源目录必选/承接夹必选/提交入参=实码;成功后任务列表刷新)。
3. 任务列表(状态筛选/取消/重试失败/删除确认)+详情文件三操作分流(B8 复用件回归)。
4. 请求链接(双入口闸门/创建即复制/失败 toast)。
5. 维护横幅(active 弹不可关/完成自动关/网络错误不误判/未登录也轮询)。
6. 通知分页(加载更多/全部已读恒显)。
7. 5xx 统一兜底(任一域 API 500→中文文案,无 DioException 字样)。
8. 对象 detail 渲染({code,message}→message)。
9. 回归:现役 366 用例全绿;§1 矩阵逐行自查清单(汇报中给出勾检结论)。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 5xx 兜底实现方式由实现者按最简评估(拦截器 or 逐域包) | 工程最简优先,语义=中文 fallback |

## 项目约定

同前批。
