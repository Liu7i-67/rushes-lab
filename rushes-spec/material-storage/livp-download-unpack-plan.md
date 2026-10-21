# 方案:PC 端 livp 下载自动解包 + 批量下载单 zip 化(服务端衍生物交付)

> 依据:2026-10-21 调研(会话结论,摘要见 §0)+ [heic-mov-preview-thumbnail-investigation.md](./heic-mov-preview-thumbnail-investigation.md)(livp 预览链路前身)。
> 目标:①消除「PC 用户下载实况照片得到 .livp,既不是图片也不是视频,小白不知道能解压」的体验问题;②消除「PC 批量下载多文件反复弹保存框、闪烁」的体验问题。
> 范围:**服务端生成"下载级"衍生物(全分辨率 JPG + H.264 MP4 打包成标准 zip),下载时对 livp 资产默认交付 zip**,原始 .livp 保留为显式次选项;**PC 批量下载同步改造:逐条弹窗 → 单 zip 一次保存**(§6)。
> 无 DB migration、无 FGA model 变更、无新外部依赖(ffmpeg 已在 `api/Dockerfile:14`,pillow_heif 已锁 `api/constraints.txt:55`)。

## 0. 问题与结论回顾

- `.livp` 是 Apple 私有封装(实为 zip),Windows 无关联程序,双击无反应。
- **光"解压"救不了小白**:livp 内静态图在 iPhone「高效」模式下是 HEIC,Windows(尤其 Win10)默认缺 HEIF/HEVC 解码器,解出来照样打不开。必须服务端转 JPG/MP4 再交付。
- 后端为「预览」已备齐全套设施(`generate_livp_thumbnail`:zipfile 解包 → pillow-heif 解码 → ffmpeg 转码),但现有产物是**预览级**(静态图 1024px q80、视频 `scale=1024` + `-t 3` 截断),不能当下载产物。
- 纯前端方案(Chromium FSA 流内解包)覆盖不了无 FSA 的浏览器与移动 web,且 HEIC→JPG 需引入 ~2MB wasm 依赖,不采纳做主方案。
- PC 批量下载现状:`handleBulkDownload` 逐条 download-link → `downloads.start` **每个文件各弹一次 `showSaveFilePicker`**,N 文件 N 次保存框闪烁;本方案将批量交付并入同一"标准 zip"口径一并根治(§6)。

## 1. 总体设计

```
上传 livp / 百度导入 livp
        │ (派发点两处,与缩略图派发并列)
        ▼
arq job generate_livp_download(新,timeout=180)
        │ 解包 livp → 静态图(JPG 透传或 HEIC→JPG 全分辨率)+ 视频(ffmpeg 全规格转 MP4)
        │ 组 zip:内含 基名.jpg + 基名.mp4
        ▼
主存储(HDD)同 bucket:derivatives/{asset_id}/livp.zip
        │ tags 落 download_zip_key / download_zip_size_bytes(失败落 download_zip_failed)
        ▼
前端下载(卡片/预览/文件面板/批量/分享页)
        │ livp 资产默认 variant="unpacked" → download-link 签 zip 的 presigned URL
        │ 未就绪(tag 无 / 404)→ 自动回落原始 .livp + toast
        ▼
用户拿到 基名.zip → Windows 双击可见/「全部解压缩」→ 基名.jpg + 基名.mp4 双击可看

PC 批量下载(批量操作栏,选中 n 个)
        │ POST /assets/batch-download-link(同步生成,上限 100 个/合计 1GB)
        │ livp 用解包衍生物直接进包(未就绪放原始 .livp 兜底)
        │ 确定性 key = 允许集 asset_ids 哈希 → 同选中集 2h 内重点击零重生成
        ▼
derivatives/batch/{hash}.zip(保留 2h;arq cron 每 10 分钟清理过期)
        ▼
一次 showSaveFilePicker(Chromium)/ 一次 anchor(火狐等)→ 批量下载_{n}个文件_{ts}.zip
```

四条原则:

- **原片不动**:`.livp` 原对象、审计、百度备份链路零变化;衍生物只是新增交付形态。
- **未就绪永远有退路**:任何时点解包产物缺失,下载回落原始 livp,不阻断不报错(与 live video 预览的 best-effort 语义同构)。
- **衍生物生命周期跟宿主**:key 记在 `tags`,purge 资产时随删(与 `thumbnail_key`/`live_video_key` 同约定)。
- **批量与单文件同口径**:批量包内 livp 同样以解包后的 jpg+mp4 交付;权限、审计、回落语义与单文件下载一致。

## 2. 后端:worker 新任务 `generate_livp_download`

### 2.1 任务注册与派发

- `api/app/workers/main.py` 新增 `generate_livp_download(ctx, asset_id)`,注册进 `WorkerSettings.functions`,用 `func(generate_livp_download, timeout=180)` per-function 覆盖(先例:百度任务 `main.py:689`;全局 `job_timeout=60` 不够全分辨率转码+zip+上传)。
- 独立 job 而非扩展 `generate_livp_thumbnail`:timeout 独立、失败互不污染(缩略图照常)、回填可单独跑;代价是二次从 MinIO 拉 livp 源(几 MB,可忽略)。
- `api/app/services/arq_pool.py` 加 `enqueue_livp_download`(镜像 `enqueue_livp_thumbnail`,`arq_pool.py:47`)。
- 派发点两处:
  - 上传完成:`api/app/routers/assets.py:255` 的 livp 分支并排多 enqueue 一个;
  - 百度导入:`api/app/workers/baidu_backup.py` `_enqueue_thumbnail`(约 :1985)的 livp 分支同样多派一个。

### 2.2 处理流程(复用既有 helper)

guards 与 `generate_livp_thumbnail` 同款:资产存在 / 未软删 / filename `.livp` / `size_bytes ≤ _LIVP_MAX_BYTES`(200MB)。

1. 下载原 livp 到临时目录(`s3.download_file`,同现模式)。
2. `zipfile.ZipFile` + `_pick_livp_entries`(`main.py:208`)选(最大静态图, 最大视频)。
3. **静态图**:
   - 扩展名 `.jpg/.jpeg` → **原字节透传**(`_read_livp_entry_capped`,上限 `_LIVP_IMAGE_MAX_BYTES`;零重压缩损失,EXIF 原样保留);
   - `.heic/.heif/.png` → `Image.open` + `exif_transpose` + `convert("RGB")` → 全分辨率 JPEG `quality=90, optimize=True`,**保留 ICC**(`icc_profile=img.info.get("icc_profile")`,Display P3 源在 Windows Photos 下色彩正确)。
4. **视频**(有条目时):
   - `_copy_livp_entry` 解出;
   - ffmpeg 下载规格:**去掉** `scale=1024` 与 `-t 3`(那是预览规格,`main.py:282-284`):
     ```
     ffmpeg -i in.mov -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p
            -c:a aac -b:a 128k -movflags +faststart -y out.mp4
     ```
     `-pix_fmt yuv420p` 防 10-bit HEVC 源产出播放器不认的 10-bit H.264;subprocess timeout=120。
5. **组 zip**(抽纯函数 `_build_livp_download_zip` 便于单测,见 §2.3):
   - 内名 `{基名}.jpg` + `{基名}.mp4`(无视频条目则 zip 仅含 jpg);
   - `ZIP_DEFLATED`(jpg/mp4 已压缩,压不小,取标准兼容即可)。
6. **上传主桶**(HDD 实例,与原片同 bucket):key = `derivatives/{asset_id}/livp.zip`,`ContentType="application/zip"`,`Metadata={"source_asset": …, "kind": "livp_download_zip"}`;同 key 覆盖写,重跑幂等。
7. **落 tags**:`download_zip_key` / `download_zip_size_bytes`,成功时 pop `download_zip_failed`;失败(无静态图条目/超限/异常)落 `tags["download_zip_failed"] = _thumb_fail_token(e)`(异常类型名,同 `thumbnail_failed` 口径),静态图缺失直接失败——zip 没有意义。

### 2.3 zip 内名清洗(纯函数)

`基名 = asset.filename` 去掉尾部 `.livp`(大小写不敏感)后,清洗 **Windows 非法字符** `<>:"/\|?*` 与控制字符为 `_`(否则 Windows 解压直接失败);清洗后空串回落 `asset_{id 前 8 位}`。非 ASCII(中文)保留——python zipfile 对非 ASCII 条目名自动打 UTF-8 flag,Win10+ 资源管理器正确解出。

## 3. 后端:`download-link` 加 `variant`

`api/app/routers/assets.py:1420` `get_download_link`,`DownloadLinkIn` 加:

```python
variant: Literal["original", "unpacked"] = "original"
```

行为:

- `variant="original"`(默认):**现行为零变化**(含权限、审计、disposition 逻辑)。
- `variant="unpacked"`:
  - 非 `.livp` 资产 → 400 `"variant unpacked 仅适用 .livp 资产"`;
  - `tags.download_zip_key` 缺失 → 404 `"解包产物未就绪,请稍后或下载原始 livp"`,同时 fire-and-forget `enqueue_livp_download`(**自愈**:上传时派发失败/漏派的兜底;enqueue 异常吞掉只 log,同 `enqueue_livp_thumbnail` 口径);
  - 就绪 → `presign.sign_get_url(asset.minio_bucket, download_zip_key, ttl, response_content_disposition=…, request_base=…)`,其中 disposition 仅在 `as_attachment=true` 时给 `attachment_content_disposition(基名 + ".zip")`(复用 `assets.py:1404`,RFC 5987 中文名已处理;桌面 FSA 路径不需要 disposition,前端 `suggestedName` 决定文件名)。
- 权限(403 → `download_denied` 审计)两 variant 共用,不动;`signed_url_issued` 的 `details` 加 `{"variant": "unpacked" | "original"}` 便于对账。

## 4. 后端:分享页与清理

- **分享**(`api/app/routers/share.py:212`,kind=="asset" 分支):livp 且 `tags.download_zip_key` 就绪 → 签 zip 的 presigned URL(attachment 文件名 `基名.zip`);未就绪/非 livp → 现行为(原始 livp)。分享受众恰是最不懂电脑的人群,收益最大;审计 `share_link_accessed` 的 details 加 `"livp_unpacked": true/false`。
- **清理**(`api/app/services/asset_cleanup.py:22`):`_DERIVED_TAG_KEYS` 现两键走缩略图 MinIO(SSD)通道;`download_zip_key` 与原片**同桶**,走 `presign.delete_object(bucket, key)` 主桶通道(入参 `bucket` 就是宿主桶,零新参)。拆成两个通道映射即可。

## 5. 前端

### 5.1 共享下载 helper(收敛既有重复)

现状四处近乎相同的 handleDownload 副本:`ProjectDetailPage.tsx:195/211`、`AssetPreviewModal.tsx:92`、`AssetSummaryPanel.tsx:93`、`AssetCardList.tsx:50`。新增 `web/src/lib/asset-download.ts`:

```ts
downloadAsset(deps, a: Asset, opts?: { forceOriginal?: boolean }): Promise<void>
```

逻辑:

1. 非 livp(`filename.toLowerCase().endsWith('.livp')`,与 `AssetPreviewModal.tsx:46` 同口径)→ 现行为原样。
2. livp 且未 `forceOriginal`:
   - `a.tags?.download_zip_key` 存在 → `dlLink.mutateAsync({ assetId, variant: 'unpacked' })`,`downloads.start(url, 基名 + '.zip', { assetId, variant: 'unpacked' })`(FSA `suggestedName` 即 `基名.zip`);
   - tag 缺失 → 直接原始下载 + `message.info('「x」解包版生成中,已下载原始 livp')`;
   - 请求 404(tag 有但对象未落/被清的竞态)→ 回落原始 + 同款提示。
3. `forceOriginal: true` → 原始 livp。

配套:

- `useDownloadLink`(`web/src/api/hooks.ts:400`)入参扩展 `variant?: 'original' | 'unpacked'`(body 透传,不传时 body 不带 variant,旧语义不变);
- `download-store.tsx` `start()` 的 opts 加 `variant` 透传——移动直连分支重签 `as_attachment=true` 时**必须带上 variant**,否则手机拿到的是原始 livp。

### 5.2 各入口接入

- 四处下载入口换 helper(机械替换,非 livp 行为零变化)。
- **原始 .livp 次选项**:预览弹窗(AssetPreviewModal)下载按钮旁加「下载原始 .livp」小入口,调 `downloadAsset(…, { forceOriginal: true })`(需要回传 iPhone 的用户用);其余入口暂不加(P1:全入口 antd Dropdown 主/次两项)。
- **批量下载**不再逐条走 helper,整体切单 zip 流程,见 §6.4。
- 分享页前端零改动(后端 resolve 已换 URL)。

## 6. 批量下载改造(PC):逐条弹窗 → 单 zip 一次保存

### 6.1 现状痛点与根因

批量入口仅 PC(批量操作栏)。`handleBulkDownload`(`web/src/pages/ProjectDetailPage.tsx:211`)逐条 download-link → `downloads.start` → **每个文件各弹一次 `showSaveFilePicker`**:N 文件 N 次保存框、任务中心 N 条任务;未加载页文件无 Asset 对象只能用 `asset_<id>.bin` 占位名;无 FSA 浏览器(火狐桌面)逐条 anchor 会被弹窗拦截(现有 >20 确认弹窗文案即为此写)。

### 6.2 后端:新端点 `POST /api/v1/assets/batch-download-link`

`BatchDownloadLinkIn`:

```python
asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)
as_attachment: bool = False
```

流程(同步生成,全程内网 MinIO,nginx 代理超时 ~60s 内完成):

1. **解析与过滤**:逐资产查行(不存在/已软删 → 跳过);权限逐个 `permissions.check(can_download)`(`is_system_admin` 直通),无权限 → 跳过并逐条记 `download_denied` 审计(与单文件 403 同口径);**全部**无权限 → 403。
2. **上限**:≤100 个(入参约束)+ 允许集合计原片 `size_bytes` ≤1GB,超限 400「超出批量打包上限(≤100 个且合计 ≤1GB),请分批下载」。1GB 内网拉流+zip+回传约 15-30s,留足余量;异步排队任务留 P2。
3. **确定性缓存 key**:`derivatives/batch/{sha256(sorted 允许集 asset_ids)[:16]}.zip`;生成前 `head_object` 命中 → 直接重签返回(**同选中集 2h 内重点击零重生成**;并发双写 last-write-wins 无害,内容相同)。
4. **组装 zip**(≤1GB,临时文件从简):
   - 普通资产:`get_object` 流式拷入;
   - livp 且 `tags.download_zip_key` 就绪:**读衍生物 zip,把 `基名.jpg`/`基名.mp4` 直接并入批量包**(与单文件下载同口径;未就绪 → 原始 `.livp` 兜底);
   - 条目名:沿用 §2.3 清洗 + **Windows 风格重名去重**(`IMG_0001.JPG` → `IMG_0001 (1).JPG`,不同夹同名文件很常见);
   - zip 名:`批量下载_{n}个文件_{YYYYMMDD-HHmm}.zip`。
5. **回传主桶** `derivatives/batch/` 前缀,`ContentType="application/zip"`,`Metadata={"kind": "batch_download_zip"}`。
6. **签发**:`sign_get_url(bucket, key, 7200, response_content_disposition=attachment_content_disposition(zip 名) if as_attachment else None, request_base=…)`;**每 contained 资产各记一条 `signed_url_issued`**(details 加 `{"kind": "batch_zip"}`,保持逐资产可追溯)。
7. 响应:`{url, filename, expires_in: 7200, skipped_no_permission: [filename…], skipped_missing: [filename…]}`。

### 6.3 保留与清理(用户拍板:保留 2h / URL 有效期 2h)

- **对象保留 2 小时、presigned URL 有效期 7200s**——防慢链路(公网跳板机入口)下载超时;URL 到期自然失效,对象到期被清,不存在"删到在途下载"的窗口。
- 新增 arq cron `cleanup_batch_zips`(每 10 分钟;先例:`mark_expired_approvals`、百度 sweeper cron):`list_objects_v2(prefix="derivatives/batch/")` 按 `LastModified` 删 >2h 的对象。
- **红线:清理只扫 `derivatives/batch/` 前缀,绝不波及 `derivatives/{asset_id}/livp.zip` 永久衍生物**——两类生命周期不同(批量包=临时缓存,livp 衍生物=跟宿主 purge,见 §4)。

### 6.4 前端

- `handleBulkDownload` 重写:单次 `POST batch-download-link`(`as_attachment: !hasFSA()`,火狐等无 FSA 桌面走 anchor 单次下载,不再被弹窗拦截)→ `downloads.start(url, filename)` →**一次保存框、任务中心一条任务**;`download-store.start` 的直连分支对无 assetId 的 URL 直接使用(批量链接签发时已按入口带 attachment)。
- 生成期间按钮 loading +「正在打包 n 个文件…」提示(同步等待数秒到数十秒)。
- 跳过项聚合提示:「N 个无权限已跳过,可单个申请下载」(替代现在逐个弹申请框的骚扰;单个资产的申请入口仍在)。
- >20 确认弹窗文案更新:「将打包为一个 zip 下载」(不再是「逐个发起下载可能被拦截」);未加载页文件由服务端从 DB 取真名,**顺带修掉 `asset_<id>.bin` 占位名 wart**。

## 7. 存量回填

- 一次性任务:api 容器内 python(或 `scripts/task/` 本地脚本,gitignore 目录)——SELECT 未软删 `.livp` 资产 id 列表 → 逐个 `enqueue_job("generate_livp_download")`。
- 顺序:dev 先行验证 → prod;prod 避开百度任务高峰(发版窗口同款判据:活动任务清零)。
- 对账:SQL 数 `filename ILIKE '%.livp' AND deleted_at IS NULL` vs `tags ? 'download_zip_key'`;差额看 `download_zip_failed` 与 worker 日志。
- 先例:W1 缩略图 664/664 全量回填(2026-10-14,临时自动化用后即删)。

## 8. 决策项(已定)

| # | 决策 | 理由 | 备选(不采纳) |
|---|------|------|----------------|
| D1 | 衍生物存**主存储(HDD)同 bucket** `derivatives/` 前缀 | ADR-0008 定位 SSD 缩略图实例 =「热而小」;zip 是冷数据且比 `previews/`(1024 预览)大一个量级(全分辨率,单件 ~5-20MB);`sign_get_url` 已带 disposition 参数,主桶路由已被原片下载证明 | 缩略图 MinIO(SSD):有 `previews/` 先例且清理通道现成,但违背 ADR 定位且 `sign_thumbnail_url` 无 disposition 参数需扩展 |
| D2 | **独立 arq job**,timeout=180 | 全局 `job_timeout=60` 装不下全分辨率转码;失败隔离;回填独立 | 扩展 `generate_livp_thumbnail`:少一次 MinIO 拉源,但 timeout/失败语义耦合 |
| D3 | 交付**单一 zip**(内含 jpg+mp4) | 一次下载一个文件,批量循环/移动直连/分享全兼容;不单独存 jpg/mp4 对象(zip 无法部分 presign,要拆分下载需三份存储) | 拆「照片/视频」两个下载按钮:P1 可加(需另存两对象),本期不做 |
| D4 | JPG 源**透传**,HEIC/PNG 转 JPEG q90+ICC | 透传零损失保 EXIF;转换保留 ICC 防 P3 色偏 | 一律重转 JPEG:JPG 源多一代损失无收益 |
| D5 | 视频**一律转码** H.264(`-pix_fmt yuv420p`) | 源可能是 HEVC(Chrome/Windows 双盲),无法廉价探测;3s 短片转码 <20s,worker 异步无压力 | H.264 源 remux(`-c copy`)省时零损:需探测 codec,复杂度不值,P2 优化项 |
| D6 | 前端以 `tags.download_zip_key` 为**就绪信号**,404 兜底回落 | 避免必然 404 的请求;tag 竞态由回落保护 | 恒请求 unpacked 靠 404 分流:多一跳,提示语义差 |
| D7 | 批量交付**单 zip**,同步生成,上限 100 个/合计 1GB | 一次保存框根治反复弹窗;同步实现简单,1GB 内网 ~15-30s 远低于 nginx 60s 代理超时;异步排队 P2 | 异步任务+轮询:交互更重,当前批量规模不值 |
| D8 | 批量包**保留 2h / URL 2h**,cron 每 10 分钟清 `derivatives/batch/`;确定性 key 同选中集复用 | 用户拍板(防慢链路下载超时);服务端无法感知浏览器下载完成,TTL 只能从生成时刻起算,2h 覆盖最慢链路且不存在删在途包的窗口;重点击 2h 内零重生成 | 原案 1 分钟:会删到正在下载的对象,断流 404 |
| D9 | 批量包内 livp **解包后直接进包**(未就绪放原始) | 用户拍板;与单文件下载同口径,批量场景不复现「解出来还是 livp」 | 一律原始 livp:批量用户重新遇到原始问题 |

## 9. 边界与已知限制

- **HDR 实况视频**(Dolby Vision)转码无 tone map,色彩可能偏移;静态图靠 ICC 保留缓解(优于现状缩略图的静默丢弃)。列为已知限制,不满不阻塞。
- 10-bit HEVC 源强转 8-bit yuv420p(兼容性优先)。
- 大 livp(几十 MB)转码最坏超 180s → job 失败落 `download_zip_failed`,用户回落原始;自愈靠下载 404 重 enqueue + 回填对账。
- `derivatives/` 前缀与百度备份无交集(备份按 DB 行 `minio_key` 走);**未来若给 bucket 配 lifecycle(如 import 前缀 30d),必须排除 `derivatives/`**。
- 移动 web 直连会拿到 zip(iOS 文件 App / Android 主流文件管理器可解压),属顺带收益,不列本期验收;Flutter App(B4 下载)仍下原始 livp,复用 variant 接口另立项。
- Windows 7 时代 zip 中文名 cp437 乱码不在支持范围(Win10+ 正确)。
- **批量**:同 key 并发双生成 last-write-wins(内容相同无害);2h 后重点击自然重新生成(等价首次点击);生成后 2h 内权限被回收 → 已签 URL 在有效期内仍可下载(zip 内容不变)——与单文件 presigned「无法即时吊销」语义一致;批量 zip 为扁平结构不含文件夹(选集恒为单夹列表内)。

## 10. 测试计划

后端(隔离栈三件套 + pytest,worker 转码不可单测的部分抽纯函数):

- `test_livp.py` 扩展(纯函数,零外部依赖,沿用该文件先例):
  - 基名提取 + Windows 非法字符清洗(中文/空基名/非法字符/大小写 .LIVP);
  - `_build_livp_download_zip`:photo-only、photo+video、内名正确性。
- download-link variant(挂 `test_download_attachment.py` 同款设施):
  - unpacked + 就绪 → 200,URL 指向 zip key,`as_attachment` 时 disposition 文件名 `基名.zip`,审计 details.variant;
  - 非 livp + unpacked → 400;未就绪 → 404 且 enqueue 被调(mock pool);
  - 403 权限路径与 original 完全一致(回归)。
- share resolve:livp 就绪 → zip URL + `livp_unpacked: true`;未就绪 → 原始(回归)。
- batch-download-link(新,挂独立测试文件):
  - 权限:部分无权限 → 跳过 + `skipped_no_permission` + 逐条 `download_denied` 审计;全部无权限 → 403;admin 直通;
  - 上限:>100 个 → 422(入参约束);合计 >1GB → 400;
  - 缓存:同选中集二次请求命中 `head_object` 不重生成(mock s3);并发双写无害;
  - 组装:livp 就绪并入 jpg+mp4 / 未就绪放原始 livp;同名 `(1)` 去重;非法字符清洗;`as_attachment` 时 disposition 为 zip 名;逐资产 `signed_url_issued(kind=batch_zip)` 审计;
  - cron 清理:只删 `derivatives/batch/` 前缀超龄对象,不碰 `{asset_id}/livp.zip`(fake list 单测)。
- 前端无单测基建(零 test runner),走隔离栈手测清单:四入口各下一次 livp、未就绪回落、forceOriginal、批量单弹窗/聚合提示/loading、非 livp 零变化。

## 11. 部署与验收

- 无迁移/无 FGA/无新依赖 → api + SPA 常规发版(deploy-lan 流程),镜像无需重建。
- 回填:dev 验证 → prod(§7)。
- PC 真机验收清单:
  1. 卡片/预览/批量/分享页各下载一次 livp → 得 `基名.zip` → 解压得 `基名.jpg` + `基名.mp4`,双击均可看(HEIC 源色彩正常);
  2. 预览弹窗「下载原始 .livp」可用;
  3. 未就绪资产(新建 livp 秒点下载)回落原始 + 提示,不报错;
  4. 403 申请下载路径、非 livp 下载、移动端直连下载均零回归;
  5. 批量下载 n 个(含 livp 与跨夹同名文件)→ **仅一次保存框** → zip 内 livp 已是 jpg+mp4、同名带 `(1)`、无权限项聚合提示;
  6. 同选中集重点击(2h 内)秒回不重新生成(dev 观察 cron 前对象 mtime 不变 / 接口耗时);
  7. 火狐桌面批量下载走 anchor 单次成功;>100 个或合计 >1GB 被拒并提示分批。
- 回滚:前端 livp 分支随 SPA 回退即失效;后端 variant 参数无调用方则无行为影响;衍生物对象留存无害(不入备份/列表/配额语义)。

## 12. 工作量估算

- 后端 livp 侧(worker job + variant + share + 清理):~0.5-1 天
- 后端批量侧(batch-download-link + cron 清理):~0.5-1 天
- 前端(helper + 四入口 + 弹窗次选项 + 批量重写):~1 天
- 回填 + dev/prod 验证:~0.5 天
- 合计 ~2.5-3 天(含测试)
