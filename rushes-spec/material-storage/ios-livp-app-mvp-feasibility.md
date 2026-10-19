# iOS 端 Flutter App(实况照片 livp 通道)MVP 可行性验证报告

> 2026-10-19 验证完成。结论:**可行,且已在 PC 侧把能验证的全部验证通过**。
> 项目代码:`material-storage/app/`(Flutter 3.47.7 / Dart 3.13.5,未提交 git,待指令)。
> PC 开发机约束(用户拍板):本机只做开发与自测,不做 iOS 打包部署;
> iOS 打包操作仅在未来明确指令下进行(清单见 §5)。

---

## 0. 验证结论摘要

| 验证项 | 方式 | 结果 |
|--------|------|------|
| 代码质量 | `flutter analyze` | ✅ 0 issue |
| livp 容器打包/解包 | 单测(roundtrip / 按类别最大挑选 / 退化无视频 / 非法容器报错) | ✅ 4/4 |
| API 全链路(登录会话/列表/分片上传/下载回读/软删) | 单测:本地 HttpServer 按后端真实契约 mock | ✅ 4/4 |
| 后端入口切换与持久化 | 单测:默认 dev 外网入口 / 切 prod / 自定义地址重启保留 | ✅ 1/1 |
| **外网入口实测(手机实际路径)** | dev 外网 `http://47.108.196.211:8080` 直连(不经隧道)全链路:登录→上传 livp→下载回读一致→软删 | ✅ **ALL PASS** |
| prod HTTPS 域名 | `https://bucket.taoxiplan.com` 登录会话(只登录+读 /me,不写入) | ✅ 200 |
| **真环境全链路** | `tool/verify_dev.dart` 经 ssh 隧道打 **hh2 dev(8090 nginx 入口)**:登录 → 项目(9 个)→ 文件夹 → **真实 multipart 上传 894B livp → presigned 下载回读逐字节一致 → 解包 → 软删自清理** | ✅ **ALL PASS** |
| iOS 相册读实况(originFile / originFileWithSubtype) | 已按 photo_manager 3.12.0 真实 API 编码 | ⏳ 待 Mac+真机 |
| iOS 存相册(editor.darwin.saveLivePhoto) | 同上 | ⏳ 待 Mac+真机 |
| 微信风格选图(onlyLivePhotos 过滤) | 已按 wechat_assets_picker 9.8.0 真实 API 编码 | ⏳ 待真机 |

后端**零改动**——App 复用既有 REST 契约(与 web Uppy/Axios 完全同参,含 16MB 分片),
上传的 livp 直接进入现有缩略图/实况预览转码链路(后端按「zip 内最大静态图+最大视频」解析,不挑文件名)。

## 1. MVP 三功能与实现落点

| MVP 需求 | 实现 |
|----------|------|
| 登录 | `lib/api/ms_api.dart`:POST /api/v1/auth/local/login,`ms_session` cookie(PersistCookieJar 持久化,重启免登录);登录失败透出后端中文 detail |
| 进入已有项目/文件夹 | `/projects` → `/folders`(内存建树 ExpansionTile 递归)→ `/assets`(分页列表,livp 有专属图标) |
| 上传 livp | iOS:`AlbumService.pickLivePhotos`(onlyLivePhotos)→ `entityToLivp`(originFile+originFileWithSubtype 原文件直 zip,零转码)→ 16MB 分片上传;**PC/Android:file_picker 选 .livp 文件上传**(PC 验证链路) |
| 下载 livp 到相册 | iOS:download-link → 下载 → 解包 → `PhotoManager.editor.darwin.saveLivePhoto`(PHAssetCreationRequest + pairedVideo);PC/Android:存临时目录 + 解包校验 |

代码结构:`lib/api`(ms_api 契约客户端)/ `lib/services`(livp 容器、相册桥)/ `lib/pages`(登录/项目/文件夹/文件)/ `test`(4+4 单测)/ `tool`(verify_dev + cleanup_verify)。

## 2. PC 侧环境(已就绪)

- Flutter SDK 3.47.7 stable 安装于 `E:\qbb\soft\flutter`(国内镜像 `pub.flutter-io.cn` / `storage.flutter-io.cn`,会话内需 `export PUB_HOSTED_URL/FLUTTER_STORAGE_BASE_URL`;PATH 未永久写入,后续可加)。
- 依赖已锁:`pubspec.lock`(dio 5.x / photo_manager 3.12.0 / wechat_assets_picker 9.8.0 / archive 3.6.1 / file_picker 8.x)。
- **未装 Android SDK** → 本机 `flutter run` 到模拟器/真机暂不可用(后续如需 Android 自测再装;不影响 iOS 目标开发)。
- dev 连通方式:`ssh -N -L 8200:127.0.0.1:8090 hh2` 后 App/脚本 baseUrl 指 `http://127.0.0.1:8200`(8090=dev nginx 入口;直接 8200→hh2:8200 ms-api 亦可)。已验证后即拆隧道。

## 3. dev 实测记录(2026-10-19)

```
PASS login → Evan(3f1b659e-…)/ me → Evan
PASS projects → 9 个 / folders → 6 个 / assets → 列表正常
PASS upload → msapp_verify_20261019160606.livp(894B,分片 1/1)
PASS download → 回读 894B 与上传载荷逐字节一致
PASS livp unpack → VERIFY.jpg + VERIFY.mov
PASS cleanup → 已软删(dev 回收站可彻底清除)
```

- 验证件 = 合法 1×1 JPEG + 4KB 伪 MOV 的退化 livp:验证字节链路,不验证实况语义。
- 遗留痕迹(均为 dev 可接受):软删行在回收站、审计 3 行(local_login_success/upload/asset_deleted)、
  worker 对伪 MOV 的实况转码会失败一次(缩略图 JPEG 正常)。
- 踩坑已修:后端 DELETE 返回 **204**(FastAPI 默认),客户端须按 200/204 双收。

## 4. iOS 待真机验证清单(拿到 Mac+iPhone 后第一件事)

1. `pickLivePhotos`:onlyLivePhotos 过滤是否只显示实况;选择后 `originFile`/`originFileWithSubtype`
   是否分别给出 HEIC 与 MOV 原文件(**photo_manager 文档口径,未实机证实**)。
2. `saveLivePhoto`:livp 下载解包后存回相册,是否恢复为实况照片(长按可播)。
   已知边界:非原配对的照片+视频硬凑不保证成功(flutter_photo_manager#1009),我们的场景是原配对,属可靠路径。
3. 权限:iOS 相册「所有照片/有限」+「添加到照片」两次授权弹窗(Info.plist 文案已配)。
4. iCloud 未下载资源的 `originFile` 为 null 的降级提示(代码已留 StateError 文案)。
5. 大批量导出性能(PHAssetResourceManager 拷资源 + zip 应在后台 isolate;当前 MVP 在主 isolate,真机测卡顿再优化)。

## 5. iOS 打包操作清单(仅明确指令后执行;PC 上不做)

前置:一台 macOS + Xcode;苹果开发者账号(内网分发三选一:企业证书 ¥299/年免 UDID /
ADP ¥99/年 + 设备 UDID 注册 / TestFlight 内测)。

```
# Mac 上(一次性)
sudo xcode-select --install / brew install --cask flutter-cocoapods  # 视情况
cd material-storage/app
flutter pub get
flutter run                      # 真机插线调试(需在 Xcode 里选 team + 信任签名)

# 打 ipa(需要签名配置后)
flutter build ipa --release      # 产物 build/ios/ipa/*.ipa
# TestFlight:xcode 上传 Organizer 或 altool;企业证书:直接分发 ipa
```

代码侧已备好的 iOS 配置:
- `ios/Runner/Info.plist`:NSPhotoLibraryUsageDescription / NSPhotoLibraryAddUsageDescription 已写;
  ATS 放开(NSAllowsArbitraryLoads,内网 http 入口;收紧时改为例外粒度)。
- bundle id `dev.rushes.ms-app`(flutter create --org dev.rushes;接签名时按账号改)。
- Windows 侧不要动 `ios/` 目录(大小写敏感路径问题只在 mac 上处理)。

## 6. 已知限制 / 下一步(按需)

- 上传在 UI 线程读整文件进内存(livp 几 MB~几十 MB 可接受;>200MB 后端本就拒收)。
- 浏览为 MVP 级:项目单页 100、无缩略图墙、无搜索/标签;按后续需求迭代。
- baseUrl:登录页 dev/prod 预设一键切换(2026-10-19 二次调整,**预设=外网直连**:
  dev `http://47.108.196.211:8080` / prod `https://bucket.taoxiplan.com`,手机不在内网也可用;
  两者均实测通过)+ 自定义手填(内网 `192.168.110.221(:8090)`、外网 prod http `:18080`、
  PC 隧道口 `127.0.0.1:8200`);登录成功落盘 shared_preferences,重启保留;
  打包期仍可用 `--dart-define=MS_API_BASE=...` 钉死默认值。
- **iOS HTTP/ATS**:prod 预设走 HTTPS 域名零顾虑;dev 预设是 IP 直连 http —— Apple 的
  NSExceptionDomains 只匹配域名不匹配 IP 字面量,故 Info.plist 保留
  NSAllowsArbitraryLoads(+NSAllowsLocalNetworking 覆盖内网自定义入口);
  未来收紧 = dev 换 TLS 入口后删 ArbitraryLoads。
- Android 实况(Motion Photo 单文件容器)是另一套格式,跨端支持另立项。
- 与 web 端五包优化方案(见 inapp-browser-tip-preview-nav-audit-enrichment-plan.md)无耦合。
