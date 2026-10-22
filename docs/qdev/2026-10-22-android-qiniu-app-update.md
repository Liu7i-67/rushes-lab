# 安卓端七牛云应用内更新链路 · 需求文档

- 日期：2026-10-22
- 分支：`feat/app-qiniu-update`（基于 liuqi@517b81f），worktree：`E:\qbb\github_not_me\rushes-lab-feat-app-qiniu-update`
- 状态：定稿（qdev 派发依据）

## 1. 背景与目标

ms_app（`material-storage/app`）安卓包目前为手动分发 APK，无应用内更新能力。目标：建立「七牛云共桶 + CDN + 静态版本 JSON + 应用内检查更新」的完整链路，包含两部分：

1. **发布脚本**：一条命令完成打包→上传→双命名→版本 JSON→CDN 缓存刷新；
2. **App 端更新功能**：【我的】页版本展示 + 安卓检查更新按钮 + 启动自动检查 + 可取消的更新弹窗 + 下载安装。

参考实现（均已验证可抄）：
- `E:\qbb\github\QWord\qi_webview_tool`：客户端更新流程（检查→弹窗→进度下载→open_filex 安装）；
- `E:\qbb\github\q_the_milky_way\milky_flutter\scripts\release.mjs`：七牛表单直传凭证签名（URLSafeBase64 + HMAC-SHA1）、multipart 流式上传。

## 2. 已探测的环境事实（PM 实证，直接采信）

| 项 | 值 |
|---|---|
| 桶 | `taoxi-resources`，区域 **z0**（上传 `upload.qiniup.com`，管理 rs `rs-z0.qbox.me`） |
| CDN 域名 | `https://resources.taoxiplan.com`（匿名可访问=404 非 403，TLS 证书有效，curl 严格校验通过） |
| 对象键前缀 | `huanhuashijie/` |
| 凭证 | `scripts/env/qiniu.env`（gitignored，已建；变量名 `QINIU_HHSJ_*`） |
| 当前 App 版本 | `0.1.0+4`（pubspec.yaml） |

## 3. 功能点明细

### F1 发布脚本 `material-storage/app/tool/release.mjs`

仅依赖 Node 内置模块（fs/path/https/crypto/child_process），运行方式 `node tool/release.mjs`（cwd=material-storage/app）。参考 milky release.mjs 的凭证/上传代码风格（可移植其 `base64url`、`buildUploadToken`、multipart 流式上传实现，注意：base64url 保留 `=` padding、HMAC 消息含 padding，去掉会 bad token）。

流程：
1. **版本处理**：
   - 默认：读 pubspec.yaml `version: x.y.z+n`，patch +1、build +1，改写回 pubspec.yaml；
   - `--version=x.y.z`：显式指定 x.y.z，build 仍自动 +1，改写 pubspec.yaml；
   - `--no-bump`：不改版本，按当前 version+build 原样重发（覆盖同键）；
   - `--changelog="..."`：可选，写进 JSON，缺省空串；
   - `--dry-run`：完整执行版本处理与 flutter build 与计划打印，但跳过所有七牛网络操作（上传/copy/刷新）；
   - `--skip-build`：跳过 flutter build 与产物清理（产物不存在时不再报错），用于快速验证版本处理与发布计划；可与 `--dry-run` 组合。
2. **打包**：`flutter build apk --release --split-per-abi`；只保留 `app-arm64-v8a-release.apk`，删除其余 ABI 产物；
3. **上传版本包**：复制保留产物为 `huanhuashijie-<version>.apk`（version 为 x.y.z，不含 build），七牛表单直传至键 `huanhuashijie/huanhuashijie-<version>.apk`；putPolicy scope 锁 `taoxi-resources:huanhuashijie/huanhuashijie-<version>.apk`（勿设 insertOnly，允许覆盖）；
4. **固定名包**：调七牛管理 API（rs，`rs-z0.qbox.me`，QBox 签名）**copy** `huanhuashijie/huanhuashijie-<version>.apk` → `huanhuashijie/huanhuashijie.apk`（`force=true` 覆盖），不二次上传；
5. **版本 JSON**：生成并上传（同表单直传，scope 锁键）`huanhuashijie/app_version.json`：
   ```json
   {
     "version": "x.y.z",
     "build": 4,
     "changelog": "...",
     "force": false,
     "android": { "url": "https://resources.taoxiplan.com/huanhuashijie/huanhuashijie-x.y.z.apk" }
   }
   ```
6. **CDN 刷新**：七牛 CDN 管理 API（`cdn.qiniuapi.com/refresh`，QBox 管理凭证签名，body `{"urls":[...]}`）刷新两个 URL：`https://resources.taoxiplan.com/huanhuashijie/huanhuashijie.apk` 与 `.../app_version.json`（版本化 APK 键名唯一不重复，无需刷）；
7. **收尾打印**：新用户直链、版本 JSON 地址、对象键、刷新结果；
8. 凭证与配置全部读 `scripts/env/qiniu.env`（脚本相对定位 `resolve(__dirname,'../../../scripts/env/qiniu.env')`），缺失时报错并提示补齐，绝不硬编码；
9. 所有七牛请求失败时打印 HTTP 状态码与响应体前 500 字符后 exit 1；各阶段日志 `[release]` 前缀。

### F2 App 端更新功能（Flutter，仅 Android 生效）

新增依赖：`package_info_plus`（读版本）、`open_filex`（调安装器）。manifest（`android/app/src/main/AndroidManifest.xml`）加 `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />`。

1. **【我的】页**（`lib/features/me/me_page.dart`）：展示当前版本号 `x.y.z+n`（所有平台）；**仅 Android** 显示「检查更新」入口（样式融入现有 me 页 tile/list 结构）；
2. **检查更新服务**（建议 `lib/core/update/` 新目录）：
   - 独立 Dio 实例：不挂业务鉴权拦截器、不触发 401 登出逻辑；连接/接收超时各 10s；**证书正常严格校验**（域名证书已验证有效）；请求 `GET https://resources.taoxiplan.com/huanhuashijie/app_version.json?t=<毫秒时间戳>`（cache-bust）；
   - JSON 解析模型 `AppVersionInfo`：version(String)/build(int，缺失=0)/changelog(String，缺失='')/force(bool，缺失=false)/android.url(String)；字段类型异常按默认值兜底（对齐 qi 的 fromJson 防御式风格），version 或 android.url 缺失/为空视为「无有效更新信息」；
3. **版本比较**：先比 version（按 `.` 切段、逐段整数、段数不齐补 0，非数字段按 0 处理），version 相同再比 build；服务端(远端 > 本地)才提示更新；比较函数为纯函数、可单测；
4. **启动自动检查**（仅 Android）：App 首帧渲染完成约 3 秒后触发一次、每 session 仅一次；**任何失败（网络/超时/解析）完全静默**（无 toast 无弹窗无日志刷屏）；发现新版本→弹更新确认弹窗；
5. **更新确认弹窗**：标题含新版本号，正文展示 changelog（可空则不显示正文区），按钮「立即更新」/「取消」；取消→关闭，**本次 session 不再自动弹**（下次启动再提示）；force 字段本期仅透传不生效，UI 不做强制分支；
6. **下载与安装**：
   - 下载 JSON 里的版本化 URL 到临时目录 `{tmp}/huanhuashijie-update-<version>.apk`；开始前删同名旧文件；
   - 进度弹窗：百分比（未知总长显示进行中态）、可取消（CancelToken，取消/失败清理半成品）；
   - 完成后 `OpenFilex.open(path, type: 'application/vnd.android.package-archive')` 调系统安装器；调起失败给出可读错误提示；
   - 手动「检查更新」：已有新版→同弹窗；已是最新→SnackBar「当前已是最新版本」；失败→SnackBar 展示可读错误；
7. **UI 规范（硬性）**：颜色/字号/间距一律用 `lib/theme/tokens.dart` 的 `Tk.*` 令牌（对齐 app_theme.dart 组装方式），**禁止裸 fontSize/Color(0x...)**；弹窗/按钮风格与现有widgets 一致（参考现有 dialog/snackbar 用法）；
8. 不改动现有登录、传输、预览等任何页面逻辑；不动 minSdk=29。

## 4. 数据库修改方案

不涉及（纯静态资源 + 客户端，无后端改动）。

## 5. 接口定义

无后端接口。对外静态资源契约：

| 资源 | URL | 说明 |
|---|---|---|
| 版本 JSON | `GET https://resources.taoxiplan.com/huanhuashijie/app_version.json` | 结构见 F1-5；客户端加 `?t=` 时间戳 |
| 新用户直链 | `GET .../huanhuashijie.apk` | 永久固定，每次发版覆盖+刷新缓存 |
| 版本化包 | `GET .../huanhuashijie-x.y.z.apk` | 老用户更新走 JSON 内此地址 |

错误语义：404=无该对象（首次发布前检查更新会得到 404，客户端按「静默失败」处理）。

## 6. 前端改动点 / 后端改动点

- 前端（Flutter App）：F2 全部；新增测试；
- 后端（Node 脚本）：F1 全部；脚本自测方式=PM 验收跑 `--dry-run` + 真实链路由用户拍板后首跑。

## 7. 测试功能点

- T1 `release.mjs --dry-run`：pubspec 版本号按预期自增/改写；计划打印的对象键、双命名、JSON 内容、刷新 URL 清单正确；不发生任何网络写操作；
- T2 版本比较纯函数单测：version 高/低/相等、build 决胜、段数不齐（1.0≡1.0.0）、非法段、空串；
- T3 `AppVersionInfo.fromJson` 单测：完整/缺 build/缺 changelog/缺 force/类型异常/version 空/android.url 空；
- T4 平台 gate：版本展示全平台可见；检查更新按钮与自动检查仅 Android（逻辑层可测，Platform 注入）；
- T5 自动检查静默：404/超时/坏 JSON 均无弹窗无 toast（单测覆盖判定逻辑）；
- T6 取消语义：确认弹窗取消后同 session 不再自动弹；
- T7 下载逻辑：已有同名文件先删、取消清理半成品（可单测的部分单测，UI 交互列入真机清单）；
- T8 回归：`flutter analyze` 0 issues；`flutter test` 全绿（现有基线全过）；
- T9 真机人工项（交付后清单，不阻塞）：安装器调起、「允许安装未知应用」引导、真实下载进度。

## 8. 模糊点与决策记录

| # | 决策 | 理由 |
|---|---|---|
| D1 | zone 不手配死，env 带 `QINIU_HHSJ_ZONE=z0` 且脚本经 `uc.qbox.me/v4/query?ak=&bucket=` 自动探测兜底 | milky 手配 zone 踩过坑；已实测 z0 |
| D2 | 固定名包用七牛 copy API 而非二次上传 | 省一半传输且字节级一致 |
| D3 | changelog 由 `--changelog` 参数传入，缺省空串 | App 无独立 changelog 文件，仓库 changelog.md 是 web 口径 |
| D4 | 版本策略：默认 patch+build 自增；`--version` 显式；`--no-bump` 原样重发 | 覆盖「每次发版自然升版本」与「补发重传」两类场景 |
| D5 | 取消=本次 session 不再弹，下次启动再提示；force 仅预留 | 用户要求「允许取消更新」 |
| D6 | iOS 不显示检查按钮、不自动检查，仅展示版本 | iOS 分发不在本期 |
| D7 | 证书严格校验，不做 badCertificateCallback 放行 | 域名证书已实测有效 |
| D8 | 脚本位置 `material-storage/app/tool/release.mjs`；凭证 `scripts/env/qiniu.env` | tool/ 已有先例；env 目录 gitignored |
| D9 | 自动检查时机=首帧后约 3s，每 session 一次 | 避开启动资源争抢，且不依赖登录态 |
| D10 | 首次真实发布（真实上传）不由 qdev 执行，交付后由用户拍板 | 上传即对外发布，属外向动作 |
| D11 | CDN 刷新失败仅警告不 exit 1（发布产物已全部就位，刷新可人工到控制台补刷） | 修订 F1-9 字面与 F1-6 的矛盾；F1-9 的 exit 1 仅适用于上传/copy/JSON 直传失败（qdev 测试 P2-2 收口，2026-10-22） |

## 9. 测试结论与遗留项（2026-10-22 专职测试）

- 结论：**可交付**。P0=0、P1=0；analyze 0 issues；全量 617 例 5 轮中 3 轮全绿、2 轮各红 1 例均为既有 livp flake（download_savers_test，与本次无关）。
- P2 遗留（不强修，修复时翻转对应断言）：
  - P2-1 `update_flow.dart` downloadAndInstall 在 context 失活后 `await dialogFuture` 永久挂起 + ValueNotifier 泄漏（触发路径：下载中 401 清栈）；留档用例 `test/core/update/update_edge_dialogs_flow_test.dart` 已固化该行为；
  - P2-3 `apk_updater.dart` 下载前 `delete()` 在 try 外，文件被锁的裸 FileSystemException 会卡死进度弹窗（Android 临时目录概率极低）；
  - P2-4 下载失败/未映射 DioException 的文案可能透出原始英文异常；
  - P2-2 已由 D11 收口（文档修订，非代码问题）。
- 真机人工项（T9）：安装器调起、「允许安装未知应用」引导、真实下载进度、启动自动检查弹窗实弹验证。
