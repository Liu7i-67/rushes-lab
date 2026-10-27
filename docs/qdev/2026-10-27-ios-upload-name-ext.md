# iOS 相册上传文件名扩展名丢失 — App 端根治

- 日期：2026-10-27
- 分支：`feat/ios-upload-name-ext`（自 `liuqi` dac85e0）
- 范围：**仅 App 端（Flutter）**。后端兜底与存量资产修复按用户指令不在本批（记入遗留项）。

## 1. 背景与目标

### 1.1 现场事实（已实证，勿再推翻）

用户在 iPhone App 上传截图（PNG），系统中落成无扩展名文件，无法在线预览。生产库与对象存储核对结果：

| 项 | 值 |
|---|---|
| filename | `IMG_7B2D32F8-5FC3-4541-80F1-5D21D270BA84-L0-001`（无点） |
| content_type | `application/octet-stream` |
| tags | `{}`（无 `thumbnail_key`） |
| 对象头 16 字节 | `89504e470d0a1a0a0000000d49484452`（标准 PNG 签名，内容完好） |

同机同时刻上传的实况照片（`.livp`）一切正常；线上 7 条 iOS App 上传的 livp **全部**是 `IMG_<localIdentifier>.livp` 兜底名，无一真名。

### 1.2 根因链（本批要根除的就是第 1~3 环）

1. `wechat_assets_picker 9.8.0` 只在 `audioOption` 开 `needTitle`；`photo_manager 3.12.0` iOS 桥接在 `needTitle=false` 时把 `title` 写成**空串**（不是 null）。故 `AssetEntity.title` 在 iOS 上恒为 `''`。
2. `upload_pick.dart` 的 `e.title ?? f.path.split('/').last` 中 `??` 对空串不生效，带真实扩展名的缓存路径永远用不上。
3. `sanitizeUploadName` 从空串取扩展名得 `''`，基名走 `IMG_${e.id}` 兜底（斜杠净化成横杠），最终文件名**没有扩展名**。
4. `enqueueLocalUpload` 按扩展名推 MIME → `application/octet-stream`；后端口径（`is_image_asset`）与 Web 口径（`detectKind`）都按「content_type 前缀 OR 扩展名」判 → 无缩略图、不可预览。

### 1.3 目标

iOS 相册（App 唯一走 `AssetEntity` 的入口）上传的**任何**素材都带正确扩展名与 content_type：截图落 `.png` / `image/png`，普通照片落 `.heic`/`.jpg`，视频落 `.mov`/`.mp4`，实况照片仍落 `.livp`（且基名变可读）。非 iOS 平台行为不得变化。

### 1.4 非目标（本批不做）

- 后端魔数嗅探兜底（B 层）——旧客户端仍在线上，建议下一批做。
- 存量 2 条坏行修复（C 层）——需后端脚本，单独排期。
- `_albumDisplayName`（跳过清单展示名）异步化——见 §7 P2。

## 2. 功能点明细（逐条可验收）

- **F1** iOS 相册上传静态图片：落库 filename 以真实扩展名结尾（如 `IMG_1234.PNG`），content_type 为 `image/png`（或对应图片类型）。
- **F2** 扩展名来源三级优先：`title`（同步；Android 有值，iOS 为空串）→ `titleAsync`（iOS 真名）→ `originFile` 缓存路径扩展名 → `mimeTypeAsync` 映射。任一级命中即止，不留空。
- **F3** 全部来源都拿不到扩展名时：基名仍走 `IMG_${e.id}` 兜底，但用 `mimeTypeAsync` 的 MIME 作为**显式 content_type** 上传（不再退化成 `application/octet-stream`），保证后端能出缩略图、Web 能预览。
- **F4** 实况照片（livp）命名同样改用解析后的真名：`IMG_1234.livp`，且 livp 包内条目基名与文件名一致（不再出现 `IMG_<uuid>-L0-001.livp`）。
- **F5** 解析过程**不得抛错**：`titleAsync`/`mimeTypeAsync` 平台异常（素材已删、iCloud 未下载等）一律吞掉按下一级兜底，上传流程行为与今天一致（失败仍由 `originFile` 为空抛 `StateError` 表达）。
- **F6** 命名净化规则不变：路径分隔符净化、空基名/点文件兜底、`create_upload` 拒 `/` 的约束全部沿用现有 `sanitizeUploadName` + `LivpService.baseNameOf`。
- **F7** content_type 解析优先级：调用方显式传入 > `.livp` 固定 `application/zip` > 扩展名映射（沿用 `contentTypeForFilename`）。
- **F8** 零平台调用开销回归：`e.title` 非空（Android 常态）时不得额外发起 `titleAsync` 调用；`mimeTypeAsync` 仅在扩展名仍未知时才调用。

## 3. 组件拆分方案

### 3.1 新增组件 `AlbumUploadName`（相册素材上传名解析）

- 文件：`material-storage/app/lib/features/assets/album_upload_name.dart`（**新建**，预估 ≤120 行）
- 职责边界：**只做「AssetEntity → (filename, contentType)」的纯解析**，不碰网络、不碰 TransferQueue、不读文件内容。
- 放在 `features/assets/`（而非 `services/`）的理由：它依赖 `upload_sheet.dart` 的 `sanitizeUploadName`，服务层不得反向依赖 features 层。无循环依赖（`upload_sheet.dart` 不 import 本文件）。
- 对外 API（**契约固定，实现与测试都按此写**）：

```dart
/// 解析结果:filename 恒非空且已净化;contentType 为空表示「交给调用方按扩展名推断」。
typedef AlbumUploadName = ({String filename, String? contentType});

/// 扩展名 ↔ MIME。iOS 常见 UTI 派生值;未知/空返回 null。
/// 入参容错:大小写不敏感、允许 `;` 参数、允许前导点。
String? extensionFromMime(String? mime);

/// 解析相册素材上传名(iOS title 空串根治点)。
/// [originPath] = AssetEntity.originFile 的本地缓存路径(可为 null)。
/// [titleOf]/[mimeOf] 仅供测试注入,生产默认 titleAsync / mimeTypeAsync。
/// 不抛错:读取失败按 null 处理并降级。
Future<AlbumUploadName> resolveAlbumUploadName(
  AssetEntity e, {
  String? originPath,
  Future<String?> Function(AssetEntity e)? titleOf,
  Future<String?> Function(AssetEntity e)? mimeOf,
});
```

- `extensionFromMime` 映射表（只收 iOS 会给出的族，未知返回 null）：

| MIME | ext |
|---|---|
| image/png | png |
| image/jpeg | jpg |
| image/heic | heic |
| image/heif | heif |
| image/gif | gif |
| image/webp | webp |
| image/tiff | tiff |
| image/bmp | bmp |
| video/quicktime | mov |
| video/mp4 | mp4 |
| video/x-m4v | m4v |
| video/webm | webm |

- `resolveAlbumUploadName` 算法（**顺序固定**）：
  1. `raw` = 第一个非空（trim 后）的：`e.title` → `await titleOf(e)`（默认 `e.titleAsync`，异常吞为 null）。都空则 `raw = ''`。
  2. `base` = `sanitizeUploadName(raw, fallback: 'IMG_${e.id}')`（复用现有函数，不重写净化）。
  3. `ext` = `extOf(base)`；空则 `extOf(originPath 的 basename)`；再空则 `extensionFromMime(await mimeOf(e))`。都空为 null。归一化：去前导点、`toLowerCase()`。
  4. `filename` = `ext == null ? base : '$base.$ext'`。
     - 若 `base` 已以该扩展名结尾（大小写不敏感）则原样返回，不要拼两次。
  5. `contentType` = `ext == null ? (mime 可识别为 image/* 或 video/* 且非 image/svg+xml ? mime : null) : contentTypeForFilename(filename)`。
- 复用资产（不得重写）：`sanitizeUploadName`（upload_sheet.dart）、`extOf` / `contentTypeForFilename`（core/api/content_types.dart）、`LivpService.baseNameOf`（services/livp.dart）。
- `mimeOf` 惰性求值：只在第 3 步需要时 await 一次，结果缓存到局部变量（contentType 复用同一结果，禁止二次调用）。

### 3.2 改造 `AlbumService.entityToLivp`

- 文件：`material-storage/app/lib/services/album.dart`（**修改**，117 → 预估 ≤128 行，+10/-4）
- 改动：签名加可选 `String? baseName`；传入非空时直接用它作 zip 条目基名，否则维持 `LivpService.baseNameOf(e.title, 'IMG_${e.id}')` 旧行为。其余（iCloud 未下载抛错、无视频退化、解包落盘）**一行不动**。

### 3.3 改造 `enqueueLocalUpload` 的 content_type 解析

- 文件：`material-storage/app/lib/features/assets/upload_sheet.dart`（**修改**，172 → 预估 ≤182 行，+12/-3）
- 改动：
  - 签名加可选 `String? contentType`（显式覆盖）。
  - 抽出纯函数（可单测，避免为了测 3 行逻辑去搭 session/Queue）：
    ```dart
    /// 上传 content_type:显式 override 优先,其次 .livp 固定 zip,再按扩展名推断。
    String uploadContentTypeFor(String filename, {String? override});
    ```
  - `enqueueLocalUpload` 内改用该函数；bytes/path 两轨与 TransferQueue 行为不变。

### 3.4 改造相册入队接线

- 文件：`material-storage/app/lib/features/assets/upload_pick.dart`（**修改**，287 → 预估 ≤325 行，+40/-12）
- `_enqueueAlbumAsset` 改为：
  - 实况轨：`final r = await resolveAlbumUploadName(e);` → `filename = '${LivpService.baseNameOf(r.filename, 'IMG_${e.id}')}.livp'` → `AlbumService.entityToLivp(e, baseName: <同一基名>)` → `enqueueLocalUpload(..., filename:, bytes:)`（contentType 仍由 `.livp` 规则给出，不传 override）。
  - 静态轨：`final f = await e.originFile;`（保持 null 即抛 `StateError`）→ `final r = await resolveAlbumUploadName(e, originPath: f.path);` → `enqueueLocalUpload(..., filename: r.filename, path: f.path, contentType: r.contentType)`。
  - `_albumDisplayName`、`enqueueNamedBatchAndReport`、`_pickFromAlbum` 的成功/跳过汇总逻辑**不动**。
- 文件多选（`_pickFiles`）与 Web/Android 路径**不动**。

### 3.5 组件依赖与数据流

```
_pickFromAlbum (upload_pick)
  └─ _enqueueAlbumAsset
       ├─ resolveAlbumUploadName (album_upload_name)  ──用──> sanitizeUploadName (upload_sheet)
       │        └─ extOf / contentTypeForFilename (core/api/content_types)
       ├─ AlbumService.entityToLivp(baseName:)         (services/album) ──> LivpService.baseNameOf
       └─ enqueueLocalUpload(contentType:)             (upload_sheet) ──> uploadContentTypeFor
```

### 3.6 新增/修改文件清单

| # | 文件 | 动作 | 预估 |
|---|---|---|---|
| 1 | `material-storage/app/lib/features/assets/album_upload_name.dart` | 新建 | ≤120 行 |
| 2 | `material-storage/app/lib/services/album.dart` | 修改 | ≤128 行 |
| 3 | `material-storage/app/lib/features/assets/upload_sheet.dart` | 修改 | ≤182 行 |
| 4 | `material-storage/app/lib/features/assets/upload_pick.dart` | 修改 | ≤325 行 |
| 5 | `material-storage/app/test/features/album_upload_name_test.dart` | 新建（测试包） | ≤200 行 |
| 6 | `material-storage/app/test/features/album_upload_name_edge_test.dart` | 新建（专职测试补充的边界/异常用例 B1~B9） | ≤200 行 |

全部远低于 500 行硬顶，无需再拆。

## 4. 数据库修改方案

不涉及。

## 5. 接口定义（App 内部函数签名，无 HTTP 变更）

- `resolveAlbumUploadName(...)`：见 §3.1，返回 `({String filename, String? contentType})`，不抛错。
- `extensionFromMime(String? mime) → String?`
- `uploadContentTypeFor(String filename, {String? override}) → String`
- `AlbumService.entityToLivp(AssetEntity e, {String? baseName}) → Future<List<int>>`（其余返回语义不变）

后端 HTTP 接口、请求体、返回值均**无变化**。

## 6. 测试功能点

**T1 扩展名映射**：`extensionFromMime` 对上表 12 个 MIME 全部命中；`'IMAGE/PNG'`、`'.png'`、`'image/png; charset=utf-8'` 容错；`'application/octet-stream'`/`''`/`null` → null。

**T2 title 有扩展名（Android 常态）**：`AssetEntity(title: 'IMG_1234.PNG', ...)` → `('IMG_1234.PNG', 'image/png')`，且 `titleOf` 注入计数器为 0（证明没有多余平台调用）。

**T3 iOS 空 title + titleAsync 真名**：`title: ''`、`titleOf → 'IMG_1234.PNG'` → `('IMG_1234.PNG', 'image/png')`。

**T4 title 全空 + originFile 路径带扩展名**：`title: ''`、`titleOf → ''`、`originPath: '/tmp/x/IMG_1234.HEIC'` → `('IMG_UUID-L0-001.heic', 'image/heic')`，且 `mimeOf` 未被调用。
（扩展名大小写口径见 §3.1 第 3 步：**合成**的扩展名（来自路径/MIME）统一小写；title 自带的扩展名保持原样，如 T2/T3 的 `IMG_1234.PNG`。）

**T5 全空 + MIME 兜底**：`title: ''`、`titleOf → ''`、无 originPath、`mimeOf → 'image/png'` → `('IMG_UUID-L0-001.png', 'image/png')`（**核心回归点：绝不再是裸名 + octet-stream**）。

**T6 全空无 MIME**：同上但 `mimeOf → null` → `('IMG_UUID-L0-001', null)`，不抛错。

**T7 异常吞掉**：`titleOf` 抛 `PlatformException`、`mimeOf` 抛异常 → 不抛错，按兜底给出结果。

**T8 净化不变**：title 含 `/`（如 `'a/b.PNG'`）→ basename `'b.PNG'`；点文件 `'.PNG'` → 基名兜底后按 MIME 补 `.png`。

**T9 content_type 优先级**：`uploadContentTypeFor('a.livp')` → `application/zip`；`uploadContentTypeFor('a.livp', override: 'text/plain')` → `text/plain`；`uploadContentTypeFor('IMG_1234.PNG')` → `image/png`；`uploadContentTypeFor('IMG_UUID-L0-001')` → `application/octet-stream`。

**T10 回归**：既有 `upload_sheet_test.dart`、`livp_base_name_test.dart`、`media_save_test.dart` 等全绿；`flutter analyze` 零 issue。

**T11 真机（人工，非本批自动化）**：iPhone 相册选截图上传 → 落库 filename 带 `.PNG`、content_type `image/png`、有 `thumbnail_key`；Web 端出缩略图且「预览」可用。

## 7. 模糊点与决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 实况照片基名是否一并换真名（F4） | **做** | 同一根因、同一解析器，成本≈0；线上 7 条 livp 全是 UUID 名，可读性收益明确；`.livp` 扩展名与后端按「类别内最大条目」挑包的口径都不变（已核对 `LivpService.pick` 与后端 `_pick_livp_entries` 均不看文件名）。 |
| D2 | 无扩展名时用 MIME 拼扩展名还是只传 content_type | **两者都做** | 拼扩展名修的是文件名（下载、类型标签、Web `detectKind` 扩展名腿）；显式 content_type 修的是后端缩略图派发与 Web 的 `image/*` 腿。任一条腿单独都能救，双保险最省事。 |
| D3 | 是否同时改后端（魔数嗅探）与修存量 2 条坏行 | **不做，记遗留** | 用户明确「按 App 端根治流程」；后端批次独立排期，避免本批跨栈扩大验证面。 |
| D4 | iOS 选择器是否改传 `filterOptions: needTitle: true` 来根治 | **不采用** | `FilterOption.merge` 是整字段覆盖，会冲掉 picker 自己的 `SizeConstraint(ignoreSize: true)`；插件文档标注 needTitle 在 iOS 上有性能代价；且它是「全量列表都带 title」的粗粒度开关，而 `titleAsync` 只在上传瞬间按需取，粒度更合适。 |
| D5 | 解析逻辑放 `services/` 还是 `features/assets/` | **features/assets/** | 依赖 `sanitizeUploadName`（features 层），服务层不得反向依赖；且它是上传域专属逻辑。 |
| D6 | `_albumDisplayName`（跳过清单展示名）是否同步改 | **不改，记 P2** | 它同步取 `e.title`，改异步需重构 `enqueueNamedBatchAndReport` 的 items 契约（文件多选共用、已有单测覆盖），收益仅在「上传失败时的清单文案」，不抵风险。 |
| D7 | 是否需要给 `content_types.dart` 补 tiff/avif/ico | **只补 `tif`/`tiff` → `image/tiff`** | iOS 可能给 `image/tiff`；映射表缺它会让合成的 `.tiff` 落回 octet-stream。avif/ico iOS 相册不会产出，不动。 |
| D8 | 解析失败是否回退到「真机缓存路径名」做文件名 | **不做** | 缓存名形如 `<uuid>_<时间戳>_o_<原名>.PNG`，可读性差；`IMG_<id>` 兜底 + 正确扩展名已达标，且改动面最小。 |

## 8. 验证命令（worktree 内）

```bash
cd E:/qbb/github_not_me/rushes-lab-feat-ios-upload-name-ext/material-storage/app
/e/qbb/soft/flutter/bin/flutter pub get
/e/qbb/soft/flutter/bin/flutter analyze
/e/qbb/soft/flutter/bin/flutter test
```

真机项 T11 由 tester 执行，本批只出自动化证据。

## 9. 交付与验收记录（2026-10-27 收口）

### 9.1 实现落点（最终行数）

| 文件 | 行数 | 说明 |
|---|---|---|
| `lib/features/assets/album_upload_name.dart` | 133 | 解析组件（含尾点归一 `_trimTailDots`） |
| `lib/services/album.dart` | 125 | `entityToLivp(baseName:)` |
| `lib/features/assets/upload_sheet.dart` | 181 | `uploadContentTypeFor` + `enqueueLocalUpload(contentType:)` |
| `lib/features/assets/upload_pick.dart` | 294 | `_enqueueAlbumAsset` 接线（实况/静态两轨） |
| `lib/core/api/content_types.dart` | 59 | +`tif`/`tiff` |

### 9.2 验收证据（PM 亲手复跑）

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**1131 通过 / 0 失败**（基线 1107 + 命名 15 + 边界 9 = 1131）
- 定向回归 6 文件（命名/上传面板/livp 基名/media_save/upload_file/upload_bytes）：59 通过
- 专职测试子智能体独立复核：P0 = P1 = 0，可交付

### 9.3 验收期补充决策

| # | 事项 | 决策 | 理由 |
|---|---|---|---|
| D9 | 扩展名大小写 | **合成的扩展名（来自路径/MIME）统一小写；title 自带的扩展名原样保留** | 合成值是本地规范化产物，大小写无业务含义；title 原样可保住 `IMG_1234.PNG` 这类真实原名。已同步修正 §6 T4 的字面值。 |
| D10 | Android 上 title 存在但无扩展名的少见情形，也会被补扩展名并显式传 content_type | **接受** | 与 F2 一致，属改进而非回归；Android 常规（DISPLAY_NAME 带扩展名）产出与旧逻辑逐字相同，且 `title` 非空时零额外平台调用（`titleAsync` 在 Android 不跨通道，photo_manager 本地返回）。 |
| D11 | 尾点 title（`IMG_1234.`）会拼出双点文件名 | **修**（第 2 步去尾点，去空回落兜底名） | 双点虽不触发后端 400（基名非空）且 `extOf` 仍能取到扩展名，但文件名不雅且易误导排查。 |

### 9.4 遗留（P2，本批不做）

1. `_albumDisplayName` 跳过清单展示名仍是同步兜底名，与真实上传名可能不同（决策 D6；已在代码注释标明「勿当 bug 返工」）。
2. `baseNameOf` 存在第三份私有实现（`album_upload_name.dart` / `services/media_save.dart` / `services/album.dart`），建议后续下沉到 core 统一。
3. 真名落库后，跨设备/导入的同名素材在同一文件夹批量上传会撞后端 `create_upload` 的同夹同名 409（`old iOS UUID 名天然唯一`的老红利消失）。与 Web 上传行为一致，若线上反馈明显再考虑自动后缀。
4. `.dng`（ProRAW）不在 App MIME 表与后端 `IMAGE_EXTS`，仍会落 octet-stream 且无缩略图。
5. 解析组件为复用 `sanitizeUploadName` 反向依赖 `features/assets/upload_sheet.dart`（决策 D5 已接受）；若将来抽 `core/naming` 可一并解决 2、5 两项。
6. 真机项 T11（iPhone 上传截图 → 落库 `.PNG` + `image/png` + 有缩略图 + Web 可预览）待 tester 执行。

