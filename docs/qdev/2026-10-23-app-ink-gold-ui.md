# App UI 重设计：墨色 + 金色 · 双主题（跟随系统）

- 日期：2026-10-23
- 分支：`feat/app-ink-gold-ui`（自 `liuqi`）
- worktree：`E:/qbb/github_not_me/rushes-lab-feat-app-ink-gold-ui`
- 设计源：Open Design 原型 `C:/Users/Administrator/AppData/Roaming/Open Design/namespaces/release-stable-win/data/projects/9fce6f31-f8fb-424c-bbae-e3ec604711ed`（`design-spec.md` / `index.html` / `app.css` / `app.js`）
- 目标端：iOS / Android Flutter（`material-storage/app`），基准 390×844，兼容 320 宽

---

## 1. 背景与目标

当前 App 是**纯浅色、暖白底 + 橙色强调**（`Tk.accent=#C2410C`）的“后台管理工具”风格：字号偏小（正文 14）、卡片直角感弱、页面以 ListTile 平铺为主。

新设计是**“墨色为骨、金色为线、素材为面”**的素材编辑台：

- 深色为第一主题：画布 `#131210`、卡片 `#1B1915`、导航 `#0E0D0A`，靠三级明度与 1px 描边分层，不靠阴影。
- 金色是唯一强调色：选中、当前页签、可管理、进度、主操作。
- 浅色是纸感主题：`#F6F3EC` 画布 + 白卡 + 1px 描边，金色压深一档。
- 双主题同源：同名令牌两组取值，组件结构/间距/字号/图标全部复用。
- 默认**跟随系统**，用户可在「我的 → 设置 → 外观」锁定深色/浅色，选择持久化。
- 预览画布、toast、上传胶囊**两种主题下都保持深色**（媒体查看与浮层惯例，不是主题缺口）。

**本次目标**：把 Flutter App 的视觉体系整体迁移到该设计，并让明暗主题在全 App 可用；同时完成核心路径（登录 / 项目 / 文件夹 / 宫格 / 预览 / 搜索 / 传输 / 我的）的版式重做。不做后端/数据库改动。

---

## 2. 设计思想对照（新 vs 旧）

| 维度 | 旧（现状） | 新（目标） |
|---|---|---|
| 主题 | 仅浅色，白底 + 橙 `#C2410C` | 深/浅双主题同源，默认跟随系统；金色 `#C1A063`（深）/`#A07B39`（浅） |
| 分层 | 白卡 + 浅灰底，阴影弱 | 深色靠明度三级 + 1px 描边；浅色白卡 + 1px 描边；阴影只托浮层 |
| 字号 | 正文 14、标题 15、页首 17 | 正文 16、列表标题 15.5、二级页标题 17、区块标题 20、页首 27 |
| 页面头 | Material AppBar 20 号字 | 一级页 27 号大标题 + 计数/副标题；二级页 17 号 + 返回 |
| 行/卡 | ListTile 平铺，分割线全宽 | 图标 34 + 标题 15.5 + 副标题 13 的卡片行；卡内 1px 分隔，卡间 12 |
| 强调 | 橙色按钮/图标/徽标 | 金色主按钮（金底深墨字）、金色选中 chip、金色进度、金色页签圆点 |
| 导航 | NavigationBar 胶囊指示器 | 深色/白色底四格，选中文字提亮 + 图标下 4px 金点；角标金色胶囊 |
| 弹层 | Material 默认圆角/把手 | 顶部 24 圆角 + 38×4 拖拽条 + 固定吸底主按钮 |
| Toast | 顶部悬浮条 | 底部 86 的暖炭底细描边条，2.4s 自动消失 |
| 素材占位 | 灰色块/类型色块 | 双径向渐变 + 纸纹感 + 金弧 + 三位编号的“打样卡”（真实缩略图仍在时保留角标/圆角/选中描边） |
| 登录 | 白底 + logo + 表单 | 纸感/墨色渐变 + 桃花瓣飘落（22 片）+ 品牌区 + 金色主按钮 |
| 状态表达 | 主要靠颜色 | 徽标带文字、选中带勾，颜色只是辅助 |

---

## 3. 范围与非目标

### 3.1 本次范围

1. **全局主题系统**：`ThemeExtension` 令牌、明/暗 ThemeData、`ThemeMode.system` 默认、持久化、外观设置面板、状态栏/导航栏自适应。
2. **全库颜色迁移**：所有 UI 文件从静态 `Tk.<color>` 迁到 `context.tk.<token>`；预览固定暗色区域迁到 `Tk.preview*` 静态令牌。迁移完成后旧颜色别名删除，`grep` 为零。
3. **共享组件重做**：按钮/输入/搜索/徽标/空态/错误态/骨架/卡片行/分段/chip/toast/sheet/确认框/类型占位/选择器。
4. **核心页面重做**：登录、项目、文件夹、素材宫格、预览、搜索、传输、我的（含设置入口）。
5. **二级页面视觉统一**：通知、审批、权限、网盘备份、管理后台、错误页、维护弹层、更新弹层、分享/请求链接、各类表单/选择器。以令牌迁移 + 共享组件替换为主，版式按设计语言收敛。
6. **低风险交互增强**：宫格顶部显式「选择/取消」；素材排序 chip；搜索类型 chip（客户端筛选）；预览「详情」面板；导航金色圆点/角标；上传进度胶囊；登录桃花动效（支持 reduced-motion）。
7. **测试**：主题单测（含对比度）、主题切换 widget 测试、核心页面双主题冒烟、既有测试对齐。

### 3.2 明确不做（本周期）

| 项 | 原因 |
|---|---|
| 传输行「右滑取消 / 左滑重试」 | 手势与无障碍成本高，保留行内按钮；记 P2 |
| 搜索「最近搜索」持久化 | 需额外本地存储与清理策略；记 P2 |
| 文件夹页「全部素材」分段 | 后端无项目级全量素材端点；不新增接口 |
| 项目卡统计（文件夹数/素材数/更新时间） | `Project` 契约无这些字段；不新增接口 |
| 我的页三项概览（项目/临时授权/未读） | 无聚合端点，避免 N+1；仅保留未读角标 |
| 后端 / 数据库 / 接口 / FGA | 本次纯前端视觉，不改任何契约 |
| 字体文件打包 | 使用系统字体栈（PingFang/HarmonyOS/MiSans/Noto/YaHei），不新增 asset |
| 新依赖 | 桃花用 `CustomPainter` 自绘；主题持久化复用 `path_provider` |

---

## 4. 设计令牌（唯一事实源）

### 4.1 颜色 · 深色（默认主题）

| 令牌 | 值 | 用途 |
|---|---|---|
| bg | `#131210` | 页面画布 |
| surface | `#1B1915` | 卡片、弹层 |
| surface2 | `#201D18` | 卡内次级块、悬停 |
| surface3 | `#292520` | 图标底、分段底、禁用面 |
| surface4 | `#383228` | 分段选中、抬升面 |
| ink | `#F3EDDF` | 正文 |
| ink2 | `#C6BFB0` | 次级正文 |
| ink3 | `#9A9384` | 元信息 |
| line | `#2E2A23` | 卡片描边、分隔线 |
| lineStrong | `#423B31` | 装饰性发丝线（拖拽把手、层级参考线） |
| controlBorder | `#70695B` | 可交互控件描边（输入框、次级按钮、chip；无障碍加值 ≥3:1，见 D11） |
| gold | `#C1A063` | 主按钮、进度、强调描边 |
| goldBright | `#DCC084` | 深色面高亮金 |
| goldInk | `#E4CB94` | 金色底容器上的金字 |
| goldSoft | `#2B2418` | 金色浅底（徽标/提示条/选中 chip） |
| fillInk | `#F0E8D6` | 需要象牙白填充的少数场景 |
| onFillInk | `#17150F` | fillInk 上的文字 |
| barBg | `#0E0D0A` | 底部导航 |
| barLine | `rgba(255,255,255,.06)` | 导航顶线 |
| tabFg | `#8D887C` | 导航未选中 |
| tabFgActive | `#F6F0E0` | 导航选中 |
| chromeFg | `#ECE5D5` | 状态栏/系统 chrome |
| scrim | `rgba(0,0,0,.62)` | 弹层遮罩 |
| sheen | `rgba(255,255,255,.07)` | 骨架高光 |
| switchKnob | `#D9D2C2` | 开关滑块 |
| ok / okSoft | `#7ECBA6` / `#16281F` | 成功 |
| warn / warnSoft | `#E3B26B` / `#2A2317` | 待处理 |
| danger / dangerSoft | `#EA8A82` / `#2C1817` | 危险文字 |
| dangerFill / onDanger | `#B94C46` / `#FFF4F1` | 危险按钮 |
| shadow1 | `0 1px 2px rgba(0,0,0,.38), 0 10px 28px -20px rgba(0,0,0,.85)` | 卡片托底 |
| shadow2 | `0 22px 48px -24px rgba(0,0,0,.9)` | 浮层 |
| loginBg | `radial-gradient(90% 60% at 80% 0%, rgba(201,169,97,.16), transparent 60%), linear-gradient(178deg,#131210,#12110D 52%,#0F0E0A)` | 登录背景 |
| loginField | `rgba(26,23,18,.84)` | 登录输入底 |
| loginBorder | `rgba(255,255,255,.13)` | 登录输入描边 |
| headBg | `radial-gradient(120% 100% at 100% 0%, rgba(201,169,97,.16), transparent 58%), linear-gradient(160deg,#262117,#1B1813)` | 项目头卡 |

### 4.2 颜色 · 浅色

| 令牌 | 值 |
|---|---|
| bg | `#F6F3EC` |
| surface | `#FFFFFF` |
| surface2 | `#FAF7F1` |
| surface3 | `#EFEAE1` |
| surface4 | `#E6DFD2` |
| ink / ink2 / ink3 | `#17150F` / `#56514A` / `#6F6A5E` |
| line / lineStrong / controlBorder | `#E5DFD3` / `#D3CBBC` / `#918777` |
| gold / goldBright / goldInk | `#A07B39` / `#C9A961` / `#6F5522` |
| goldSoft | `#F4EBD9` |
| fillInk / onFillInk | `#17150F` / `#F7F2E6` |
| barBg / barLine | `#FFFFFF` / `rgba(23,21,15,.09)` |
| tabFg / tabFgActive | `#6F6A5E` / `#17150F` |
| chromeFg | `#17150F` |
| scrim | `rgba(23,21,15,.36)` |
| sheen | `rgba(255,255,255,.8)` |
| switchKnob | `#FFFFFF` |
| ok / okSoft | `#1D6B52` / `#E6F0EB` |
| warn / warnSoft | `#8A5A12` / `#F8ECD8` |
| danger / dangerSoft | `#9D2B2F` / `#FBE9E8` |
| dangerFill / onDanger | `#9D2B2F` / `#FFF6F3` |
| shadow1 | `0 1px 2px rgba(23,21,15,.05), 0 8px 24px -18px rgba(23,21,15,.22)` |
| shadow2 | `0 18px 44px -22px rgba(23,21,15,.32)` |
| loginBg | `radial-gradient(90% 60% at 80% 0%, rgba(201,169,97,.2), transparent 60%), linear-gradient(180deg,#F6F3EC,#F2EEE4)` |
| loginField / loginBorder | `#FFFFFF` / `#D9D1C1` |
| headBg | `radial-gradient(120% 100% at 100% 0%, rgba(201,169,97,.26), transparent 58%), linear-gradient(160deg,#FFFDF8,#F5EFE1)` |

### 4.3 预览固定暗色（两种主题都不变，静态常量）

| 令牌 | 值 |
|---|---|
| `Tk.previewBg` | `#0F0E0A` |
| `Tk.previewSurface` | `#1A1813` |
| `Tk.previewFg` | `#F7F1E2` |
| `Tk.previewFg2` | `#A49D8C` |
| `Tk.previewLine` | `rgba(255,255,255,.09)` |
| `Tk.previewGold` | `#DCC084` |
| `Tk.videoCanvas` | `#000000` |
| `Tk.dangerOnDark` | `#EF8B86` |

### 4.4 字号 / 间距 / 圆角

字号（全库 6 档，正文下限 16、元信息下限 13、徽标 11）：

| 名称 | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| `Tk.fzDisplay` | 27 / 1.15 | 620 | 一级页大标题 |
| `Tk.fzSection` | 20 / 1.35 | 620 | 区块标题、弹层标题 |
| `Tk.fzTitle` | 17 / 1.3 | 600 | 二级页标题；列表标题用 15.5 单独常量 `Tk.fzRowTitle` |
| `Tk.fzBody` | 16 / 1.5 | 400 | 正文、表单 |
| `Tk.fzMd` | 13 / 1.5 | 400 | 元信息 |
| `Tk.fzXs` | 11 / 1.4 | 500 | 微标签（字距 .1em 用于分组标签） |
| 兼容别名 | `fzSm=12`（紧凑标签：页签/徽标）、`fzLg=20`（=fzSection）、`fzMicro=11`、`fzMeta=13` | | 存量代码可继续编译 |
| 新增 | `fzRowTitle=15.5`、`fzStat=22` | | 列表标题、概览数字 |

间距：`spaceXs=4 / spaceSm=8 / spaceMd=12 / spaceLg=16 / spaceXl=24 / space2xl=32 / spacePage=20`（页面左右留白 20）。

圆角：`rXs=6（小徽标）/ rSm=10（输入、按钮）/ rMd=14（卡片）/ rLg=18（媒体块）/ rXl=24（弹层顶部）/ rPill=999`。

> 注意：`rSm/rMd/rLg/rXl` 的数值由旧 `8/12/16/20` 调整为 `10/14/18/24`，属于全局视觉升级；所有引用自动生效，无需逐处改。

### 4.5 动效

- 弹层上滑 260ms `cubic-bezier(.2,.7,.2,1)`，遮罩淡入 220ms。
- 主题切换 220ms 过渡（`MaterialApp.themeAnimationDuration`）。
- 预览切张 260ms；选中态 160ms；列表项不逐条入场。
- 全部动效尊重 `MediaQuery.disableAnimations` / `prefers-reduced-motion`，降级为瞬时；登录桃花在 reduced-motion 下不启动（或静态低透明度展示）。
- 触控目标 ≥44×44，相邻 ≥8。

---

## 5. 主题架构与迁移规则（硬约束）

### 5.1 主题令牌实现

新增 `lib/theme/tk_colors.dart`：

```dart
@immutable
class TkColors extends ThemeExtension<TkColors> {
  const TkColors({
    required this.brightness,
    required this.bg, required this.surface, required this.surface2,
    required this.surface3, required this.surface4,
    required this.ink, required this.ink2, required this.ink3,
    required this.line, required this.lineStrong,
    required this.gold, required this.goldBright, required this.goldInk,
    required this.goldSoft, required this.fillInk, required this.onFillInk,
    required this.barBg, required this.barLine,
    required this.tabFg, required this.tabFgActive, required this.chromeFg,
    required this.scrim, required this.sheen, required this.switchKnob,
    required this.ok, required this.okSoft, required this.warn, required this.warnSoft,
    required this.danger, required this.dangerSoft, required this.dangerFill, required this.onDanger,
    required this.shadow1, required this.shadow2,
    required this.loginBg, required this.loginField, required this.loginBorder, required this.headBg,
  });

  static const TkColors dark = TkColors(...);
  static const TkColors light = TkColors(...);
  static TkColors of(Brightness b) => b == Brightness.dark ? dark : light;

  @override TkColors copyWith({...});
  @override TkColors lerp(ThemeExtension<TkColors>? other, double t);
}
```

`lib/theme/context_tk.dart`：

```dart
extension TkContext on BuildContext {
  TkColors get tk => Theme.of(this).extension<TkColors>() ?? TkColors.of(Theme.of(this).brightness);
}
```

> `??` 兜底必须是**不带 context 的静态回退**：既有 widget 单测常裸挂 `MaterialApp` 默认主题，不能因缺 extension 崩溃。

`Tk`（`lib/theme/tokens.dart`）只保留：
- 字号/间距/圆角常量；
- 预览固定暗色常量（§4.3）；
- **临时**旧颜色别名（light 值 + `@Deprecated('use context.tk')`），用于在分工作包并行迁移期间保持编译；全部迁移完成后由收尾包删除。

### 5.2 主题组装

`lib/theme/app_theme.dart` 导出 `ThemeData buildAppTheme(Brightness brightness)`：

- 显式 `ColorScheme`（不用 `fromSeed`）：
  - `brightness`, `primary=gold`, `onPrimary=#1A1509`, `primaryContainer=goldSoft`, `onPrimaryContainer=goldInk`
  - `surface=surface`, `onSurface=ink`, `surfaceContainerHighest=surface3`, `surfaceContainerHigh=surface2`, `surfaceContainerLow=surface2`
  - `error=danger`, `onError=onDanger`, `errorContainer=dangerSoft`, `onErrorContainer=danger`
  - `outline=line`, `outlineVariant=line`, `surfaceTint=Colors.transparent`
  - `inverseSurface=fillInk`, `onInverseSurface=onFillInk`
- `scaffoldBackgroundColor=bg`
- `AppBarTheme`：`backgroundColor=bg`、`foregroundColor=ink`、`elevation=0`、`scrolledUnderElevation=0`、`centerTitle=false`、`toolbarHeight=60`、`titleTextStyle=17/600`、`iconTheme=ink/22`、`systemOverlayStyle` 按 brightness 给状态栏浅/深图标、底部 1px line 分隔（`shape`）。
- `NavigationBarThemeData`：保留（旧 `AppTabBar` 会改为自绘，但其它页面可能仍用）。
- `CardThemeData`：`surface`、`elevation=0`、`margin=0`、圆角 14、1px line 描边。
- `InputDecorationTheme`：`filled=true`、`fillColor=bg`（内凹）、`border=OutlineInputBorder(rSm, controlBorder 1)`、`enabledBorder` 同、`focusedBorder` 金色 1.5 + 3px 光晕（用 `GoldGlowInputBorder`，见下）、`errorBorder=danger`、`hintStyle=ink3`、`labelStyle=ink2`、`floatingLabelStyle=goldInk`、`errorStyle=danger`、`contentPadding=12/12`、`isDense=false`。
- `FilledButtonThemeData`：金底 `gold`、前景 `#1A1509`、`minimumSize=Size(44,48)`、圆角 `rSm`、字号 15.5/600；disabled 透明度 0.45。
- `OutlinedButtonThemeData`：透明底 + `lineStrong` 描边、前景 `ink`、48 高。
- `TextButtonThemeData`：前景 `goldInk`、最小高 44。
- `IconButtonThemeData`：44×44、颜色 `ink`。
- `DividerThemeData`：`line`、space 1。
- `ListTileThemeData`：`iconColor=ink2`、`titleTextStyle=15.5/550`、`subtitleTextStyle=13/ink3`、`contentPadding=16`、`minVerticalPadding=12`。
- `BottomSheetThemeData`：`backgroundColor=surface`、`modalBackgroundColor=surface`、`shape=顶部 rXl`、`dragHandleColor=lineStrong`、`dragHandleSize=Size(38,4)`、`barrierColor=scrim`。
- `DialogThemeData`：`backgroundColor=surface`、圆角 `rXl`、标题 20/620、内容 16/ink2、`barrierColor=scrim`。
- `SnackBarThemeData`：深色暖炭底（toast 自定义，但兜底统一）。
- `ChipThemeData` / `FilterChipThemeData`：`surface2` 底 + `lineStrong` 描边；选中 `goldSoft` + `gold` 描边 + `goldInk` 文字；高度 44。
- `TextTheme` 按 §4.4 组装；全局 `FontFeature.tabularFigures()`（数字等宽），保留。
- 字体：不设 `fontFamily`，用系统默认；`fontFamilyFallback` 可留空。中文标题负字距 -0.01~-0.02em，英文/数字标签正字距 .1em（在具体文字样式里设）。

`lib/theme/app_typography.dart` 放 TextTheme 组装与 tabularFigures，避免 `app_theme.dart` 超 300 行。

`lib/theme/gold_input_border.dart`：`GoldGlowInputBorder extends OutlineInputBorder`，`paint` 时先画 3px `gold.withValues(alpha:.14)` 外圈再画 1.5px 金边；用于 `focusedBorder`。若实现风险高，降级为仅 1.5px 金边并在验收记录中标注（不阻塞）。

### 5.3 主题控制器与持久化

`lib/theme/theme_store.dart`：

- `ThemeStore({Future<String?> Function()? read, FutureOr<void> Function(String)? write})`，可注入（单测零 IO）。
- `ThemeStore.openDefault()` 使用 `getApplicationSupportDirectory()/theme.txt`；打开失败返回 null（静默降级仅内存）。
- `read()` 返回 `'system'|'dark'|'light'` 或 null；非法值按 `system`。

`lib/theme/theme_controller.dart`：

```dart
enum ThemePref { system, dark, light }
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeStore? store});
  ThemePref pref;          // 默认 system
  ThemeMode get mode;      // system/dark/light
  String labelFor(Brightness systemBrightness); // 「跟随系统 · 深色」/「深色」/「浅色」
  Future<void> load();     // 启动读盘；失败保持 system
  Future<void> setPref(ThemePref); // 更新 + notify + 异步落盘
}
final themeController = ThemeController();
```

`main()` 改 `Future<void> main() async`：`WidgetsFlutterBinding.ensureInitialized(); await themeController.load();` 再执行现有初始化；读取失败不阻塞。

`app.dart`：

- `AnimatedBuilder(animation: themeController)` 包 `MaterialApp`。
- `theme: buildAppTheme(Brightness.light)`、`darkTheme: buildAppTheme(Brightness.dark)`、`themeMode: themeController.mode`、`themeAnimationDuration: 220ms`。
- `builder` 现有维护弹层 Stack 外包 `AnnotatedRegion<SystemUiOverlayStyle>`：按当前 `Theme.of(context).brightness` 设置 `statusBarColor=bg`、`statusBarIconBrightness`（深色主题 light icons / 浅色主题 dark icons）、`systemNavigationBarColor=barBg`、`systemNavigationBarIconBrightness` 反向。预览页用嵌套 `AnnotatedRegion` 覆盖为全透明 + 浅色图标，退出自动恢复。
- 不改变路由表与启动逻辑。

### 5.4 外观设置

`lib/features/me/settings_sheet.dart`：`showAppearanceSheet(BuildContext)`，用 `SheetScaffold` + `AppSegmented<ThemePref>`（跟随系统/深色/浅色）+ 说明「跟随系统时，随设备外观自动切换；当前系统为浅色/深色」。选择即 `themeController.setPref`，弹层不关闭，实时预览；持久化异步。
入口两处：
1. 「我的」页右上角 settings 图标；
2. 「我的 → 偏好 → 外观」行（副标题显示当前 `labelFor`）。

### 5.5 全库颜色迁移规则（每个工作包都必须执行）

1. 新增/修改的 UI 代码**不得**再引用 `Tk.<颜色>` 旧别名；一律 `context.tk.<token>`。
2. 映射表（旧 → 新）：
   - `Tk.bg → context.tk.bg`
   - `Tk.surface → context.tk.surface`
   - `Tk.surface2 → context.tk.surface2`
   - `Tk.fill → context.tk.surface3`
   - `Tk.border → context.tk.line`
   - `Tk.fg → context.tk.ink`
   - `Tk.muted → context.tk.ink2`
   - `Tk.subtle → context.tk.ink3`
   - `Tk.accent → context.tk.gold`
   - `Tk.accentStrong → context.tk.goldInk`
   - `Tk.accentSoft → context.tk.goldSoft`
   - `Tk.accentFaint → context.tk.goldSoft`
   - `Tk.green → context.tk.ok`
   - `Tk.amber → context.tk.warn`
   - `Tk.red → context.tk.danger`
   - `Tk.neutral → context.tk.ink3`
   - 预览暗色区：`Tk.dark → Tk.previewBg`、`Tk.darkSurface → Tk.previewSurface`、暗底上的 `Tk.subtle/Tk.fg/Tk.accent` → `Tk.previewFg2/previewFg/previewGold`。
3. `const` 处理：`const TextStyle(color: Tk.x)` 改为非 const `TextStyle(color: context.tk.x)`；`const Icon(color: Tk.x)` 改为非 const。批量替换后跑 `dart format`。
4. 无 `BuildContext` 的工具函数（如 `dangerButtonStyle`、`kindColors`、`highlightText`、`_pill`）加 `BuildContext` 参数；调用点同步。
5. 纯函数单测若断言颜色，改为断言 `TkColors.light/dark` 的期望值。
6. 每个包收尾跑 `dart analyze <自己负责的目录>`，并在交付报告中贴结果；全仓 `flutter analyze` 由验收统一跑。
7. 完成后全库 `grep -rn "Tk\.\(bg\|surface\|surface2\|fill\|border\|fg\|muted\|subtle\|accent\|accentStrong\|accentSoft\|accentFaint\|green\|amber\|red\|neutral\)" lib` 必须为 0（预览静态常量除外）。

### 5.6 单文件 300 行规则与例外

- 新文件一律 ≤300 行；被判超限的既有文件在本次改动中**先拆再改**。
- 已拆分：`login_page(356→214)`、`me_page(404→154)`、`baidu_new_task_page(414→296)`、`batch_move_sheet(343→266)`、`asset_selection_bar(319→255)`、`upload_sheet(314→172)`、`assets_page(324→294)`、`preview_page(302→290)`、`notifications_page(301→238)`、`admin/baidu_task_file_list(323→224)`；收尾另拆 `tk_colors(314→163, part)`、`login_form(339→253)`、`toast(303→288)`、`upload_pick(369→287)`。
- **唯一例外**：`preview_media.dart(674)` 本次只替换 2 处颜色常量（行 497/530），不新增职责，允许保留原文件长度。`notifier.dart(463)`/`transfer_queue.dart(386)` 是本分支未改动的既有核心文件，不纳入本次约束。

---

## 6. 功能点明细（逐条可验收）

### F1 双主题与跟随系统
- 默认 `ThemeMode.system`；系统深色 → 深色调色板，系统浅色 → 浅色调色板。
- 系统外观在 App 运行中变化时实时切换（MaterialApp 自动跟随）。
- 「我的 → 设置 → 外观」三档：跟随系统/深色/浅色；选择立即生效并持久化；重启 App 保持。
- 两种主题下所有页面无“白底白字/黑底黑字”不可读区域；正文对比 ≥4.5:1，图标/描边 ≥3:1。
- 状态栏图标颜色随主题切换；预览页状态栏为浅色图标并沉浸透明。

### F2 主题令牌与旧代码迁移
- `TkColors` 覆盖 §4 全部令牌；`context.tk` 单入口。
- 旧颜色别名全部删除后全仓编译通过。
- 预览、toast、上传胶囊在浅色主题下仍为深色表面。

### F3 共享组件
- `AppCard/SectionCard/SectionLabel/PageHeader/AppRow/AppChip/AppSegmented/StatRow` 新增并有单测/组件测试。
- `Badge` 支持 gold/ok/warn/danger/neutral/outline 六态，22 高、11.5 字、无纯色依赖。
- `EmptyState` 支持图标圆底 + 标题 + 一句可执行说明 + 可选主操作。
- `Toast` 底部 86、暖炭底、细描边、2.4s、错误红色圆点、点击可关；浅色主题下仍深色。
- `SheetScaffold` 顶部 24 圆角、38×4 拖拽条、吸底按钮安全区 16、键盘顶起。
- `AppTextField` 保持 `isDense:false`（历史浮起 label 裁切钉子），聚焦金色光晕；`SearchField` 46 高。
- `ListSkeleton` 使用 surface3 + sheen，呼吸动画尊重 reduced-motion。
- `TypeBlock/AssetPlate` 在无缩略图时呈现双径向渐变 + 金弧 + 编号，而非灰块。

### F4 壳层与导航
- 底部四格自绘：深色主题 `#0E0D0A` 底，浅色白底 + 顶线；未选中 `tabFg`，选中 `tabFgActive` + 图标下 4px 金点。
- 传输角标/通知角标为金色胶囊数字，0 隐藏。
- 一级页（项目/搜索/传输/我的）使用 27 号大标题 + 计数/副标题；二级页 17 号标题 + 返回。
- 返回保留上一页滚动位置与选中态（现有 Navigator 行为不回退）。

### F5 登录页
- 背景按主题使用 `loginBg` 渐变；右上金色光晕。
- 桃花层：22 片、12–27px、40%–77% 透明度、向右下飘落 + 横摆 + 自转 + 翻面；层级在表单之下、不挡触控；离开登录页停止绘制；`disableAnimations` 时不启动；主题切换按新配色重建。
- 品牌区：logo 66、圆角 18、金色细描边；wordmark 21、字距 .18em；下方金色细分隔线。
- 表单：字段标签始终可见（不靠 placeholder）；输入 46 高、内凹底、金色聚焦；探活状态行（金点脉冲）；金色主按钮 48；错误固定高度区；法务小字行。
- 保持现有探活闸门、autofill、密码眼睛、法务外开与回退逻辑。

### F6 项目页
- 大标题「项目」+ 项目数 + 副标题；右上通知铃（未读金点）+ 新建项目。
- 搜索行独立于标题（46 高）；输入即时过滤（现有逻辑）。
- 项目卡：40 金色底首字标记、名称 16/600、code + 角色徽标；卡间 12、圆角 14、1px 描边。
- 管理动作长按菜单保留；空态/错误/加载按新组件。
- 不展示契约不存在的统计字段。

### F7 文件夹页
- 二级页 17 标题（项目名）+ 返回；右上「⋯」项目操作 + 新建一级文件夹（角色闸门不变）。
- 项目头卡：code（微标签金）、项目名 19、meta（文件夹数 / 素材数合计 / 我的角色）——数据由已加载文件夹列表求和，不新增接口。
- 「目录」区块标签 + 行卡片：文件夹图标（敏感=金锁/金底；含文件=实心）、名称 15.5、直属计数徽标（「N 项」为唯一计数位，副标题只表「敏感目录/空文件夹」）、`⋯` 菜单；保留多级缩进/折叠/竖参考线。
- 空态/错误/加载按新组件。

### F8 素材宫格
- 顶栏：返回 + 标题（文件名/夹名；多选时「已选 N」）+ 副标题（项目路径 · N 个素材）+ 右侧「选择/取消」文字钮。
- 「选择」显式进入多选（长按仍可进入）；多选态底部操作栏常驻（0 选中时动作禁用），支持全选/取消全选。
- 面包屑（项目 / 文件夹）+ 计数 + 排序 chip（最新优先/最早优先，客户端排序）+ 3 列宫格。
- 格子：1:1.06 媒体块、圆角 12、无缩略图用 AssetPlate；右上类型角标（PDF/MD/视频/实况）；选中金环 2px + 左上勾；文件名 12.5、元信息 11。
- 上传：金色胶囊 FAB（上传图标 + 文案）；上传进度胶囊位于底部导航上方，显示进度条与「正在上传 N 项」，点击切传输页。
- 批量操作栏：全选/下载/分享/移动/删除/更多（批量打标/前缀/申请权限），触控 ≥44，文案与闸门保持现状。
- 空态：图标圆底 + 标题 + 说明 + 上传主操作。
- 回收站入口保持文件夹菜单内。

### F9 预览
- 暗色画布 `#0F0E0A`；顶部渐变条（关闭 / n/N / 更多）；单击沉浸；横滑切张保留；胶片条保留并重做。
- 底部元数据浮层（`#1A1813` 圆角 18）：文件名 15.5、类型/大小/时间 12、标签 chips、备注。
- 操作行五项：下载（入队后「已入队 ✓」金色）/ 分享 / 标签 / 申请权限 / 详情；详情打开 `PreviewDetailSheet`（文件名/类型/大小/时间/位置/标签/备注）。
- 搜索入口的预览序列可能跨文件夹：`PreviewArgs.folderIds/wheres` 提供逐素材映射；`PreviewPermissions` 按**当前素材的 folderId** 逐夹补水 `canDownload`，下载 where / 详情 where / 标签编辑 folderId 均随当前素材（D16）。
- 状态栏浅色图标；退出恢复。
- `preview_media.dart` 仅替换 2 处颜色常量（见 §5.6 例外）。

### F10 搜索
- 一级页大标题「搜索」+ 副标题；搜索框 46；类型 chip 轨道（全部/图片/视频/PDF/Markdown），客户端按 `detectKind` 过滤结果。
- 结果行：44 缩略图 + 名称高亮（金浅底/金字）+ 归属（项目/文件夹）+ 类型徽标 + chevron。
- 空态/未搜索态/无结果/50 条截断提示按新语言。
- 最近搜索不在本期（P2）。

### F11 传输
- 一级页大标题「传输」+ 计数 + 副标题「上传与下载在后台继续…」；右上「清已完成」。
- 分段 全部/上传/下载（计数）；任务卡：图标容器、文件名 15.5、路径 13、状态徽标、金色进度条、字节/百分比；取消/重试/移除保留并确认。
- 空态引导。
- 底部导航角标、宫格胶囊、传输页三处同源 TransferQueue（现有逻辑）。

### F12 我的
- 一级页大标题「我的」+ 右上设置。
- 身份卡：56 金色底头像、姓名 19、角色徽标。
- 分组：协作（审批/通知/我的权限/回收站）、网盘与传输（网盘备份/传输通知）、偏好（外观）、管理（admin tiles）、账号与安全（改密/退出）、诊断（日志/当前服务）、关于（版本/检查更新）。
- 「外观」行显示当前模式（跟随系统 · 深色 / 深色 / 浅色）。
- 不展示无数据支撑的三项统计。

### F13 二级页面
- 通知：17 标题 + 未读数 + 全部已读；行卡未读金点/金浅底、kind 徽标、相对时间；自动加载保留。
- 审批：17 标题 + 待审数；分段待我审批/我发起；审批卡状态徽标、申请人、对象、理由、有效期、批准/拒绝（确认+备注）。决策按钮：拒绝=ghost、批准=gold。
- 权限：17 标题；区块「临时授权」「项目角色」「仅访客」；行卡 + 角色徽标。
- 网盘：绑定卡（状态徽标、账号/授权期、绑定/切换、新建任务、解绑）；任务卡（进度金/失败红/完成绿、统计、操作）；新建任务分步；绑定授权码页。
- 管理：2 列磁贴（金图标 + 标题 + 说明）；用户/用户组列表卡；审计 chip 筛选 + 金色竖线时间线；授权模板/目录模板/备份任务列表卡。
- 错误页、维护弹层、更新弹层、分享/请求链接、各表单/选择器：令牌迁移 + 卡片/按钮/输入统一。

### F14 可访问性
- 图标按钮均有 tooltip/语义；导航项 `Semantics(selected:)`；选中态有勾/文字，不只靠颜色。
- 正文对比 ≥4.5、图标/描边 ≥3（用纯 Dart 计算并测试）；可交互控件统一用 `controlBorder`（≥3:1），`lineStrong` 只作装饰发丝线（D11）。
- 触控 ≥44；支持系统字号放大 1.3 不裁切（固定高度改 minHeight / 弹性）。
- 弹层可 Esc/返回关闭，关闭后焦点回到触发按钮（Material 默认 + 必要时 FocusScope）。

### F15 动效与降级
- 主题切换 220ms；sheet 260ms；预览 260ms；选中 160ms。
- `disableAnimations` 时全部瞬时；桃花不启动；骨架动画静止或低频。
- 低端机：桃花用预计算 Path/Shader，不做逐帧渐变；不引入新依赖。

---

## 7. 组件拆分方案

### 7.1 新增文件（P0 基础设施，全部 ≤300 行）

| 文件 | 职责 | 预估行数 |
|---|---|---|
| `lib/theme/tk_colors.dart` | `TkColors extends ThemeExtension`，深/浅两套常量，copyWith/lerp | 230 |
| `lib/theme/context_tk.dart` | `BuildContext.tk` 扩展（带 brightness 兜底） | 20 |
| `lib/theme/app_typography.dart` | TextTheme/字阶/tabularFigures | 130 |
| `lib/theme/gold_input_border.dart` | 金色聚焦 3px 光晕 InputBorder（可降级） | 70 |
| `lib/theme/app_theme.dart`（重写） | `buildAppTheme(Brightness)` 组装 ThemeData | 270 |
| `lib/theme/theme_store.dart` | theme.txt 读写（可注入） | 80 |
| `lib/theme/theme_controller.dart` | ThemePref/ThemeMode/持久化 ChangeNotifier | 120 |
| `lib/features/me/settings_sheet.dart` | 外观设置面板 | 160 |
| `lib/widgets/app_card.dart` | `AppCard` + `SectionCard` | 140 |
| `lib/widgets/section_label.dart` | `SectionLabel` | 50 |
| `lib/widgets/page_header.dart` | `PageHeader`（大标题/二级标题/返回/动作/计数/副标题） | 160 |
| `lib/widgets/app_row.dart` | `AppRow`（图标 34 + 标题/副标题 + trailing） | 110 |
| `lib/widgets/app_chip.dart` | `AppChip`（44 高胶囊，选中金浅底） | 80 |
| `lib/widgets/app_segmented.dart` | `AppSegmented<T>`（surface3 轨道 + surface4 滑块 + 计数） | 120 |
| `lib/widgets/stat_row.dart` | `StatRow`（3 格，1px 分隔） | 80 |
| `lib/widgets/asset_plate.dart` | 打样卡（双径向渐变 + 金弧 + 编号） | 160 |

各组件接口（P0 必须按此实现，后续工作包直接复用）：

```dart
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding, this.margin, this.onTap, this.radius});
  final Widget child; final EdgeInsetsGeometry? padding; final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap; final double? radius;
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.children, this.margin, this.dividerIndent = 0});
  final List<Widget> children; final EdgeInsetsGeometry? margin; final double dividerIndent;
}

class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.title, this.hint});
  final String title; final String? hint;
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key, required this.title, this.count, this.subtitle, this.actions = const [],
    this.back = false, this.onBack,
  });
  final String title; final String? count; final String? subtitle;
  final List<Widget> actions; final bool back; final VoidCallback? onBack;
}

class AppRow extends StatelessWidget {
  const AppRow({super.key, this.leading, required this.title, this.subtitle, this.trailing, this.onTap, this.goldIcon = false});
  final Widget? leading; final String title; final String? subtitle; final Widget? trailing;
  final VoidCallback? onTap; final bool goldIcon;
}

class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, this.selected = false, this.onTap, this.icon});
  final String label; final bool selected; final VoidCallback? onTap; final IconData? icon;
}

class Segment<T> { const Segment({required this.value, required this.label, this.count}); ... }

class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({super.key, required this.segments, required this.value, required this.onChanged});
  final List<Segment<T>> segments; final T value; final ValueChanged<T> onChanged;
}

class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.items});
  final List<StatItem> items; // StatItem(value,label,onTap?)
}

class AssetPlate extends StatelessWidget {
  const AssetPlate({super.key, this.seed = 0, this.child, this.borderRadius});
  final int seed; final Widget? child; final BorderRadius? borderRadius;
}
```

### 7.2 页面级新增/拆分文件

| 文件 | 职责 | 预估行数 |
|---|---|---|
| `lib/features/projects/project_card.dart` | 项目卡（标记/名称/code/角色） | 110 |
| `lib/features/folders/project_head.dart` | 项目头卡（code/名称/meta） | 110 |
| `lib/features/assets/assets_header.dart` | 宫格面包屑/计数/排序 chip | 120 |
| `lib/features/assets/asset_kind_tag.dart` | 类型角标（PDF/MD/视频/实况） | 80 |
| `lib/features/assets/upload_progress_pill.dart` | 上传胶囊（进度条+文案+跳转） | 100 |
| `lib/features/auth/login_brand.dart` | 品牌区（logo/wordmark/金线） | 80 |
| `lib/features/auth/login_petals.dart` | 桃花 CustomPainter/动画 | 220 |
| `lib/features/auth/login_form.dart` | 登录表单（字段/状态/按钮/法务） | 220 |
| `lib/features/me/me_header_card.dart` | 身份卡 | 90 |
| `lib/features/me/me_sections.dart` | 分组构建器 + 外观行 | 150 |
| `lib/features/preview/preview_chrome.dart` | 顶部/底部 chrome 组装 | 120 |
| `lib/features/preview/preview_detail_sheet.dart` | 详情面板 | 100 |
| `lib/features/notifications/notifications_body.dart` | 列表/分页体 | 140 |
| `lib/features/baidu/new_task_step_views.dart` | 新建任务两步视图 | 220 |
| `lib/features/assets/selection_actions_menu.dart` | 选择栏溢出菜单 | 90 |
| `lib/features/assets/upload_guide.dart` | 空态引导 + 跳过清单 | 140 |
| `lib/features/admin/baidu_task_file_rows.dart` | 文件明细行 | 120 |

> 拆分后原文件保留编排/状态，子文件只做展示，避免状态分散。

### 7.3 可复用资产映射

| 需求 | 直接复用 | 改造复用 | 新建 |
|---|---|---|---|
| 卡片/行 | — | `Card`/`Container` 页面内实现 | `AppCard/SectionCard/AppRow` |
| 页面头 | 现有 `AppBar` | 二级页 AppBar 主题化 | `PageHeader` |
| 徽标 | `widgets/badge.dart` | 六态映射 + 尺寸 | — |
| 空态/错误 | `empty_state.dart`/`error_view.dart` | 增加标题/说明/动作 | — |
| 骨架 | `list_skeleton.dart` | 颜色/圆角/动效 | — |
| 弹层 | `sheet_scaffold.dart` | 圆角/把手/吸底 | — |
| 输入 | `form_text_field.dart`/`password_field.dart`/`search_field.dart` | 主题化 + 标签/光晕 | `GoldGlowInputBorder` |
| Toast | `toast.dart` | 位置/配色/时长 | — |
| 分段/chip | `SegmentedButton`/`FilterChip` | 主题化 | `AppSegmented/AppChip` |
| 项目角色 | `role_badge.dart`/`role_chips.dart` | 配色随 token | — |
| 类型占位 | `type_block.dart` | 接 `AssetPlate` | `AssetPlate` |
| 缩略图 | `thumbnail_image.dart` | 占位换 AssetPlate | — |
| 桃花 | 原型 `app.js` 算法 | Flutter 自绘 | `LoginPetals` |
| 主题持久化 | `TransferStore` 模式 | 同款可注入读写 | `ThemeStore/ThemeController` |

---

## 8. 数据库修改方案

不涉及。无表/字段/索引/迁移。

## 9. 接口定义

不涉及。无新增/修改 API。

数据契约限制（UI 不得编造）：
- `Project` 无 folder/asset 统计、无 updated_at；项目卡不显示统计。
- `Me` 无项目数/临时授权数；我的页不做三项概览。
- 无项目级「全部素材」端点；文件夹页不做该分段。
- 素材列表仅分页返回；宫格计数用 `total`，大小用已加载项求和并标注「已加载」。

---

## 10. 前端改动点（按工作包）

### WP0 · 主题基础（先做，硬依赖）
- 新增 §7.1 全部文件；重写 `theme/tokens.dart`、`theme/app_theme.dart`；改 `main.dart`、`app.dart`。
- `tokens.dart` 保留旧颜色别名（light 值 + deprecated）保证并行期编译。
- 单测：`test/theme/theme_store_test.dart`、`theme_controller_test.dart`、`theme_palette_test.dart`（含对比度计算）、`settings_sheet_test.dart`。
- 完成标准：`flutter analyze` 0 error；app 可在 system/dark/light 三态启动；设置面板可切换并持久化；旧别名仍可编译。

### WP1 · 共享组件与基础件
- 文件：`lib/widgets/**`（badge、empty_state、error_view、list_skeleton、buttons、app_confirm、form_text_field、password_field、search_field、sheet_scaffold、toast、type_block、copy_button、handle_strip、role_chips、pickers/**）。
- 使用 WP0 组件与 token；保持公共 API 向后兼容（新增可选参数）。
- 更新 `test/widgets/**` + `test/features/toast_polish2_test.dart` 等。
- 注意：`dangerButtonStyle()` 增加 `BuildContext` 参数；`kindColors` 增加 context；`highlightText` 增加 context。
- 完成标准：共享组件在明暗两主题下视觉成立；测试全绿；`dart analyze lib/widgets` 0。

### WP2 · 壳层 + 项目/搜索/传输/我的
- 文件：`features/shell/home_shell.dart`、`tab_bar.dart`；`features/projects/projects_page.dart` + 新 `project_card.dart`；`features/search/search_page.dart`、`result_row.dart`；`features/transfers/transfers_page.dart`、`transfer_card.dart`；`features/me/me_page.dart` + 新 `me_header_card.dart`、`me_sections.dart`、`admin_tiles.dart`、`collab_tiles.dart`、`update_tile.dart`、`settings_sheet.dart`（WP0 创建，WP2 只接入）。
- 拆分 `me_page.dart`（404）≤300；`projects_page` 用 `project_card` 控制行数。
- 更新：`test/features/tab_bar_badge_test.dart`、`me_collab_badge_test.dart`、`me_page_stamp_test.dart`、`projects_page_ux_test.dart`、`projects_polish2_test.dart`、`search_page_test.dart`、`transfers_page_test.dart`、`pages_polish_test.dart`。
- 完成标准：四 tab 双主题冒烟；导航金点/角标；设置入口可达；测试全绿。

### WP3 · 登录与改密
- 文件：`features/auth/login_page.dart`（拆分）、新 `login_brand.dart`、`login_petals.dart`、`login_form.dart`；`change_password_page.dart`。
- 保留探活闸门/autofill/密码眼睛/法务外开逻辑；桃花尊重 reduced-motion。
- 更新：`test/features/login_polish_test.dart`、`auth_polish2_test.dart`、`password_pages_toggle_test.dart`、`probe_*`。
- 完成标准：双主题登录页、桃花只在登录页、无 pumpAndSettle 卡死（测试用定长 pump）；测试全绿。

### WP4 · 素材域
- 文件：`features/assets/assets_page.dart`（拆分）、`assets_body.dart`、`asset_tile.dart`、`asset_selection_bar.dart`（拆分）、`trash_page.dart`、`upload_sheet.dart`（拆分）、`thumbnail_image.dart`；新 `assets_header.dart`、`asset_kind_tag.dart`、`upload_progress_pill.dart`、`selection_actions_menu.dart`、`upload_guide.dart`；`batch_move_sheet.dart`（拆分）、`batch_tag_sheet.dart`、`batch_prefix_sheet.dart`、`selection_actions.dart`。
- 保留上传/下载/删除/批量逻辑与闸门；新增显式选择态/排序/类型角标。
- 更新：`test/features/assets_*`、`asset_selection_bar_test.dart`、`upload_*`、`trash_page_test.dart`、`batch_*`。
- 完成标准：宫格双主题、选择态、排序、上传胶囊；测试全绿。

### WP5 · 文件夹域
- 文件：`features/folders/folders_page.dart`、`folder_row.dart`、`folder_menu_sheet.dart`、`folder_form_sheet.dart`、`folder_invite_sheet.dart`、`folder_invite_form.dart`、`folder_grants_sheet.dart`、`folder_grants_form.dart`、`move_folder_sheet.dart`、`folder_tree.dart`（仅如引颜色）；新 `project_head.dart`。
- 保留树/折叠/敏感/计数/菜单闸门。
- 更新：`test/features/folder_*`、`folders_*`、`move_folder_sheet_test.dart`。
- 完成标准：项目头卡数据正确（列表求和）、双主题树行、测试全绿。

### WP6 · 预览域
- 文件：`features/preview/preview_page.dart`（拆分）、`preview_permissions.dart`（逐素材权限解析）、`preview_actions.dart`、`meta_panel.dart`、`filmstrip.dart`、`preview_doc_views.dart`、`preview_player.dart`、`request_access_sheet.dart`；新 `preview_chrome.dart`、`preview_detail_sheet.dart`；`preview_media.dart` 仅 2 处颜色常量（例外，不改结构）。
- 保留横滑/沉浸/胶片条/入队就地态/申请权限；新增详情面板。
- 更新：`test/features/preview_*`、`filmstrip_test.dart`、`request_access_sheet_test.dart`。
- 完成标准：预览双主题（固定暗色）、详情面板、测试全绿。

### WP7 · 通知/审批/权限
- 文件：`features/notifications/notifications_page.dart`（拆分）、新 `notifications_body.dart`、`notification_row.dart`；`features/approvals/approvals_page.dart`、`approval_card.dart`；`features/permissions/my_permissions_page.dart`、`grant_row.dart`。
- 更新：`test/features/notifications_page_test.dart`、`approvals_page_test.dart`、`my_permissions_page_test.dart`。
- 完成标准：列表卡/金点/徽标/分段；测试全绿。

### WP8 · 网盘备份
- 文件：`features/baidu/**` 全部（baidu_page、baidu_binding_card、baidu_task_card、baidu_new_task_page 拆分 + 新 `new_task_step_views.dart`、new_task_source_step、task_detail_page、bind_code_page、bind_step_views、netdisk_tree_sheet、baidu_target_picker、baidu_task_files）。
- 更新：`test/features/baidu_*`、`bind_code_page_test.dart`。
- 完成标准：绑定卡/任务卡/分步页双主题；拆分后 ≤300；测试全绿。

### WP9 · 管理后台
- 文件：`features/admin/**` 全部（admin_home、admin_users_page、admin_user_row、admin_groups_page、admin_audit_page、audit_event_card、audit_filter_bar、audit_labels、admin_grant_templates_page、grant_template_row、grant_template_form_sheet、admin_folder_templates_page、folder_template_form_sheet、admin_baidu_tasks_page、baidu_task_detail_sheet、baidu_task_file_list 拆分 + 新 `baidu_task_file_rows.dart`、apply_default_sheet、apply_default_result_view、admin_form_skeleton、admin_auto_load、user_form_sheets、user_edit_sheet、group_form_sheet、group_members_sheet、temp_password_sheet、admin_user_row）。
- 更新：`test/features/admin_*`。
- 完成标准：2 列磁贴、列表卡、审计时间线、双主题；测试全绿。

### WP10 · 项目表单/分享/请求链接
- 文件：`features/projects/**` 除 `projects_page.dart`/`project_card.dart`（WP2）外的全部：new_project_sheet、new_project_form、new_project_no_permit、project_create_fail、project_members_sheet、member_add_form、initial_grants_field、artist_account_field、folder_template_field、minio_buckets、project_grants_overview、role_badge、deleted_projects_page；`features/share/**`。
- 更新：`test/features/new_project_sheet_test.dart`、`project_members_sheet_test.dart`、`request_link_sheet_test.dart`、`share_create_sheet_test.dart`、`deleted_projects_page_test.dart`、`forms_*`、`minio_bucket_picker_test.dart`、`role_badge_test.dart`。
- 完成标准：表单/弹层/分享双主题；`AppTextField` 标签不裁切；测试全绿。

### WP11 · 全局浮层与错误页
- 文件：`core/maintenance/maintenance_overlay.dart`、`core/update/update_dialogs.dart`、`core/error_boundary.dart`、`features/error_report/error_report_page.dart`（必要时拆分）、`features/me/log_push.dart`（如引颜色，WP2 负责则跳过）。
- 更新：`test/core/maintenance_banner_test.dart`、`test/core/error_boundary_test.dart`、`test/features/error_report/*`、`test/core/update/*`。
- 完成标准：维护/更新/错误页双主题；测试全绿。

### WP12 · 收尾与迁移审计（所有包完成后）
- 删除 `tokens.dart` 旧颜色别名。
- 全库 grep 旧颜色引用 = 0；`flutter analyze` 0；`flutter test` 全绿。
- 新增 `test/theme/theme_switch_widget_test.dart`（系统/深/浅切换）、`test/theme/dark_light_smoke_test.dart`（核心页面 320×640/390×844 双主题无 overflow）。
- 汇总遗留 P2。

---

## 11. 测试功能点

### 11.1 主题单元测试
- `TkColors.dark/light` 全部令牌值与 §4 表一致。
- 对比度：`ink/bg`、`ink/surface`、`ink2/surface`、`ink3/surface`、`goldInk/goldSoft`、`danger/dangerSoft` 等文本对 ≥4.5；`gold/bg`、`line/gold` 等描边 ≥3（纯 Dart 计算）。
- `ThemeStore`：写入/读取 `system|dark|light`；非法值→system；读写异常→null 且不抛。
- `ThemeController`：默认 system；setPref 更新 mode/notify/持久化；load 失败保持 system；label 文案三态。
- `TkColors.lerp` 在 t=0/1 返回两端。

### 11.2 主题切换 Widget 测试
- 系统深色（`platformBrightness=dark`）→ 应用深色 palette；系统浅色→浅色。
- 打开设置面板选「深色」→ `MaterialApp.themeMode==dark`，页面背景为深色；选「浅色」→ 浅色；选「跟随系统」→ system。
- 重启模拟：新 `ThemeController` load 持久化值 → 恢复上次选择。
- 设置面板入口：我的页 settings 图标 + 外观行均可打开。

### 11.3 核心页面双主题冒烟
在 390×844 与 320×640 下分别以 light/dark pump：登录、项目、文件夹、宫格、搜索、传输、我的、通知、审批、权限、网盘、管理首页、错误页。
- 无 `RenderFlex overflow` 异常；
- 关键文案存在；
- 背景色/文字色随主题变化（至少断言 Scaffold 背景/标题颜色）。

### 11.4 组件测试
- `Badge` 六态颜色/文字；`EmptyState` 动作回调；`Toast` 底部位置/2.4s 消失/点击关闭/错误点；`SheetScaffold` 圆角/把手/吸底；`AppTextField` 聚焦金边、`isDense=false`；`SearchField` 清除；`AppSegmented` 选中切换/计数；`AppChip` 选中金浅底；`AssetPlate` 无缩略图渲染；`ListSkeleton` reduced-motion；`PageHeader` 返回/动作/计数。

### 11.5 交互功能测试
- 宫格：「选择」进入多选（0 选中操作栏可见且动作禁用）；长按仍进入；全选/取消；取消退出；排序 chip 切换顺序。
- 搜索：类型 chip 过滤；高亮；50 条提示。
- 预览：详情面板打开/字段；下载入队「已入队 ✓」；横滑切张；沉浸；**跨文件夹搜索预览按当前素材切换下载权/where/标签 folderId（含失败路径）**。
- 登录：探活中按钮禁用/ready 恢复；密码眼睛；法务外开回退；桃花在 `disableAnimations` 下不启动。
- 导航：传输角标/通知角标；选中金点；切 tab 保持状态。
- 主题：切换后列表页滚动位置不丢（Navigator 不重建）。

### 11.6 回归测试
- 全量 `flutter test`（现有 130+ 测试文件）通过；仅允许更新断言旧视觉结构的用例，禁止削弱行为断言。
- `flutter analyze` 0 error/warning（或与基线一致）。
- 上传/下载/删除/移动/打标/分享/审批/网盘/管理核心路径不回归（复用现有测试）。

---

## 12. 验收标准（PM 逐项打勾）

1. `flutter analyze` 0 error；`flutter test` 全绿；贴真实输出。
2. 旧颜色引用 grep 为 0（预览静态常量除外）；无新增硬编码 `Color(0x...)`（预览/媒体叠加例外）。
3. 默认跟随系统；设置三档可切换并持久化；重启保持。
4. 登录/项目/文件夹/宫格/预览/搜索/传输/我的 8 个核心页在明暗两主题下截图级成立（PM 肉眼 + 冒烟测试）。
5. 二级页面（通知/审批/权限/网盘/管理/错误/维护/更新/分享/表单）无不可读区域。
6. 320 宽 + 字号 1.3 无 overflow。
7. 新/改文件 ≤300 行（§5.6 例外清单除外）。
8. 组件化：新组件按 §7.1 接口落地；页面不重复实现卡片/行/分段/chip。
9. 无新增依赖；pubspec 不变。
10. 现有行为与权限闸门零回归。

---

## 13. 模糊点与决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 是否全 App 重做还是只核心页 | **全 App 令牌迁移 + 核心页重做 + 二级页统一** | 双主题必须全库迁移才成立；二级页用共享组件低成本统一，避免两套语言 |
| D2 | 是否改交互（多选入口/滑动操作/最近搜索） | 只做低风险：显式「选择」、排序、类型筛选、详情面板、导航金点；滑动操作/最近搜索/全部素材分段不做 | 手势与持久化成本高，且不属于“视觉表现”核心；无 API 的分段不做 |
| D3 | 登录桃花是否实现 | **实现**，自绘 + reduced-motion 降级 | 设计识别元素，自包含；不引依赖 |
| D4 | 是否引入自定义字体 | 不引入，用系统中文栈 | iOS/Android 系统字体已覆盖；避免包体与授权问题 |
| D5 | 主题持久化方式 | 复用 `path_provider` 写 `theme.txt`，可注入；不引 shared_preferences | 项目已有 path_provider 与同款存储模式；单测零 IO |
| D6 | 项目卡/我的页缺数据 | 不显示不存在的统计；用已有数据（文件夹列表求和）展示项目头卡 | 不编造业务指标、不新增接口 |
| D7 | 字号整体上调是否影响布局 | 采用设计字阶（正文 16/页首 27），以 minHeight/弹性布局适配；320 宽冒烟 | 设计明确要求；需防裁切 |
| D8 | 预览是否随主题变浅 | 否，预览画布/浮层/toast/上传胶囊固定深色 | 设计规范 §3.1 明示；媒体查看惯例 |
| D9 | 旧 `Tk` 颜色别名何时删 | 并行期保留 deprecated，收尾包统一删除并 grep 审计 | 避免并行包互相阻塞编译 |
| D10 | 是否保留胶片条 | 保留并重做（设计原型省略但现有可用性价值高） | 不牺牲既有能力；横滑+胶片条并存 |
| D11 | 设计 `lineStrong`（#423B31/#D3CBBC）作可交互描边仅 ~1.6:1，与“描边 ≥3:1”冲突 | **保留 `lineStrong` 作装饰发丝线；新增 `controlBorder`（深 #70695B / 浅 #918777）用于输入框/次级按钮/chip/可交互卡边** | 兼顾设计原值与无障碍；实算 3.19–3.54:1，写入对比度测试 |
| D12 | 文件夹直属计数展示位置（徽标 vs 副标题） | **保留既有「N 项」徽标为唯一计数位**；副标题只表「敏感目录/空文件夹」 | 不删除已上线功能；同时消除 P2-3 的重复展示 |
| D13 | 搜索进入预览 `canDownload=null` 导致申请权限死路 | **预览页在 null 且知 folderId 时拉单夹详情补水**；失败保持中性 | 关闭权限闭环，不新增接口；后端 403 仍是最终裁决 |
| D14 | 新增 `StatRow` 无数据可展示 | **用于「我的权限」概览（项目角色/临时授权/仅访客）** | 用已加载真实数据，避免死组件/编造指标 |
| D15 | 320 宽 + 字号 1.3 下按钮/标签截断 | 网盘绑定按钮窄屏纵向、选择栏/预览操作标签两行、登录错误区最小高 | 真机小屏与大字场景可用性优先；不改业务逻辑 |
| D16 | 搜索预览序列跨文件夹共用首个 folderId，下载权/路径/编辑 folderId 可能错位 | **`PreviewArgs` 增逐素材 `folderIds/wheres`；`PreviewPermissions` 按当前素材 folderId 逐夹补水并缓存** | 搜索结果天然跨夹；按素材解析才符合权限边界；单夹入口仍走页面级三态零额外请求 |
| D17 | 登录输入框 `loginBorder` 对比度仅 ~1.5:1 | 登录输入框启用态改用 `controlBorder`；`loginBorder` 令牌保留但不再用于输入框 | 登录是首屏关键输入；与全站可交互描边口径一致；保留设计原值备查 |

---

## 14. 工作包派发顺序

```
WP0 主题基础（串行，硬依赖）
  ├─ WP1 共享组件
  ├─ WP2 壳层+项目/搜索/传输/我的
  ├─ WP3 登录/改密
  ├─ WP4 素材域
  ├─ WP5 文件夹域
  ├─ WP6 预览域
  ├─ WP7 通知/审批/权限
  ├─ WP8 网盘
  ├─ WP9 管理后台
  ├─ WP10 项目表单/分享
  └─ WP11 全局浮层/错误页
        ↓
WP12 收尾（删别名/grep/全量 analyze+test/双主题冒烟）
```

- WP1~WP11 文件归属互斥，全部并行；仅在共享文件（`widgets/**`）由 WP1 独占。
- 每个包的交付报告必须列出：改动文件、每处改动、`dart analyze` 结果、测试结果、未完成/风险。
- 测试专用子智能体在 WP12 后独立派发，做全量回归 + 边界/权限/主题组合；只报问题不修。

---

## 15. 附：原型页面与源码对照

| 原型页面 | Flutter 文件 |
|---|---|
| 登录/改密 | `features/auth/login_page.dart`、`change_password_page.dart` |
| 项目 | `features/projects/projects_page.dart` |
| 文件夹 | `features/folders/folders_page.dart`、`folder_row.dart`、`folder_menu_sheet.dart` |
| 宫格 | `features/assets/assets_page.dart`、`assets_body.dart`、`asset_tile.dart`、`asset_selection_bar.dart` |
| 预览 | `features/preview/preview_page.dart`、`meta_panel.dart`、`preview_actions.dart` |
| 搜索 | `features/search/search_page.dart`、`result_row.dart` |
| 传输 | `features/transfers/transfers_page.dart`、`transfer_card.dart` |
| 我的/设置 | `features/me/me_page.dart`、`settings_sheet.dart` |
| 通知/审批/权限 | `features/notifications/`、`features/approvals/`、`features/permissions/` |
| 网盘 | `features/baidu/` |
| 管理 | `features/admin/` |
| 上传/分享/请求链接 | `features/assets/upload_sheet.dart`、`features/share/` |

---

## 15. 交付状态（2026-10-23）

- 分支：`feat/app-ink-gold-ui`（worktree `E:/qbb/github_not_me/rushes-lab-feat-app-ink-gold-ui`，自 `liuqi`，**未合并、未 commit**，提交/合并由用户拍板）。
- 验证：`dart analyze lib test` **0 issue**；`flutter test --concurrency=4` **1033 全绿**；`pubspec.yaml`/`pubspec.lock` 无改动；无新增依赖、无后端/数据库/API 变更。
- 生产文件 >300：仅 `preview_media.dart(674)`（文档唯一例外，diff 仅 2 行颜色）；`notifier.dart(463)`/`transfer_queue.dart(386)` 为未改动的既有文件；`preview_page.dart` 恰好 300 行。
- 独立测试两轮：首轮 4 个 P1 已闭环；第二轮发现并修复「搜索预览跨文件夹复用首个 folderId」新 P1；终轮无 P0/P1。
- 剩余 P2（可后置）：
  1. 二级页仍在独立 push route 上，底部四格导航不常驻（与设计 IA 的“项目分支内保留页签”有差距；需嵌套 Navigator 架构，另期）。
  2. 预览来源的「标签编辑」sheet 仍随主题变浅；详情/更多已固定深色，标签 sheet 待统一。
  3. 预览权限补水在途/失败时保持中性（下载可点、申请不可用）；可在 UI 上显示“权限解析中”或禁用下载。
  4. 网盘绑定卡 390 宽仍触发 `<340` 纵向布局，阈值需按实际内容宽再调。
  5. TypeBlock 在 48px 胶片条仍用 32px 图标/11px 文本，浅色打样卡上象牙字对比约 3.1–3.25:1，建议小尺寸提高暗角/改白字。
  6. 外观设置面板仍直接 `showModalBottomSheet`，未统一 `SheetScaffold` 关闭钮/吸底；`loginBorder` 令牌保留无 UI 引用。
  7. 真机验收清单：明/暗切换与重启保持、状态栏图标、登录桃花帧率/低端机、320 宽+1.3 字号、预览横滑/沉浸、上传胶囊/角标、设置面板三档、各权限闸门与 401/维护弹层。
- 建议：先真机走一遍上述清单，再 commit + merge `liuqi`；`scripts/changelog.md` 已记账（hash 待提交后补）。
