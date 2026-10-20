# iOS App 打包上传手册(交 Mac + 开发者账号同事执行)

> 对象:有 macOS 与 Apple 开发者账号的同事。目标:把 `material-storage/app/`
> (医美素材库 iOS 端,实况照片 livp 通道 MVP)在真机跑起来,并打包分发。
> 前置事实:后端**零改动零部署**(App 复用现有 REST 接口);所有代码、权限文案、
> ATS 配置均已就绪;PC 侧开发验证已全过(见 `ios-livp-app-mvp-feasibility.md`)。
> 本手册每一步都给出命令与预期结果,遇到与预期不符即停,把报错原文发回来。

---

## 0. 你会得到什么 / 需要什么

- 产物:装在 iPhone 上的「素材库」App —— 登录 → 浏览项目/文件夹 →
  从相册选**实况照片**上传为 `.livp` / 下载 `.livp` 存回相册(恢复实况)。
- 需要:macOS(Xcode 16+)+ Apple 开发者账号(个人/公司 ADP 或企业账号均可)+ 一台 iPhone(iOS 15+)。

## 1. 环境准备(一次性,~30 分钟)

```bash
# ① Flutter SDK(建议与我们一致的 3.47.x stable;国内网络加两行镜像)
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
#   下载:https://docs.flutter.dev/get-started/install/macos
#   或 brew install --cask flutter

# ② Xcode(App Store 装) + 命令行工具
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch        # 接受许可

# ③ CocoaPods(插件依赖集成需要)
sudo gem install cocoapods
#    慢/失败可换 brew install cocoapods

# ④ 拉代码(fork 仓的 liuqi 分支是最新主线;origin 上的 liuqi 可能滞后)
git clone -b liuqi https://github.com/Liu7i-67/rushes-lab.git
cd rushes-lab/material-storage/app
flutter pub get                        # 依赖已锁在 pubspec.lock,版本可复现
flutter doctor                         # 确认 iOS toolchain 全绿
```

## 2. 首次真机运行(调试,必做——这是 iOS 专属链路的第一次真机验证)

1. iPhone 用数据线连 Mac,Xcode 菜单 Device Manager 里**信任设备**;
   手机上 设置→通用→VPN与设备管理 里信任你的开发者证书。
2. 打开签名配置:
   ```bash
   open ios/Runner.xcworkspace
   ```
   Xcode 左侧选 `Runner` → TARGETS `Runner` → **Signing & Capabilities**:
   - Team:选你的开发者账号(Xcode 会自动管理证书;个人账号即可真机调试);
   - Bundle Identifier:`dev.rushes.ms-app` —— 若与你的账号前缀冲突/想用自己组织的,
     直接改成你账号可签名的值(例如 `com.你的公司.msapp`),只改这一处即可;
   - 勾选 Automatically manage signing。
3. 跑起来:
   ```bash
   flutter devices        # 确认 iPhone 在列
   flutter run            # 首次编译较慢,几分钟
   ```
4. **真机验收清单**(这五项是 PC 验证不了的,逐条过):
   - [ ] 登录页选 dev(默认)→ 用测试账号登录成功;
   - [ ] 选图器只显示实况照片(非实况不出现/不可选);
   - [ ] 上传一张实况 → 网页端同文件夹能看到 `.livp` 且预览有「播放实况」;
   - [ ] 下载该 `.livp` → 「已存入相册」→ 相册里长按能播放(是实况不是静态图);
   - [ ] 两次相册权限弹窗文案正确(读取/添加)。
   - [ ] 点右上角 🐞 图标 →「推送」→ 企业微信群收到 `msapp_log_*.log` 文件消息,
     App 内提示已清空(移动端 debug 主通道:全量日志含每个 API 请求/错误/未捕获异常)。
   若 ③④ 行为异常(选图含非实况/存回变静态图),把现象 + 点 🐞 推送的日志文件发回来,
   对应 `lib/services/album.dart`(读取 `originFile/originFileWithSubtype`,
   保存 `editor.darwin.saveLivePhoto`,注释里标了每处原理)。

## 3. 后端环境说明(无需配置,知悉即可)

- 登录页 `dev | prod | 自定义` 三档,登录成功即记忆:
  - dev = `http://47.108.196.211:8080`(测试环境,外网直连,默认);
  - prod = `https://bucket.taoxiplan.com`(生产,HTTPS);
  - 自定义:内网地址 `http://192.168.110.221:8090`(dev)/ `http://192.168.110.221`(prod)、
    或其他入口,手填即可。
- iOS 明文 HTTP 限制已在 Info.plist 处理(dev 是 IP 直连 http,Apple 的
  NSExceptionDomains 不匹配 IP 字面量,故开了 NSAllowsArbitraryLoads;勿删,否则 dev 入口连不上)。
- Android 同理:主清单(`android/app/src/main/AndroidManifest.xml`)已开
  `android:usesCleartextTraffic="true"`(networkSecurityConfig 同样不认 IP 字面量),勿删。
- 打包期想钉死单一环境:`flutter build ipa --dart-define=MS_API_BASE=https://bucket.taoxiplan.com`。

## 4. 打包发布(按你的分发方式二选一)

### 路线 A:TestFlight / App Store(推荐,正式)

```bash
flutter build ipa --release \
  --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
# 产物:build/ios/ipa/ms_app.ipa
```

> `APP_BUILD_TIME` 注入源码最后编辑时间(git 最新提交时刻),App 项目页标题会显示
> 「项目 · 最后编辑 YYYY-MM-DD HH:mm」——TestFlight 装上新构建后**看标题时间即确认已更新**
> (旧构建没有该段)。若标题看不到该段,说明打包命令漏带了 `--dart-define`,请重打。

上传(任选其一):
- Xcode → Window → Organizer → 选最新 Archive → Distribute App → App Store Connect;
  (flutter build ipa 会自动产出 Archive,Organizer 里能看到;也可以直接
  `open build/ios/archive/Runner.xcarchive` 触发)
- 或用 Transporter App 拖入 `ms_app.ipa`。

App Store Connect(https://appstoreconnect.apple.com)→ 我的 App → 新建:
Bundle ID 选你在第 2 步设定的 → 上传构建 → TestFlight 标签页等处理完成(~15 分钟)
→ 添加内测人员/内部测试组 → 手机上 TestFlight App 安装。

### 路线 B:Ad Hoc 直接发 ipa(不走过审,内部分发)

1. App Store Connect → 用户和访问 → 设备(或 Xcode Devices 窗口)注册测试 iPhone 的 **UDID**;
2. Profile 含这些设备后重新生成(Xcode 自动签名会处理);
3. ```bash
   flutter build ipa --release --export-method ad-hoc \
     --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
   # 产物:build/ios/ipa/ms_app.ipa(dart-define 同路线 A,标题显示最后编辑时间)
   ```
4. 把 ipa 发给同事 → Mac Finder/Finder「访达」双击装设备,或 Apple Configurator。
   (若你们账号是企业账号 Enterprise,`--export-method enterprise` 同理,免 UDID。)

> 内网工具类 App 过 App Store 审核可能有阻力(账号登录内网服务);
> 不确定就先走 TestFlight 内测(100 人内)或 Ad Hoc。

## 5. 常见问题速查

| 症状 | 处置 |
|------|------|
| `pod install` 卡住/报 CDN 错 | `pod repo update` 后重试;或 `flutter clean && flutter pub get` 再 run |
| 签名报错 "No profiles for 'dev.rushes.ms-app'" | Xcode 里 Team 没选/Bundle ID 与账号不匹配,按 §2 第 2 步改 |
| 真机装上闪退(灰图标) | 手机未信任证书:设置→通用→VPN与设备管理→信任 |
| 登录转圈超时 | 手机网络到所选入口不通;切另一档入口或确认外网可达 `http://47.108.196.211:8080` |
| 相册里看不到存入的照片 | 检查相册权限(设置→隐私→照片);实况照片在相册默认视图就有,不用筛选 |
| `flutter doctor` 报 iOS toolchain 异常 | 按 `flutter doctor -v` 提示逐条修(Xcode/许可/CocoaPods) |

## 6. 改代码的约定(如需动)

- `lib/` 是全部 Dart 源码(API 客户端在 `lib/api/ms_api.dart`,契约注释在文件头);
- iOS 原生配置只有 `ios/Runner/Info.plist`(权限文案 + ATS),其余 `ios/` 目录由
  Flutter 生成,**约定 Windows 侧不改 `ios/`/`android/` 平台目录,平台问题一律在 Mac 上处理**;
- 提交遵循仓库惯例:不直推 main,改动提 feature 分支;`material-storage/app/` 整目录随仓库走,
  `build/`、`.dart_tool/` 已被 .gitignore 排除,`pubspec.lock` **要提交**(锁版本)。
