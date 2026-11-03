# 素材自动打标 + 视频切片方案(CPU-only 内网重调研版)

- 状态: **proposed(等待用户拍板 §3 决策点后实施)**
- 日期: 2026-11-03
- 关联: [PR #178](https://github.com/kevinfitzroy/rushes-lab/pull/178) / [Issue #179](https://github.com/kevinfitzroy/rushes-lab/issues/179)(2026-09-15 原「AI 打标底座」spec,其硬件前提已失效);本文件是按 2026-11-03 实测硬件事实的**重调研替代稿**
- 实施约束(用户给定):①未经允许不部署生产;②注意性能与合理性,考虑内网素材服务器实际;③**打标内容至少要能让人看出「这是哪个项目中的什么素材内容」**

## 1. 背景与硬件前提变化

Issue #179 的原 spec 按「单卡 RTX 3080(10GB 显存)」规划:vLLM 跑 Qwen2.5-VL-7B AWQ + SigLIP embedding + pgvector 语义搜索。2026-11-03 对内网素材服务器(hh2)的实测资源盘点:

| 资源 | 总量 | 已用/剩余 |
| --- | --- | --- |
| CPU | 2× AMD EPYC 7763 = 128 核 256 线程 | 负载 ~4.6,**空闲 ≈98%** |
| 内存 | 251 GiB | 可用 235 GiB(93%) |
| NVMe /ssd(元数据/缩略图 MinIO/PG) | 1.6T | 剩 1.5T |
| HDD 原片盘 8×21T | ~168T | 每盘 ~20T 可用 |

**没有 GPU。** 原 spec 的 vLLM/显存预算/多卡引子全部不适用;但服务器有海量空闲 CPU 与内存,CPU 推理小模型完全可行。本方案继承原 spec 中与硬件无关的架构决策(独立 ML 服务、独立 ai 队列、AI 标签独立成区、model_version 幂等、离线分发机制),替换模型层与分期。

## 2. 目标与非目标

**目标**

1. 素材上传后自动打标:图片 + 视频关键帧,产出标签与描述;**最终呈现 = 「项目/目录上下文 + 内容标签 + 内容描述」,读标签即可知「哪个项目的什么素材」**(约束③,实现见 §9)。
2. 视频自动切片:场景检测分段(虚拟切片,只落元数据+关键帧,不产新文件),每段独立打标,详情页分段列表 + 点击定位播放。
3. AI 结果进盲搜:`/assets/search` 在 filename/notes/user_labels 之外增加第四路命中。
4. 底座健壮性:ML 服务停机不影响上传/搜索;恢复后积压自动补打;同素材重跑幂等。

**非目标(本期不做)**

- 语义搜索(自然语言以文搜图,pgvector + embedding)→ 另立 spec(P3,§14)。
- 物理切片(真实切出 mp4 新素材文件)→ 不做(§3-D1)。
- 语音转写(Whisper)、人脸聚类、训练/微调、云端 API(素材隐私不出内网)。
- App(Flutter)端展示 → 后置;本期只做 web。

## 3. 待拍板决策点(已按推荐默认撰写全文)

| # | 决策 | 选项与推荐 | 影响 |
| --- | --- | --- | --- |
| D1 | 「切片」语义 | **推荐 A 虚拟切片**(场景检测落元数据+关键帧+定位播放,零存储新增、可逆);B 物理切片(占存储/新资产管理/复杂度高,不推荐) | §10 整章 |
| D2 | 打标模型路线 | **推荐 A 两级**:P1 全量粗标 SmolVLM2-256M(英文+受控词表汉化),P2 可选加 Qwen2.5-VL-3B(原生中文+OCR)做视频/精选精标;B 只用 SmolVLM2;C 直接 Qwen2.5-VL-3B 单级(中文最好但 10-20s/图,全库回填 1-2 天) | §7/§9 |
| D3 | 语义搜索是否本期 | **推荐后置**(本期只做关键词第四路;约束只提了打标+切片) | §11/§14 |

D2 依据:SmolVLM2-256M 官方模型卡明确 **Language: English**(无中文输出能力,这是硬约束),但参数小(Apache 2.0,CPU 单进程 ~1GB 内存,预估 2-5s/图,见 §7.4),符合 deepseek「初筛与粗标」定位;中文缺口由受控词表汉化层补标签、P2 精标模型补描述。

## 4. 现状锚点(代码事实)

- 上传完成派发点:`api/app/routers/assets.py:353-369`(complete_upload 按类型 enqueue 三族缩略图 job,fire-and-forget,`services/arq_pool.py:31-73`)。
- 缩略图管线:`api/app/workers/main.py` —— `generate_thumbnail`(图片 Pillow 1024px JPEG,q80)、`generate_video_thumbnail`(:869,URL 直读 presigned URL 抽帧 + head/full 回落链)、`generate_livp_thumbnail`(静态图+实况转码);产物落缩略图 MinIO(SSD,bucket `ms-thumbs`);tags 经 `_merge_asset_tags`(:297)jsonb_set 原子合并。
- 失败口径先例:`tags['thumbnail_failed']` 只存异常类型名(workers/main.py:290-294,防容器路径随 AssetOut 下发给能列到资产的用户);完整 traceback 只进 worker 日志。
- worker 拓扑:ms-worker 单容器 arq,`max_jobs=8`(settings.worker_max_jobs),per-function `func(fn, timeout=…, max_tries=…)` 先例齐备(:1172-1198);cron sweeper 先例:`sweep_stalled_baidu_tasks` / `cleanup_batch_zips`。
- arq 多队列(已核实锁版 0.28.0):`WorkerSettings` 类属性经 arq `worker.py get_kwargs` 映射到 `Worker(queue_name=…)`;`pool.enqueue_job(..., _queue_name="ai")` 入对应队列。
- 盲搜:`GET /assets/search`(assets.py:633-724),三路 ILIKE OR + pg_trgm GIN;权限先行(folder 集过滤),sensitive 存在性零泄露。
- 数据模型:`assets.tags` JSONB(派生数据,随 AssetOut 全量下发,models/__init__.py:165 —— **AI 结果不得塞 tags,会撑大所有列表载荷**);`assets.media_metadata` JSONB 空预留(不用:AI 结果需独立版本化+索引,独立表更优);迁移最新 0020;`tests/test_db_schema.py` 有表数断言,加表须同步。
- 依赖/镜像:ffmpeg 已在镜像(Dockerfile:14);httpx/pillow 已依赖;**全库零 ML 依赖**。
- 部署:`scripts/deploy_lan.sh dev|prod`;同机 dev(:8090)/prod(:80/:443);`.env` 与 override 不被部署覆盖。**本周期只部署 dev,prod 等用户指令(约束①)。**

## 5. 总体架构

```
generate_thumbnail / generate_video_thumbnail / generate_livp_thumbnail(ms-worker,既有)
        │ 成功落 thumbnail_key 后:先写 ai_jobs(pending) 行,再 enqueue(§8.1)
        ▼
Redis arq 队列 "ai"(arq queue_name 即 Redis zset key;独立于默认 arq:queue)
        │ 独占消费
ms-ai-worker(新容器,复用 api 镜像,无 torch,max_jobs=8)
        │ httpx POST(内网容器网)                     ├─ PG(ms-db):ai_jobs /
ms-ml(新容器,python:3.12-slim + torch-cpu +          │   asset_ai_annotations /
        transformers,SmolVLM2-256M,8 推理进程)◀──────┤   asset_video_segments(迁移 0021)
                                                      └─ 缩略图 MinIO(SSD):
                                                          keyframes/{asset_id}/{seg}_{n}.jpg
```

(ms-ml 不访问 MinIO/PG、不持任何凭证;读写存储与库的全部在 ms-ai-worker 侧。)

与原 spec 的形态一致(Immich 式:worker 不装 torch,ML 独立容器崩溃域隔离),仅把「GPU+vLLM」换成「CPU+transformers 进程池」。**ms-ai-worker 与 ms-ml 全挂时,上传/缩略图/搜索行为完全不变**(enqueue fire-and-forget;搜索第四路查不到行自然不命中)。

## 6. 数据模型(迁移 0021,3 张新表)

| 表 | 列 | 约束/索引 |
| --- | --- | --- |
| `ai_jobs` | id UUID PK;asset_id FK assets **CASCADE**;kind varchar(16)(`annotate`/`slice`);status varchar(16)(pending/running/done/failed/skipped);attempts int;**claim_token uuid NULL**(认领时生成,CAS 凭据);**heartbeat_at timestamptz NULL**(心跳只刷此列,判活/接管依据);last_error varchar(128)(**受控 token 集**:`ml_error`/`minio_missing`/`minio_transient`/`decode_failed`/`asset_gone`/`poison`/`partial` 等(ffmpeg 侧超时/失败在 §8.4 均走降级而非失败 token,无 `ffmpeg_timeout` 写入方,勿照抄缩略图管线的 token),不用自由文本——沿 thumbnail_failed 「不落敏感信息」哲学,且按 token 精确 DELETE/筛选);model_version varchar(64);created_at/updated_at | UNIQUE(asset_id, kind, model_version);INDEX(status, updated_at)(sweeper 扫描) |
| `asset_ai_annotations` | asset_id FK **CASCADE**;model_version varchar(64);tier varchar(8)(`coarse`/`refined`);context_path varchar(600)(打标时的 项目名/目录链/文件名 快照);tags_zh JSONB(数组);tags_en JSONB(数组);description text(呈现用,§9);description_en text;searchable_text text(**聚合:context_path + tags_zh/en + description + description_en + 各段描述**(见 §9),搜索第四路唯一命中面);**meta JSONB**(降级标记:partial 等 —— §8.2 软预算止损的落点);created_at/updated_at | PK(asset_id, model_version);GIN trgm(searchable_text) |
| `asset_video_segments` | id UUID PK;asset_id FK **CASCADE**;idx int(段序,0 起);start_ms bigint;end_ms bigint;keyframe_keys JSONB(该段关键帧对象 key 数组);tags_zh JSONB;tags_en JSONB;description text;**meta JSONB**(降级标记:segmented_by(interval/scene)/describe_failed 等 —— §8.4-2/§8.4-6 与验收 #5 的判定落点);model_version varchar(64)(仅记录,不参与唯一键);created_at | UNIQUE(asset_id, idx)(前导列即 asset_id,无需单列索引) |

设计说明:

- **不加 embedding 向量列**(D3 后置);**不动 assets 表任何列**(回滚 = 停容器弃表)。
- 搜索命中面收敛到单列 `searchable_text`(= context_path + tags_zh + tags_en + description + description_en + 各段描述,见 §9;分段描述在切片 job 完成时聚合进该列,搜索自然命中到 asset 级;**索引形态与拼 SQL 方式见 §11 —— 不能把 EXISTS 臂直接 OR 进既有三路**,详见该节)。
- `model_version` 形如 `smolvlm2-256m@<权重sha8>+p1+lm<词表版>`(权重指纹+提示词版本+**词表版本**——词表影响 tags_zh,扩词表 = 换版本行,存量有重跑通道);换模型/换词表 = 新版本行,旧行保留,active 版本由 settings 指定,搜索只命中 active(原 spec §4 语义不变)。
- **segments 的版本取舍**:段结构由场景检测参数决定(与打标模型弱相关),重跑/换版本 = DELETE 该 asset 全部旧段后重写(**UNIQUE 键不含 model_version**,防多版本段无限堆积);旧版本 annotation 行的 searchable_text 聚合文本随之过期属**已接受取舍**——旧行非 active,搜索不命中、详情不展示,仅作历史留存。
- **tier=refined(P2 精标)读取语义预留**:refined = 新 model_version 新行(PK 不同);`ai_active_model_version` 单值,精标落地时 active 直接指向精标版本(coarse 行自然退居历史)——不设计「同 active 双 tier 并存」的读取,P2 前再定稿,勿提前实现双读。
- `ai_jobs.status` 取值域:pending(待跑/等待 ML 恢复)、running、done、failed(瞬时失败待 sweeper 重试,attempts<5)、**skipped(永久终态,不重试:asset 已删/缩略图对象丢失/解码永久失败等,minio_missing、decode_failed 类)**。
- PG 体量:~2.4 万 annotation 行 + ~1.3 千视频×平均段数(估 ≤60 段)segment 行,零压力;关键帧对象 ~100-300KB/帧×(段×≤3 帧),按 1300 视频×10 段×3 帧估 ≈ 4GB,SSD 剩 1.5T 安全。

## 7. ms-ml 推理服务(新容器)

### 7.1 形态

- 镜像:独立 `material-storage/api/ml.Dockerfile`(python:3.12-slim;pip 装 torch **CPU 版**(index `https://download.pytorch.org/whl/cpu`,~200MB,不走 CUDA 轮子)+ transformers(**下限 ≥4.48,SmolVLM2 架构 2025 才合入,旧版直接 KeyError 'smolvlm'(config model_type 实为 smolvlm,非 smolvlm2);钉版以实际 `AutoModelForImageTextToText.from_pretrained` 冒烟为准;模型卡示例的 `_attn_implementation="flash_attention_2"` 是 CUDA 参数,CPU 加载须去掉**)+ **num2words(SmolVLM processor 硬依赖,缺它 AutoProcessor 加载即 ImportError——模型卡明示,勿漏)** + pillow + **fastapi/uvicorn(服务本体,slim 基镜不含)**;torch/transformers/num2words/pillow/fastapi/uvicorn 版本钉死进 ml 专用 constraints 文件,与 api constraints 同款机制)。与 api 镜像彻底分离,torch 依赖不进 ms-api/ms-worker/ms-ai-worker。
- 服务:FastAPI + uvicorn,`--workers 8`(进程池;**推理端点必须 `async def` 且内联阻塞执行推理 —— 天然一进程一请求;禁用 to_thread/线程池跑推理**(否则单进程并发多 torch 推理,§7.3 内存/线程预算全部失真);**/healthz 例外,用同步 `def`**,见 §7.2);每进程 `torch.set_num_threads(16)`(8×16=128 线程,加 ffmpeg 2×4 峰值 ~136 线程,256 线程余量充足);内存峰值(权重+进程基线)见 §7.3。
- 权重:宿主卷 `./ml-models` 只读挂载;在线拉取走 `HF_ENDPOINT=https://hf-mirror.com`(hh2 可出公网),或从有网机下载 tar 后导入(离线路径,ops-manual 增章节);启动时校验权重目录 sha256 与 `model_version` 一致,不一致拒起。
- 模式开关 `MS_ML_MODE=stub|stub-fault|real`:stub 返回确定性假结果(固定 tags/描述),供 dev 全链路与 CI 测试,**不含 torch 也能起**(CI/单测不装权重);**stub-fault 在 stub 基础上注入非法 JSON / 传输层拒绝**(按请求序号奇偶交替),让验收 #4 的故障注入在 P0(stub 环境)即可执行。

### 7.2 API(仅内网容器网可达,不 publish 端口)

- `GET /healthz` → `{status, mode, model_version, loaded}`(健康闸探测点)。**探测超时 ≥16s(≈2× 最坏单请求阻塞 8s)+ 连续 2 次失败才判死**:推理端点 async def 内联阻塞会冻结进程事件循环(accept/解析/响应全停),满载稳态 healthz 实际等待可达 2-8s——1s 超时必然误判 → 重派震荡、吞吐自我限制;healthz 用同步 `def` 的收益仅是 handler 自身不阻塞事件循环,**满载时请求解析/响应写回仍需事件循环,不解决问题,主防线是超时余量**。
- `POST /v1/describe`:入参 `{image_b64, max_tags, lang_hint}`(图片字节 base64;worker 侧已取好帧/缩略图,ms-ml **不访问 MinIO、不持任何凭证**——比给它 presigned URL 更简单也更安全,单帧 ≤ 1024px JPEG ~200KB,内网传输可忽略);出参 `{tags_en: [..≤8], description_en: str}`。
  - prompt(版本化在 ms-ml 代码内):要求输出严格 JSON `{"description": "<=30 words English", "tags": ["<=8 short English tags"]}`;JSON 解析失败 → 一次修复重试(重新 generate + 宽松正则抽取)→ 仍失败则整帧报错(计 failed,不 crash 进程)。
  - SmolVLM2-256M 输入由其 processor 自带缩放(约 512px 级),1024 缩略图/关键帧直接喂。
- 并发上限:uvicorn 8 进程即天然并发 8;每请求完整占一进程 2-5s。不做请求排队(排队在 ai 队列侧)。
- 日志卫生:只记 asset 维度由调用方打;ms-ml 自身日志不落图片内容/描述文本(防素材内容进日志)。

### 7.3 资源预算与吞吐

| 项 | 预算 |
| --- | --- |
| SmolVLM2-256M 权重×8 进程(权重 ~0.5-1GB + torch/transformers 进程基线 ~1GB/进程) | ~14-20GB |
| ms-ml 容器 mem_limit | **20g**(235G 可用,宽裕;实测后按需上探) |
| ms-ai-worker(无 torch,含 2 路并发 ffmpeg) | 2g(§13 口径) |
| 关键帧/段对象(SSD) | ~4GB(全量视频回填后) |

吞吐口径(两个旋钮对齐):ms-ml 8 推理进程 × ms-ai-worker `max_jobs=8`(§8.2,settings `ai_worker_max_jobs`)—— describe 并发 ≤ min(两值)。按每图 2-5s(64-96 new tokens)估:**聚合 ~1.5-3 图/s,全库图片 23776 张回填 ≈ 2.5-5 小时**;⚠ EPYC 7763(Zen3)无原生 BF16,torch CPU 会落 fp32 跑,实测可能向 5-8s/图 偏移 —— **回填排期按 2 倍余量(≈5-10h)规划**,实测后校准。若实测低于预估,先调 `ai_worker_max_jobs` 与 ms-ml `--workers` 两者中较小者(内存余量 20+GB,各自可上探),不改代码。日常增量(每天几十~几百张)分钟级消化。

### 7.4 P2 精标模型(可选,后置)

`Qwen2.5-VL-3B-Instruct` GGUF q4(llama.cpp 路线,~2.5GB,原生中文+OCR),同容器按配置懒加载第二模型,`/v1/describe?tier=refined`;用于视频段精标与「重新精标」入口。本期不实施,仅保证 ms-ml 的 tier 参数与 annotation 表 tier 列预留兼容。

## 8. 任务管线(ms-ai-worker)

### 8.1 入队挂载点:链式派发 + ai_jobs 行先行(不从 complete_upload 直接派)

`generate_thumbnail` / `generate_livp_thumbnail`(静态图段落成功后)/ `generate_video_thumbnail` 在 thumbnail_key 落库成功后,链式触发两步:**① INSERT ai_jobs(pending) 行(ON CONFLICT DO NOTHING)→ ② enqueue**(沿用 fire-and-forget 口径,enqueue 失败仅 log)。理由:

- **行先行 = ai_jobs 表无条件成为事实源**:enqueue 是 fire-and-forget,Redis 抖动/重启丢 zset 条目时,若行不存在 sweeper 永远看不见该资产(永久漏标);行先落库后,enqueue 丢了也会被 sweeper(§8.5)在 10-25min 内补派。
- 图片 AI 的输入就是 1024px 缩略图(SSD,现成),链式 = 天然不与缩略图生成赛跑,不重复拉原图;
- 缩略图 skip/failed 的资产天然不进 AI(non_video/超限本就不该打标),无需重复判定;
- complete_upload 零改动(主链路零侵入;原 spec §6.1「上传零阻塞」语义更强了)。

视频 AI job(slice)由 `generate_video_thumbnail` 成功后派发,自带全流程(ffprobe→场景检测→关键帧→打标→落库),不依赖缩略图。

新 enqueue helper:`services/arq_pool.py` 增 `enqueue_ai_annotate / enqueue_ai_slice`(`_queue_name="ai"`,确定性 `_job_id=f"ai:{kind}:{asset_id}@{model_version}"` 派发去重,沿 livpdl 先例;**`_expires` 按类区分:annotate ≈1800, slice ≥86400(24h)** —— 闸=2 × 单条 8-15min 下批量上传排队轻易超 30min,`_expires` 太短会使取出时 job_key 已过期被判 expired 丢弃,退化为 sweeper 补派多付 10-25min/轮)。

### 8.2 worker 定义

新文件 `api/app/workers/ai_main.py`:`AIWorkerSettings`:

- `functions = [func(ai_annotate_asset, timeout=120, max_tries=2, keep_result=0), func(ai_slice_video, timeout=5400, max_tries=1, keep_result=0), func(ai_refresh_context, timeout=300, max_tries=2, keep_result=0)]`
- `cron_jobs = [cron(requeue_ai_jobs, minute=set(range(0,60,10)), timeout=300)]`(cron 函数归 cron_jobs,勿混进 functions —— 仓库先例 workers/main.py:1150-1156)
- **凡 §8 定义的 ai 队列 job 必须逐个出现在 functions,漏注册 = arq 取出即判 JobExecutionFailed 静默丢弃**(仓库既知失败模式,workers/main.py:1187-1188 注释;契约测试断言 functions 集合)
- `queue_name="ai"`;`max_jobs=8`(对齐 ms-ml 8 推理进程,settings `ai_worker_max_jobs` 可调);**`keep_result = 0` 类属性兜底**(per-function keep_result 管不到 JobExecutionFailed 特殊路径——function not found / job expired / 反序列化失败走 finish_failed_job,只用 Worker 级 keep_result 写 result key,残留 1h 会吞确定性 id 重派,worker.py:723)。

容器 `ms-ai-worker` 复用 api 镜像(`command: arq app.workers.ai_main.AIWorkerSettings`)。

- **keep_result=0(关键,arq 0.28 机制)**:`enqueue_job` 在 job_key **或 result key** 任一存在时返回 None(arq/connections.py:158);job 正常结束后写 result key,TTL=keep_result(默认 3600s)。**受益方 = 确定性 id 通道**:链式首派/restore 补派用确定性 `_job_id`,若 result key 残留 1h,窗口内同 id 重派会全部静默 None(退化到等 sweeper);sweeper 重派用时间戳后缀 id 天然不撞,但 keep_result=0 仍是统一防线。AI 函数 fire-and-forget 本就无结果消费方。
- **视频并发闸在行认领层(不是进程内 Semaphore)+ 闸满自延迟重排**:slice 行认领前先 `SELECT count(*) FROM ai_jobs WHERE kind='slice' AND status='running' AND heartbeat_at > now()-interval '35 min'`(heartbeat 过滤防僵尸占槽),`≥ ai_slice_max_concurrent(默认 2)` → **job 内 `enqueue_job("ai_slice_video", asset_id, _job_id=f"…:d{int(time.time())}", _defer_by=600s)` 自延迟重排后 return**(_job_id 用**时间戳后缀 d{unix_ts} 单调量**而非代次=attempts:闸满不认领 → attempts 不前进,「下一代次」会在第二次撞自身运行期存活的 job key 被 connections.py:158 静默吞,自延迟链断裂)——不依赖 sweeper、不烧 attempts(P0 教训:若靠 sweeper 重派消化排队,每拍 attempts+1 会在 50min 内耗尽 5 次预算,视频积压 > 十余条即永久停摆)。闸是无锁 count 属**软限**(两 job 同时过闸可短暂超发至 3,可接受)。理由(弃进程内 Semaphore):排队等待计入 arq per-function timeout,超时杀死不写 failed/attempts(毒丸循环);认领层闸 = job 本体零等待,slice timeout 只需覆盖自身最坏算术:**检测 600s + 抽帧 ≤60 帧×~10s + describe ≤60 帧×单次 ≤30s(帧级不重试,§8.4-6)≈ 3000s + 余量 → 5400**(presigned 7200 > 5400 不撞过期;沿 workers/main.py:1173「timeout ≥ 最坏算术」传统);另设 **wall-clock 软预算 4300s:超时即止损**(跳过剩余帧,已有段照常落库,ai_jobs done + `last_error='partial'` 入受控 token 集,annotation 行带 `partial: true`),防名义值翻倍击穿 timeout。

### 8.3 ai_annotate_asset(图片 / livp 静态图)

1. **行认领(幂等 + 接管 + 心跳;认领与终态全程 CAS 化)**:slice 先过 §8.2 并发闸;然后 `INSERT … ON CONFLICT (asset_id,kind,model_version) DO NOTHING`,再单条 CAS 认领:
   ```sql
   UPDATE ai_jobs SET status='running', claim_token=gen_random_uuid(), heartbeat_at=now()
   WHERE id=:row_id
     AND (status IN ('pending','failed') OR (status='running' AND heartbeat_at < now()-interval '35 min'))
   RETURNING claim_token
   ```
   RETURNING 0 行 → return(done/skipped 终态、或别的实例在跑且心跳新鲜;认领侧 CAS 消灭「回读→UPDATE」TOCTOU 双认领,沿百度 lease_until 租约先例 workers/baidu_backup.py:1878/2042)。心跳阈值 annotate/slice 统一 35min(与 sweeper 一致,勿两处口径)。
   - **心跳与 CAS 凭据分离(P0 教训)**:job 内起 asyncio 任务每 5min `UPDATE ai_jobs SET heartbeat_at=now() WHERE claim_token=:token`(只刷 heartbeat_at);**终态/中间态 CAS 一律 `WHERE claim_token=:token`**——CAS 谓词绝不能比较 updated_at/heartbeat_at 这类被心跳改写的列,否则合法执行者自己也会被自己挡死(心跳一刷列值就变,终态永远写不进 → 接管死循环)。心跳任务 try/finally 取消。
   - sweeper 判活/接管一律看 `heartbeat_at`(running 行认领时即写,非 NULL);`updated_at` 仅观测用。
   - **同步阻塞段(ffmpeg/boto3/httpx 同步调用)一律 asyncio.to_thread**(仓库铁律,workers/main.py:140-143 注释:同步阻塞体会冻结事件循环 → 心跳饿死 → 被 sweeper 误接管双跑)。
2. 读 asset + folder 链 + project,拼 `context_path`(`{project.name}/{folder 路径链}/{filename}`,截 600);asset 已软删/不存在 → status=skipped(asset_gone)。
3. 健康闸:GET ms-ml /healthz **16s 超时 + 连续 2 次失败才判死**(满载时推理阻塞事件循环,healthz 应答可达 2-8s,1s 超时必误判,§7.2);**且断言 `settings.ai_model_version == healthz.model_version`,不一致同样判死 + 醒目 error 日志**(消灭「api 侧 settings 的写入版本」与「ms-ml 实际加载权重」双事实源静默血缘错位);判死 → ai_jobs 置回 pending、attempts 不动,**正常 return**(sweeper 稍后重派;不 raise 不烧 arq tries —— 沿用「失败分级」先例,瞬时失败不进重试计数)。
4. 从缩略图 MinIO 读 `thumbnails/{id}.jpg`(SSD,亚秒);读不到时**区分:ClientError 404/NoSuchKey → skipped(minio_missing,永久终态不重试);其他异常(网络抖动)→ failed(minio_transient) 待 sweeper 重试**——瞬时故障不得误杀为永久终态。
5. POST /v1/describe(`ai_ml_timeout_s` 默认 30s;**annotate 路径 ×2 次重试,slice 帧级不重试**——帧级容错已兜,重试会把 slice 超时算术翻倍);失败 → **attempts+1(真实执行失败才计)**,`attempts+1 ≥ 5` → 直接写 skipped(poison)(终态可见,不永久卡 pending/running);否则写 failed(ml_error) 交 sweeper 重试。
6. 词表汉化(§9)→ upsert asset_ai_annotations(PK 冲突即覆盖,幂等第二道)→ ai_jobs done。
7. **意外异常路径(代码 bug 级未捕获)**:不写行状态 → 行停留 running,35min 心跳过期后被 sweeper 接管(attempts+1)——行为有界、自愈,接受;annotate 的 arq `max_tries=2` 第二次 try 会因「行已被自己认领且心跳新鲜」被 CAS 谓词跳过空转一次,**arq tries 在本路径实际不生效属预期**,勿据此调参。日志卫生:描述/标签/context_path 内容物不进 ms-ai-worker 日志(对齐 workers/main.py:949-952 presigned URL 不落日志铁律)。

### 8.4 ai_slice_video(视频:切片+打标一体)

1. 同上行认领(§8.3-1)/健康闸/context_path。
2. 签主桶 presigned GET URL(**ExpiresIn=7200**,> slice job timeout 5400 + 余量,防长视频尾部抽帧撞过期;worker 与 MinIO 同机容器网,先例 workers/main.py:959 用 600s 但其 job 仅 360s,这里按比例放大;**ffprobe(步 3)/场景检测(步 4)/抽帧(步 5)共用同一 URL —— 直读远端对象的一切 ffmpeg/ffprobe 调用都在签发之后**)。
3. **前置 ffprobe**(容器内自带):取时长/分辨率;失败 → 重试一次仍失败则 skipped(decode_failed,永久);时长 <10s 或 >30min → 跳过场景检测,直接**固定间隔分段**(间隔 = `max(60s, ceil(时长/ai_max_segments))`,**段数恒 ≤ ai_max_segments**,长视频不会被兜底路径击穿段数/帧预算;`segmented_by: "interval"`)。
4. **场景检测一遍**:ffmpeg 直读 URL `-vf "select='gt(scene,{thr})',showinfo" -f null -` 解析 showinfo 的 pts_time 得切点(thr 默认 0.30,settings 可调);检测 subprocess 超时 600s → 降级固定间隔分段(§8.4-2 同款含段数上限)。切点聚合:相邻切点 <5s 合并;**时长 >5min 且切点数 <3 的单镜头长视频(无人机缓慢运镜常态),叠加均匀锚点再分段:按 `max(60s, duration/30)` 间隔强制补切**(防 10s-30min 区间的场景路径产出整条 1 段、描述粒度过粗);**段数 > ai_max_segments(默认 60)时反复合并「时长最短的相邻段对」直到达标**(showinfo 不输出 scene 分数,top-N 按分数排序不可行,按最短段合并是确定性的降级)。
5. **关键帧抽取二遍**:每段抽帧数自适应段数(`段数≤20:3 帧 / ≤40:2 帧 / >40:1 帧`),**且全视频总帧数硬封顶 ai_max_frames(默认 60)——超出时从末段起逐段降为 1 帧直到达标**(§8.2 超时算术与 §16-R9 吞吐预估一律按此封顶值),帧位=段首/中(3 帧时含段尾),-ss 精确 seek + scale 512,写 `keyframes/{asset_id}/{seg}_{n}.jpg` 到缩略图 MinIO(SSD);单帧 ffmpeg 失败 → 该段降级用已得帧(≥1 帧即可),全段失败才影响该段描述(见 6)。
6. 逐帧 POST /v1/describe → 段级聚合:段 tags = 帧标签并集 top8;段 description = 首个成功帧的描述;**帧级失败分两类**:①**内容层失败**(模型返回非法 JSON/解析失败)→ 帧级容错,段内全部帧失败 → 该段 tags/description 置空并在段 meta 标 `describe_failed: true`(分段结构照常落库);②**传输层异常**(httpx ConnectError/ConnectTimeout/ReadTimeout = ms-ml 宕/过载)**不计入帧级容错**——连续 ≥2 帧传输层失败 → 判 ml 瞬时失败,job 置 failed(ml_error) 交 sweeper(与 §8.4-8 闭环;否则中途宕机会把整条视频误判 done 终态,恢复后永不补打)。视频整体 tags/description = 段级并集摘要(忽略失败段)。
7. 事务落:asset_video_segments(先 DELETE WHERE asset_id 再 INSERT,重跑段数不增)+ asset_ai_annotations(searchable_text 聚合含全部段描述)→ ai_jobs done。
8. 失败分级:ms-ml 瞬时失败(健康闸后中途宕,传输层连续 ≥2 帧)→ 置 failed(ml_error) + attempts+1 交 sweeper 重派(与 §8.3-5 同款分级;重跑代价 = 重新解码,接受;frame 级结果不缓存)。

livp 的实况短片视频部分:本期不打标不切片(静态图已覆盖主体;视频轨道另期)。

### 8.5 sweeper cron(requeue_ai_jobs,每 10min)

两臂分开处置(批上限 500/拍,沿百度 SWEEP_BATCH=50 批闸先例);**各臂谓词均带 `AND model_version = 当前写入版本`**(灰度换版窗口内,旧版本残留 pending/failed 行不被新权重错标——ms-ml 已换权重而行的 model_version 是旧版,重派落库会造成血缘错位;旧版本行由 backfill 按需处理):

- **pending/failed 臂**(`status IN ('pending','failed') AND updated_at < now()-10min`):**不加 attempts** 直接重派(P0 教训:纯排队/派发丢失的 pending 若计 attempts,回填批排空 >10min 的尾部行会被虚耗到 5 次上限永久漏标;毒丸防护不由本臂承担)。
- **running 接管臂**(`status='running' AND heartbeat_at < now()-35min`):置 pending + **attempts+1**(接管僵尸,真执行过才计数);attempts ≥5 → 转 skipped(poison),终态可见。
- 兜底臂:`attempts ≥ 5 AND status IN ('pending','running','failed')` → skipped(poison)(防超时被 arq 杀死、行无终态的观测黑洞;**含 failed** —— 毒丸最常落的状态,漏了它 = failed 行无限重派)。

**重派 _job_id 一律带时间戳后缀**(`ai:{kind}:{asset}@{v}:s{unix_ts}`):绕开 arq 的 `arq:in-progress:{job_id}` 墓碑键(kill -9 后该键存活 max_timeout+10=5410s,同 id 重派被「already running elsewhere」挡住)与 kill -9 残留的 `arq:job:{id}`(TTL=_expires,同 id 派发静默 None);**重派后同拍 touch 行 `updated_at`**,防下一拍 sweeper 对同一行再派(条目重复有界)。互斥唯一事实源仍是 ai_jobs 行认领(§8.3-1),job_id 只影响派发不去重,行认领挡住并发双跑。backfill 派发同样带唯一后缀(§8.7)。闸满自延迟重排(§8.2)用 `:d{unix_ts}` 并同样 touch 行,与 sweeper 的 `:s{unix_ts}` 互不冲突。

**时延如实**:pending 补派最坏 ≈ 20-25min(陈旧阈值 10min + cron 拍 10min);kill -9 接管最坏 ≈ 35min(心跳阈值)+ 10min(拍子)。验收 #2 按 ≤30min 口径。覆盖:ms-ml 宕机期间链式派发的积压、ms-ai-worker 重启丢 zset 条目、瞬时 ml_error、worker 被 kill 后的僵尸 running。ai_jobs 表即事实源(pending 堆积=队列深度,failed/skipped 率=质量观测)。

### 8.6 上下文刷新(资产移动/改名后防过期)

`batch_move_assets`(assets.py:1172)/`batch_prefix`(assets.py:829)/folder 改名/移动(folders.py:181 update_folder,改名与 reparent 均影响子树)落库处,顺带 enqueue 轻量 job `ai_refresh_context`(ai 队列,纯 SQL,**已注册进 AIWorkerSettings.functions,§8.2**):对受影响 asset_ids(或 folder 子树全量)`UPDATE asset_ai_annotations SET context_path=重拼, searchable_text=重拼聚合`(context/tags 部分保留,只换上下文前缀与重聚合段描述);**子树模式分批执行**(每批 ≤500 行,重拼是纯函数幂等,重跑无害;顶层目录子树可达数千行,单批 300s timeout 内未必跑完)。移动/改名是低频管理操作,行数有限,代价可忽略;不刷新则「哪个项目」指向旧路径,违背目标①。**已知竞态窗口**:运行中的 slice 用认领时读到的旧 context_path 完成覆写,若 refresh 先完成则上下文短暂回退旧路径,直到 `--refresh-context` 对账——低频可接受,不设锁。派发失败仅 log —— 兜底:backfill_ai.py 增 `--refresh-context` 模式可全量对账重拼。(项目改名端点现状不存在,若将来支持须同样挂钩。)

软删恢复出口:`restore_asset`(assets.py:544)顺带两步 —— ① `DELETE FROM ai_jobs WHERE asset_id=… AND status='skipped' AND last_error='asset_gone'`(软删期落下的终态行);② **该资产若无 annotation 行,按当前写入版本补 INSERT ai_jobs(pending) + enqueue**(复用 §8.1 链式两步;只 DELETE 不重派会违背「ai_jobs 无条件事实源」——行没了 sweeper 看不见,恢复的资产静默漏标且无观测)。backfill 另提供 `--reset-skipped` 兜底。

### 8.7 回填脚本

`api/scripts/backfill_ai.py`(仿 backfill_thumbnails.py):`--kind annotate|slice --model-version <v> [--force] [--reset-skipped] [--refresh-context]`;annotate 扫 `is_image_asset OR filename like %.livp` 且缩略图 tags 就绪的行;slice 扫 `is_video_asset` 行(**含 thumbnail_failed 的视频行** —— 链式挂载使缩略图失败的视频零 AI 覆盖,slice 自带独立 decode_failed 分级,backfill 是其唯一补打通道)。**`--force` 语义 = 对已 done 的行也重置**(`UPDATE ai_jobs SET status='pending', attempts=0, claim_token=NULL WHERE asset_id=… AND kind=… AND model_version=…`,含 done)后 enqueue——否则行认领见 done 即 return,§15-3 的幂等验收会空洞通过。`--reset-skipped` 同款重置 skipped 终态行(排除 asset_gone,除非资产已恢复)。**派发 id 带唯一时间戳后缀**(kill -9 残留的 `arq:job:{id}` TTL=_expires 期内同 id 派发会静默 None,connections.py:158);**annotate 类批大小按「10min 内可排空」折算**(批仍在排队时不被 sweeper 视为陈旧重派,防重复条目堆积);**slice 类不限批**(闸=2 × 8-15min 排队超 10min 是常态,闸满自延迟与 sweeper 重派均 touch 行保鲜,不会重复堆积)。全库回填窗口建议夜间、按吞吐预估 ×2 余量排期(§7.3)。

## 9. 打标内容契约与中文层(约束③的落点)

**呈现目标示例**(web 详情面板「AI 识别」区):

```
上下文: Q4品牌发布会 / 现场视频 / DJI_20261019_1630.MP4
AI 标签: [发布会] [舞台] [灯光] [人群] [夜拍] [航拍]
AI 描述: 大型户外舞台夜景,密集人群,灯光秀,无人机航拍视角
```

- **项目/目录上下文不打扰模型**:context_path 由 worker 从 DB 拼(project.name + folder 链 + filename),不进 prompt(SmolVLM2 英文模型对中文项目名无增益),落库后随 annotation 下发并在前端置顶展示 —— 「哪个项目」由此保证,**准确率 100%(结构化事实,非模型猜测)**。
- **「什么素材内容」由模型 + 词表双轨**:
  - tags_en ← ms-ml;tags_zh ← **受控词表汉化**(`api/app/services/ai_label_map.py` + 数据文件,版本化;v1 预置 ~200 高频词:场景/人物/物体/动作/风格/光线/摄影术语;匹配策略:小写化→精确→词形归一(复数/ing/ed)→命中映射;未命中标签原样保留进 tags_en 并可观测词表外比率,回填后按 top 未命中词扩词表)。
  - description 呈现 = 「英文原描述」在 P1 直接展示(标签已中文,可读性主体靠标签);P2 精标模型直出中文替换 description 字段(同表覆盖,tier=refined)。
- **searchable_text = context_path + tags_zh + tags_en + description + description_en + 各段 description**(两语描述都聚合,P2 精标后中文 description 直接可搜),中文搜索「发布会 航拍」、英文「drone night」都能命中 —— 「从打标内容看出是哪个项目的什么素材」在搜索侧同样成立。

## 10. 视频切片(虚拟切片,D1)

- **产出**:asset_video_segments 行(时间轴元数据)+ keyframes 对象(SSD)+ 段级 tags/description。**不产生新素材文件、不占原片盘、完全可逆**(删表+删 keyframes 前缀即回滚)。
- **消费(web,本期)**:素材详情面板(视频类型)增「智能分段」区:时间段列表(起止时间 + 段标签 + 段描述 + 首帧缩略图),点击行 → 内嵌 `<video>` 控件 `currentTime = start_ms/1000` 定位播放(纯前端,零后端);新端点 `GET /assets/{id}/ai`(annotation + segments 一次带回)。
- **消费(搜索)**:段描述聚合进 searchable_text;命中视频返回 asset 级结果(打开详情即见高相关段)。P2 再考虑结果直接标注命中段(SearchResultOut 增可选字段)。

## 11. 搜索接入(第四路,两臂独立执行 + 应用层合并;非 OR 臂也非 DB 层 UNION)

**不能把 AI 命中写成 EXISTS 直接 OR 进既有三路**:现状三路 OR 全部是可索引臂,PG 走 BitmapOr;OR 中加入相关 EXISTS(SubLink)后 planner 不可能再进 BitmapOr,整个 OR 退化为逐行 filter —— 系统 admin(folder 过滤恒真)直接退化为全表 seq scan + 每行 EXISTS 探测,是数量级回归。也不用 DB 层 `UNION`(现状解析循环依赖 ORM 实体 + `AssetOut.model_validate`,assets.py:716-723,union 后实体映射丢失),定稿为**两臂各自独立查询 + 应用层合并**:

- **臂 A = 现有三路查询原样保留**(同 folder_filter/排序;`ai_enabled=false` 时只跑臂 A,与线上逐字节一致)。
- **臂 B = `SELECT asset_id FROM asset_ai_annotations an JOIN assets a ON a.id=an.asset_id WHERE an.model_version=:active AND an.searchable_text ILIKE :pattern AND a.deleted_at IS NULL [AND folder_filter] ORDER BY a.created_at DESC, a.id DESC LIMIT :offset_plus_limit` → `assets.id IN (…)` 回查实体**;searchable_text 有自己的 trgm GIN,独立走索引扫描。**排序键必须 = 臂 A 的 `assets.created_at DESC, id DESC`**(annotation 表自身 created_at = 回填序 ≠ 资产序,两臂排序键不一致时合并分页不正确;k 路合并要求各臂按同一全局键取前 N;id tiebreak 沿 list_assets 翻页漂移先例 assets.py:460-465)。
- **臂 A 的 tiebreak**:`ai_enabled=true` 时臂 A 在现状 `.order_by(Asset.created_at.desc())`(assets.py:710,现状无 id)之上**补 `Asset.id.desc()` tiebreak**(批量上传 created_at 全并列的翻页漂移是本仓真实发生过的问题,list_assets 已补过,assets.py:446-448 注释);`ai_enabled=false` 时臂 A 不动一个字节(与线上逐字节一致)。on 态臂 A 与基线的这一处差异属**预期差异**,§15-9 的性能对比按此口径。
- **合并分页**:两臂各取前 `offset+limit` 行(同键同 tiebreak)→ 应用层按 asset.id 去重 → 合并重排(同键)→ 内存切 `[offset : offset+limit]`(limit≤200 量级,零压力;正确性与 SQL 层 LIMIT+OFFSET 等价,同资产两臂命中只出现一次)。
- 沿用同一 `folder_filter` 权限先行,两臂都带;sensitive 零泄露语义不变(权限过滤在 AI 路之前,AI 标签本身不新增任何可见面)。
- `:active_version` 来自 settings(进程内缓存,不查库)。
- 验收含性能对比:同 q 在 ai_enabled on/off 下的耗时与 EXPLAIN 计划臂 A 不退化(§15-9)。

## 12. web 前端(本期范围)与派生媒体权限口径

**keyframes 签发口径(与既有两档先例的关系,显式拍板)**:本仓派生媒体有两档 —— ①缩略图(1024px):认证不鉴权豁免(assets.py:2172「模糊化、信息密度低」);②livp 实况视频:can_download 强制 + audit(assets.py:2467 docstring,enforce 在 :2485-2490,接近原片内容)。分段关键帧是**原片真实画面但分辨率低(512px)且只能经详情面板按 asset 逐个取**,定位取中间档:**GET /assets/{id}/ai 及其 keyframes 签发 = 素材列表/详情同口径(folder can_view + public 项目非敏感夹豁免,复用 list_assets 的判定形态 assets.py:415-431,防止「列表可见、AI 区 403」口径分裂;软删资产 404,对齐 get_live_preview_url 先例 assets.py:2475)**,且每次签发写一条 `signed_url_issued` 审计(details 记 count 与对象前缀,不逐帧审计)。比缩略图档严格(多了 folder 权限 + 审计),比下载档宽松(不要求 can_download)—— 搜索零泄露硬验收不受影响(搜索仍 folder 过滤先行)。

1. **素材详情面板**(FolderDetailPage 详情 Drawer):新增「AI 识别」独立区(与人工标签区视觉隔离):上下文行 + 标签 chips(中文)+ 描述 + 元信息(tier/模型版本/时间);「采纳为人工标签」按钮 → 调既有 `PATCH /assets/{id}/meta`(labels_mode=merge,不新增写路径;该端点要求 can_upload,无权限用户前端隐藏按钮,后端 403 兜底)。
2. **视频智能分段区**(同面板,视频类型且 segments 非空):段列表 + 首帧缩略图 + 点击定位播放。**keyframes 返回/签发形态定稿**:`GET /assets/{id}/ai` 只回对象 key 列表(不预签 180 条 URL);新端点 `POST /assets/{id}/ai/keyframe-urls`(入参 segment idx 列表,≤10 段/请求)按需批量签发(每段 ≤3 帧),权限/审计口径同上(每次签发一条审计记 count)——详情面板按段懒加载,载荷与审计量都有界。
3. SearchPage 命中 AI 路的结果加「AI」角标(前端按 q 与 filename/labels 是否命中区分可选,P1 可先不加)。
4. 新 API client 方法:`getAssetAi(id)`;类型定义对齐新端点。

## 13. 部署、配置与回滚

- compose 增两服务,均挂 **`profiles: ["ai"]`**(默认不起,`COMPOSE_PROFILES=ai` 显式启用 —— 未启用环境 `docker compose up -d` 完全不感知,与 `AI_ENABLED=false` 双保险):`ms-ml`(build ml.Dockerfile;不 publish 端口,仅 poc-net 内;**mem_limit 20g**(§7.3 口径,勿写 16g —— 8 进程×(权重+基线)贴 16g 下限,超限 OOM 一次杀全部推理进程反复震荡);卷 ./ml-models:ro + `./ml:/app/ml:ro`(代码 bind mount 热更,沿 ./app 同款;MS_ML_MODE env)、`ms-ai-worker`(与 ms-api/ms-worker 共用同一 build;compose 里 ms-api 显式 `image: ms-api-image` 命名、ms-ai-worker 引用同 image,避免双镜像;command 改 arq ai_main;mem_limit **2g** —— 容器内要跑 2 路并发 ffmpeg 子进程,cgroup 计入容器内存,1g 偏紧;现状 ms-worker 跑 ffmpeg 未设限,2g 居中)。ms-ml 服务代码放 `api/ml/` 目录(随 deploy_lan rsync 热更,不烧进镜像)。
- settings 新增(api 与 worker 共用):`ai_enabled`(总开关,默认 **false**;false 时:缩略图链不写行不 enqueue、search 只跑段 A、`GET /assets/{id}/ai` 404 —— 与 baidu_backup_enabled 同款急停语义)、`ai_ml_base_url`(默认 http://ms-ml:8000)、`ai_model_version`(**写入版本**:新打标/回填落库用)、`ai_active_model_version`(**读取版本**:搜索与展示只认它;常态 = 写入版本。灰度换版 runbook:改写入版本 → backfill 全量 → 翻转 active → 旧行保留。启动时校验 active 是否存在于 ai_jobs 已见版本,不一致打 warning 防设错静默不可搜)、`ai_scene_threshold`、`ai_max_segments`、`ai_max_frames`、`ai_slice_max_concurrent`、`ai_ml_timeout_s`(默认 30;annotate ×2 重试 / slice 帧级不重试属调用侧语义,§8.3-5)、`ai_worker_max_jobs`。
- deploy_lan.sh:`--restart` 的重启对象列表(`ms-api ms-worker`)增补 `ms-ai-worker`,命令写成 `docker compose restart ms-api ms-worker ms-ai-worker 2>/dev/null || docker compose restart ms-api ms-worker`(未启用 ai profile 的环境降级重启两件,勿让脚本因 no such service 中断;ms-ml 无状态随 settings 变更手动重启);**rsync 排除清单增补 `ml-models`**(权重目录走一次性手动导入,勿随部署同步)。
- 回滚:①`AI_ENABLED=false` 急停(不删数据);②下线两容器 + 删三表(可逆数据全在表与 keyframes 前缀内)。
- **本周期实施后只部署 dev 验证;prod 部署等用户明确指令(约束①)。**

## 14. 分期

| 期 | 内容 | 出口 |
| --- | --- | --- |
| P0 底座 | 迁移 0021 三表;ai 队列 + ms-ai-worker + sweeper + 心跳/接管;链式写行+enqueue;ms-ml(stub 模式);backfill 脚本;settings + 总开关;上下文刷新 job;**搜索第四路 SQL(两臂合并)与 `GET /assets/{id}/ai` 端点** | dev 全链路跑通(stub 假标签落库、第四路可搜中、`GET /assets/{id}/ai` 可读),故障注入(停 ms-ml / kill -9 worker)演练过 |
| P1 图片粗标 | ms-ml real 模式(权重导入);词表 v1;web AI 标签区 + 采纳(链路沿用 P0 的第四路/端点) | 传图出真标签可搜;全库图片回填完成 |
| P2 视频切片打标 | slice job(场景检测/关键帧/段聚合);web 分段区 + 定位播放;视频全量回填;keyframes 孤儿清扫 cron(§16-R7 出口) | 长视频可分段浏览定位,段描述可搜 |
| P3(另期) | Qwen2.5-VL-3B 精标(tier=refined);语义搜索(pgvector+embedding+RRF);App 端;livp 视频轨;语音转写 | 另立 spec |

## 15. 验收标准

分期归属:P0 出口 = #1(stub 版,命中口径=英文标签+上下文路径)/#2/#3(「annotation 行数不增」子句)/#4(stub-fault 模式)/#6(端点权限部分)/#7/#8/#10;P1 出口 = #1(真模型,含中文标签命中)/#6(采纳按钮)/#9/#14;P2 出口 = #3(「segment 行数不增」子句)/#5/#11/#12/#13。逐条执行时按所属期验收,勿把 P2 项当 P0 卡点。

1. dev 上传 jpg → 链式触发 → **120s 内** annotation 落库,`GET /assets/{id}/ai` 可读,搜索按英文标签/上下文路径可命中(**中文标签命中随 P1 词表生效**,P0 词表未交付属预期)。
2. 停 ms-ml 容器:上传/缩略图/搜索(前三路)全部照常;恢复后 sweeper **≤30min 内完成积压重派**(补打执行时间另计,随积压量线性;keep_result=0 保证重派不被 result key 吞,§8.2;时延口径见 §8.5)。
3. 同 asset 同 model_version 重跑(backfill --force 两次,--force 须真实重置行,§8.7):annotation 行数不增、segment 行数不增。
4. ms-ml 返回非法 JSON 注入:job 落 failed + last_error 为受控 token,worker 不 crash,其他 job 不受影响。
5. 视频上传(含 >1GB 与 >60min 长视频样本):分段落库,段数 ≤ ai_max_segments(**interval 兜底路径同样受限**),总帧数 ≤ ai_max_frames,每段关键帧对象存在**或该段带 describe_failed/降级标记**;详情页分段列表点击后播放器定位到段起点(±1s);单帧 describe 内容层失败注入 → 分段照常落库、失败段带 describe_failed 标记、job 不失败;**ms-ml 中途宕机注入(传输层)→ job 非 done、恢复后 sweeper 补打成功**。
6. 权限:无 folder 权限用户(含 sensitive 场景)搜索任何 AI 关键词零泄露(沿用盲搜既有验收口径);`GET /assets/{id}/ai` 与 keyframes 签发对无 can_view 用户 403/404;签发落一条审计。
7. `AI_ENABLED=false` 时:上传不写 ai_jobs 行不派发、搜索 SQL 与当前线上逐字节一致(只跑段 A)、AI 端点 404。
8. stub 模式下 CI 全量测试绿(ms-ml 不依赖 torch/权重)。
9. 性能不回归:ai_enabled on/off 两态,同 q 组(filename 词/AI 词/混合)各 20 次搜索 P95 耗时对比,off 态与上线前基线一致;on 态 EXPLAIN 确认段 A 计划形状不变、段 B 走 searchable_text GIN。
10. 资产移动/改名后:刷新 job 完成,搜索按新路径命中、旧路径不再命中;annotation 的 context_path/searchable_text 指向新路径(§8.6)。
11. kill -9 ms-ai-worker(注入运行中的 slice job):sweeper 接管后重跑,segment 行数不增、无并发双写交错(CAS 生效);恢复软删的资产不因 skipped(asset_gone) 永久卡死(§8.6)。
12. keyframes 对象孤儿:本期接受(资产硬删后前缀残留),P2 补清扫 cron(§16-R7 出口)。
13. 批量并发上传 ≥10 条视频:最终全部落库分段(允许长时延,闸满自延迟重排不烧 attempts),无资产因 attempts 耗尽漏标(§8.2/§8.5 的 P0 回归防护)。
14. 版本灰度切换(§13 runbook):改写入版本回填后,搜索/展示只命中新 active 版本,旧版本行保留且不被命中;active 指向不存在版本时启动 warning 兜底生效。

## 16. 风险与对策

| # | 风险 | 对策 |
| --- | --- | --- |
| R1 | SmolVLM2-256M 描述质量粗/幻觉(256M 小模型) | 独立标签区隔离 + 词表收敛 + tier 标注 + 采纳工作流;P2 精标升级路径预留;验收不卡「描述精确」,卡「标签可读可搜」 |
| R2 | 英文输出中文可读性 | 标签走词表汉化(主体);描述 P1 英文展示 P2 中文替换;词表外标签可观测可扩 |
| R3 | 大视频(4GB)全量解码耗时/CPU 占用 | 行认领层并发闸(§8.2,默认 2);URL 直读零拷贝;检测超时降级固定间隔分段;wall-clock 软预算止损;回填夜间分批;ffmpeg 显式 `-threads 4`(2 并发 × 4 + ms-ml 8×16=128,峰值 ~136 线程,不超卖 256) |
| R4 | 场景检测对无人机缓慢运镜不敏感(长镜头切不出段) | 阈值可调 + 最小段合并 + 固定间隔兜底(§8.4-2/§8.4-4);`segmented_by` 字段如实标注来源 |
| R5 | torch/transformers 供应链与镜像体积 | CPU-only index 钉版本进 constraints 同款机制;ml.Dockerfile 独立钉死;权重 sha256 校验拒起 |
| R6 | HF 权重拉取失败(网络) | hf-mirror.com 主路径 + tar 离线导入备路径(ops-manual);stub 模式保 CI/dev 可用 |
| R7 | keyframes 无限增长 | 同 asset 重跑覆盖写同 key;资产删除 CASCADE 行 + keyframes 前缀随资产清理通道(asset_cleanup 先例)后续补清扫 cron(P2 收尾) |
| R8 | arq ai 队列积压无告警 | ai_jobs 表 pending 计数 + sweeper 日志;P1 手查,P3 接 healthz 汇总 |
| R9 | 视频全量回填耗时长(1280 视频;单条典型 8-15min、最坏 [检测 600s + 抽帧 600s + describe 1800s] ≈ 50min,并发 2) | 典型档预估 **85-160h**、最坏档 **≈533h**(1280×50min/2);夜间窗口按最坏档排期、分多晚跑;backfill 分晚批 + slice/annotate 独立成 kind 可分别排期;增量上传不受影响(实时链路) |

## 17. 实施雷(已知,提前写给 qdev)

1. `tests/test_db_schema.py` 表数断言须 +3;新表 FK CASCADE 语义须与既有软删(hard purge)清理通道核对(purge 先例 asset_purge.py)。
2. ms-worker 链式挂载点:thumbnail 函数挂 AI 写行+enqueue —— **P0 只挂 generate_thumbnail 与 generate_livp_thumbnail(静态图段)两族;generate_video_thumbnail 的 slice 链随 P2 落地**(slice 未注册就挂派发 = 取出即 JobExecutionFailed 静默丢弃,§8.2 既知雷);挂载须 grep 各函数收尾点,漏一处 = 该族资产永不打标。
3. `_merge_asset_tags` 的 jsonb_set 模式不要复用给 AI 结果(独立表);但 AI job 里读 asset.tags 判 thumbnail_key 存在性与写侧无竞争(链式已保证先后)。
4. 视频分段事务:segments DELETE+INSERT 与 annotation upsert 须同事务;失败回滚防半态。
5. ffmpeg showinfo 输出解析:pts_time 格式(科学计数法/缺帧)要有单测表驱动;showinfo 走 stderr 稳定格式;ffprobe 用 `-show_entries format=duration` 容错缺字段。
6. compose 多服务共用 build:ms-api 显式命名 image,ms-worker/ms-ai-worker 引用之,勿各自 build 产生双镜像;两 AI 服务挂 `profiles: ["ai"]`。
7. 词表数据文件放 `api/app/services/ai_label_map.py` 同包(打包进镜像,不依赖运行时文件挂载)。
8. 搜索第四路必须是**两臂独立查询 + 应用层合并**(§11 定稿):禁止把 EXISTS OR 进既有三路(击穿 BitmapOr),**也禁止 DB 层 UNION**(union 后 Row 丢 ORM 实体映射,现状解析循环 assets.py:716-723 依赖 `AssetOut.model_validate(asset)`)。臂 B 候选查询必须 JOIN assets 按 `assets.created_at DESC, id DESC` 取前 `offset+limit`(与臂 A 同键同 tiebreak——本仓 list_assets 因批量上传 created_at 全并列翻页漂移补过 id tiebreak,assets.py:460-465);`ai_enabled=false` 时臂 A SQL 形状要与现状逐字节一致(既有性能不回归);active_version 参数绑定用 settings 缓存值勿硬编码。
9. arq:AI 函数 keep_result=0 必须显式写(§8.2;**受益方是确定性 id 通道**——链式首派/restore 补派在 keep_result TTL 窗口内同 id 重派会被 `arq:result:{id}` 吞,退化到等 sweeper);首次派发 _job_id 用确定性 id + `_expires≈1800` 防上传并发双派;**sweeper 重派一律 `:s{unix_ts}` 后缀、闸满自延迟 `:d{unix_ts}` 后缀**(§8.5,勿用 `:r{attempts}` —— pending 臂不加 attempts,同 attempts 重复重派会撞 TTL 内的 `arq:job:{id}` 被静默吞)。
10. ai_jobs 行认领必须 ON CONFLICT + 回读分支(§8.3-1),不要裸 INSERT 撞 UNIQUE 就 return(会把僵尸 running 永久卡死);**心跳只刷 heartbeat_at、CAS 只比 claim_token,两者绝不碰同一列**(P0 教训:比较被心跳改写的列 = 合法执行者被自己挡死 → 接管死循环)。
11. `GET /assets/{id}/ai` 权限=folder can_view + public 项目非敏感夹豁免(与列表同口径,§12),keyframes 签发写一条审计;不要照抄 get_thumbnail_url 的认证不鉴权豁免。
12. deploy_lan.sh --restart 列表须含 ms-ai-worker,且带 profile 未启用降级(§13);**rsync 排除清单须加 `ml-models`**(权重 ~0.5-1GB,走一次性手动导入,勿随部署全量同步,§13)。
13. **新 ai 队列 job 必须与 AIWorkerSettings.functions 对账**(§8.2):新增 job 函数忘了注册 = 取出即 JobExecutionFailed 静默丢弃(workers/main.py:1187-1188 注释的既知失败模式);cron 函数归 cron_jobs;契约测试断言 functions/cron_jobs 集合。
14. 心跳任务必须 try/finally 取消;终态/中间态 UPDATE 带 CAS(WHERE claim_token=:token),防接管后旧执行者交错写(§8.3-1)。
15. slice 并发闸 = 行认领层的 running 计数 + 闸满 `_defer_by=600s` 自延迟重排(§8.2),不是进程内 Semaphore(排队等待会吃掉 arq timeout 且超时不计 attempts);**sweeper 的 pending 臂绝不加 attempts**(排队不是失败,P0 教训)。
16. ms-ai-worker 内同步阻塞段(ffmpeg/boto3/httpx)一律 asyncio.to_thread:心跳是同事件循环的 asyncio task,同步阻塞体会饿死心跳 → 被 sweeper 误接管双跑(workers/main.py:140-143 铁律同源)。
