# 浣花视界 App 完整版 · B0+B1 批需求文档

> 2026-10-20 · qdev 周期。上位文档=方案 v2.2 定稿:
> `rushes-spec/material-storage/mobile-app-full-version-plan.md`(八轮盲审已定,以它为唯一口径)
> 本批范围=方案 §16 的 **B0 技术验证批 + B1 基建批**。开发全程在 worktree
> `E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b0-b1`(分支 feat/mobile-app-b0-b1)。

## 背景与目标

App 现状=MVP(material-storage/app/,扁平结构,登录+项目/文件夹/宫格+livp 上传下载)。
完整版方案把 App 对标 web 全量功能,按 §16 十批交付。本批做前两批:

- **B1 基建**:目录重构到 §9 目标结构 + 主题令牌(§10) + Session 探活(§4) + 登录简化 +
  改密页(含强制流) + HomeShell 四 tab + 我的页骨架。交付判据:探活双端真机过;
  强制改密闭环;旧功能不回归(浏览/上传/下载/livp 全链路可用)。
- **B0 技术验证**(代码部分):①百度绑定 oob 复制码流程页;②Android 落盘 PoC
  (photo_manager 图库 + media_store_plus Downloads)。真机闭环验证由用户执行,
  子智能体交付可运行、可自测的代码与入口。

## 功能点明细(B1)

1. **目录重构(§9)**:main.dart 拆 main/app/theme;api→core/api;models.dart→models/
   按域拆;pages→features/{auth,shell,projects,folders,assets};services 四文件平移;
   新增 core/session.dart、core/fmt.dart、widgets/ 基础件(EmptyState/ErrorView/Badge)。
   **硬约束:单文件 ≤200 行目标、300 硬顶**。现役 12 个 dart 文件全部有去处,无孤儿。
2. **Session 探活(§4 定稿)**:冷启动按序探测 `GET /healthz`(免鉴权,connectTimeout 3s):
   ①`--dart-define=MS_API_BASE`(仅开发构建,不进 UI) ②`http://192.168.110.221`
   ③`https://bucket.taoxiplan.com`。命中即用;全失败→登录页「服务不可达·重试」横幅
   (重按重探)。**删除**:登录页 dev/prod/custom 切换 UI、`ms_api_base` 手动持久化、
   `kDevEntry` 预设(47.108.196.211:8080 不在探活序列,dev 调试一律走 dart-define)。
   保留 cookie 会话持久化(重启免登录);运行中不热切换 baseUrl。我的页只读显示当前入口
   (内网/公网)。kAppBuildStamp 注入机制保留(项目页标题)。
3. **登录简化**:登录页只剩 用户名/密码/登录 + 维护横幅位(B9 填充) + 右上日志推送出口
   (登录失败兜底,现役平移)。401 单次触发清会话跳登录(去抖,并发多请求只弹一次)。
4. **改密页+强制流(§2)**:Me 返回 `must_change_password=true` → 只放行改密页
   (改密/退出可走),改完进入 HomeShell。改密页字段口径对标 web ChangePasswordPage
   (旧密码/新密码/确认;后端 POST /api/v1/auth/change-password,入参以
   material-storage/api/app/routers/auth.py 实际契约为准,动手前先读)。
5. **HomeShell(§2)**:IndexedStack 四 tab + TabBar。tab1=项目(现役 ProjectsPage
   功能平移,kAppBuildStamp 标题保留);tab2 搜索/tab3 传输=占位页(「即将上线」,
   B2/B3 交付);tab4=我的。路由仍命名路由+Navigator.push,不引 go_router。
6. **我的页骨架(§2)**:账号信息行(用户名/角色)+ 账号与安全(改密入口)+ 诊断
   (日志推送入口,现役 log_push 平移)+ 当前服务入口(只读,内网/公网标识)+ B0 验证入口
   (见 B0)+ 退出登录(POST /auth/logout,清会话回登录页)。
7. **主题令牌(§10)**:theme/tokens.dart 全部色值 + app_theme.dart
   (ColorScheme.fromSeed(0xFFC2410C) 起步精调,卡片圆角 20,tabularFigures)。

## 功能点明细(B0)

8. **B0① 百度绑定 oob 页(features/baidu/bind_code_page.dart,§8.10 定稿)**:
   - `POST /api/v1/baidu/backup/binding/authorize-url` → 展示授权链接(复制按钮 +
     url_launcher 外开系统浏览器);入口挂我的页「网盘备份」区(占位入口即可,B9 做完整页);
   - 授权码输入框(一次性:提交无论成败即清输入态;提示勿外传)→ `POST binding`
     (请求体与响应以 baidu_backup.py 实际契约为准,先读代码);
   - 成功/失败/过期文案分明,失败可重走;不自动重试;授权码/链接中的敏感参数不入日志
     (§13 脱敏红线:百度授权 code 不入 AppLog)。
   - 注意端点挂 `/api/v1/baidu/backup` 前缀;开关关闭(baidu_backup_enabled=false /
     404)时入口置灰提示「未启用」。
9. **B0② Android 落盘 PoC(features/me/b0_download_poc_page.dart 或同等)**:
   - 入口=我的页→诊断→「B0 落盘验证」;功能:任选一个已有资产(输入 asset_id 或取
     宫格第一页第一个)→ download-link 下载到 app cache → 两路落盘:
     ①photo_manager 存图库(现役 album.dart 逻辑复用)②media_store_plus 写
     Downloads(Downloads/浣花视界/ 子目录);两路分别报成功/失败与落点路径;
   - 失败详情完整展示(供真机取证);仅 Android 显示此入口(iOS 无 media_store_plus)。
10. **依赖(§12)**:`url_launcher`、`media_store_plus` 新增(pub add 锁版本+pubspec 注释
    「用途/批次」);不引 webview/share_plus(后续批)。

## 数据库修改方案

不涉及(方案零后端改动)。

## 接口定义(本批消费;全部已有)

| 端点 | 用途 |
| --- | --- |
| GET /healthz(免鉴权) | 探活 |
| POST /api/v1/auth/local/login | 登录 |
| GET /api/v1/auth/me | 会话恢复(Me 含 must_change_password/is_system_admin/baidu_backup_enabled 等,字段以 auth.py 实际返回为准) |
| POST /api/v1/auth/change-password | 改密(入参读 auth.py) |
| POST /api/v1/auth/logout | 退出 |
| POST /api/v1/baidu/backup/binding/authorize-url | B0① |
| POST /api/v1/baidu/backup/binding | B0①(契约读 baidu_backup.py) |
| GET /api/v1/projects、/folders、/assets 族 | 现役平移 |

错误口径(§4.1):401 清会话跳登录去抖;403/422 detail 透传(`_extractDetail` 兼容数组,
现役仅 toString——本批按 §4.1 实现数组→友好文案的增强);429/超时不自动重试。

## 前端改动点 / 后端改动点

- 前端(Flutter,material-storage/app/):全部改动。
- 后端:**零改动**(不许碰 material-storage/api/ 与 web/)。

## 测试功能点

1. 探活:顺序正确(dart-define 优先/内网→公网降级)、healthz 超时 3s、全失败态可重试。
2. Session:cookie 恢复、401 去抖(并发多请求只触发一次跳登录)。
3. 改密强制流:must_change_password=true 仅放行改密页;改密成功后放行。
4. Me 模型解析(must_change_password/is_system_admin/baidu_backup_enabled)。
5. B0①:authorize-url 响应解析、binding 请求体、授权码输入一次性清空逻辑。
6. B0②:落盘路由纯函数(平台×类型矩阵骨架,§6.1)单测。
7. 回归:现役测试全保留全绿(livp baseNameOf、上传分片、模型解析等)。

## 模糊点与决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 本周期范围=B0+B1,后续批次逐批另启周期 | 方案 §16 工程顺序,每批可独立验收;一次全做无法真机验收 |
| 2 | B0 真机闭环由用户执行;本批交付代码+自测,结论记 changelog 待真机后补 | 子智能体无法真机 |
| 3 | tab2/3 占位页;tab1 现役功能平移不加新功能(徽标等 B2) | B1 交付判据=旧功能不回归 |
| 4 | 探活序列无 47.108.196.211 dev 口;dev 调试走 dart-define | 方案 §4 定稿口径 |
| 5 | B0② 入口仅 Android 显示;PoC 页在真机结论后随 B4 正式实现移除 | §16 B0② |
| 6 | 现役 models.dart 拆 models/ 时保留解析行为不变(纯搬迁+补新字段) | 防回归 |

## 项目约定

- Flutter SDK: `E:\qbb\soft\flutter`;跑 pub/test 前导出镜像变量
  `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`
  (Git Bash: export)。`flutter test` 不需安卓 SDK/JAVA。
- 自测=`flutter analyze`(0 error)+`flutter test`(全绿)。
- 完成一批工作后 `scripts/changelog.md` 记账(按天分节,最新在前,一句话+commit hash
  可溯;本批由主流程验收后统一记)。
- 单文件 ≤200 行目标/300 硬顶;不引状态管理/路由框架;命名路由+Navigator.push。
- commit 前必 `git status` 对账(防并行会话误伤)。
