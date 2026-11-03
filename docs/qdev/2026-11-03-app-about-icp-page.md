# App「关于我们」页 + 备案号展示（qdev 需求文档）

日期：2026-11-03　基线：liuqi 655ed12　分支：feat/app-about-icp（worktree rushes-lab-feat-app-about-icp）

## 1. 背景与目标

App 双端工信部备案已通过，备案号 **蜀ICP备2021008473号-4A**。按备案合规要求（App 内显著位置展示备案号），在「我的」页新增「关于我们」入口，点进展示 App 图标、名称、版本号与备案号；备案号可点击跳转工信部备案核验站。

纯 Flutter App 改动：无后端、无数据库、无 FGA、无新依赖。

## 2. 功能点明细（逐条可验收）

1. 「我的」页底部「关于」分组内新增「关于我们」行（分组内第一项，位于「检查更新/当前版本」之上），带 leading 图标 `Icons.info_outline`，点击跳转 `/about`。
2. `/about` 页面（二级页，带返回）：
   - 页头：`PageHeader(title: '关于我们', back: true)`；
   - 居中内容自上而下：App 图标（`assets/logo.png`，96×96，圆角 ClipRRect 半径 20）→ App 名称「浣花视界」（w600 标题级字号）→ 版本号「版本 x.y.z+n」（小字次级色，来源 package_info_plus，经 `appUpdate.currentVersion` + `localVersionLabel`）；
   - 底部居中备案号行：文本精确为 `蜀ICP备2021008473号-4A`，可点击，`launchUrl` 外开 `https://beian.miit.gov.cn`（`LaunchMode.externalApplication`，照抄 login_page `_launchExternal` 模式）；打开失败落 SnackBar「打开失败，请稍后重试」，不打断页面。
3. 备案号与核验站 URL 为 Dart 顶层常量并导出，供测试与后续复用。
4. 双端（Android/iOS）同一页面同一备案号；主题跟随既有 Tk 深/浅双主题（仅用 tk 令牌，不写死颜色）。

## 3. 组件拆分方案

| 文件 | 动作 | 职责 | 预估行数 |
|---|---|---|---|
| `lib/features/me/about_page.dart` | 新建 | `AboutPage` StatefulWidget：页面编排+版本读取+外开链接 helper；注入点见 §7 | ≤200 |
| `lib/features/me/me_page.dart` | 修改 | 「关于」分组加「关于我们」AppRow（约 +8 行） | 155→~165 |
| `lib/app.dart` | 修改 | `onGenerateRoute` 加 `case '/about'`（约 +4 行） | — |
| `test/features/me_about_page_test.dart` | 新建 | §6 测试功能点对应单测 | ≤300 |

依赖关系：me_page 与 app.dart 仅依赖 about_page 暴露的 `AboutPage` 与常量；测试仅依赖公共契约（§7）。

### 可复用资产映射

- `AppRow`/`MeGroup`（widgets/app_row.dart、me_sections.dart）：直接复用，入口行写法参照同页「修改密码」行；
- `PageHeader`（widgets/page_header.dart，`back: true`）：直接复用；
- `LocalAppVersion`/`localVersionLabel`/`appUpdate`（core/update/update_flow.dart）：直接复用版本读取与展示口径；
- `launchUrl` 外开模式：照抄 `lib/features/auth/login_page.dart` `_launchExternal`（try/catch→bool），不在本页重构他人代码；
- `context.tk` 主题令牌 + `Tk.*` 字号间距：直接复用，禁止旧 Tk 颜色别名。

## 4. 数据库修改方案

不涉及。

## 5. 接口定义

不涉及（无后端改动；唯一外部动作是外开浏览器到工信部核验站）。

## 6. 测试功能点

1. 我的页「关于」分组渲染「关于我们」行（原有「检查更新」行不受影响，分组两行共存）。
2. 点击「关于我们」行 → 请求路由 `/about`。
3. `AboutPage` 渲染：logo 图（Key `about_logo`）、名称「浣花视界」、备案号文本。
4. 备案号文本精确等于 `kAppIcpNumber`（`蜀ICP备2021008473号-4A`），Key `about_icp`。
5. 点击备案号 → 注入的 `openUrl` 被调，且入参 URL == `kIcpQueryUrl`（`https://beian.miit.gov.cn`）。
6. `openUrl` 注入返回 false → 页面出现「打开失败，请稍后重试」SnackBar。
7. 版本注入 `(version: '1.2.3', build: 45)` → 页面显示「版本 1.2.3+45」。
8. 回归：`me_update_tile_test.dart`、`me_page_stamp_test.dart` 等既有 me 系测试全绿。

## 7. 公共契约（开发/测试两包对齐用）

```dart
// lib/features/me/about_page.dart 顶层导出
const String kAppIcpNumber = '蜀ICP备2021008473号-4A';
const String kIcpQueryUrl = 'https://beian.miit.gov.cn';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.localVersion, this.openUrl});
  /// 版本来源注入(null = appUpdate.currentVersion；测试用)
  final Future<LocalAppVersion> Function()? localVersion;
  /// 外开链接注入(null = launchUrl externalApplication；测试用)
  final Future<bool> Function(String url)? openUrl;
}
```

- 版本行文案：`'版本 ${localVersionLabel(v)}'`；PackageInfo 通道异常时静默保持 null → 该行显示「版本 …」不渲染数字（参照 update_tile 的容错）。
- 备案号 Key：`about_icp`；logo Key：`about_logo`。
- 入口行 onTap：`Navigator.of(context).pushNamed('/about')`（无 arguments）。

## 8. 前端改动点 / 后端改动点

前端=§3 全部；后端=不涉及。

## 9. 模糊点与决策记录

1. **iOS/Android 备案号是否分开展示**：用户口径为统一「蜀ICP备2021008473号-4A」→ 决策：双端同号单常量；若后续发现双平台各持独立号，只改 `kAppIcpNumber` 一处常量（按 Platform 分叉的口子不预留，YAGNI）。
2. **入口位置**：用户只说「我的页新增入口」→ 决策：放既有「关于」分组内第一项（与检查更新同组语义最贴），不新开分组。
3. **外开失败反馈**：决策 SnackBar 提示（login_page 是错误区模式但那是整页表单；本页轻提示即可）。
4. **红线评估**：可行、成本极小（纯静态页，改动 3 文件+1 测试文件），不触发不可行红线。

## 10. 项目约定（派发随附）

- Flutter SDK：`/e/qbb/soft/flutter`（`flutter analyze` 0 警告、`flutter test` 全绿为完成标准）；
- 只 format 自己新建/修改的文件；既有功能不得删；单文件 ≤500 行；
- 主题一律 `context.tk`/`Tk.*`；禁用旧 Tk 颜色别名；文案与注释风格照抄现有 me 系文件（中文注释，带决策号引用）。
