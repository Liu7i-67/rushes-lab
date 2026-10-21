# 需求文档:livp 下载自动解包 + PC 批量下载单 zip 化

> 日期:2026-10-21 · 分支:`feat/livp-download-unpack`(基线 `qplan/livp-download-unpack-plan`)
> **权威依据:[rushes-spec/material-storage/livp-download-unpack-plan.md](../../rushes-spec/material-storage/livp-download-unpack-plan.md)(qplan 18 轮盲审定稿)**——实现细节(ffmpeg 参数/锁语义/arq 陷阱/文件行号锚点)一律以定稿为准,本文档只定契约与拆分;两者冲突时以定稿为准并回报 PM。

## 背景与目标

1. PC 用户下载 livp 实况照片得到 `.livp`(Apple 私有 zip 封装),Windows 打不开且内部静态图多为 HEIC——服务端生成"下载级"衍生物(全分辨率 JPG + H.264 MP4 打包 zip),livp 资产下载默认交付解包 zip,原始 .livp 保留为次选项。
2. PC 批量下载逐文件弹保存框、闪烁——改造为异步打包单 zip、一次保存框(定稿 §6)。

## 功能点明细(逐条可验收)

### A 组 · livp 单文件侧(后端包 A)

- **F1** worker 新 job `generate_livp_download(ctx, asset_id)`:`func(…, timeout=300, max_tries=2)`;解包 livp → 静态图(JPG 透传 / HEIC·PNG 转 JPEG q90+ICC+EXIF 剥 orientation / RGBA 白底 / 显式调高 `Image.MAX_IMAGE_PIXELS`)→ 视频全规格转码(`-pix_fmt yuv420p` 无 scale 无 -t,失败降级仅 jpg 落 `download_zip_video_failed` 时间戳)→ ZIP_STORED 组包(内名 §2.3 清洗:非法字符/尾部点空格/保留设备名/空基名回落)→ 上传主桶 `derivatives/{asset_id}/livp.zip`(Metadata kind=livp_download_zip);tags 落 `download_zip_key`/`download_zip_size_bytes`,失败分级:永久(无静态图/超 200MB/解码失败)落 `download_zip_failed`、瞬时(网络/超时)不落,超时路径 `except BaseException`;**阻塞段全部 `asyncio.to_thread`**。
- **F2** 派发点两处并排多 enqueue:上传完成(`routers/assets.py:255` livp 分支)+ 百度导入(`workers/baidu_backup.py` `_enqueue_thumbnail` livp 分支);`arq_pool.py` 加 `enqueue_livp_download`(确定性 `_job_id=f"livpdl:{asset_id}"` + `_expires≈3600`)。
- **F3** `download-link` 加 `variant: Literal["original","unpacked"]="original"`:unpacked 仅 livp;就绪(tag 有 + **签发前 head 校验对象存在,`asyncio.to_thread`,孤儿 tag 按缺失走 404**)→ 签 zip URL(disposition 仅 as_attachment 时 `基名.zip`);缺失 → 404 + 自愈(permanent tag 有值不重派;Redis 频控 `livpdl:heal:{asset_id}` SETNX EX 600,**SETNX 异常 try/except 只 log 照常 404**);权限/审计口径与 original 完全一致,details 加 variant。
- **F4** 分享 resolve(kind=asset):livp 就绪 → **head 校验后**签 zip(attachment `基名.zip`);否则原始 livp;审计 details 加 `livp_unpacked`。
- **F5** purge 清理:`asset_cleanup.py` 拆双通道——`download_zip_key` 走主桶 `delete_object`(与原片同桶),`thumbnail_key`/`live_video_key` 维持缩略图通道。
- **F6** `presign.head_object` 扩展返回 Metadata(dict)。
- **F7** 存量三族缩略图 job 必做改造:tags 写点全部 `jsonb_set` 单条 UPDATE 原子合并;同步阻塞段(boto3/subprocess)全部 `asyncio.to_thread` 化(不改行为)。
- **F8** 回填脚本 `scripts/backfill_livp_download.py`(可提交;容器内直连 arq Redis 逐资产 `enqueue_job("generate_livp_download", …)`,含 dry-run 与对账输出)。

### B 组 · 批量侧(后端包 B,与 A 串行)

- **F9** `POST /api/v1/assets/batch-download-link` 双职能端点(创建/轮询,定稿 §6.2 六步全量:单条 IN 查行、FGA gather、denied 首次审计 SETNX EX 1800、作业记录 `batchzip:job:{user}:{key}` EX 3600(selection_ids=canonical 形态/allowed_ids 分存)、确定性 key(canonical+就绪位+允许集摘要)、上限 100 个/折算 10GB(livp ×3)双文案、同桶断言、ready=全量复检+key 收敛(新 key 先 head)+TTL `min(21600, 21600-age)`+单条聚合审计、miss=失败标记短路(retry:true 清标记)→锁闸单段 Lua 原子落(keygate+active NX EX 2400,active 值含 job_token)→enqueue(`_job_id=f"{key}:{int(time.time())}"`,入参带 bucket/job_token)→enqueue 失败 Lua 回滚、429 异 key、`retry_after_seconds`)。
- **F10** worker job `generate_batch_download_zip(ctx, user_id, job_token, asset_ids, bucket, key)`:`func(…, timeout=1800, max_tries=1)`,新文件 `workers/batch_download.py`;执行开始 Lua 续期两键(**值含本 job_token 才续,失主只 log 不写失败标记**);信号量 ≤2 acquire 限时 120s;job 自管 deadline+shield 宽限 60s;逐资产重查行按当前 minio_key 拉流(行删/NoSuchKey 跳过;有效条目 0 → 失败收尾写标记);livp 就绪解开衍生物取成员重写内名(对象缺失回落原始 livp);重名 `(1)` 去重;`zf.open(zinfo,"w",force_zip64=True)` 流式;ZIP_STORED;multipart 回传(`upload_file`+ExtraArgs{ContentType,Metadata{kind,contained-sha256}}+TransferConfig);finally 值匹配 DEL 两键+失败时 SET `batchzip:fail:{key}` EX 600。
- **F11** cron `cleanup_batch_zips`(每 10 分钟,`cron(…, timeout=300)`):`list_buckets()` 迭代全部桶 → `list_objects_v2(prefix="derivatives/batch/")` 分页 → key 形态粗筛 `^[0-9a-f]{16}\.zip$` → `LastModified` >6h → head 校验 `Metadata.kind=="batch_download_zip"` 才删。

### C 组 · 前端

- **F12** `web/src/lib/asset-download.ts` 共享 helper:livp 恒请求 unpacked(永久失败 tag 除外→直落原始+「暂不支持解包」toast;404→回落原始+「尚未就绪」toast;200→`downloads.start(url, 基名.zip, {assetId, variant})`)。四处单文件入口换 helper:`ProjectDetailPage.tsx:195`、`AssetPreviewModal.tsx:89`、`AssetSummaryPanel.tsx:89`、`AssetCardList.tsx:47`。
- **F13** `useDownloadLink` 入参扩展 `variant`;`download-store.tsx` `start()` opts 透传 variant(移动直连重签必须带 variant,重签 404 兜底原始);**导出 `hasFSA`**;`start()` 拆两段式 `pickSaveTarget(filename)`/`streamToHandle(handle,url,task)`(单文件路径改调两段式,行为不变)。
- **F14** 预览弹窗(AssetPreviewModal)加「下载原始 .livp」次选项(`forceOriginal`)。
- **F15** `handleBulkDownload` 重写(定稿 §6.4):Chromium 点击瞬间先 `pickSaveTarget`(取消=不发请求)→ POST(`as_attachment: !hasFSA()`)→ ready 直写 / packing 占位任务+3s 轮询(附 resume_key,取自最近响应 key;上限 `max(180s, 估算合计 bytes÷20MB/s,未加载项按 50MB/个)` 封顶 900s;超时 toast「仍在打包…」)/ failed→toast+重试按钮(`retry:true`)/ 429/422 toast / resume-400 静默全新 POST / **轮询 403 → 终止占位+「权限已被回收」**;跳过项聚合提示(用前端已知名渲染,含 livp_raw_count「m 个实况照片暂以原始格式保留」);>20 确认弹窗文案更新。

## 数据库修改方案

- **无 migration、无新表、无 FGA model 变更**。
- `assets.tags`(JSONB)新增 4 个 key:`download_zip_key`(str)/`download_zip_size_bytes`(int)/`download_zip_failed`(str,异常类型名)/`download_zip_video_failed`(时间戳 str);**一切写入用 `jsonb_set` 单条 UPDATE 原子合并**(含存量三族 job 写点改造,防双 writer 整列互覆)。
- Redis(非持久 schema,键名/TTL 语义):`batchzip:job:{user}:{key}`(EX 3600)/`batchzip:active:{user_id}`(NX EX 2400,值 `key:job_token`)/`batchzip:keygate:{key}`(NX EX 2400)/`batchzip:fail:{key}`(EX 600)/`batchzip:audited:{user}:{key}`(SETNX EX 1800)/`livpdl:heal:{asset_id}`(SETNX EX 600)。

## 接口定义

1. **`POST /api/v1/assets/{asset_id}/download-link`**(变更):body 加 `variant: "original"|"unpacked"`(默认 original,不传行为零变化);响应 `{url, expires_in}` 不变;错误:非 livp+unpacked→400、无权限→403(不变)、unpacked 未就绪→404(并自愈 enqueue)。
2. **`POST /api/v1/assets/batch-download-link`**(新):入参 `{asset_ids: uuid[](1..100 必填), as_attachment: bool=false, resume_key: str|null, retry: bool=false}`;响应 `{status:"ready"|"packing"|"failed", key: str, url?: str, expires_in?: int, filename: str, skipped_no_permission: uuid[], skipped_missing_count: int, livp_raw_count: int, retry_after_seconds?: int}`(url/expires_in 仅 ready;跳过列表**只回 id 不回文件名**);错误:全无权限 403 / 全不存在·跨桶·超限·resume 不符 400 / >100 个 422 / 异 key 锁 429。
3. **`GET /share/resolve`**(内容变更,结构不变):asset 分支对就绪 livp 改签 zip URL。

## 前端改动点 / 后端改动点

- 后端:`api/app/workers/main.py`(新 job+存量改造+注册)、`api/app/workers/batch_download.py`(新)、`api/app/workers/baidu_backup.py`(派发点)、`api/app/routers/assets.py`(variant+batch 端点)、`api/app/routers/share.py`、`api/app/services/{arq_pool,presign,asset_cleanup}.py`、`scripts/backfill_livp_download.py`(新)。
- 前端:`web/src/lib/{asset-download.ts(新),download-store.tsx}`、`web/src/api/hooks.ts`、`web/src/pages/ProjectDetailPage.tsx`、`web/src/components/{AssetPreviewModal,AssetSummaryPanel,AssetCardList}.tsx`。

## 测试功能点(定稿 §10 全量为准,摘要)

- 纯函数:基名清洗(非法字符/尾部点空格/保留名 CON/中文/空基名/.LIVP 大小写)、`_build_livp_download_zip`(photo-only/photo+video/转码失败仅 jpg/EXIF orientation 已剥除断言/RGBA 白底)。
- variant 端点:就绪 200(URL 指向 zip、attachment 文件名 `基名.zip`、审计 details.variant)/非 livp 400/未就绪 404+enqueue 被调(频控占用不重派;permanent tag 有值不重派)/403 回归。
- share:就绪 zip+`livp_unpacked:true`/未就绪原始(回归)。
- batch 端点:权限跳过(只含 id)/403/400/422/429;同 key 二次 POST 不重入队;job 执行开始续期;信号量 120s;TTL=min(21600,21600-age) 与 age≥6h 按 miss;失败标记 failed+retry 重派;canonical(同集不同序同 key;resume 不符 400;跨用户 resume 400;带 skipped 项 resume 不 400);缓存分 key(权限不同 key 不同;权限相同共享);jsonb_set 并发不丢 key;锁 token Lua(旧 job 不删新锁);>4GB force_zip64 参数断言;multipart+ExtraArgs 断言;cron(形态粗筛+元数据守卫+分页,`{asset_id}/livp.zip` 不删)。
- 前端:无 test runner,走手测清单(第 4 步与真机验收执行)。

## 模糊点与决策记录

| # | 决策 | 理由 |
|---|------|------|
| D-1 | 无开放模糊点,全部按 qplan 定稿执行 | 定稿经 18 轮盲审收敛(P0×3/P1×37 全修),实现细节已钉死 |
| D-2 | 保留策略统一 6h(用户初拍 2h) | 定稿 D8:跳板机公网 0.4-1.5MB/s,2h 连 3GB 拉不完;用户派发实施即按定稿 |
| D-3 | 回填脚本放 `scripts/backfill_livp_download.py`(可提交) | `scripts/task/` 在 .gitignore,交付物须可提交 |
| D-4 | 开发期自测=纯函数单测+`pytest --collect-only`+前端 lint/build;集成测试不在本地 docker 跑(CLAUDE.md 立规),第 4 步统一安排 | 立规约束 |
| D-5 | 后端拆 A(livp 侧)/B(批量侧)两包**串行** | 两包都要改 `workers/main.py` 注册段,并行会并发踩踏同文件 |
| D-6 | 缓存 key 物料 = canonical(允许集)摘要 + 就绪位(**不含原始选中集**) | PM 验收采纳 B 包偏离:内容寻址——允许集相同即包内容相同,共享缓存更优;权限分 key/防投毒/防乒乓等正确性属性不变;resume 校验仍按 canonical 选中集对作业记录(记录分存 selection_ids/allowed_ids 不变) |
| D-7 | original 路径审计 details **不加** `variant` 字段(定稿 §3 口径收窄) | 契约测试钉死「original 审计零变化」;variant 只标在 unpacked 路径,对账语义不受损 |
| D-8 | 实现级取舍(语义与定稿一致):`_job_id` 后缀用 time_ns+进程内序号(防同秒撞 id);`Image.MAX_IMAGE_PIXELS` 解码段内抬至 6 亿像素并 finally 恢复;cron 分页用 boto3 默认 MaxKeys(测试 monkeypatch 强制小页覆盖分页逻辑);`WorkerSettings.crons` 别名(零行为差异);batch job 双形态签名兼容端点扁平入参与直调;job 临时目录 60s 延迟清理+下次启动清扫残留 | 各为满足测试契约/健壮性的等价实现 |
