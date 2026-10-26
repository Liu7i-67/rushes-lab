# qdev 需求文档：大视频封面补全 + 小尺寸缩略图变体 + web 预览渐进式

> 2026-10-27 · 依据定稿方案 `rushes-spec/material-storage/thumb-variant-and-video-cover-plan.md`（qplan 8 轮盲审收敛版）实施。
> 决策点已拍板：**D1=240px**（small 规格）、**D2=做「查看原图」按钮**、**D3=手动回补脚本**（非常驻 cron）、**D4=URL 主路径无 cap（8GB 防御值）+ 全量兜底段维持 50MB**。
> 决策记录补充：App 版本号本次**不 bump**（发版周期处理）；`workers/main.py`(1061行)/`routers/assets.py`(2425行)/`workers/baidu_backup.py`(2153行) 为既有超限文件，**沿用现状仅增量修改**，新增逻辑优先放新文件；新建文件一律 ≤500 行；`AssetPreviewModal.tsx`(480行) 本次必须抽 hook/子文件守住 500 行。

## 1. 背景与目标

1. 生产大量 >50MB 视频因 cap+派发盲区**双静默**无封面 → ffmpeg 直读 presigned URL 抽帧主路径（传输量与文件大小解耦）+ 扩展名兜底 + 存量回补。
2. 全仓唯一 1024 规格，web 图标实渲染 32/44px、App 宫格 cell ≈110dp → 新增 small(240px) 变体，端点 `size` 参数 + **缺失回落 large**（三端切换与回补零耦合）。
3. web 预览每次打开 POST download-link 拉原图+审计噪音 → 渐进式 small 先行（与列表同缓存）→ large 替换；原图仅兜底/显式按钮。

## 2. 可复用资产（禁止重写）

| 资产 | 位置 | 复用方式 |
| --- | --- | --- |
| `_merge_asset_tags`（jsonb_set 原子合并） | `api/app/workers/main.py:279-310` | 直接复用（新 tags 全走它） |
| `_thumb_s3_client` / 缩略图桶 client | `api/app/workers/main.py:67-76` | 直接复用 |
| ffmpeg 同步执行 + to_thread 包装 | `api/app/workers/main.py:779-796` 附近 | 沿用参数族与包装模式 |
| 主桶内部端点 boto3 client（签 URL 用） | `api/app/workers/main.py:838-844` 附近 | 直接复用（与 download_file 同源） |
| `sign_thumbnail_url` | `api/app/services/presign.py:263-283` | 改造复用（加 cache_control 参数） |
| 批量签名端点 | `api/app/routers/assets.py:2119-2170` | 改造复用（加 size） |
| 派生对象清理清单 | `api/app/services/asset_cleanup.py:26-27` | 改造复用（补 small key） |
| web react-query 缓存（['thumbnail-url', id]） | `web/src/components/AssetThumbnail.tsx:21-30` | 改造复用（key 加 size 维度） |
| App ThumbPipeline/ThumbSignGate/ThumbDiskStore/thumbnailCache | `app/lib/core/*.dart` | 改造复用（键加 variant 维度） |
| W6 磁盘直读 / W4 放大不换原图 | `app/lib/features/preview/*.dart` | 语义保持不动 |

## 3. 全局契约（所有工作包按此开发，并行不等待）

### 3.1 共享常量模块（BE1 创建，其余包只 import 不创建）

新文件 `api/app/services/thumb_exts.py`（≤80 行）：

```python
VIDEO_EXTS = {".mp4", ".mov", ".webm", ".m4v", ".avi", ".mkv", ".3gp", ".mts", ".m2ts", ".wmv", ".mpg", ".mpeg"}  # 刻意不含 .ts/.svg
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".heif", ".bmp", ".tiff", ".tif"}
def is_video_asset(filename: str, content_type: str | None) -> bool   # content_type video/* 前缀 OR 扩展名
def is_image_asset(filename: str, content_type: str | None) -> bool   # content_type image/* 前缀(非 image/svg+xml) OR 扩展名
def is_livp_asset(filename: str) -> bool                              # .livp 扩展名
THUMB_SMALL_MAX_PX = 240
VIDEO_THUMB_ABSOLUTE_MAX_BYTES = 8 * 1024**3
```

### 3.2 端点契约（BE2 实现，web/app 按此消费）

- `GET /api/v1/assets/{asset_id}/thumbnail-url`：新增 query `size: "large"|"small"`（默认 large）。`size=small` 时优先签 `tags.thumbnail_small_key`，缺失回落签 `thumbnail_key`；响应 `{"url": str, "expires_in": 1800, "variant": "small"|"large"}`（variant=实际签发的对象规格；无 `thumbnail_key` 仍 404）。签发时传 `cache_control="public, max-age=604800"`。
- `POST /api/v1/assets/thumbnail-urls`：body 新增可选 `size`（同上默认 large，pydantic `Literal["large","small"]`）；响应 `urls[]` 每项增加 `"variant"` 字段；missing/去重/上限 100/无审计/认证不鉴权语义全部不变。
- 两端点审计/权限/TTL 1800 **均不变**。
- `POST download-link` / `GET live-preview-url` **不动**。

### 3.3 presign 契约（BE2 实现）

`sign_thumbnail_url(key, ttl, request_base=..., cache_control: str | None = None)`：`cache_control` 非空时在 presign Params 加 `ResponseCacheControl`；**默认 None**——live-preview-url 调用点不传，行为不变。

### 3.4 worker 契约（BE1 实现）

- `generate_video_thumbnail`：新主路径 = 主桶内部端点 client 签 presigned GET（ExpiresIn=600）→ `ffmpeg -hide_banner -loglevel error -y -ss 1 -i <url> -frames:v 1 -vf scale=1024:-2 -q:v 3 -f image2 <tmp>/out.jpg`（subprocess timeout 60s，to_thread 包裹）→ 失败 `-ss 0` 重试；任一异常回落旧「头部 10MB → 全量下载（cap 50MB）」链。cap 语义改为：`size_bytes > 8GB` 才 skip。**日志卫生**：cmd/TimeoutExpired.cmd/stderr（可能含 URL）不得进日志与 tags，沿用只 log asset_id 口径。
- 受纳条件（worker 侧）：视频 job 用 `is_video_asset`、图片 job 用 `is_image_asset`（替换现 content_type 前缀判断）。
- skip 标记：`tags['thumbnail_skipped']`：视频 >8GB → `'too_large'`；视频受纳不过 → `'non_video'`；livp >200MB → `'too_large'`（main.py:356-357 现静默口子）。成功时移除该标记（`_merge_asset_tags` removes）。
- small 派生（三族 job）：成功产出 1024 产物后（图片/livp 内存字节；视频 tmp 文件读回），调 `thumb_variants.derive_and_put_small(asset_id, source)`；**独立 try/except 仅 log**，不得影响 1024 主链路；tags 合并一次性写入 `thumbnail_key + thumbnail_small_key(+thumbnail_small_size_bytes)`（或分两次 merge 也可，但失败隔离必须保证 1024 主产物 tags 不丢）。
- 新 worker job `derive_small_thumbnail(asset_id)`（在 `thumb_variants.py`）：读缩略图桶 `thumbnails/{id}.jpg` → 派生 240 → put `{id}_s.jpg` → merge tags；源对象缺失 log+`{"status": "source_missing"}`。
- `WorkerSettings.functions` 注册：`func(generate_video_thumbnail, timeout=360, max_tries=1)`；`generate_thumbnail`/`generate_livp_thumbnail` 补 `max_tries=1`（timeout 维持全局 60）；`func(derive_small_thumbnail, timeout=60, max_tries=1)`。

### 3.5 派发契约（BE2/BE3 实现）

`complete_upload`（assets.py:271-284）与 `_enqueue_thumbnail`（baidu_backup.py:1989-2013）改用 `is_video_asset/is_image_asset/is_livp_asset` 判定派发（livp 优先级最高，维持现状）。

### 3.6 web 契约（W1/W2 按此消费）

- `AssetThumbnail.tsx`：queryKey `['thumbnail-url', asset.id, 'small']`，请求 `?size=small`；`<img>` 加 `loading="lazy" decoding="async"`；staleTime 25min、onError fallback 逻辑不变。
- `AssetPreviewModal.tsx` image kind（非 .gif、非 heic）：
  1. 有 `tags.thumbnail_key` → `queryClient.fetchQuery({queryKey:['thumbnail-url', id, 'small'], staleTime:25min})` 渲染 small；响应 `variant` 为 `"small"` 时后台 `fetchQuery(['thumbnail-url', id, 'large'])` 并在 onload 后替换 src；`variant==="large"` 或**字段缺失**（旧后端瞬态）→ 跳过 large 步骤；
  2. 无 `thumbnail_key` → 维持现 download-link 原图；有 key 但 URL 失败 → onError 回落 download-link 原图；
  3. **GIF carve-out**：`.gif` 扩展名维持现状原图预览（download-link，可播动画），不进渐进模型；
  4. **heic 分支不动**（缩略图 + 失败卡，无原图兜底无查看原图按钮）；
  5. **「查看原图」按钮**：footer 增加（仅非 GIF image kind 且有 thumbnail_key 时显示），点击才 POST download-link 换 `<img src>`（审计随之产生）；
  6. 渲染区注明「预览为压缩图（≤1024px），下载可获取原片」（livp 分支已有同款文案先例）；
  7. video 分支：`<video poster={thumbnailUrl}>`（large），src 不变；无 thumbnail_key 不设 poster；pdf/text/livp 分支不动。
- **文件行数硬约束**：`AssetPreviewModal.tsx` 现为 480 行，渐进逻辑抽到新文件 `web/src/hooks/useProgressiveThumb.ts`（约 70 行：small/large fetchQuery + variant 短路 + onload 替换状态机），改后主文件 **必须 ≤500 行**（验收以 `wc -l` 为准）；如仍超，继续抽子组件到 `web/src/components/preview/` 下。

### 3.7 App 契约（A1 实现 core，A2 按此消费）

新文件 `app/lib/core/thumb_variant.dart`：

```dart
enum ThumbVariant { large, small }
extension ThumbVariantX on ThumbVariant {
  String get diskTag;   // 'lg' / 's'
  String get apiSize;   // 'large' / 'small'
}
```

- 磁盘：根目录改 `<cacheDir>/thumbs_v2/`（**与旧 `thumbs/` 同级**，禁止嵌套）；文件名 `<净化assetId>.<diskTag>.bin`；`init()` 建 v2 目录并**文件级**清空旧 `thumbs/` 内文件（非递归删目录）。
- 键维度（全链，漏一环即互串）：`fetchThumb(assetId, {ThumbVariant variant = ThumbVariant.large})`；管线去重键 `'$assetId:$variant索引或diskTag'`；签名闸 `_Job` 键同加；URL 缓存键同加；**签名函数**（thumbnail_cache 内单发/批量签名入口）带 variant → 单发 `GET thumbnail-url?size=`、批量 body `{'asset_ids': [...], 'size': 'small'}`（small 时）。
- 批量预热：`prewarmThumbUrls(items, {ThumbVariant variant = ThumbVariant.large})`。
- 消费面：宫格 `AssetTile`（经 `thumbnail_image.dart`）、胶片条 48px 小格、搜索结果行 → `small`；预览页 `_loadThumb` 维持 `large` 且**保留现有写盘行为**（large 落 `<id>.lg.bin`）；解码 clamp（cacheWidth 96..600）不动。
- 响应新增字段 `variant`：App 手工 JSON 解析**容忍未知字段**，不新增必填解析。

### 3.8 回补脚本契约（BE4 实现）

重写 `api/scripts/backfill_thumbnails.py`（现 82 行，默认补缺 + `--force`）：

- `--mode missing`（默认，兼容旧行为）/ `--mode missing-covers`（视频+图片+livp 三族盲区）/ `--mode derive-small`。
- `missing-covers` 筛选：`deleted_at IS NULL AND (content_type LIKE 'video/%' OR (content_type LIKE 'image/%' AND content_type != 'image/svg+xml') OR filename ILIKE '%.livp' OR 扩展名命中 thumb_exts 列表) AND tags 无 thumbnail_key AND 无 thumbnail_skipped AND 无 thumbnail_failed`；**图片族追加 `AND (size_bytes IS NULL OR size_bytes <= 209715200)`**（防 OOM，超限行打印在 dry-run 报告人工处置）；按族 enqueue（视频→`enqueue_video_thumbnail`、图片→`enqueue_thumbnail`、livp→`enqueue_livp_thumbnail`）。
- `derive-small` 筛选：`deleted_at IS NULL AND thumbnail_key 存在 AND thumbnail_small_key 不存在` → enqueue `derive_small_thumbnail`。
- 默认 **dry-run**（打印命中数+样例 5 条），`--apply` 才派发；`--include-failed` 把 `thumbnail_failed` 行纳入；`--window HH:MM-HH:MM`（**UTC+8 固定偏移解释**，启动时+每批派发前各判定，越窗优雅停止）；`--sleep 2`（逐条派发间隔秒）；`--yes`（非交互放行 `--force`/确认提示，交互 TTY 才问）。
- 跑批锁：Redis `SET backfill:lock <hostname> NX EX 90`，每 60s `EXPIRE 90` 续期，释放 compare-and-del（校验 value）；拿不到锁退出。
- 派发带 `_job_id=f"thumbbf:{mode}:{asset_id}"` + `_expires`（先例 `arq_pool.py:63-67` livpdl）。

## 4. 组件拆分方案与工作包

| 包 | 域 | 文件（新建 N / 修改 M） | 预估 |
| --- | --- | --- | --- |
| BE1 | 后端 worker | N `api/app/services/thumb_exts.py`(~80)、N `api/app/workers/thumb_variants.py`(~150)、M `api/app/workers/main.py`(+~130) | main.py 既有超限，仅增量 |
| BE2 | 后端端点 | M `api/app/routers/assets.py`(+~70)、M `api/app/services/presign.py`(+~10)、M `api/app/services/asset_cleanup.py`(+2) | assets.py 既有超限 |
| BE3 | 后端百度派发 | M `api/app/workers/baidu_backup.py`(+~10) | 仅 `_enqueue_thumbnail` 段 |
| BE4 | 后端回补脚本 | M `api/scripts/backfill_thumbnails.py`(重写 ~260) | 新版 ≤500 行 |
| W1 | web 列表图标 | M `web/src/components/AssetThumbnail.tsx`(+~8) | |
| W2 | web 预览 | N `web/src/hooks/useProgressiveThumb.ts`(~80)、M `web/src/components/AssetPreviewModal.tsx`(净+≤20) | 主文件 ≤500 硬约束 |
| A1 | App core | N `app/lib/core/thumb_variant.dart`(~15)、M `thumb_disk_store.dart`/`thumb_pipeline.dart`/`thumb_sign_gate.dart`/`thumbnail_cache.dart`/`thumb_fetch.dart`/`core/api/assets_api.dart`(各 +8~30) | |
| A2 | App 消费面 | M `thumbnail_image.dart`/`asset_tile.dart`/`assets_body.dart`/`filmstrip.dart`/`result_row.dart`/`thumb_prewarm.dart`/`preview_media.dart`(各 +3~15) | |
| T1 | 后端测试 | N `api/tests/test_thumb_size_param.py`、N `api/tests/test_thumb_dispatch_and_variants.py`、N `api/tests/test_backfill_script.py`、M `api/tests/test_thumbnail_urls_batch.py` | 只写不跑 |
| T2 | web 测试清单 | N `docs/qdev/2026-10-27-thumb-variant-web-checklist.md` | 结构化手测清单 |
| T3 | App 测试 | N `app/test/thumb_variant_cache_test.dart` 等 2-3 个 | 只写不跑 |

依赖关系：A1↔A2 按契约并行；T1/T2/T3 按契约并行写；BE1 创建 `thumb_exts.py`/`thumb_variants.py`，BE2/BE3/BE4 **只 import 不创建**（该模块由 BE1 负责落地；若你测试时模块尚不存在，如实报告，不得自行创建）。

## 5. 数据库修改方案

不涉及（无 migration、无 FGA）。新状态全在 `assets.tags` JSONB：`thumbnail_small_key` / `thumbnail_small_size_bytes` / `thumbnail_skipped`，经 `_merge_asset_tags` 原子写入，随 `AssetOut` 自动下发。

## 6. 测试功能点（逐条可验收）

1. 派发兜底：octet-stream + `.mov` 文件名 → complete_upload 与 baidu `_enqueue_thumbnail` 均派发视频 job；octet-stream + `.heic` → 派发图片 job；`.svg`/`.ts` 不派发。
2. worker 受纳：content_type 非视频但扩展名 `.mp4` 的 job 不再 skip_non_video；非视频输入写 `thumbnail_skipped='non_video'`。
3. cap：`size_bytes > 8GB` → skip + `'too_large'` 标记；livp >200MB → `'too_large'`；≤8GB 正常走主路径。
4. URL 主路径（mock/monkeypatch presign+subprocess）：ffmpeg 调用参数含 `-y`/`-ss 1`/scale=1024:-2；`-ss 1` 失败重试 `-ss 0`；ffmpeg 异常回落旧头部路径；日志/tags 不含 presigned URL。
5. small 派生：三族 job 成功后产物含 `thumbnails/{id}_s.jpg` 且 tags 含 `thumbnail_small_key`；small 段抛异常时 1024 主链路 tags 照常写入。
6. `derive_small_thumbnail`：注册断言（`WorkerSettings.functions` 含该名）；源 1024 缺失 → `source_missing`；正常 → put + merge tags。
7. 端点：`size=small` 有 small key → 签 `{id}_s.jpg` + `variant=small`；无 small key → 签 large + `variant=large`；`size=large`/缺省 → 现行为；批量端点 body `size` 生效、响应含 variant、missing/去重/上限不变。
8. presign：`cache_control` 传入 → presigned params 含 `ResponseCacheControl`；不传 → 不含；live-preview-url 调用不含。
9. cleanup：含 `thumbnail_small_key` 的 asset purge → 两个缩略图对象均被删。
10. 回补脚本：dry-run 默认不派发；missing-covers 命中 octet-stream `.mov`/`.heic`/`.livp`、排除 svg 与 >200MB 图片；`--window` UTC+8 边界 + 逐批复检；锁 NX 互斥 + compare-and-del；`_job_id` 形如 `thumbbf:{mode}:{id}`。
11. web（手测清单 T2 产出）：列表图标走 small+lazy；预览渐进/回落短路/GIF 原图/heic 失败卡/查看原图审计/video poster/无缩略图回落。
12. App（T3 单测）：v2 目录与旧目录隔离、文件名含 diskTag、管线/URL 缓存/签名闸键含 variant、批量预热 body 带 size、预览写盘 large 文件名正确。

## 7. 构建与验证命令（PM 验收与测试阶段用）

- API：`cd material-storage/api && uv run ruff check . && uv run mypy app && uv run pytest tests/ -k "thumb" -o asyncio_mode=auto`（全量回归测试阶段跑）
- Web：`cd material-storage/web && pnpm lint && pnpm build`
- App：`cd material-storage/app && flutter analyze && flutter test`（Flutter 在 /e/qbb/soft/flutter，JAVA_HOME=E:/qbb/soft/java）

## 8. 模糊点与决策记录

| 点 | 决策 | 理由 |
| --- | --- | --- |
| D1 尺寸 | 240px | 方案推荐值，App 3x 屏 73% 可接受、web 过剩；用户"方案ok"视为接受文档推荐 |
| D2 查看原图按钮 | 做 | 质检诉求出口 + 审计保留 |
| D3 回补调度 | 手动脚本，非常驻 cron | 一次性动作；脚本自带 UTC+8 窗口闸门 |
| D4 cap | URL 主路径 8GB 防御值，兜底段 50MB | 全量路径才是带宽风险源 |
| App 版本号 | 不 bump | 发版周期统一处理（先例 release.mjs） |
| 既有超限文件 | 仅增量修改不重拆 | main.py/assets.py/baidu_backup.py 为既有 1000+ 行文件，重拆超出本周期范围 |
