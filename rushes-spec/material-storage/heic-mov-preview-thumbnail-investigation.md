# 调研：HEIC 预览黑图 / MOV 无缩略图 / 预览触发「临时链接签发」审计

> 2026-10-15 纯调研产物，未动任何代码。三个现象的根因定位 + 可选修复方案。
> 涉及环境：内网素材服务器（dev/prod 同构，本文按当前 liuqi 分支代码分析）。

## TL;DR

| 现象 | 根因 | 性质 |
| --- | --- | --- |
| HEIC 缩略图正常、点预览看不到大图 | 预览把**原始 HEIC 文件**的 presigned URL 塞给 `<img>`，Windows 上的 Chrome/Edge/Firefox **不能原生解码 HEIC**；缩略图正常是因为服务端 Pillow+pillow-heif 已转码成 JPEG | 已知设计缺口（ROADMAP「Asset preview 二期」明确列了 HEIC 兜底为待办） |
| MOV 可播放、无缩略图 | 视频缩略图 worker 有 **50MB size cap**（>50MB 静默 `skip_too_large`，不写任何失败标记）；另一可能是上传时浏览器没报 `video/*` content_type → 任务根本没派发。两条路径都是**静默跳过** | 前者 = 设计如此（pilot cap），后者 = 派发条件盲区 |
| 点预览出现「临时链接签发」审计 | 预览与下载**共用同一端点** `POST /assets/{id}/download-link`（拿原图 presigned URL），该端点每次签发必写 `signed_url_issued` 审计 | 合理设计，非 bug（详见 §3） |

---

## 1. HEIC：缩略图正常，预览黑图

### 1.1 链路事实

**缩略图为什么正常**（`api/app/workers/main.py:81` `generate_thumbnail`）：

- 上传完成时按 content_type 派发（`routers/assets.py:232`）：`ct.startswith("image/")` → 图片缩略图任务。HEIC 上传时浏览器报 `image/heic`，命中。
- worker 里 pillow-heif 已注册（`workers/main.py:45` `register_heif_opener()`，依赖在 `pyproject.toml:39` 钉了 `pillow-heif>=0.13`，容器 Dockerfile 装 ffmpeg）。
- 因此服务端能把 HEIC 解码 → 转 1024px JPEG → 存缩略图 MinIO。**缩略图产物是 JPEG**，前端 `<img>` 显示没有障碍（`AssetThumbnail.tsx`）。

**预览为什么黑图**（`web/src/components/AssetPreviewModal.tsx`）：

- `detectKind()`（第 40 行）：`ct.startsWith('image/')` → HEIC 的 `image/heic` 命中 → kind=`'image'`。
- 预览逻辑（第 101-108 行）：对 image 类型，调用 `POST /assets/{id}/download-link` 拿到的是**原始 HEIC 文件**的 presigned URL，直接塞进 `<img src=...>`（第 174 行），没有任何转码兜底。
- 浏览器侧：**HEIC 只有 Safari（macOS/iOS）原生支持**；Windows 的 Chrome/Edge/Firefox 默认都不能解码 `image/heic`（Edge 需要系统装 HEVC 扩展且默认关闭）。`<img>` 加载失败且该处无 `onError` 处理 → 弹窗里图片区域空白。
- 附带一提：前端 `IMAGE_EXT` 扩展名白名单（第 26-28 行）也不含 `.heic/.heif`——若某 HEIC 上传时 content_type 落成 `application/octet-stream`，预览会直接判 `unsupported`（"此文件类型暂不支持在线预览"）。两条路径都到不了大图。

### 1.2 这是已知待办

`rushes-spec/material-storage/ROADMAP.md`「Asset preview 二期 — docx / xlsx / video / heic（候选，等需求驱动）」一节明确写着：

> HEIC（iOS 默认）：浏览器原生不支持，heic-to（~200KB）兜底

即当年设计时已知浏览器不支持，计划用前端库兜底，尚未实施。

### 1.3 修复方案（供决策，未实施）

**方案 A（推荐）：预览直接用已有的缩略图链路** —— 改动最小。
HEIC 缩略图本来就是服务端转好的 1024px JPEG（质量 80，`workers/main.py:52-53`）。`AssetPreviewModal` 对 `image/heic`、`image/heif`（以及 `IMAGE_EXT` 白名单加入 `.heic/.heif`）不走 `download-link`，改走已有的 `GET /assets/{id}/thumbnail-url`（30min TTL，登录即可取，无需 can_download）。
代价：预览上限 1024px（可接受——livp 静态图预览现在就是这么做的，`AssetPreviewModal.tsx:94` 已有先例）；想要更清晰可另起一档「预览图」规格（如 2048px）由 worker 一并生成。
注意点：需要区分「缩略图还没生成」（显示生成中）与「生成失败」（显示失败卡），UI 语义照抄 livp 分支即可。

**方案 B：前端 heic-to 解码**（ROADMAP 原思路）——lazy-load ~200KB 库，浏览器端解码原图。
代价：每个客户端首次要多拉库；大 HEIC（4800 万像素 ~5-10MB）解码耗内存；且原始字节仍要走 `download-link`（审计照记）。相比方案 A 无明显收益，除非明确要求「预览必须看原图分辨率」。

**方案 C：服务端全量转 JPEG 预览档**（类似 livp 的 `previews/{aid}_live.mp4` 先例）：worker 生成 `previews/{aid}.jpg`，预览走独立签发端点。最干净但改动面最大（worker + 端点 + 前端），除非要和方案 A 的 2048px 预览档合并设计，否则不必。

## 2. MOV：可播放，无缩略图

### 2.1 链路事实

**预览为什么正常**（`AssetPreviewModal.tsx:30,44`）：`.mov` 在前端 `VIDEO_EXT` 白名单里 → kind=`'video'` → 拿原图 presigned URL 塞 `<video controls>`。Chrome/Edge 对 QuickTime 容器（H.264/AAC 编码）可以直接播，所以能放。

**缩略图为什么没有**——三个候选路径，按可能性排序：

1. **50MB cap 静默跳过**（最可能，`workers/main.py:482-487`）：
   `generate_video_thumbnail` 对 `size_bytes > 50MB` 直接 `return {"status": "skip_too_large"}`——**不写 `thumbnail_failed`、不留任何标记、无重试**。相机/iPhone 的 MOV 普遍几十 MB 到几 GB，命中概率极高。这是 ROADMAP #102 / ops-manual §「视频缩略图 50MB cap pilot」记录的 pilot 决策（当时用 deferred queue 后续承接，但 deferred queue 至今未做）。
2. **派发盲区**（`routers/assets.py:235`）：派发只认 `content_type.startswith("video/")`。Firefox 的 MIME 表不含 `.mov`（上传时 `file.type` 为空 → 落库 `application/octet-stream` 或空）→ 任务根本不入队，同样静默。Chrome/Edge 报 `video/quicktime` 不受影响。
3. **ffmpeg 抽帧失败**（`workers/main.py:554-564`）：会写 `tags.thumbnail_failed`（异常类型名），这是唯一留下痕迹的失败路径。Debian 容器的 ffmpeg 自带 HEVC 解码，iPhone HEVC-MOV 理论上能抽帧，但 30s 超时（`_FFMPEG_TIMEOUT_SEC`）对高分辨率 MOV 偏紧，超时写 `ffmpeg_timeout`。

注意 worker 侧 `skip_too_large` / `skip_non_video` 两条静默路径连 `thumbnail_failed` 都不写——所以「无缩略图且无失败标记」的 MOV，基本就是 1 或 2。

### 2.2 现场判别（一条 SQL 定位是哪种）

```sql
SELECT filename, content_type, size_bytes,
       tags->>'thumbnail_key'     AS thumb,
       tags->>'thumbnail_failed'  AS fail
FROM assets
WHERE lower(filename) LIKE '%.mov' AND deleted_at IS NULL
ORDER BY created_at DESC LIMIT 20;
```

- `size_bytes > 52428800` 且 `thumb`/`fail` 均空 → 命中 50MB cap（路径 1）。
- `content_type` 不是 `video/*` 且均空 → 派发盲区（路径 2）。
- `fail` 非空（如 `ffmpeg_timeout`）→ 路径 3，看 worker 日志 `docker logs ms-worker` 有完整 traceback。

### 2.3 修复方案（供决策，未实施）

- **路径 1 的根治 = 提高/移除 cap 或做「大文件抽帧通道」**：cap 存在的真实原因是 worker `job_timeout=60s`（`workers/main.py:692`）内要完成「拉文件 + ffmpeg」。大文件方案要么 per-function timeout 提额（如 `func(generate_video_thumbnail, timeout=300)`），要么继续 Range 拉头部但把 cap 提到 500MB 并配 fallback 限流。改动集中在 worker，风险点是 worker 并发占满（`max_jobs=4`）拖慢其他任务。
- **低成本止血**：把两条静默 skip 路径写上标记（如 `tags['thumbnail_skipped']='too_large'`），前端 `AssetThumbnail` 已经有 fallback 图标，至少让排查不用进 DB。
- **路径 2 的根治 = 派发条件加扩展名兜底**：`complete_upload` 与百度导入 `_enqueue_thumbnail`（`workers/baidu_backup.py:1775`）两处同步补「`video/*` 或扩展名 ∈ {.mov,.mp4,.webm,.m4v}」。注意 worker 内 `skip_non_video` 的 content_type 判定也要同步放宽，否则派发了还是被 skip。
- 存量补生成：两个路径都没跑过任务，修完后需要一次性回补脚本（对 `content_type LIKE 'video/%' OR filename LIKE '%.mov'` 且无 `thumbnail_key` 的行重新 enqueue；可复用百度侧 `_enqueue_thumbnail` 口径）。

### 2.4 大文件视频封面方案深化（2026-10-15 追加：回应「取消 50MB 限制 + 流读前几秒抽帧」设想）

**先澄清两个前提**：

1. **「流读取前几秒抽帧」已经是现状**。worker 第一阶段就是 Range 流式拉头部 10MB（`workers/main.py:510` `Range: bytes=0-10485759`）喂给 ffmpeg 抽 1s 帧——不管原文件多大，这条路径只传 10MB。50MB cap 护的不是这条路，而是**兜底路径**：头部抽帧失败（典型=moov box 在文件尾部，iOS 录制/屏录/ffmpeg 默认输出皆如此，代码注释 `#135` 自证）时，worker 会**全量下载整个文件**再重试（`workers/main.py:526`）。cap 把这个「最坏情况全量拉」的代价封顶在 50MB。
2. **不动代码无法取消 cap**。`_VIDEO_THUMBNAIL_MAX_BYTES` 是硬编码常量（`workers/main.py:187`），无 env/配置开关。

**只取消 cap（一行改动）会发生什么**：

- **moov 在头部的 >50MB 视频**（faststart 的 MP4/MOV，剪辑导出/网络素材常见）：直接受益——头部 10MB 抽帧成功，全程只传 10MB，这正是设想想要的效果。
- **moov 在尾部的 >50MB 视频**（iPhone 相机录制，即本次问题的主要素材）：头部 10MB 里没有解码索引，ffmpeg 拆包失败 → 走全量下载兜底 → 两个雷：
  - **60s 任务超时被杀**：`WorkerSettings.job_timeout=60`（`workers/main.py:692`），2GB 文件在百兆内网全量拉也要 2 分钟+，arq 直接取消任务，带宽白耗、封面仍然没有；
  - **worker 事件循环被阻塞**：`s3.download_file` 是同步 boto3 调用直接写在 async 函数里，下载期间**整个 worker 事件循环卡死**——`max_jobs=4` 名义并发全部停摆，连 `mark_expired_approvals` cron、百度备份任务也一起被拖住。50MB cap 客观上一直在给这个阻塞时长封顶。

**真正符合「只读必要字节」直觉的解法：ffmpeg 直接读 presigned URL（Range 自寻址）**——

worker 用容器内凭据给原对象签一个内部 presigned GET URL，然后 `ffmpeg -ss 1 -i "<url>" -frames:v 1 -vf scale=1024:-2 out.jpg`。ffmpeg 的 HTTP demuxer 自己发 Range 请求：先 seek 到文件尾把 moov 索引读下来（通常几百 KB~几 MB），再精确定位 1s 处关键帧所在字节段拉取解码。**moov 在头在尾都能处理，全程实际传输量只有几 MB，与文件总大小基本无关**。cap 可彻底取消（或留 2GB 级防御值）。

配套改动（均必要）：

- 该任务 per-function 超时提额：`func(generate_video_thumbnail, timeout=180)`（百度任务 `timeout=3600` 已有同款先例，`workers/main.py:686`）；ffmpeg subprocess 超时同步提到 60~90s。
- 旧路径保留为 fallback（presigned URL 通道异常时退回「头部 10MB + 全量」老逻辑），且全量下载段补 `asyncio.to_thread` 包裹防事件循环阻塞。
- 验证点：容器内 Debian ffmpeg 的 HTTP 协议支持（标准构建默认启用，仍需实测一次）；presigned URL 过期时间覆盖任务时长（签 10min 足够）；worker 出网仅到 MinIO 内部 endpoint，无新增外联面。

**低成本替代（如果不想引入 ffmpeg HTTP 输入）**：cap 提到 500MB + per-function timeout=300s + 全量下载段 `asyncio.to_thread`。覆盖大部分真实素材（iPhone 短片多在 500MB 内），但 moov-at-end 文件仍是全量拉，治标。

**两个方案都绕不开的收尾**：派发盲区同步修（§2.3 扩展名兜底，两处派发点）+ 存量已跳过文件回补脚本 + 两条静默 skip 路径补标记。另注意百度导入侧与网页上传侧共用同一 worker 函数，改动对两条来源同时生效。

## 3. 疑问：为什么「点预览」会记一条【临时链接签发】审计

### 3.1 机制（不是 bug）

前端预览弹窗对 image/pdf/video/text/md 全部调用 `POST /api/v1/assets/{id}/download-link`（`AssetPreviewModal.tsx:101-103`）——**与点「下载」按钮走的是同一个端点、同一个权限检查（`can_download`）、同一条审计**：

- 端点逻辑（`routers/assets.py:984-1045`）：check OpenFGA `can_download` → 签 presigned GET URL（TTL 15min，`settings.py:92` `presigned_normal_ttl_seconds=900`）→ `audit.signed_url_issued(...)` → 返回 URL。
- 前端文案映射：`web/src/lib/labels.ts:53` `signed_url_issued: '临时链接签发'`。

### 3.2 为什么设计成必审计

presigned URL 本质是一张**不记名凭证**：TTL 内任何拿到 URL 的人都能直接从 MinIO 取走文件（浏览器→MinIO 直连，后续 GET 不再过 API、不再有用户身份）。API 无法区分「拿去预览」和「拿去下载」，也不该区分——**签发即授权**。所以审计的落点是「签发」而非「传输」，预览和下载在审计里同一条目（`details` 里只有 `expires_in_seconds`，没有 intent 字段可区分）。

这也是为什么缩略图 URL（`GET /{id}/thumbnail-url`）**不写**审计：既有决策认为 1024px 缩略图信息密度低、信任组织内可见性（`routers/assets.py:1057-1058` 注释）；livp 实况短片走 `live-preview-url`，因为也是转码降清产物但需 can_download，做了折中（写 audit，与 download-link 同门槛，`routers/assets.py:1218-1221`）。

### 3.3 如果想让审计能区分预览/下载（可选增强，未实施）

- 方案 1（最小改动）：`download-link` 请求体加可选 `intent: 'preview' | 'download'`（前端预览传 `preview`），后端写进 `details.intent`。审计事件类型不变，查询时可区分。语义上仍是签发审计，只是多了上下文。
- 方案 2（不推荐）：预览改走独立端点不写审计——**安全性倒退**，预览拿到的同样是原图 presigned URL，凭据等价，漏审会造成「有人拿预览链接批量取文件但审计无痕」的盲区。

## 4. 附：三份证据文件索引

| 关注点 | 位置 |
| --- | --- |
| 图片缩略图 worker（Pillow+pillow-heif→JPEG） | `material-storage/api/app/workers/main.py:81` |
| 视频缩略图 worker（50MB cap + ffmpeg 抽帧） | `material-storage/api/app/workers/main.py:453` |
| 上传后缩略图派发条件（content_type 前缀） | `material-storage/api/app/routers/assets.py:226-237` |
| 百度导入侧同款派发 | `material-storage/api/app/workers/baidu_backup.py:1775` |
| 预览弹窗（kind 判定 + 原图直塞 img/video） | `material-storage/web/src/components/AssetPreviewModal.tsx:26-48,101-108` |
| download-link 端点 + signed_url_issued 审计 | `material-storage/api/app/routers/assets.py:984-1045` |
| 审计事件类型与文案映射 | `material-storage/api/app/services/audit.py:90` / `web/src/lib/labels.ts:53` |
| ROADMAP 已知待办（HEIC 兜底） | `rushes-spec/material-storage/ROADMAP.md`「Asset preview 二期」节 |
| 50MB cap pilot 记载 | `rushes-spec/material-storage/ops-manual.md:292` / `ROADMAP.md` #102 |
