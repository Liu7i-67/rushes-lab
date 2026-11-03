# 需求文档:素材自动打标 + 视频切片实施

- 日期: 2026-11-03
- **方案正本: `rushes-spec/material-storage/ai-tagging-slicing-plan.md`(本分支已含,10 轮盲审定稿)**——背景/架构/机制论证/验收标准以正本为准,本文档是实施导向的派发契约,冲突时以正本为准。
- 范围: 正本 §14 的 P0+P1+P2 全量一次交付(语义搜索/精标模型后置)。
- 约束: ①不部署生产(仅 dev);②ML 全挂不影响上传/缩略图/搜索现状;③打标内容可读出「哪个项目的什么素材」(context_path+中文标签+描述)。

## 0. 可行性结论

qplan 阶段已由 10 轮独立盲审确认:架构与全部核心机制(arq 0.28 多队列/keep_result/墓碑键/行认领 CAS/两臂搜索合并)经代码逐条证实可行,无需红线问询。

## 1. 功能点明细(验收对照,细化正本 §15)

P0 底座:
1. 迁移 0021 三表(ai_jobs/asset_ai_annotations/asset_video_segments)+ ORM + test_db_schema 表数断言 +3。
2. 独立 arq 队列 `ai` + ms-ai-worker(容器,复用 api 镜像)+ WorkerSettings(queue_name/keep_result=0/max_jobs=8/per-function timeout)。
3. 三个 job(ai_annotate_asset/ai_slice_video/ai_refresh_context)+ sweeper cron(requeue_ai_jobs,分臂 attempts 语义)+ 契约测试断言 functions/cron_jobs。
4. 行认领(INSERT ON CONFLICT + CAS UPDATE RETURNING claim_token)/心跳(5min 刷 heartbeat_at)/终态 CAS(WHERE claim_token)。
5. 缩略图链式挂载:generate_thumbnail/generate_livp_thumbnail(静态图段)/generate_video_thumbnail 成功后「写 ai_jobs(pending) 行 + enqueue」;slice 链随本批全量挂载(ai_slice_video 同批注册,无静默丢弃)。
6. ms-ml 容器(stub/stub-fault/real 三模式)+ compose profiles ["ai"] + settings ai_* 全家 + AI_ENABLED 总开关急停语义。
7. `GET /assets/{id}/ai` 端点(folder can_view + public 豁免 + 软删 404 + 审计)。
8. 搜索第四路:两臂独立查询 + 应用层合并(on 态臂 A 补 id tiebreak;off 态逐字节与现状一致)。
9. backfill_ai.py(annotate/slice/--force/--reset-skipped/--refresh-context)。

P1 图片粗标:
10. ms-ml real 模式(SmolVLM2-256M,torch-cpu,num2words,async def 内联推理)。
11. 词表 v1(services/ai_label_map.py,~200 词,英文→中文映射+词形归一)。
12. web 素材详情「AI 识别」区 + 采纳为人工标签(PATCH meta,labels_mode=merge)。

P2 视频切片:
13. ai_slice_video:ffprobe→场景检测(select+showinfo)→关键帧(自适应+封顶 60)→逐帧 describe(传输层/内容层二级失败分级)→段聚合落库。
14. web 视频智能分段区(段列表+首帧缩略图懒加载+点击定位播放)+ POST keyframe-urls 按需签发。
15. restore/batch_move/batch_prefix/folder 改名挂 ai_refresh_context 钩子 + restore 删 skipped(asset_gone) 补行重派。

## 2. 接口契约(定死,所有包按此开发)

### 2.1 数据库(迁移 0021,ORM 同步加 tables.py)

```sql
CREATE TABLE ai_jobs (
  id UUID PRIMARY KEY,
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  kind VARCHAR(16) NOT NULL,              -- annotate | slice | refresh
  status VARCHAR(16) NOT NULL DEFAULT 'pending',  -- pending|running|done|failed|skipped
  attempts INT NOT NULL DEFAULT 0,
  claim_token UUID,
  heartbeat_at TIMESTAMPTZ,
  last_error VARCHAR(128),
  model_version VARCHAR(64) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_ai_job UNIQUE (asset_id, kind, model_version)
);
CREATE INDEX ix_ai_jobs_status_updated ON ai_jobs (status, updated_at);

CREATE TABLE asset_ai_annotations (
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  model_version VARCHAR(64) NOT NULL,
  tier VARCHAR(8) NOT NULL DEFAULT 'coarse',
  context_path VARCHAR(600) NOT NULL,
  tags_zh JSONB NOT NULL DEFAULT '[]',
  tags_en JSONB NOT NULL DEFAULT '[]',
  description TEXT,
  description_en TEXT,
  searchable_text TEXT NOT NULL DEFAULT '',
  meta JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (asset_id, model_version)
);
CREATE INDEX ix_ai_annotation_trgm ON asset_ai_annotations
  USING gin (searchable_text gin_trgm_ops);

CREATE TABLE asset_video_segments (
  id UUID PRIMARY KEY,
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  idx INT NOT NULL,
  start_ms BIGINT NOT NULL,
  end_ms BIGINT NOT NULL,
  keyframe_keys JSONB NOT NULL DEFAULT '[]',
  tags_zh JSONB NOT NULL DEFAULT '[]',
  tags_en JSONB NOT NULL DEFAULT '[]',
  description TEXT,
  meta JSONB NOT NULL DEFAULT '{}',
  model_version VARCHAR(64) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_ai_segment UNIQUE (asset_id, idx)
);
```

注意:last_error 受控 token 集 `ml_error/minio_missing/minio_transient/decode_failed/asset_gone/poison/partial`(无 ffmpeg_timeout 写入方);updated_at 由 onupdate 维持。

### 2.2 settings(api/app/settings.py 追加,env 名 = 字段名大写)

`ai_enabled: bool = False`、`ai_ml_base_url: str = "http://ms-ml:8000"`、`ai_model_version: str = "smolvlm2-256m@p1+lm1"`、`ai_active_model_version: str | None = None`(None=回落 ai_model_version)、`ai_scene_threshold: float = 0.30`、`ai_max_segments: int = 60`、`ai_max_frames: int = 60`、`ai_slice_max_concurrent: int = 2`、`ai_ml_timeout_s: int = 30`、`ai_worker_max_jobs: int = 8`。追加 `validate_ai_settings()`(active 与已见版本校验只做 warning 日志,启动不炸;api lifespan 与 ai-worker on_startup 均调用)。

### 2.3 enqueue helper(services/arq_pool.py 追加)

```python
async def enqueue_ai_annotate(pool, asset_id: str) -> None   # _job_id=f"ai:annotate:{asset_id}@{settings.ai_model_version}", _expires=1800
async def enqueue_ai_slice(pool, asset_id: str) -> None      # 同上 kind=slice, _expires=86400
# 均带 _queue_name="ai";fire-and-forget 仅 log(沿既有口径)
```

### 2.4 job 函数(app/workers/ai_main.py,AIWorkerSettings)

- `async def ai_annotate_asset(ctx, asset_id: str) -> dict`(func timeout=120 max_tries=2 keep_result=0)
- `async def ai_slice_video(ctx, asset_id: str) -> dict`(timeout=5400 max_tries=1 keep_result=0)
- `async def ai_refresh_context(ctx, asset_ids: list[str] | None = None, folder_id: str | None = None) -> dict`(timeout=300 max_tries=2 keep_result=0;两者至少一个非空)
- cron `requeue_ai_jobs`(minute=0..50 step10, timeout=300)
- `queue_name="ai"`、`keep_result=0`(类属性)、`max_jobs=settings.ai_worker_max_jobs`、on_startup 校验 ai 配置。
- 容器 command: `arq app.workers.ai_main.AIWorkerSettings`。

### 2.5 ms-ml(api/ml/,FastAPI + uvicorn --workers 8)

- `GET /healthz`(同步 def)→ `{"status":"ok","mode":"stub|stub-fault|real","model_version":<str>,"loaded":<bool>}`
- `POST /v1/describe`(async def 内联推理)入参 `{"image_b64":str,"max_tags":int=8}` 出参 `{"tags_en":[str≤8],"description_en":str}`;非 200 或解析失败按正本 §8.3-5 分级。
- stub:确定性假结果(tags_en=["demo","stub"],description_en="stub description");stub-fault:按请求序号奇偶注入非法 JSON / 连接拒绝。
- real:SmolVLM2-256M(lazy import torch;无权重或 MS_ML_MODE 非 real 时永不 import torch —— CI 不装 torch 也能 import app 模块)。
- 文件:api/ml/app.py(≤300 行)、api/ml/model_runner.py(real 推理,lazy torch)、api/ml/Dockerfile、api/ml/constraints.txt(torch-cpu/transformers≥4.48/num2words/fastapi/uvicorn/pillow 钉版)。

### 2.6 HTTP 端点(routers/assets.py 或新 ai.py router)

- `GET /assets/{id}/ai` → 200 `{"annotation": {context_path,tags_zh,tags_en,description,description_en,tier,model_version,meta,updated_at} | null, "segments": [{idx,start_ms,end_ms,tags_zh,tags_en,description,meta,keyframe_count}] | null, "model_version_active": str}`;权限=素材列表同口径(folder can_view 或 public 非敏感豁免,系统 admin 直通);软删/不存在 404;AI_ENABLED=false → 404;无 annotation 也 200(空值)。
- `POST /assets/{id}/ai/keyframe-urls` 入参 `{"segment_idxs":[int] ≤10}` 出参 `{"urls": {str(idx): [presigned_url,…]}}`;同权限 + 每次签发一条 `signed_url_issued` 审计(details 记 count 与对象前缀 keyframes/{asset_id}/)。
- restore_asset 末尾:删 skipped(asset_gone) 行 + 无 annotation 则 INSERT pending + enqueue_ai_annotate(fire-and-forget)。
- batch_move_assets/batch_prefix/update_folder 成功后 enqueue ai_refresh_context(fire-and-forget;asset_ids 或 folder_id)。

### 2.7 搜索第四路(routers/assets.py search_assets)

`ai_enabled=false`:与现状逐字节一致。`ai_enabled=true`:臂 A = 现查询 + `.order_by(Asset.created_at.desc(), Asset.id.desc())`;臂 B = `SELECT an.asset_id FROM asset_ai_annotations an JOIN assets a ON a.id=an.asset_id WHERE an.model_version=:active AND an.searchable_text ILIKE :pattern AND a.deleted_at IS NULL [folder_filter] ORDER BY a.created_at DESC, a.id DESC LIMIT offset+limit` → `IN` 回查实体;两臂各取前 offset+limit → 按 asset.id 去重 → (created_at,id) 重排 → 内存切片。active 取 settings.ai_active_model_version or ai_model_version。

## 3. 组件拆分与工作包(单文件 ≤500 行)

| 包 | 内容 | 文件(新增 N/修改 M) | 预估行数 |
| --- | --- | --- | --- |
| A 数据层 | 迁移 0021 + ORM 三表 + test_db_schema | N: db/migrations/versions/2026_11_03_0021_ai_tagging.py;M: db/tables.py, tests/test_db_schema.py | 180/60/10 |
| B ai 服务+worker | 行认领/心跳/CAS/失败分级(services/ai_jobs.py)、ml 客户端(ai_ml_client.py)、业务管线(ai_pipeline.py)、arq 壳(workers/ai_main.py)、ffmpeg 纯函数(workers/ai_scene.py) | N×5;M: services/arq_pool.py | 5×(200-400) |
| C 链式挂载 | 三族缩略图成功点写行+enqueue(ai_enabled 闸) | M: workers/main.py(+~40) | 40 |
| D 搜索第四路 | search_assets 两臂合并 | M: routers/assets.py(+~60) | 60 |
| E 端点+钩子 | GET /ai + keyframe-urls + restore/move/prefix/folder 钩子 | N: routers/ai_assets.py(如塞不下 assets.py 则独立 router 挂载);M: routers/assets.py, routers/folders.py | 260/30 |
| F ms-ml | stub/stub-fault/real 服务 + Dockerfile + constraints | N: api/ml/app.py, api/ml/model_runner.py, api/ml/Dockerfile, api/ml/constraints.txt | 300/200 |
| G 配置部署 | settings ai_* + compose 两服务(profiles) + deploy_lan restart 降级 + rsync 排除 ml-models | M: settings.py, docker-compose.yml, scripts/deploy_lan.sh(主仓 material-storage/scripts) | 90/40/10 |
| H backfill | scripts/backfill_ai.py | N | 260 |
| I 词表 | services/ai_label_map.py(词表数据+匹配) | N | 280 |
| J web 前端 | 详情面板 AI 识别区+分段区+keyframe 懒加载+采纳;api client+类型 | M: FolderDetailPage 相关组件文件、api client、types;N: AiInfoSection.tsx | 组件级 |
| K/L 测试 | 见 §5 | tests/test_ai_*.py 系列 | — |

依赖:A/B/F/G/I 契约内并行(第一波);C/D/E/H/J 按契约并行(第二波);K/L 测试(第三波,专职测试)。

## 4. 可复用资产盘点

- arq 派发口径:services/arq_pool.py(fire-and-forget+确定性 _job_id+_expires 先例)。
- 行认领/心跳/接管先例:workers/baidu_backup.py(lease CAS/SWEEP_BATCH=50);毒丸/attempts 语义按正本 §8.5(与百度不同,pending 臂不加 attempts)。
- tags 原子合并 workers/main.py `_merge_asset_tags`(AI 结果不用它,独立表)。
- to_thread 铁律(workers/main.py:140-143):ms-ai-worker 内同步阻塞段(ffmpeg/boto3/httpx 同步调用)一律 to_thread;心跳任务 try/finally 取消。
- 日志卫生:worker 日志不落描述/标签/context_path/presigned URL。
- 权限判定形态:routers/assets.py list_assets(:415-431)/search(:668-691)的 folder can_view+public 豁免+admin 直通。
- 审计:services/audit.py signed_url_issued 既有方法。
- 回填脚本形态:api/scripts/backfill_thumbnails.py。
- web:详情面板组件结构按 FolderDetailPage 既有 Drawer/分区模式,AI 区与人工标签区视觉隔离。

## 5. 测试功能点(K/L 测试包依据,对齐正本 §15)

1. 行认领幂等:CAS 谓词分支(done/skipped return、新鲜 running return、陈旧 running 接管);心跳只刷 heartbeat_at;终态 CAS WHERE claim_token。
2. sweeper 三臂 SQL 语义 + 毒丸兜底含 failed + model_version 过滤 + 批上限。
3. ai_annotate_asset 失败分级:ml_error attempts+1、≥5 skipped(poison)、minio 404→skipped/网络异常→failed(minio_transient)、asset 软删→skipped(asset_gone)、健康闸判死置回 pending 不计 attempts、model_version 不一致判死。
4. showinfo pts_time 解析表驱动(科学计数法/缺帧/多切点)、切点聚合(<5s 合并/超上限最短段合并/均匀锚点)、interval=max(60s,ceil(dur/60))、帧数自适应+60 封顶。
5. slice 传输层/内容层二级分级:内容层帧失败→段 meta describe_failed、job 不失败;传输层连续≥2→failed(ml_error)+attempts+1。
6. 搜索:off 态 SQL 与基线一致(可断言 str(stmt) 形状);on 态两臂合并分页正确性(两臂重叠去重/排序/深分页);sensitive 零泄露沿用既有测试口径。
7. GET /assets/{id}/ai 权限三态(can_view 通过/public 豁免/无权 404)+软删 404+AI_ENABLED false 404+审计落一条。
8. keyframe-urls:≤10 段闸 + 签发 + 审计。
9. 链式挂载:三族成功点各触发(ai_enabled on);off 不触发;thumbnail skipped/failed 不触发。
10. restore/move/prefix/folder 改名钩子:行刷新/重派语义;restore 删 asset_gone+补行。
11. 词表:英文→中文映射/词形归一(复数/ing/ed)/未命中保留原文/词表版本并入 model_version。
12. backfill:--force 真重置(done 也重置)/--reset-skipped 排除 asset_gone/批大小。
13. 契约:AIWorkerSettings functions/cron_jobs/queue_name/keep_result=0;compose profiles。
14. ms-ml stub 契约:确定性输出/stub-fault 注入/real 无 torch 时 import app 不炸(lazy)。

## 6. 模糊点与决策记录

- D1 切片=虚拟切片(推荐默认,用户未即时作答;物理切片被否:存储/资产管理复杂度高)。
- D2 两级模型路线(P1 SmolVLM2 粗标+P2 预留 3B 精标;deepseek 建议 SmolVLM2 初筛已采纳为 P1)。
- D3 语义搜索后置 P3(本期只做关键词第四路)。
- 一次交付 P0+P1+P2(用户「结合方案完成代码开发」口径);slice 链与底座同批交付,无 P0/P2 分批挂载窗口。
- 部署仅 dev;prod 等用户指令。
