# iOS App TestFlight 发布 Runbook

> 适用对象：`material-storage/app/`（Flutter iOS，实况照片 livp 通道）。
> 目标：把 Release 包发布到 TestFlight 内部测试。
> 本文只写流程与「去哪里查」，**不记录任何账号、邮箱、Issuer ID、密钥**。
> 首次从零搭建环境见 `ios-livp-app-build-handbook.md`；本文是发布操作手册。

---

## 0. 一次性准备（做完可长期复用）

### 0.1 账号与协议

- 需要付费的 Apple Developer Program 账号（免费 Apple ID 不能用 TestFlight）。
- 协议会不定期更新。**只有账号持有人（Account Holder）能接受**，Admin 不行。
- 查协议状态的两个入口：
  1. `https://developer.apple.com/account` → 顶部「协议」图标（《Apple Developer Program 许可协议》的接受日期会显示在这里）
  2. `https://appstoreconnect.apple.com/business` →「协议」标签（《免费 App 协议》，状态可能是「有效（新协议可用）」）

> 注意：App Store Connect 的协议提示可能比开发者网站晚生效。
> 接受后 API 仍报 `403 REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` 时，等 15 分钟–4 小时再试；
> 超过 24 小时才联系 Apple Support。**不要**重建证书或 API key，这对该错误无效。

### 0.2 App 记录

- App Store Connect →「我的 App」→ 左上 `+` → 新建 App。
- Bundle ID 下拉里没有目标值时，先在 `developer.apple.com/account/resources/identifiers` 注册；
  或先跑一次带签名的构建，Xcode 自动签名会注册 Bundle ID。
- 记录：平台 iOS、名称、主要语言、Bundle ID、SKU。

### 0.3 App Store Connect API Key

- 入口：`https://appstoreconnect.apple.com/access/integrations/api`
- 页面顶部是 **Issuer ID**；下方密钥表格里的 **Key ID** 与下载文件名一致。
- 点 `+` 生成密钥（角色选 **App 经理**），`.p8` 只能下载一次。
- 存放位置（本机）：

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

> `.p8`、Issuer ID、Key ID 一律不进 commit、不进文档、不进 issue。

### 0.4 本机环境与工程配置

- macOS + Xcode（`xcodebuild -version`）+ Flutter 3.47.x（`flutter --version`）+ CocoaPods。
- Xcode 需登录开发者账号；自动签名会创建 `Apple Distribution` 证书与 App Store 描述文件
  （证书可能只存在 Apple 云端，不在本机钥匙串，属正常）。
- 工程里必须有 `DEVELOPMENT_TEAM`（`ios/Runner.xcodeproj/project.pbxproj`），
  且 `CODE_SIGN_STYLE = Automatic`。
- `ios/Runner/Info.plist` 必须具备：
  - `ITSAppUsesNonExemptEncryption = false`（免每次上传的合规问卷）
  - 相册/相机/定位等用途说明（插件引用敏感 API 时苹果强制要求，见 §4）

---

## 1. 构建

```bash
cd material-storage/app
flutter pub get
```

**先升 build number**：`pubspec.yaml` 的 `version: <版本>+<build>`，每次上传必须严格递增
（传过的号永久作废）；也可以本次用 `--build-number N` 临时指定，但建议回写 pubspec 保持可复现。

```bash
flutter build ipa --release
```

产物：`build/ios/ipa/ms_app.ipa`。

签名自查（可选）：

```bash
TMP=$(mktemp -d)
unzip -q build/ios/ipa/ms_app.ipa -d "$TMP"
security cms -D -i "$TMP/Payload/Runner.app/embedded.mobileprovision" | plutil -extract Name raw -
codesign -dvv "$TMP/Payload/Runner.app" 2>&1 | grep -E 'Authority|TeamIdentifier'
rm -rf "$TMP"
```

预期：`Apple Distribution: ...` + `iOS Team Store Provisioning Profile: <Bundle ID>`。

---

## 2. 上传

```bash
xcrun altool --upload-app \
  -f build/ios/ipa/ms_app.ipa -t ios \
  --apiKey <KEY_ID> \
  --apiIssuer <ISSUER_ID>
```

成功标志：`UPLOAD SUCCEEDED with no errors` + 一行 `Delivery UUID`（记下来便于排查）。

> 上传成功 ≠ 可以测试。苹果要先处理（通常 5–30 分钟，偶发更久）。

---

## 3. 处理、分组与邀请

### 3.1 查处理状态

- 界面：App Store Connect → 该 App → **TestFlight** 标签（不是「App Store」标签）。
- API：`GET /v1/builds?filter[app]=<APP_ID>&sort=-uploadedDate`
  - `processingState`：`PROCESSING` → `VALID` / `INVALID` / `FAILED`
  - 处理失败时苹果会向账号邮箱发 `Invalid Binary` 邮件，里面写明原因。

### 3.2 内测组（只需建一次）

- 界面：TestFlight →「内部测试」→ `+`。
- API：`POST /v1/betaGroups`，`attributes.isInternalGroup = true`，并关联 `app`。

### 3.3 把构建分配给内测组

- 界面：组 →「构建版本」→ `+` → 选中新构建。
- API：`POST /v1/builds/<BUILD_ID>/relationships/betaGroups`
  body：`{"data":[{"type":"betaGroups","id":"<GROUP_ID>"}]}`

分配后 TestFlight 才会给组内测试员发邀请邮件。

### 3.4 添加内测员

- 内测员必须先是 **App Store Connect 团队成员**（用户和访问）。
  可用界面邀请，或 API `POST /v1/userInvitations`（需名、姓、邮箱、角色）。
- 对方接受邀请后，才会出现在 `GET /v1/users` 里；此时 `GET /v1/userInvitations` 不再列出他。
- 再加进内测组：
  - 界面：组 →「测试员」→ `+`
  - API：`POST /v1/betaTesters`，并同时带 `relationships.betaGroups`
    （直接向组关系端点 POST 会报 `409 STATE_ERROR: Tester(s) cannot be assigned`）

### 3.5 查 API（可选）

App Store Connect API 用 JWT（ES256）鉴权，`iss` 填 Issuer ID、`kid` 填 Key ID：

```python
import jwt, time, json, os, urllib.request
issuer, key_id = "<ISSUER_ID>", "<KEY_ID>"
key_path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
tok = jwt.encode(
    {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 1200,
     "aud": "appstoreconnect-v1"},
    open(key_path).read(), algorithm="ES256", headers={"kid": key_id},
)
req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/apps?limit=200",
                             headers={"Authorization": "Bearer " + tok})
print(json.load(urllib.request.urlopen(req)))
```

---

## 4. 常见错误与处置

| 报错 | 原因 | 处置 |
|---|---|---|
| `ITMS-90683: Missing purpose string in Info.plist` | 插件引用了相机/定位等敏感 API，但 Info.plist 没写用途说明 | 补 `NSCameraUsageDescription` / `NSLocationWhenInUseUsageDescription` 等 → **升 build number** → 重新构建上传 |
| `403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` | 有协议未生效/已过期 | Account Holder 去开发者网站或 ASC「商务→协议」接受；等 15 分钟–4 小时；别重建证书/密钥 |
| `409 STATE_ERROR: Tester(s) cannot be assigned` | 邮箱不是团队成员 | 先发团队邀请，对方接受后再加入内测组 |
| `No suitable application records were found` | ASC 没有对应 App 记录 | 先建 App 记录（§0.2） |
| 上传报 build number 已存在 | 号被用过 | 升 build number 重传 |
| 仍显示 Flutter 默认图标 | 模板占位图 | 内测不拦；**上架 App Store 前必须换**，1024 图标不能带 alpha |
| 欧盟 DSA 红条 | 未声明交易商身份 | 只影响欧盟区 App Store 分发；内部 TestFlight 可暂不处理 |

---

## 5. 本次发布记录（2026-10-20）

- App：`Rushes 素材库`，Bundle ID `dev.rushes.msApp`
- `0.1.0 (1)`：上传后被苹果拒，`ITMS-90683` 缺 `NSCameraUsageDescription`
  （另有一条非阻断提示：缺 `NSLocationWhenInUseUsageDescription`）
- 修复后 `0.1.0 (2)`：上传成功，处理通过（`VALID`），已分配「内部测试」组，
  组内测试员已收到邀请
- 本次代码改动（仅 3 个文件）：`Info.plist`、`project.pbxproj`、`pubspec.yaml`
  - PR：https://github.com/Liu7i-67/rushes-lab/pull/1
- 遗留：App 图标仍是 Flutter 默认占位；`rushes-spec` 未上架 App Store（不涉及审核）

---

## 6. 敏感信息去哪查（本文不记录具体值）

| 要用的值 | 查询位置 |
|---|---|
| Issuer ID | ASC → 用户和访问 → 集成 → App Store Connect API 页面顶部 |
| Key ID | 同上页面的密钥表格；也等于 `.p8` 文件名里的 `AuthKey_<KEY_ID>` |
| API 私钥 | `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`（权限 600） |
| Team ID | `material-storage/app/ios/Runner.xcodeproj/project.pbxproj` 的 `DEVELOPMENT_TEAM` |
| Bundle ID | `project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` |
| App Apple ID | App Store Connect 该 App 页面 URL，或 API `GET /v1/apps?filter[bundleId]=...` |
| 测试员名单 | ASC → 用户和访问（**不要抄进文档或 commit**） |
