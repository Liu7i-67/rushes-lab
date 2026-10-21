# 方案:PC 端 livp 下载自动解包 + 批量下载单 zip 化(服务端衍生物交付)

> 依据:2026-10-21 调研(会话结论,摘要见 §0)+ [heic-mov-preview-thumbnail-investigation.md](./heic-mov-preview-thumbnail-investigation.md)(livp 预览链路前身)。
> 目标:①消除「PC 用户下载实况照片得到 .livp,既不是图片也不是视频,小白不知道能解压」的体验问题;②消除「PC 批量下载多文件反复弹保存框、闪烁」的体验问题。
> 范围:**服务端生成"下载级"衍生物(全分辨率 JPG + H.264 MP4 打包成标准 zip),下载时对 livp 资产默认交付 zip**,原始 .livp 保留为显式次选项;**PC 批量下载一并改造:逐条弹窗 → 异步打包单 zip 一次保存**(§6)。
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
arq job generate_livp_download(新,timeout=300)
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
        │ POST /assets/batch-download-link(创建+轮询双职能;校验/head/enqueue 毫秒级)
        │ 未命中缓存 → arq job generate_batch_download_zip 异步打包(timeout=1800)
        │ livp 用解包衍生物直接进包(未就绪放原始 .livp 兜底)
        │ 确定性 key = (asset_id, livp 就绪位) 序列 + 允许集摘要 的哈希 → 同选中集同权限 6h 内重点击零重生成
        ▼
derivatives/batch/{hash}.zip(统一保留 6h;arq cron 每 10 分钟清理过期)
        ▼
ready 后一次 showSaveFilePicker(Chromium)/ 一次 anchor(火狐等)→ 批量下载_{n}个文件_{ts}.zip
```

四条原则:

- **原片不动**:`.livp` 原对象、审计、百度备份链路零变化;衍生物只是新增交付形态。
- **未就绪永远有退路**:任何时点解包产物缺失,下载回落原始 livp,不阻断不报错(与 live video 预览的 best-effort 语义同构)。
- **衍生物生命周期跟宿主**:key 记在 `tags`,purge 资产时随删(与 `thumbnail_key`/`live_video_key` 同约定)。
- **批量与单文件同口径**:批量包内 livp 同样以解包后的 jpg+mp4 交付;权限、审计、回落语义与单文件下载一致。

## 2. 后端:worker 新任务 `generate_livp_download`

### 2.1 任务注册与派发

- `api/app/workers/main.py` 新增 `generate_livp_download(ctx, asset_id)`,注册进 `WorkerSettings.functions`,用 `func(generate_livp_download, timeout=300, max_tries=2)` per-function 覆盖(先例:百度任务 `main.py:689`;全局 `job_timeout=60` 不够;`max_tries` 显式设定,勿用 arq 默认 5;300s 余量核算:200MB 源拉取 + HEIC 全分辨率解码 + ffmpeg ≤120s(须低于 job timeout,沿用 `main.py:204` 约定)+ zip + 上传)。
- 独立 job 而非扩展 `generate_livp_thumbnail`:timeout 独立、失败互不污染(缩略图照常)、回填可单独跑;代价是二次从 MinIO 拉 livp 源(典型几 MB,防御上限内最坏 200MB,worker 侧可接受)。
- `api/app/services/arq_pool.py` 加 `enqueue_livp_download`(镜像 `enqueue_livp_thumbnail`,`arq_pool.py:47`;**入队带确定性 `_job_id=f"livpdl:{asset_id}"` + `_expires≈3600`** 在途去重——自愈 404 重派与上传派发并发时同一资产不双跑;`_expires` 把崩溃残留的墓碑键盲窗从默认 24h 压到 1h(arq 0.28 `enqueue_job` 支持);与批量侧 epoch-id 结论不冲突:livp job 单资产,结果键 300s 尾窗内自愈至多多等一轮,无假 packing 问题)。
- 派发点两处:
  - 上传完成:`api/app/routers/assets.py:255` 的 livp 分支并排多 enqueue 一个;
  - 百度导入:`api/app/workers/baidu_backup.py` `_enqueue_thumbnail`(约 :1989)的 livp 分支同样多派一个。

### 2.2 处理流程(复用既有 helper)

guards 与 `generate_livp_thumbnail` 同款:资产存在 / 未软删 / filename `.livp` / `size_bytes ≤ _LIVP_MAX_BYTES`(200MB)。

**阻塞模型(铁律)**:本 job 的 boto3 下载/上传、zip 组装、ffmpeg 一律 `asyncio.to_thread` 包裹(ffmpeg 可用 `asyncio.create_subprocess_exec`)——arq 的 `max_jobs` 是**单事件循环协程数**,同步阻塞体会冻结整个 worker(冻结期间在跑百度任务的 5s 租约续期停摆会被 sweeper 误判接管)。**顺带小项(必做,两项同批但动机各自独立)**:①tags `jsonb_set` 化(§2.2 第 7 步)是**双 writer 互覆**安全的前提;②存量三族缩略图 job(`generate_thumbnail`/`generate_video_thumbnail`/`generate_livp_thumbnail`)的同步阻塞段(最坏 = 200MB 拉取 + ffmpeg 45s,已逼近百度 60s 租约)to_thread 化是**事件循环健康**(百度 5s 租约续期不被冻结)的前提——纯防御性小改,不改行为。

1. 下载原 livp 到临时目录(`s3.download_file`,同现模式)。
2. `zipfile.ZipFile` + `_pick_livp_entries`(`main.py:208`)选(最大静态图, 最大视频)。
3. **静态图**:
   - 扩展名 `.jpg/.jpeg` → **原字节透传**(`_read_livp_entry_capped`,上限 `_LIVP_IMAGE_MAX_BYTES`;零重压缩损失,EXIF 原样保留);
   - `.heic/.heif/.png` → `Image.open` + `exif_transpose` + `convert("RGB")`(**RGBA 透明区贴白底合成**——裸 convert 会把 alpha 丢成黑底;**本 job 显式调高 `Image.MAX_IMAGE_PIXELS`**——预览链路依赖 Pillow 默认 DecompressionBomb 守卫(~1.78 亿像素),合法超大全景图会被它判死且归入「解码失败=永久失败」;下载级要放行,防滥用由 livp 200MB 入口上限兜)→ 全分辨率 JPEG `quality=90, optimize=True`,**保留 ICC 与 EXIF**(`icc_profile=img.info.get("icc_profile")` + `exif=` 取 **transpose 返回对象自带的 exif**——必须是已剥除 orientation 标签的 EXIF,带原 orientation 落盘会让 Windows 查看器二次旋转;Pillow 各版本此处行为有差异,以单测钉住)——只传 ICC 不传 EXIF 会丢拍摄时间等元数据,「高效」iPhone 恰是本方案主场景。
4. **视频**(有条目时,best-effort 与预览链路同语义):
   - `_copy_livp_entry` 解出;
   - ffmpeg 下载规格:**去掉** `scale=1024` 与 `-t 3`(那是预览规格,`main.py:282-284`):
     ```
     ffmpeg -i in.mov -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p
            -c:a aac -b:a 128k -movflags +faststart -y out.mp4
     ```
     `-pix_fmt yuv420p` 防 10-bit HEVC 源产出播放器不认的 10-bit H.264;subprocess timeout=120;
   - **转码失败(超时/ffmpeg 非零/HEVC 解码缺失)→ 降级交付「仅 jpg 的 zip」**,不判 job 失败,落 `tags["download_zip_video_failed"]` 时间戳供观测(对齐 `generate_livp_thumbnail` 的实况 best-effort 口径:预览能出图,下载不能反而更脆)。
5. **组 zip**(抽纯函数 `_build_livp_download_zip` 便于单测,见 §2.3):
   - 内名 `{基名}.jpg` + `{基名}.mp4`(无视频条目则 zip 仅含 jpg);
   - `ZIP_STORED`——jpg/mp4 均为已压缩数据,deflate 只白烧 CPU 不减体积(§6.2 批量包同款)。
6. **上传主桶**(HDD 实例,与原片同 bucket):key = `derivatives/{asset_id}/livp.zip`,`ContentType="application/zip"`,`Metadata={"source_asset": …, "kind": "livp_download_zip"}`;同 key 覆盖写,重跑幂等。
7. **落 tags(失败分级,自愈回路的关键;写入用原子 `jsonb_set`)**:本方案在上传/百度导入两派发点**并排入队缩略图 job 与本 job**,两者对同一 `tags` 列做「读-改-写」会整列互覆丢对方的 key(现有 RMW 模式单 writer 时代安全,双 writer 即破)——**新增写入点一律单条 `UPDATE assets SET tags = jsonb_set(tags, …)` 原子合并,存量三族缩略图 job 写点同批一并 jsonb_set 化(§9 必做项)**:
   - 成功 → `download_zip_key` / `download_zip_size_bytes`,并删 `download_zip_failed`;
   - **永久失败**(无静态图条目 / 超 `_LIVP_MAX_BYTES` 上限 / **静态图解码失败**(损坏 HEIC/PNG——确定性失败,重跑必同结果)——重派注定同结果)→ `download_zip_failed = _thumb_fail_token(e)`;§3 的 404 自愈**不重派**此类;
   - **瞬时失败**(MinIO/网络异常、job 超时等)→ **不落** `download_zip_failed`(只在 worker 日志留痕),让 §3 的 404 自愈按 600s 频控自然重派——若所有失败都落永久 tag,超时资产永远进不了自愈回路,只剩 §7 人工回填一条路(自相矛盾)。
   - **超时路径落盘须 `except BaseException`**:arq timeout 走 `wait_for` 取消,`except Exception` 捕不到 `CancelledError`——瞬时失败若要在取消前留日志/tag,须捕 BaseException 后 re-raise。

### 2.3 zip 内名清洗(纯函数)

`基名 = asset.filename` 去掉尾部 `.livp`(大小写不敏感)后,清洗 **Windows 非法字符** `<>:"/\|?*` 与控制字符为 `_`,**并去掉尾部点/空格**(「名字.」「名字 」在资源管理器解压同样出错),**命中 Windows 保留设备名**(`CON`/`PRN`/`AUX`/`NUL`/`COM1-9`/`LPT1-9`,含带扩展名形态)加 `_` 后缀(`CON.jpg` 解压/`CON.zip` 保存均直接报错);清洗后空串回落 `asset_{id 前 8 位}`。非 ASCII(中文)保留——python zipfile 对非 ASCII 条目名自动打 UTF-8 flag,Win10+ 资源管理器正确解出。

## 3. 后端:`download-link` 加 `variant`

`api/app/routers/assets.py:1420` `get_download_link`,`DownloadLinkIn` 加:

```python
variant: Literal["original", "unpacked"] = "original"
```

行为:

- `variant="original"`(默认):**现行为零变化**(含权限、审计、disposition 逻辑)。
- `variant="unpacked"`:
  - 非 `.livp` 资产 → 400 `"variant unpacked 仅适用 .livp 资产"`;
  - `tags.download_zip_key` 缺失,分两支:
    - `download_zip_failed` **有值**(永久失败:无静态图/超限/解码失败)→ 404,**不重派**(重派注定同结果);
    - **无值**(未生成或瞬时失败)→ 404 + 自愈:若 Redis 频控 `livpdl:heal:{asset_id}`(SETNX EX 600)未占用(**SETNX 连接异常须 try/except 只 log 后照常 404**——download-link 现状不依赖 Redis,不能让 livp 下载从「404 回落原始」退化成 500),fire-and-forget `enqueue_livp_download`(上传时派发失败/漏派的兜底,频控防反复点击刷派发;enqueue 异常吞掉只 log,同 `enqueue_livp_thumbnail` 口径);
  - 就绪 → **签发前先 `head_object` 校验衍生物对象存在(tag 在而对象被外力清除的孤儿 tag → 按「缺失」分支处理走 404/自愈,不给无 FSA 的移动/火狐路径签出必 404 的 URL——JS 捕获不到 anchor 下载失败,兜底必须在服务端;head 同步 boto3 按 `asyncio.to_thread` 包裹,铁律 `asset_purge.py:12`)** → `presign.sign_get_url(asset.minio_bucket, download_zip_key, ttl, response_content_disposition=…, request_base=…)`,disposition 仅在 `as_attachment=true` 时给 `attachment_content_disposition(基名 + ".zip")`(复用 `assets.py:1404`,RFC 5987 中文名已处理;桌面 FSA 路径不需要 disposition,前端 `suggestedName` 决定文件名;单文件下载频度低,head 代价可忽略)。
- 权限(403 → `download_denied` 审计)两 variant 共用,不动;`signed_url_issued` 的 `details` 加 `{"variant": "unpacked" | "original"}` 便于对账。

## 4. 后端:分享页与清理

- **分享**(`api/app/routers/share.py:212`,kind=="asset" 分支):livp 且 `tags.download_zip_key` 就绪 → **先 `head_object` 校验衍生物存在(`asyncio.to_thread` 包裹,先例 `assets.py:877`;孤儿 tag → 回落签原始 livp——share 页前端零改动无回落 UI,兜底必须在服务端,与 §3 同原则)** → 签 zip 的 presigned URL(attachment 文件名 `基名.zip`);未就绪/非 livp → 现行为(原始 livp)。分享受众恰是最不懂电脑的人群,收益最大;审计 `share_link_accessed` 的 details 加 `"livp_unpacked": true/false`。
- **清理**(`api/app/services/asset_cleanup.py:22`):`_DERIVED_TAG_KEYS` 现两键走缩略图 MinIO(SSD)通道;`download_zip_key` 与原片**同桶**,走 `presign.delete_object(bucket, key)` 主桶通道(入参 `bucket` 就是宿主桶,零新参)。拆成两个通道映射即可。

## 5. 前端

### 5.1 共享下载 helper(收敛既有重复)

现状四处近乎相同的单文件 handleDownload 副本:`ProjectDetailPage.tsx:195`、`AssetPreviewModal.tsx:89`、`AssetSummaryPanel.tsx:89`、`AssetCardList.tsx:47`(另有批量循环 `handleBulkDownload` `ProjectDetailPage.tsx:211`,由 §6 整体重写,不在此列)。新增 `web/src/lib/asset-download.ts`:

```ts
downloadAsset(deps, a: Asset, opts?: { forceOriginal?: boolean }): Promise<void>
```

逻辑:

1. 非 livp(`filename.toLowerCase().endsWith('.livp')`,与 `AssetPreviewModal.tsx:46` 同口径)→ 现行为原样。
2. livp 且未 `forceOriginal`:
   - `a.tags?.download_zip_failed` 有值(永久失败)→ 直接原始下载 + `message.info('「x」暂不支持解包,已下载原始 livp')`(tags 随 AssetOut 下发,勿把永久失败也报「生成中」误导用户);
   - **其余情形(含 tag 缺失)一律请求 `variant: 'unpacked'`**——自愈回路的唯一入口就是 unpacked 请求的 404(tag 缺失分支若前端直落原始下载,§3 的「上传漏派/瞬时失败 600s 频控重派」对 Web 用户全部死路);404 → 回落原始 + `message.info('「x」解包版尚未就绪,已下载原始 livp')`(不承诺「生成中」——反复瞬时失败的资产可能长期不就绪,文案弱化承诺);
   - 200 → `downloads.start(url, 基名 + '.zip', { assetId, variant: 'unpacked' })`(FSA `suggestedName` 即 `基名.zip`);孤儿 tag(对象被外力清除)已由服务端签发前 head 拦下(§3),前端 FSA fetch 404 回落原始仅作二道防线。
3. `forceOriginal: true` → 原始 livp。

配套:

- `useDownloadLink`(`web/src/api/hooks.ts:401`)入参扩展 `variant?: 'original' | 'unpacked'`(body 透传,不传时 body 不带 variant,旧语义不变);
- `download-store.tsx` `start()` 的 opts 加 `variant` 透传——移动直连分支重签 `as_attachment=true` 时**必须带上 variant**,否则手机拿到的是原始 livp;该分支重签若 404(首签与重签之间衍生物失效的边缘)→ helper 捕获后兜底原始下载(与桌面路径同款回落语义)。

### 5.2 各入口接入

- 四处下载入口换 helper(机械替换,非 livp 行为零变化)。
- **原始 .livp 次选项**:预览弹窗(AssetPreviewModal)下载按钮旁加「下载原始 .livp」小入口,调 `downloadAsset(…, { forceOriginal: true })`(需要回传 iPhone 的用户用);其余入口暂不加(P1:全入口 antd Dropdown 主/次两项)。
- **批量下载**不再逐条走 helper,整体切单 zip 流程,见 §6.4。
- 分享页前端零改动(后端 resolve 已换 URL)。

## 6. 批量下载改造(PC):逐条弹窗 → 单 zip 一次保存

### 6.1 现状痛点与根因

批量入口仅 PC(批量操作栏)。`handleBulkDownload`(`web/src/pages/ProjectDetailPage.tsx:211`)逐条 download-link → `downloads.start` → **每个文件各弹一次 `showSaveFilePicker`**:N 文件 N 次保存框、任务中心 N 条任务;未加载页文件无 Asset 对象只能用 `asset_<id>.bin` 占位名;无 FSA 浏览器(火狐桌面)逐条 anchor 会被弹窗拦截(现有 >20 确认弹窗文案即为此写)。

### 6.2 后端:异步打包任务 + `POST /api/v1/assets/batch-download-link`(创建/轮询双职能)

**为什么异步(而不是同步 ≤1GB)**:素材库以照片/视频为主,**单个文件超过 1GB 属常态**(视频原片)——同步方案要么整单拒绝(「请分批下载」对单文件已超限的情况物理上不可执行,视频夹批量每次必败),要么把数分钟的拉流+组包塞进代理窗口(hh2 内层 nginx 对 `/api/v1/` 未覆写 `proxy_read_timeout`,取默认 ~60s;跳板机公网入口是 3600s,不救内层)并阻塞 API 事件循环。异步归档 + 轮询是 Google Photos/Dropbox/百度网盘对大批量导出的通行做法,且本库 arq per-function timeout + 前端轮询进度(百度任务)均为现成先例,故列入本期。

**归属桶**:批量包存**选中集所在项目的桶**(bucket 按项目,`assets.py` `_project_bucket` 口径);端点断言允许集全部资产同桶(跨桶选集 → 400「跨项目批量暂不支持」;实际选集恒为单夹,此为防御);cron 清理按 `list_buckets()` 迭代全部桶(§6.3,不用 projects 表——项目逻辑删后其桶会漏)。

`BatchDownloadLinkIn`:

```python
asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)
as_attachment: bool = False
resume_key: str | None = None   # 轮询沿用首次 key(服务端校验其选中集哈希一致)
retry: bool = False             # failed 后手动重试:清失败标记重新入队
```

**端点职责只有校验 + head 探测 + enqueue(亚秒级,不做重活;首次 POST 与 ready 复检的逐资产 `permissions.check` 是 OpenFGA 网络往返,100 资产用 `asyncio.gather` 并发查,勿串行)**;重活全部在 worker job。同步 boto3(head_object 等)按仓库铁律 `asyncio.to_thread` 包裹(先例 `assets.py:877`)。流程:

1. **解析与过滤——首次 POST 全量校验并落作业记录,轮询凭记录回放**:首次**单条 `SELECT … WHERE id IN (…)` 查全部行**(AsyncSession 不允许并发,勿逐资产 `db.get`;不存在/已软删 → 跳过)+ 权限逐个 `permissions.check(can_download)`(**仅 FGA check 用 `asyncio.gather` 并发**,`permissions.py` 走 OpenFGA client 无 DB session,可并发),无权限 → 跳过并**仅首次**逐条记 `download_denied`(Redis SETNX `batchzip:audited:{user}:{key}` **EX 1800** 去重,窗口 ≥ 前端轮询上限 900s);允许集为空 → 全无权限 403 / 全不存在 400「无可下载文件」。首次 POST 把作业上下文写 Redis `batchzip:job:{user}:{key}`(**按用户分记录**——同 key 不同请求者互不覆盖;EX 3600):`{bucket, filename, selection_ids, allowed_ids, skipped_no_permission, skipped_missing_count, created_at}`——**`selection_ids` = 请求体原始 ids 的 canonical 形态(去重+升序,resume 校验与 key 哈希共用同一 canonical 函数——前端 `selectedIds` 顺序依赖 Set 插入序,按原始序比较会恒 400)**,`allowed_ids` = 过滤后允许集(ready 收敛基准);两者必须分开存:resume 校验若误用 allowed_ids,任何含无权限/缺失项的选集轮询会恒 400 → 前端静默全新 POST → 每 3s 一轮全量 FGA 复检,轻校验设计整体翻车;**轮询的 resume 校验与响应回放全靠它**(见第 3/6 步)。轮询(带 `resume_key` 再 POST)只做轻校验(**canonical(body ids) == 记录 `selection_ids`**,不做行存在性/软删检查——打包途中资产被软删时轮询不得 400,缺席由 job 跳过、收敛交 ready 复检,与 §6.2 组装段的「跳过缺席」口径一致),**ready 时刻才做全量复检 + key 收敛**(第 4 步)——安全与内容闸门钉在 URL 签发时刻,轮询不放大 FGA 成本。
2. **上限**:≤100 个(入参约束)+ 合计**折算体积** ≤**10GB(名义值)**,超限 400,**文案区分两种情况**:「选集中单个文件超过 10GB 上限,请单独下载该文件」/「合计超出批量打包上限(≤100 个且合计 ≤10GB),请分批下载」——单文件物理上无法分批,不能给它「请分批」的死胡同文案。**折算体积 = 普通资产按 `size_bytes` 原值 + livp 资产按 `size_bytes × 3` 计入**(livp 解包产物 = 全分辨率 JPEG——「高效」HEIC 静态图膨胀 2.5-4 倍——+ 转码 MP4,重 HEIC 轻视频条目的极端选集整包膨胀可达 ~3 倍;×2 会击穿校准,取保守 ×3)。**名义 10GB 的实际 zip 上界 ~1.3-1.5×**(折算是启发式,极端 HEIC 密集选集仍可超)——下游三处校准按实际上界留余量:临时盘判据 **2×15GB=30GB**(部署 checklist)、6h URL × 0.7MB/s ≈ 15GiB 实际上界(§6.3/D8;更慢链路靠 §11 checklist ⑤ 实测门槛联动下调上限)、前端轮询 900s 封顶同理。**单文件 >1GB 正常入包**。
3. **确定性缓存 key**:`derivatives/batch/{sha256(选中集 + livp 就绪位 + **允许集摘要**)[:16]}.zip`——**ids 先 canonical 化(去重 + 升序排序)再序列化哈希,前后端共用同一契约**(前端 `selectedIds` 是数组、天然无重复,但顺序为点击/跨页选择的插入序,非规范序——按原始序哈希则同一选集两次点击 key 不同、缓存永不命中);**允许集摘要入 key** 是缓存正确性的根本:权限不同的用户天然分 key(A 缺权限与 B 全权不会撞包,无投毒无乒乓重打包),权限相同的用户天然共享缓存;**就绪位入 key**(livp 衍生物就绪与否随时间变化,不含就绪位会把「含原始 livp 的旧包」钉住 6h)。轮询沿用首次 key:请求带 `resume_key`,服务端读 `batchzip:job:{user}:{key}` 记录校验 **canonical(body ids) == 记录 `selection_ids`**(第 1 步:基准是 canonical 形态,不是 allowed_ids)后沿用(记录天然挡住跨用户/换选集的 resume);轮询期间就绪位或权限翻转由 ready 时刻的全量复检收敛(第 4 步:key 变化 → 自动按新批处理),轮询本身不换 key。
4. **head_object 命中 → ready(全量复检 + key 收敛)**:做全量权限复检得出当前允许集与**当前应然 key**——**全部无权限 → 403**;**当前应然 key ≠ resume_key/首次 key(权限被回收或跨请求者权限不同)→ 按新批处理**(**先对新应然 key `head_object`,命中即直接按 ready 签发**——新 key 恰有缓存包时免一次重打包;**该分支本用户可能无作业记录(包是同权限另一用户生成的),filename/skipped 按当前全量复检现算回放并补写记录**;未命中才走第 5 步入队——权限变化对调用者透明,前端照常按响应里的新 key 继续轮询)。`age = now - LastModified`;**age ≥ 保留期(6h)→ 按 miss 处理**(cron 是 10 分钟粒度,可能扫到超龄对象,此时剩余寿命 ≤0,botocore `ExpiresIn` 会直接抛错);否则签 `sign_get_url(bucket, key, min(21600, 21600 - age), disposition if as_attachment else None, request_base=…)`(**剩余寿命收缩**:重签满额会造出「URL 还活着、对象已被清」的断流尾窗);**审计写单条聚合事件**(`signed_url_issued` 一条,details 携 `{"kind": "batch_zip", "ids": […]}`——语义与逐资产等价、写放大小一个量级,双 tab/反复重点击不放大审计行数);轮询以 ready 为终点,前端保证单实例轮询,不刷审计。**改动点备注:现 `PresignService.head_object`(`presign.py:367`)不返回 Metadata**——§6.3 删除守卫要读 `kind`,须扩展该方法返回 metadata 字段(或调用处直用 boto3),列入改动清单(对象 Metadata 里的 `contained-sha256` 降为观测字段,不再参与校验)。
5. **miss → 入队(锁即去重闸)**,按序判定:
   - **失败标记 `batchzip:fail:{key}` 存在**(job 失败时写,EX 600)→ `{status:"failed"}`;请求带 `retry: true` → DEL 标记后继续走下述入队(手动重试,不受标记 TTL 拘束);
   - **per-user 锁存在且 value 前缀 == key**(本批 job 在跑)→ 返 `{status:"packing"}`,**不重入队**——确定性 `_job_id` 去重已被弃用(见下),轮询防踩踏靠这把锁;
   - **锁不存在** → **per-key 在途闸 `batchzip:keygate:{key}`(NX EX 2400)与 per-user 锁 `batchzip:active:{user_id} = f"{key}:{job_token}"`(NX EX 2400)用单段 Lua 原子落**(单段防「两 SET 之间进程死亡」留 40 分钟假 packing 的孤儿窗)。per-key 闸是**跨用户同 key 打包期的去重**(同选集+同权限集的另一用户点击即撞闸 → 按 packing 返回;没有这道闸,「拍完照多人同时导出同一夹」的主场景会双份拉流+占满打包信号量;闸由 job finally DEL);**两键 TTL 2400 仅作崩溃兜底,job 开始执行时先对两键 Lua 续期(以执行时刻重置 TTL)**——满载排队(8 槽被百度+缩略图占用)时第三个打包 job 可排队近 1800s,静态 TTL 撑不住执行期,不续期会出现「闸先过期 → 同 key 重新入队双份打包」与「信号量等待吃光 job 预算 → 自管 deadline 快速失败 → 用户重试空转」两类失效。撞闸 → 返 packing(带 `retry_after_seconds` = 闸剩余 TTL,供前端提示预计等待);两键落成 → `enqueue_job("generate_batch_download_zip", user_id, job_token, 允许集 ids, bucket, key, _job_id=f"{key}:{int(time.time())}")` → packing(**入参显式带 bucket**——端点已按 `_project_bucket` 断言同桶,job 不再自行推导;**enqueue 抛错/返 None → 按 token Lua 匹配 DEL 刚落的两键回滚**,不留锁孤儿)。job 入参**必须带 job_token**,否则 finally 的「值匹配才删」无米下锅。注意参数名是 **`_job_id`**(arq 0.28;写成 `job_id=` 会被当 job 函数 kwarg 序列化,worker 侧 TypeError);**id 用 epoch 后缀而非确定性 key**:确定性 id 会与已完成 job 的**墓碑键 `arq:job:{id}`(崩溃/kill 残留最长可达 24h)**和 keep_result 结果键(300s)相撞,`enqueue_job` 静默返 None → 假 packing 空转——head 检查是缓存闸门、同用户踩踏由锁防、跨用户由 per-key 闸防,arq 层去重并无必要,epoch id 一劳永逸绕开残留窗口。权限回收/就绪位变化触发的「按新批处理」同样落此分支(新 key 新记录,与旧包互不干扰);
   - **锁存在且 value 前缀 ≠ key** → 429「打包进行中,请稍候」。
   - 锁由 job `finally` 管理:**值匹配才删**(value 含 job token,Lua 比对——不同批次/重试的 job 不得误删后来者的锁);成功 → DEL 锁;失败 → DEL 锁 + SET 失败标记。**worker 崩溃(max_tries=1 无自动重试)**:崩溃残留 job 被重拾时 arq 按 retry 计数直接判失败**且不执行函数**(`arq:retry:{job_id}` 计数跨重拾持久)——不会自动重跑自愈;恢复依赖锁/闸 TTL 2400s 自然过期 + 用户重点击(head miss → 新 epoch id 入队);期间同 key 轮询仍放行(前缀==key)、异 key 429,端点持续 packing 属已知窗口(§9)。
6. **响应**(三态同形):`{status: "ready"|"packing"|"failed", key, url?, expires_in?, filename, skipped_no_permission: [asset_id…], skipped_missing_count: int, livp_raw_count: int}`——`key` 供轮询带 `resume_key`;`livp_raw_count` = 以原始 `.livp` 兜底入包的数量(未就绪/永久失败;**packing 首响应按当时 tags 静态判定,ready 响应以 job 实际打包计数回写**——轮询期间就绪位翻转时首响应数字可能与实际包内容有偏差,以 ready 为准),前端聚合提示「m 个实况照片暂以原始格式保留」;**filename 与跳过列表从 `batchzip:job:{user}:{key}` 记录回放**(轮询轻校验不重算权限,响应一致性靠记录);**跳过列表只回 asset_id 不回文件名**(防侧信道:单文件 403 从不回资产名,本端点不能成为用随机 UUID 探测 sensitive 夹文件名的新通道;前端用自己已加载的 Asset 名渲染提示,未加载项只计总数)。

**worker job `generate_batch_download_zip(ctx, user_id, job_token, asset_ids, bucket, key)`**:`func(…, timeout=1800, max_tries=1)` 注册(先例与同款理由:`func(baidu_backup_run, timeout=3600, max_tries=1)`——**自动重试会与 `retry: true` 手动通道叠加**:try-2 自动派发时用户已点重试清标记入新队,两个 10GB 级 job 并发双跑、双跑 finally 还会互相误删锁;重试语义统一交给手动通道,瞬时失败由用户一次重试恢复)。**阻塞段(逐对象拉流、zip 组装、上传)一律 `asyncio.to_thread`**——arq 的 `max_jobs=8` 是单事件循环协程数,同步阻塞体不是「占一个槽」而是**冻结全部 8 槽**:缩略图/cron 停摆,且在跑百度任务的 5s 租约续期(`baidu_backup.py` `RENEW_INTERVAL_S=5`)停摆 → 租约过期 → sweeper 误判接管,数分钟级同步 job 在本库是生产事故级反模式(`asset_purge.py:12` 铁律对 worker 同样适用)。**超时取消的线程僵尸窗口**:arq timeout 走 `wait_for` 取消协程,被取消的 `await to_thread(...)` 立即抛 CancelledError 但**线程继续跑**——finally 的 `rmtree` 会删在线程脚下的目录、僵尸不持信号量会击穿临时盘核算。**执行开始即续期锁/闸两键**(Lua,**值含本 job_token 才续,失配(满载排队期 TTL 过期、同 key 已被后继 job 落新闸)→ 按「锁已易主」快速收尾——只 log 不写失败标记**(后继正持锁打包,失败语义归 token 持有者;写标记会让端点在后继完成前误报 failed);以执行时刻重置 TTL 2400,见第 5 步);**打包并发信号量 acquire 限时 120s**(超时快速失败写失败标记,不烧 1800s job 预算);**job 自管 deadline**(逐资产循环检查剩余时间,余量不足自行按失败收尾,不指望外层取消)+ finally 用 `asyncio.shield` 有界宽限(如 60s)等待在途线程;残余僵尸窗口(1800s 超时 + 60s 宽限仍没收尾)文档化为已知限制。**打包类 job 全局并发信号量 ≤2**(模块级,**单进程语义——部署 checklist 注明勿横向扩 worker 副本**,扩前须改分布式闸;限临时盘占用按实际上界 **2×15GB=30GB**,部署 checklist 核 worker 容器盘余量)。组装:

- 临时目录 `tempfile.mkdtemp` + `finally shutil.rmtree`;zip 条目流式写入 **`zf.open(zinfo, "w", force_zip64=True)`** + `copyfileobj`(单对象不整读内存;`force_zip64` 必传——流式写入大小未知,单条目 >4GiB(`zipfile.ZIP64_LIMIT = 2^32-1`)不带它必炸,而「单文件 >1GB 属常态」下单条 >4GB 的视频原片完全可能);
- **逐资产重查行,以重查行的当前 `minio_key` 为唯一事实拉流**(enqueue 到执行隔数分钟,资产可能被软删/purge/移动——不存在「key 已变」的参照系,移动后的资产照常入包):行删/不存在 → 跳过计日志,不崩 job;`NoSuchKey` 同样跳过——**zip 可能少于请求资产数**(§9);
- **有效条目为 0(全选集在打包途中被软删/purge)→ 按失败收尾**:不产出空 zip、写 `batchzip:fail:{key}`,与前端 failed/retry 通道衔接;
- 普通资产(含 >1GB 视频原片):`get_object` 流式拷入;
- livp 且 `tags.download_zip_key` 就绪:**解开 `derivatives/{id}/livp.zip` 取其成员,按批量包自己的清洗/去重规则重写内名后写入**(不是把 livp.zip 整体当条目塞入——那会把「解出来还是 zip 套 zip」的原始问题搬进批量包;**衍生物对象意外缺失(tag 在对象不在)→ try/except 回落原始 `.livp` 条目**,不炸整个 batch job;未就绪 → 原始 `.livp` 条目兜底);
- 条目名:沿用 §2.3 清洗 + **Windows 风格重名去重**(`IMG_0001.JPG` → `IMG_0001 (1).JPG`,不同夹同名文件很常见);
- **`ZIP_STORED`**(条目全为已压缩媒体,deflate 白烧 20-35s/GB 级 CPU);
- zip 名(供签发时 disposition/suggestedName):`批量下载_{n}个文件_{YYYYMMDD-HHmm}.zip`;
- **回传项目桶** `derivatives/batch/{key}.zip` 用 boto3 managed transfer——`s3.upload_file(path, bucket, key, ExtraArgs={"ContentType": "application/zip", "Metadata": {"kind": "batch_download_zip", "contained-sha256": 允许集摘要}}, Config=TransferConfig(multipart_threshold=64MB))` 自动分片(**注意 `Metadata`/`ContentType` 必须经 `ExtraArgs` 传,挂在 `upload_file` 顶层是 TypeError**;S3/MinIO 单次 `put_object` 有 5GiB 硬限,批量包上限 10GB 走单 PUT 必炸——缩略图族产物均为小对象 put_object,**大对象 multipart 先例见百度导入链路(`create_multipart_upload`+`upload_part`)**,本 job 沿用)——kind 同时是 §6.3 清理 cron 的**删除守卫**,摘要降为观测字段;完成即对前端可见(head 命中),无中间状态表、无 DB migration;
- **锁、闸与失败标记的 finally 管理**:DEL 一律**值匹配才删**——per-user 锁与 per-key 闸统一 token 语义(active 值含 job_token;keygate 落键时同写 token 进 value,删除前 Lua 比对——防僵尸线程拖尾在闸过期、后继 job 已落新闸后才执行 finally 误删后继闸引致三重打包;本 job `max_tries=1` 无自动重试,此守卫防御实现层失误);成功 → DEL 两键;失败/异常 → DEL 两键 + SET `batchzip:fail:{key}` EX 600(供端点第 5 步短路)。

### 6.3 保留与清理(统一 6h——用户初拍 2h,盲审迭代按跳板机实际带宽口径修正,见 D8)

- **对象统一保留 6 小时**(用户初拍 2h 系「防慢链路超时」意图;盲审迭代证实跳板机轻量机型公网常见 0.4-1.5MB/s,2h 连 3GB 包都拉不完、分档只把矛盾挪到档位边界——统一 6h 是对该意图的忠实落地且删掉分档复杂度:cron 无需按 size 判档,`LastModified` >6h 即删);presigned URL 有效期 = `min(21600, 对象剩余寿命)`(6h ≈ 覆盖 0.7MB/s × 实际上界 ~15GiB;更慢链路由 §11 checklist ⑤ 实测门槛联动下调 10GB 上限)。
- **缓存命中路径按对象剩余寿命收缩 TTL**(生成后 5h58m 命中 → 只签 ~2 分钟),首签路径 URL 与对象寿命对齐。注意 URL 过期只在**请求发起时**校验、在途下载不受其影响;真正会掐断在途下载的是 cron 对超龄对象的删除——**收缩把该窗口显著缩小但未消除**(命中缓存尾部的慢链路传输仍可能在过期后被清,见 §9 已知限制)。
- 新增 arq cron `cleanup_batch_zips`(`cron(…, timeout=300)` per-cron 覆盖,先例:`main.py:666` 百度 sweeper):按 **`list_buckets()` 迭代全部桶**(不用 `SELECT DISTINCT minio_bucket FROM projects`——项目逻辑删后其桶不再被迭代,桶内 10GB 级批量包会永久滞留),`list_objects_v2(prefix="derivatives/batch/")` **处理 IsTruncated 分页**(默认单页 1000 条),候选对象按 `LastModified` >**6h** 筛选。
- **删除守卫(红线升级)**:候选对象先按 **key 形态粗筛**(`^[0-9a-f]{16}\.zip$`,不匹配直接跳过——用户自建 `derivatives/batch` 夹内大量原片时免掉每 10 分钟一轮的 head 放大),形态匹配且超龄(>6h,以 §6.3 筛选口径为准,守卫不另设阈值)的**逐个 `head_object` 校验 `Metadata["kind"] == "batch_download_zip"` 匹配才删,不匹配跳过**——根文件夹 `minio_prefix` 就是夹名(`folders.py`),用户可以建名为 `derivatives` 的根夹 + `batch` 子夹,其原片 key 与批量包同桶同前缀;无守卫的「按前缀 + 年龄删」会**误删用户原片**。元数据守卫同时兜住 `derivatives/{asset_id}/livp.zip` 被撞名的极端情形。同理,**绝不波及 `derivatives/{asset_id}/livp.zip` 永久衍生物**——两类生命周期不同(批量包=临时缓存,livp 衍生物=跟宿主 purge,见 §4)。
- **lifecycle 交集(按前缀拆口径)**:百度链路已把 bucket lifecycle 当孤儿分片兜底(abort 失败时,`workers/baidu_backup.py` 各 abort 点注释)。**`derivatives/{asset_id}/`(永久衍生物)排除一切 lifecycle 规则**;**`derivatives/batch/` 允许且建议配 incomplete-multipart abort 规则**——批量包走 multipart 上传,失败/中断上传的孤儿分片可达 10GB 级,须有 30d abort 兜底,否则永久滞留。既有/未来任何前缀型过期/删除规则不得作用于 `derivatives/{asset_id}/`;落地时核实现网规则作用域。

### 6.4 前端

- `handleBulkDownload` 重写。**Chromium FSA 主路径的硬钉子:保存框必须在点击瞬间弹**——`showSaveFilePicker` 受 Chromium transient activation 闸门约束(激活窗口 ~5s),「轮询分钟级 → ready → 再弹保存框」必抛 `SecurityError: Must be handling a user gesture`;而 `createWritable()` 不需要激活。因此:
  - 点击时(激活窗口内)先 `showSaveFilePicker`(suggestedName 用前端预生成的 `批量下载_{n}个文件.zip` 模板)拿到 `FileSystemFileHandle`,**再**发起 POST;用户在保存框点取消 = 取消整个批量(不发请求);**最终落盘名以保存框输入为准**(服务端 disposition 文件名带时间戳,供 anchor 路径/展示用,两处不严格一致属预期);**保存框先于服务端校验是刻意取舍**(FSA 激活窗口只够「点击→弹框」一步,不能先 POST 再弹)——超限/无权限在选完保存位置后才暴露属已知代价,可选优化:前端对已加载资产先行 size 预估,名义超限时弹框前提示分批;
  - `download-store` 把现 `start()` 内联的两步拆开:`pickSaveTarget(filename)`(激活窗口内取 handle)与 `streamToHandle(handle, url, task)`(复用现 FSA 流式写盘/进度/取消逻辑)——单文件路径改调两段式,行为不变;
  - `status=ready`(缓存命中)→ `streamToHandle` 立即写;`status=packing` → 任务中心插「正在打包 n 个文件」占位任务,每 3s 重发同 body **附 `resume_key`**(取自最近一次响应的 `key`——权限/就绪位变化时服务端收敛出新 key,前端透明跟随)轮询(单实例;**轮询上限自适应**:`max(180s, 估算合计 bytes ÷ 20MB/s)`,封顶 900s——**未加载页资产无 size,按保守均值(如 50MB/个)计入**估算,避免混选场景提前假超时;10GB 视频批量的打包时间是主路径而非边缘);ready 后 `streamToHandle` 一次写入 → **一次保存框、任务中心一条下载任务**;超时 toast「仍在打包,稍后重新点击批量下载即可获取」并移除占位(权限有变化的边缘场景重点击会重新生成,不承诺绝对「不会重新生成」);
  - `status=failed` → toast「打包失败」+「重试」按钮(请求带 `retry: true`,§6.2 第 5 步清标记重新入队);
  - **resume 400**(作业记录过期/校验不符)→ 静默去掉 `resume_key` 按全新 POST 重走流程(记录 EX 3600 过期后的常态路径);
  - **轮询 403**(ready 复检发现权限被整体回收)→ 终止占位任务 + toast「下载权限已被回收」,不进通用错误通道;
  - **无 FSA(火狐等)**:POST 带 `as_attachment: true`(`hasFSA` 现为 `download-store.tsx:48` 模块私有,**需导出**),ready 时程序化 anchor 单次下载(单次自动下载一般放行;被拦时降级 toast + 「保存」按钮手动触发);`downloads.start` 的直连分支对无 assetId 的 URL 直接使用;
  - **429**(异 key 锁占用)→ toast「已有打包进行中,请稍候」;**422**(>100 个)→ 走 axios 错误通道展示 detail(前端 `errorMessage` 已兼容 FastAPI detail 数组)。
- 跳过项聚合提示:「N 个无权限已跳过,可单个申请下载」——用前端已加载的 Asset 名渲染,id 无名者只计入总数(服务端不回名,见 §6.2 第 6 条);替代现在逐个弹申请框的骚扰;单个资产的申请入口仍在。
- 请求期间按钮 loading;>20 确认弹窗文案更新:「将打包为一个 zip 下载(大文件打包可能需要几分钟)」;未加载页文件由服务端打包、前端不再需要 `asset_<id>.bin` 占位名(**顺带修掉该 wart**,且不回名——见 §6.2 第 6 条,占位名本身消失而非换成服务端真名)。

## 7. 存量回填

- 一次性任务:api 容器内 python 直连 arq Redis 逐个 `enqueue_job("generate_livp_download", …)`(若走本地脚本则放 `scripts/task/`——**目录现不存在须自建,`scripts/.gitignore` 已有 `task/` 条目无需再补**)。
- 顺序:dev 先行验证 → prod;prod 避开百度任务高峰(发版窗口同款判据:活动任务清零)。
- 对账:SQL 数 `filename ILIKE '%.livp' AND deleted_at IS NULL` vs `tags ? 'download_zip_key'`;差额看 `download_zip_failed` 与 worker 日志。
- 先例:W1 缩略图 664/664 全量回填(2026-10-14,临时自动化用后即删)。

## 8. 决策项(已定)

| # | 决策 | 理由 | 备选(不采纳) |
|---|------|------|----------------|
| D1 | 衍生物存**主存储(HDD)同 bucket** `derivatives/` 前缀 | ADR-0008 定位 SSD 缩略图实例 =「热而小」;zip 是冷数据且比 `previews/`(1024 预览)大一个量级(全分辨率,单件 ~5-20MB);`sign_get_url` 已带 disposition 参数,主桶路由已被原片下载证明 | 缩略图 MinIO(SSD):有 `previews/` 先例且清理通道现成,但违背 ADR 定位且 `sign_thumbnail_url` 无 disposition 参数需扩展 |
| D2 | **独立 arq job**,timeout=300 | 全局 `job_timeout=60` 装不下全分辨率转码;失败隔离;回填独立;300s = 200MB 拉源 + 解码 + ffmpeg≤120s + zip + 上传的核算余量 | 扩展 `generate_livp_thumbnail`:少一次 MinIO 拉源,但 timeout/失败语义耦合 |
| D3 | 交付**单一 zip**(内含 jpg+mp4) | 一次下载一个文件,批量循环/移动直连/分享全兼容;不单独存 jpg/mp4 对象(zip 无法部分 presign,要拆分下载需三份存储) | 拆「照片/视频」两个下载按钮:P1 可加(需另存两对象),本期不做 |
| D4 | JPG 源**透传**,HEIC/PNG 转 JPEG q90+ICC | 透传零损失保 EXIF;转换保留 ICC 防 P3 色偏 | 一律重转 JPEG:JPG 源多一代损失无收益 |
| D5 | 视频**一律转码** H.264(`-pix_fmt yuv420p`) | 源可能是 HEVC(Chrome/Windows 双盲),无法廉价探测;3s 短片转码 <20s,worker 异步无压力 | H.264 源 remux(`-c copy`)省时零损:需探测 codec,复杂度不值,P2 优化项 |
| D6 | 前端对 livp **恒请求 unpacked**(永久失败 tag 除外),404 兜底回落 | 404 是自愈回路的唯一入口(上传漏派/瞬时失败的重派都挂在它上面),省掉这一次 404 换来的是自愈对 Web 用户不可达;回落保证任何时点不阻断 | 以 `tags.download_zip_key` 为就绪信号、tag 缺失直落原始:省一次 404,但自愈断链(初版方案,已否决) |
| D7 | 批量交付**单 zip,异步 arq 任务生成**(本期范围),上限 100 个/合计折算 10GB 名义值(livp ×3 计入,实际 zip 上界 ~1.5×),**单文件 >1GB 正常入包** | 领域事实「单文件 >1GB 属常态」:同步方案要么整单拒绝不可用、要么塞不进 nginx ~60s 窗口且阻塞 API 事件循环;异步归档+轮询是 Google Photos/Dropbox/百度网盘通行做法,本库 arq per-function timeout(`main.py:689`)+ 前端轮询(百度任务)均现成先例;缓存命中路径仍秒级直下;livp 折算防解包膨胀击穿下载/盘/时长三处校准 | 同步 ≤1GB:视频原片整单失败,「请分批」物理上不可执行;同步+单文件超限跳过:视频夹批量名存实亡;两档混合(小同步大异步):双份复杂度,异步路径命中缓存后小包也已秒级,无收益 |
| D8 | 批量包**统一保留 6h**;URL ≤ 剩余寿命(命中路径收缩);cron 每 10 分钟清 `derivatives/batch/`;确定性 key(选中集+就绪位+允许集摘要)同权限集复用 | 用户初拍 2h 的意图是「防慢链路超时」;盲审迭代证实跳板机轻量机型公网常见 0.4-1.5MB/s——2h 连 3GB 都拉不完,分档只把矛盾挪到档位边界;统一 6h × 0.7MB/s ≈ 15GiB 实际上界,删掉分档复杂度,更忠实于用户意图;服务端无法感知浏览器下载完成,TTL 只能从生成时刻起算;同权限集重点击 6h 内零重生成 | 原案 1 分钟:会删到正在下载的对象,断流 404;一刀切 2h:0.4-0.7MB/s 链路 3-10GB 包必断流;分档(≤5GB 2h):2-5GB 区间矛盾未消除 |
| D9 | 批量包内 livp **解包后直接进包**(未就绪放原始) | 用户拍板;与单文件下载同口径,批量场景不复现「解出来还是 livp」 | 一律原始 livp:批量用户重新遇到原始问题 |

## 9. 边界与已知限制

- **HDR 实况视频**(Dolby Vision)转码无 tone map,色彩可能偏移;静态图靠 ICC 保留缓解(优于现状缩略图的静默丢弃)。列为已知限制,不满不阻塞。
- 10-bit HEVC 源强转 8-bit yuv420p(兼容性优先)。
- 大 livp 的实况**转码**超时/失败 → 降级交付「仅 jpg 的 zip」(§2.2 第 4 步),不失败不阻断;**瞬时** job 失败(网络/超时)不落永久 tag,自愈靠下载 404 重 enqueue(600s 频控 + `livpdl:{asset_id}` 确定性 job_id 在途去重)+ 回填对账;**永久**失败(无静态图/超 200MB/解码失败)落 `download_zip_failed`,只等回填口径复核,404 不重派。**livpdl 确定性 job_id 的崩溃残留盲窗**:worker 崩溃/kill 后 `arq:job:{id}` 墓碑键残留最长 24h,期间 `enqueue_job` 静默返 None(自愈 enqueue 不查返回值只 log)——该资产 404 自愈最长静默失效 24h,只剩 §7 回填兜底;已知限制,`enqueue_livp_download` 对返回 None 记 warning 供排查。
- **存量 tags「读-改-写」修复(必做,本方案验收项)**:本方案在两派发点并排入队缩略图 job 与下载 job,直接制造了双 writer 条件——存量三族缩略图 job 的 tags 写入(`main.py` 各 RMW 写点)若不 `jsonb_set` 化,livp 快路径 job 先落 `download_zip_key` 后,慢缩略图 job 的整列回写会把它覆盖丢失(自愈重跑只是掩盖)。**与 §2.2 的 to_thread 顺带项同批实施**,不留观察项。
- `derivatives/` 前缀与百度备份无交集(备份按 DB 行 `minio_key` 走);百度链路已依赖 bucket lifecycle 兜底孤儿分片,**任何前缀型 lifecycle 删除规则必须排除 `derivatives/` 前缀**(§6.3)。
- 移动 web 直连会拿到 zip(iOS 文件 App / Android 主流文件管理器可解压),属顺带收益,不列本期验收;Flutter App(B4 下载)仍下原始 livp,复用 variant 接口另立项。
- livp 资产**改名后单文件 zip 内条目名过期**:衍生物 zip 内名在生成时按当时 filename 固化,`batch-prefix` 等改名入口不触发重生成——改名后 disposition 用新名、解压出来是旧基名(批量侧按当前行重写内名不受影响)。已知限制,接受;若反馈强烈再改「改名清 tag 走自愈重派」。
- **打包 job 对 worker 槽位的挤占**:两个 1800s 级打包 job 长占 `max_jobs=8` 中的 2 槽,大包期间百度 + 缩略图 + livp job 共 6 槽——缩略图排队延迟属接受的代价(极端时可上调 `worker_max_jobs`);§6.2 信号量 ≤2 即为此预算的对账。
- Windows 7 时代 zip 中文名 cp437 乱码不在支持范围(Win10+ 正确)。
- **批量**:轮询防踩踏靠 per-user 锁(value 前缀==key 放行且**不重入队**,job `_job_id` 用 epoch 后缀、绕开墓碑键(残留可达 24h)/结果键(300s)的假 packing 窗口);**key 含选中集 + 就绪位 + 允许集摘要**——权限不同天然分 key(无投毒无乒乓),权限相同天然共享缓存;轮询期间权限/就绪位变化由 ready 全量复检收敛为「按新批处理」(新 key 新包,前端透明跟随);6h 后重点击自然重新生成(等价首次点击);job 失败 → 锁清 + 失败标记(EX 600)→ 端点 failed 态直出,`retry: true` 清标记立即重派;已签 URL 在有效期内权限被回收仍可下载(zip 内容不变)——与单文件 presigned「无法即时吊销」语义一致,但**ready 时刻全量复检 + key 收敛**,新签发的 URL 不会越过已回收的权限;worker 崩溃 → 锁/闸最长 **2400s(40 分钟,即闸 TTL——非 job timeout)**自然过期(同 key 轮询仍放行,异 key 429;**崩溃残留 job 无自动重跑**——`max_tries=1` 下 arq 重拾即按 retry 计数判败不执行,恢复靠锁/闸过期 + 用户重点击,期间端点持续 packing 属已知窗口;两键(keygate+active)落键与 enqueue 间进程死亡的孤儿窗口同样由 TTL 收敛;**Redis 整体丢失 → 锁蒸发,同 key 至多双打包一次,同 key 覆写幂等仅浪费 I/O**,与百度链路的 Redis 丢失风险口径一致);上传完成到 finally DEL 锁之间的毫秒级窗口,同 key 收敛路径可能撞自家闸 429,重点击即恢复;**zip 可能少于请求资产数**(打包途中被软删/purge 的资产跳过缺席,worker 日志可查);**超时僵尸线程窗口**:job 自管 deadline + shield 宽限后仍可能残留不持信号量的在途线程,极端场景临时盘短暂超预算(已知限制);批量包 multipart 失败上传的孤儿分片由 `derivatives/batch/` 的 incomplete-multipart abort 规则兜底(§6.3);批量 zip 为扁平结构不含文件夹(选集恒为单夹列表内);用户自建 `derivatives/batch` 文件夹的原片与批量包同前缀——清理 cron 的元数据守卫兜底不误删(§6.3);**写入侧对称风险**:用户原片若恰占 `derivatives/{asset_id}/livp.zip` 或 `derivatives/batch/{hash}.zip` 同名 key 会被衍生物覆盖——前提是根夹名恰为某个 uuid/哈希,概率可忽略,声明接受。
- **批量超大包的下载侧**:FSA 流式下载无断点续传,公网慢链路拉大包失败须整包重来——已知限制(可分批或改用火狐/anchor 系统下载器续传);**下载侧校准**:统一 6h 保留 × 0.7MB/s ≈ 15GiB(实际上界),慢于此的链路靠分批或 §11 checklist ⑤ 实测后下调 10GB 上限;打包临时盘占用按实际上界 **2×15GB=30GB**(打包并发信号量 ≤2,部署 checklist 核 worker 容器盘)。**缓存尾部在途掐断残余窗口**:cron 按 `LastModified` 超 6h 无条件删除,TTL 收缩只护住 URL 签发时刻——命中缓存尾部的慢链路传输仍可能在过期后被清断(6h 已按 0.7MB/s × 实际上界校准;实测跳板机速率后联动重估,§11 checklist ⑤)。

## 10. 测试计划

后端(隔离栈三件套 + pytest,worker 转码不可单测的部分抽纯函数):

- `test_livp.py` 扩展(纯函数,零外部依赖,沿用该文件先例):
  - 基名提取 + Windows 非法字符/尾部点空格/保留设备名(CON 等)清洗(中文/空基名/非法字符/大小写 .LIVP);
  - `_build_livp_download_zip`:photo-only、photo+video、内名正确性、转码失败降级仅 jpg;
  - **EXIF orientation 钉子**:HEIC 带 orientation 源转出 JPEG 后,EXIF 中 orientation 必须已剥除且像素已旋转(用 Pillow 生成带 orientation 的测试图断言,防二次旋转)。
- download-link variant(挂 `test_download_attachment.py` 同款设施):
  - unpacked + 就绪 → 200,URL 指向 zip key,`as_attachment` 时 disposition 文件名 `基名.zip`,审计 details.variant;
  - 非 livp + unpacked → 400;未就绪 → 404 且 enqueue 被调(mock pool;**频控**:SETNX 占用时同资产再点不重派);**永久失败 tag(`download_zip_failed`)有值 → 404 且不重派**(自愈分级闸门);
  - 403 权限路径与 original 完全一致(回归)。
- share resolve:livp 就绪 → zip URL + `livp_unpacked: true`;未就绪 → 原始(回归)。
- batch-download-link + 异步 job(新,挂独立测试文件):
  - 权限:部分无权限 → 跳过 + `skipped_no_permission` **只含 asset_id 不含文件名** + 首次逐条 `download_denied` 审计(SETNX 去重,轮询不重写);全部无权限 → 403;全不存在 → 400;admin 直通;**ready 时刻权限回收 → 不签发不审计 signed_url_issued**(复检闸门);
  - 上限:>100 个 → 422(入参约束);**合计折算体积 >10GB(livp 按 ×3)→ 400**;跨桶选集 → 400;**单个 >10GB(非 livp 原值超限)→ 400 单文件文案**;**单个 >1GB 文件正常入包**;
  - 双职能:未命中 → `{status:"packing"}` 且 enqueue 被调(`_job_id` 为 epoch 后缀形态,mock pool 断言);**同 key 二次 POST(锁 value==key)不再入队**(锁即去重闸);**job 执行开始续期两键 TTL**(断言续期调用);**信号量 acquire 120s 超时快速失败**;命中 `head_object` → `{status:"ready"}` 带 URL 且 **TTL=min(21600, 21600-age)**(造 LastModified 老化对象断言收缩;age≥6h 按 miss 重新生成);
  - **缓存分 key**:A(缺 X 权限)与 B(全权)同选中集 → **key 不同**(允许集摘要在 key 里),各生成各的包,互不投毒不乒乓;A 权限回收后重点击 → 新 key 自动重新生成(**先 head 新 key,命中缓存即免重打包**);同权限集两用户 → 同 key 共享缓存(第二次秒回);**同集不同序/含重复 id 的两次请求 → 同 key**(canonical 化断言);
  - **tags 并发**:并排派发缩略图 job + 下载 job 交错写 tags,断言 `jsonb_set` 原子合并不丢对方 key;
  - **锁 token Lua**:旧 job finally 不删新 token 锁(断言值匹配删除);
  - **超时取消**:job deadline 自管收尾路径(shield 宽限;僵尸窗口文档化即可,不强测);
  - **>4GB 单条目**:流式写入 `force_zip64=True` 参数断言(免真实 4GB);multipart 上传路径(上传方法选用断言,非 put_object;`ExtraArgs` 形态断言);
  - `resume_key`:轮询凭 `batchzip:job:{user}:{key}` 记录校验 **canonical(body ids) == `selection_ids`**(与 key 哈希同一 canonical 函数,同集不同序/含重复 id 恒过),回放 filename/skipped(记录缺失/过期或 ids 不符 → 400 拒绝);**带 skipped 项(含无权限/缺失资产)的选集轮询 resume 不 400、不触发全量 FGA 复检**(防记录误用 allowed_ids 的实现走偏);**key 收敛命中新 key 缓存直接 ready 的分支现算回放并补写记录**;轮询期间就绪位翻转 key 不变;**跨用户拿别人 key 做 resume → 400**;
  - 作业记录:首次 POST 写 `batchzip:job:{user}:{key}`(EX 3600),字段完整可回放;
  - **job 注册**:`max_tries=1`(防自动重试与 retry:true 双跑);
  - 失败标记:job 失败 → 锁清 + `batchzip:fail:{key}` → 端点 `{status:"failed"}` 且**不再入队**;`retry: true` → 清标记 + 重新入队;
  - 单飞锁 + per-key 在途闸:同 key 轮询 POST 放行(value==key)且不重入队;**跨用户同 key 打包期点击撞 per-key 闸 → packing 不双跑**;异 key 占用中 → 429;纯缓存命中路径不上锁;enqueue 失败/返 None → 两键 Lua 回滚不留孤儿;
  - 响应:`livp_raw_count` 断言(未就绪 livp 兜底入包计数);
  - job 组装:livp 就绪**解开取成员重写内名并入**(非整体塞入;**衍生物对象缺失回落原始 livp,不炸 job**)/ 未就绪放原始 livp;同名 `(1)` 去重;非法字符/尾部点空格/保留名清洗;RGBA PNG 白底合成;>1GB 条目流式入包;打包途中软删资产跳过不崩 job(zip 缺席该资产)、**移动后资产按重查行当前 key 照常入包**;`as_attachment` 时 disposition 为 zip 名;ready 时**单条聚合** `signed_url_issued(kind=batch_zip, details.ids)` 审计、packing 响应不写审计(重复 ready 重签重审计为可接受行为,presign 便宜);
  - key:就绪位不同 → key 不同(纯函数断言);
  - cron 清理:只删 `derivatives/batch/` 前缀、`LastModified`>**6h** **且 Metadata kind=batch_download_zip** 的对象——同前缀无标记对象(模拟用户 `derivatives/batch` 夹原片)不删,`{asset_id}/livp.zip` 不删;分页路径覆盖(fake list 单测)。
- 前端无单测基建(零 test runner),走隔离栈手测清单:四入口各下一次 livp、未就绪回落、forceOriginal、批量单弹窗/聚合提示/loading、非 livp 零变化。

## 11. 部署与验收

- 无迁移/无 FGA/无新依赖 → api + SPA 常规发版(deploy-lan 流程),镜像无需重建。**发版 checklist 补四条 ops 项**:①为各项目桶 `derivatives/batch/` 前缀配 incomplete-multipart abort 规则(兜底 10GB 级孤儿分片);②核实现网存量 lifecycle 规则作用域——任何前缀型过期/删除规则不得覆盖 `derivatives/{asset_id}/`(§6.3);③核 worker 容器盘余量 ≥30GB(临时盘实际上界;**tempfile 默认落 docker root 所在 SSD,ADR-0008 容量测算未含此峰值——建议 worker 显式 `TMPDIR` 指向 HDD 卷,或把打包峰值纳入 SSD 水位告警分母**);④**勿横向扩 worker 副本**(打包并发信号量是单进程语义,扩前须改分布式闸);⑤**【发版前置门槛】实测跳板机公网下载速率,用实测值重算「10GB 上限 × 6h 保留期」组合是否成立**(轻量机型常见峰值 0.4-1.5MB/s,统一 6h × 0.7MB/s ≈ 15GiB 是当前校准;实测 <0.7MB/s 则发版前联动下调 10GB 上限或再延保留期——默认值不得带病上线);⑥**【发版前置门槛】用 `assets.size_bytes` 一条 SQL 统计真实选集体积分布后再冻结 10GB 上限常量**(「单文件 >1GB 属常态」下 10GB ≈ 10 个视频原片,上线即频繁触顶则先调上限再发版);另:livp job 300s timeout 在回填时实测校准(200MB 拉源+解码+转码最坏组合偏紧);验收期持续统计选集体积分布,普遍触顶则上限联动重估。
- 回填:dev 验证 → prod(§7)。
- PC 真机验收清单:
  1. 卡片/预览/批量/分享页各下载一次 livp → 得 `基名.zip` → 解压得 `基名.jpg` + `基名.mp4`,双击均可看(HEIC 源色彩正常);
  2. 预览弹窗「下载原始 .livp」可用;
  3. 未就绪资产(新建 livp 秒点下载)回落原始 + 提示,不报错;
  4. 403 申请下载路径、非 livp 下载、移动端直连下载均零回归;
  5. 批量下载 n 个(含 livp、跨夹同名文件、**至少 1 个 >1GB 视频原片**)→ **点击即弹一次保存框**(Chromium)→ 轮询打包 → ready 后自动写入,zip 内 livp 已是 jpg+mp4、同名带 `(1)`、大文件完整、无权限项聚合提示(提示用前端已知名,服务端响应无文件名);
  6. 同选中集重点击(6h 内)ready 秒回不重新生成(dev 观察对象 mtime 不变 / 接口耗时);livp 衍生就绪后再点同集 → 落新 key 重新生成(含 jpg+mp4);
  7. 火狐桌面批量下载走 anchor 单次成功;>100 个或合计 >10GB 被拒并提示分批;大包(≥5GB)轮询时长达自适应上限、超时文案正确(「仍在打包,稍后重点击直接获取」);失败场景重试立即生效(不等 keep_result 尾窗)。
- 回滚:前端 livp 分支随 SPA 回退即失效;后端 variant 参数无调用方则无行为影响;衍生物对象留存无害(不入备份/列表/配额语义)。

## 12. 工作量估算

- 后端 livp 侧(worker job + variant + share + 清理 + tags jsonb_set 化):~1 天
- 后端批量侧(双职能端点 + 异步 job + 锁/token/失败标记/作业记录 + 元数据守卫 cron;测试矩阵 ~15 组场景):~2-3 天
- 前端(helper + 四入口 + 弹窗次选项 + 批量两段式 FSA/轮询/任务中心):~1-1.5 天
- 回填 + dev/prod 验证:~0.5 天
- 合计 ~4.5-6 天(含测试)
