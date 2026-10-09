# 百度网盘备份导入 实施方案

> 状态：待实施（qplan 审查中） ｜ 分支：`research/baidu-netdisk-import` ｜ 日期：2026-10-08
> 依据：本仓 2026-10-08 调研实测（授权码模式全链路、读取/越界下载放行、账号级限速 0.08 MiB/s、Range 206 断点续传），见 `scripts/changelog.md` 当日记账与 `scripts/task/baidu_*.py` 脚本。

## 1. 目标与范围

用户将百度网盘指定文件夹的内容通过**服务端直连**导入 material-storage 指定项目目录，跳过本地下载中转。

**v1 范围（已拍板）**

| 决策点 | 结论 |
|---|---|
| 入口 | 用户菜单「修改密码」下方新增「百度网盘备份」，打开抽屉 |
| 绑定 | 每个系统用户绑定自己的百度账号（oob 复制码授权）；已绑定显示绿勾，仍可重新授权切换账号 |
| 任务可见性 | 仅创建者可见 |
| 同名冲突 | 默认**跳过**并在进度中展示；用户可对单个跳过文件点「覆盖导入」（failed **或 completed** 任务的跳过行均可）——语义为**清除-再导入**（物理删除旧 asset 与对象，需对该 asset 有 `can_admin`，见 §6/§8） |
| 任务操作 | 单文件重试、全部重试失败（仅 `failed` 任务）、取消、删除记录（仅已结束任务可删） |
| 增量 | 不做，一次性手动任务（任务与网盘目录不形成长期关联） |

**非目标（v1 明确不做）**：增量/周期备份、暂停恢复、单用户多百度账号、百度会员提速验证、敏感目录作为导入目标（见 §3.3，留 v2 单独设计）。

## 2. 关键实测结论（实施约束来源）

1. **OAuth**：授权码模式 + `redirect_uri=oob`，用户在任意可上网设备的浏览器完成授权后复制授权码回填内网 UI；授权码单次有效 10 分钟——**只存 token 不存 code**。access_token 30 天、refresh_token 10 年且**单次有效**（每次刷新响应带新值，须原子覆盖更新；并发刷新须单飞，见 §5.3）。
2. **下载无沙箱**：网盘任意目录（`/apps` 之外）可列、可取 dlink、可下载（206/200 实测通过）——**用户无需把文件夹移进「我的应用数据」**。
3. **限速为账号级**：非会员单线程 ≈0.08 MiB/s；并发 Range 部分连接 403 且聚合不提升 → **按绑定账号串行导入，多线程无意义**。
4. **dlink 8 小时有效**：长任务须自动重取（链接失效类 errno，含 31360；确切分类批次 1 实测确认）；`filemetas` 批量取 dlink 每次最多 100 个 fsid，端点是 `/rest/2.0/xpan/multimedia`（打 `/xpan/file` 同名 method 静默返回空）。
5. **测试态应用频控**：接口 10 次/小时、用户上限 10——**上线前必须通过百度开放平台「应用上线审核」转正式态**（见 §11）。
6. 百度侧 UA 要求 `pan.baidu.com`；下载 URL 必须拼 `access_token` 且 302 需跟随。

## 3. 用户体验流程

### 3.1 入口与抽屉
- `web/src/components/UserMenu.tsx`「修改密码」菜单项下方加「百度网盘备份」——**插入在 `me.password_set` 条件块之外**（未设本地密码的用户也须能看到入口，置于 logout divider 之前）；点击打开 `BaiduBackupDrawer`（组件惯例参照 `TaskCenterDrawer.tsx`）。
- 抽屉头部：绑定状态（已绑定=绿勾 Badge + 「已绑定」；未绑定=灰色提示）；两个按钮：
  - **绑定百度网盘账号 / 切换账号**（已绑定时文案切换，操作相同）；
  - **新建备份任务**：未绑定时 disabled + Tooltip「请先绑定百度网盘账号」。
- 抽屉主体：任务列表（antd List + Pagination），每项展示：来源目录 → 目标（项目名/目录路径）、状态 Tag（清单准备中/进行中/**排队中（并发上限——接口派生 `queued: true`=（running 且 speed_bps=0 且无 importing 行）或（enumerating 且派发超时且（runner_id IS NULL 或租约过期）），**且 runner_id IS NULL 或租约已过期**（活跃租约必非排队——门控退出按设计清租约，该条件消除建链/退避 sleep 等活跃窗口的误显闪烁）——引用 §4 三谓词口径，防频控退避中的活跃枚举被误显；认领后首锚点前（≈200s）短暂误显可接受）**/已完成/已取消/失败）、进度条（文件数 done/total + 字节进度）、预计剩余时间、操作（查看明细 / 取消[进行中，含清单准备中] / 全部重试失败[**任务 failed 且存在 non_retryable=false 的失败行**（全结构性失败的任务按钮不出现/置灰）] / 删除[已结束且非进行中]）。
- 任务明细（抽屉内展开或二级视图）：manifest 表格（原网盘路径、预计导入路径、大小、状态 Tag：等待/导入中/成功/跳过(已存在)/失败/已取消、失败原因 Tooltip），行操作：**重试**（仅失败任务的失败行）、**覆盖导入**（**failed 或 completed 任务的跳过行**）。支持按状态筛选。

### 3.2 绑定流程（BindModal，步骤引导）
1. 前端请求授权链接，展示**可一键复制**的 URL 与说明「在手机或可上网电脑的浏览器中打开，登录百度账号并同意授权」。
2. 用户在授权成功页（oob）复制授权码，粘贴到输入框提交。
3. 后端立即用 code 换 token（10 分钟内、单次），加密落库；成功后弹窗关闭、抽屉头部变绿勾。
4. 失败（code 过期/已用）：提示重新获取授权码；绑定过期（refresh 确认失效）：状态置 `expired`，抽屉提示重新绑定，进行中任务以 `binding_expired` 失败终止。

### 3.3 新建备份任务（NewTaskModal，双栏）
- 左栏：百度网盘文件夹树，懒加载（`GET /backup/netdisk/folders?path=...`），根部列出网盘根目录；已选路径面包屑展示。
- 右栏：项目下拉 + 项目内目录树（复用 `FolderTree.tsx` + `useFolders`，组件需小幅扩展"选择模式+sensitive 禁选"，见 §7）。目标语义：**必须选定一个目录**——可直接选项目内某文件夹；若用户选择「项目根」，系统将自动创建以网盘目录末段命名的承接文件夹（同名复用）；**敏感目录（Lock 图标）禁止选择**（UI 置灰 + 后端校验）。
- 底部：点击「开始备份」创建任务（状态 `enumerating`）→ 抽屉列表出现该任务；ETA 在首次进度回报时展示。文案明确「非会员限速约 0.08 MiB/s，大目录耗时较长；单轮导入上限约 14GB/48h，超限后可用『全部重试失败』继续下一轮（断点续传）；单文件上限 160GB，且超大文件（>130GB）须在 30 天内完成（含排队等待），建议拆分目录」。

## 4. 数据模型（migration：`2026_10_08_0013_baidu_backup.py` 一次建三表，基于 head `2026_09_30_0012`；§10 批次 1/2 为功能分层，非迁移拆分。注意：`tests/test_db_schema.py` 断言表名全集，0013 落地时须同步更新断言并补三表约束断言）

FK 策略对齐现有惯例：`task_files.task_id`→CASCADE、`task_files.asset_id`→SET NULL、`task_files.target_folder_id`→SET NULL、`tasks.user_id`→RESTRICT（并建索引）、`tasks.binding_id`→RESTRICT、`tasks.project_id`→RESTRICT、`tasks.target_folder_id`→**nullable+SET NULL**（目标夹被删后置空，明细展示「(已删除)」）。

约束：`partial unique index uq_baidu_task_active ON baidu_backup_tasks(binding_id) WHERE status IN ('enumerating','running')`——同绑定同时最多一个活动中任务（应用层检查之外的硬兜底，撞唯一约束统一转 409）。

```
baidu_bindings
  id PK, user_id FK(users, ondelete=RESTRICT, unique—one binding per user),
  access_token_enc TEXT NOT NULL, refresh_token_enc TEXT NOT NULL,
  baidu_uid VARCHAR(32) NOT NULL, nickname VARCHAR(128) NULL,  -- bind 后调 xpan/nas?method=uinfo 落库：UI 显示绑定账号；重授权 uid 不变则跳过断点作废（仅清 dlink 缓存——multipart 会话在自家 MinIO，同账号续传无损坏风险）。NOT NULL：uinfo 失败/缺 uid → 本次绑定整体失败（502 提示重试）——否则 NULL==NULL 会让真换绑被误判"同账号"，绕过断点作废防线产出跨账号静默损坏
  access_token_expires_at TIMESTAMPTZ NOT NULL,
  status VARCHAR(16) ('active'|'expired'|'unbound'),   -- unbound=软解绑(密文已清空,行保留供任务历史引用)
  last_authorized_at TIMESTAMPTZ NULL,   -- 仅 bind/重授权（调 uinfo）时刷新——换绑甄别锚点之一
  token_rotated_at TIMESTAMPTZ NULL,     -- 任何 token 覆盖写入（绑定/重授权/refresh）都刷新——403 dlink 甄别锚点（防仅 refresh 过的同账号任务被误判换绑）
  created_at/updated_at (TimestampMixin)

baidu_backup_tasks
  id PK, user_id FK(index), binding_id FK,
  bound_baidu_uid VARCHAR(32) NULL,      -- 创建时从 binding 快照：换绑甄别（409 前置与 not_found 文案）统一比较此快照与当前 binding.baidu_uid
  source_dir VARCHAR(1024) NOT NULL,          -- 网盘所选目录绝对路径（创建时护栏见下；不允许 "/"）
  project_id FK NOT NULL,
  target_folder_id FK NULL,                   -- 创建时解析后的承接目录（见 §5.2）；SET NULL 见上文
  target_auto_created BOOLEAN DEFAULT false,  -- 目标是否为自动创建的承接夹（创建时落定）：仅该类允许在途自动重建（§6 步骤 2）
  status VARCHAR(16) ('enumerating'|'running'|'completed'|'cancelled'|'failed'),
  cancel_requested BOOLEAN DEFAULT false,
  cancel_reason VARCHAR(64) NULL,             -- 置 cancel_requested 时一并写入：user_cancel/binding_replaced（急停走 fail_reason=feature_disabled 直终态化，不经此列）
  retry_count INT NOT NULL DEFAULT 0,         -- 复活次数（audit dedup_key 轮次维度）
  enum_done BOOLEAN DEFAULT false,            -- 枚举完成标记：runner 枚举完成置 running 时同事务置位；复活时 false→重枚举
  total_files INT, done_files INT, failed_files INT, skipped_files INT,   cancelled_files INT,  -- 聚合口径重算；供回摆后被取消任务（终态 cancelled）的进度展示
  total_bytes BIGINT, done_bytes BIGINT DEFAULT 0,
  speed_bps BIGINT DEFAULT 0,                 -- 滚动吞吐（滑动窗口/EMA），ETA=剩余字节/此值
  speed_anchor_bytes BIGINT DEFAULT 0, speed_anchor_at TIMESTAMPTZ NULL,  -- 采样锚点：runner 检查点差分更新 speed_bps（无锚点则窗口算不出、重启后清零重采）
  runner_id VARCHAR(64) NULL, lease_until TIMESTAMPTZ NULL,   -- lease_until 即心跳（续期即心跳，不另设列）
  lease_seq INT NOT NULL DEFAULT 0,           -- 派发版本号：每次派发自增，job 按 expected_seq 认领
  dispatched_at TIMESTAMPTZ NULL,             -- 最近派发时刻：sweeper 节流（NULL=从未派发，必须被接管）
  round_started_at TIMESTAMPTZ NULL,          -- 轮起点（两次复活之间）：认领 COALESCE 保留、仅复活派发与并发门控退出复位 NULL——48h 判停依据（从未认领=NULL 不参与判停）
  fail_reason VARCHAR(512),                   -- 终态失败原因(binding_expired/timeout/...)
  created_at/updated_at

baidu_backup_task_files                       -- manifest
  id PK, task_id FK(index),
  fs_id BIGINT NOT NULL, source_path TEXT NOT NULL,          -- 改 TEXT 不进索引（仅展示用）
  source_size BIGINT NOT NULL, rel_path VARCHAR(1024) NOT NULL,   -- 相对 source_dir
  target_folder_id FK NULL,                   -- 导入时按需建出的目录链（展示"预计导入路径"用）
  asset_id FK NULL,                           -- 成功后关联 assets
  status VARCHAR(16) ('pending'|'skipped_exists'|'importing'|'success'|'failed'|'cancelled'),
  overwrite BOOLEAN DEFAULT false,            -- 覆盖导入标记（清除-再导入，导入时复查 can_admin）
  bytes_done BIGINT DEFAULT 0,                -- 已完成 multipart parts 的累计字节（断点偏移）
  minio_upload_id VARCHAR NULL,               -- MinIO multipart 会话（断点续传载体）
  minio_bucket VARCHAR(63) NULL, minio_key VARCHAR(1024) NULL,    -- create_multipart 时同事务落定；abort 三元组直读（防目标夹被删后 key 无法重建）；bucket 列宽对齐 assets.minio_bucket(S3 名 ≤63)
  attempts INT DEFAULT 0, last_error VARCHAR(512),
  non_retryable BOOLEAN DEFAULT false,        -- not_found 类终态：retry-failed 排除、单文件 retry 409、UI 置灰
  dlink TEXT, dlink_fetched_at TIMESTAMPTZ, dlink_expires_at TIMESTAMPTZ,   -- 8h 缓存；仅存原始 dlink 不拼 access_token（下载时现拼）；fetched_at 供换绑后 403 甄别（勿用 expires_at-8h 反推，时钟偏差会误判）
  created_at/updated_at
  UNIQUE(task_id, rel_path)   -- 唯一键绑 rel_path（source_dir 创建时定长，rel_path ≤600 足以唯一定位行；绑 source_path 会因 source_dir 变长误伤浅目录下长文件）
```

长度护栏（枚举时静态校验，不进下载流程；**结构性失败一律置 `non_retryable=true`：path_too_long/name_too_long/key_too_long/target_sensitive_chain/invalid_name**——重试不可能改变文件名/路径结构，复位空耗轮次）：`source_dir`（创建时，**先 `rstrip('/')` 再取末段**作承接夹名，防尾斜杠取出空名）与 `rel_path` ≤600 字符（超长标 `failed('path_too_long')`；最坏 UTF-8 2400B 低于 DB btree 索引行上限——唯一键绑 (task_id, rel_path)，source_path 仅展示不进索引）；**文件名**超 `Asset.filename` String(512) 字符、或 **UTF-8 >255 字节**（**MinIO 官方 limits：每个 `/` 分隔段上限 255 且受后端文件系统约束——本仓 POSIX 后端（xl 模式按段建目录）会硬性拒绝超长段；AWS S3 无此限制但本仓不是 S3**）或超 **动态上限 = 目标 `minio_prefix` UTF-8 字节数后的剩余 key 预算**（见下）→ `failed('name_too_long')`；**对象 key 须同时满足 ≤1024 字符（列定义）且 UTF-8 ≤1024 字节**——1024 字节是 **S3/MinIO 硬限**（天然低于 DB 唯一索引字节上限），超限 → `failed('key_too_long')`；即：**key 字节预算 1024 = minio_prefix 字节（按 `rstrip('/')` 后口径计——列存储带尾斜杠，folders.py:100-102）+ 1('/') + filename 字节**，prefix 占用越多、文件名配额越小（≥342 个汉字的文件名在浅 prefix 下就会超）。

状态谓词：**活动中 = status IN ('enumerating','running')**；**无租约/租约过期 = `lease_until IS NULL OR lease_until < now()`**；**派发超时（sweeper 节流放行）= `dispatched_at IS NULL OR dispatched_at < now()-interval '10 min'`**。（SQL 中 NULL 参与比较恒为假——**所有涉及时间戳列的谓词必须显式含 NULL 分支**，任务在「创建后未派发」「派发后未认领」两个窗口均为 NULL 状态。）

状态迁移：`enumerating → running` 发生在 **job 枚举完成、manifest 首批 pending 行就绪时**（由 runner 置位，同事务置 `enum_done=true`）；之后进入导入循环。**枚举结果为空（0 行）→ 任务直接 `completed`，列表文案标注「源目录为空」**。**复活型派发步按 `enum_done` 决定目标状态：`false`（枚举期失败：enum_rate_limited/enum_failed/manifest_too_large/枚举段 timeout）→ `status='enumerating'` 重枚举**（靠 manifest `ON CONFLICT DO NOTHING` 幂等续接，防残缺 manifest 被直接"导入完成"静默丢文件、防超护栏任务复活后被全量导入）；`true` → `running` 直接导入循环。**已知浪费（记录）**：枚举期接力的新 job 从第 0 页重走（ON CONFLICT 只保已写行、不保翻页进度），超大目录+频控退避下可能反复重枚举至 48h 上界——v1 接受，v2 评估加枚举游标（last fsid/页 offset）续接。**终态判定：导入循环结束（无 pending/importing 行）时，`failed_files > 0` → 任务置 `failed`（`fail_reason='file_failed'`），否则置 `completed`**——部分文件失败的任务必须是 failed 终态，否则失败行将失去全部重试入口（§5.2 复活型前置都要求 failed）；完整三分支口径（含 cancelled_files>0→cancelled）见 §6 终态化统一规则。

`fail_reason` 取值域：`binding_expired`（绑定失效）/ `timeout`（48h 超时）/ `file_failed`（部分文件失败）/ `enum_rate_limited`（枚举频控耗尽）/ `enum_failed`（枚举其他错误，含枚举段异常中断）/ `manifest_too_large`（超 20,000 文件护栏）/ `feature_disabled`（回滚急停，保留断点可复活）；复活派发步复位 `fail_reason=NULL`。

原则：**不落 MinIO 前先建 DB 行**（manifest 是任务创建的核心产出）；预计导入路径 = 解析后的目标目录 + rel_path，明细接口动态拼出展示，不冗余存全文。

## 5. 后端设计（FastAPI）

### 5.1 新增服务

- `api/app/services/baidu_client.py`：百度 API 客户端（从 `scripts/task/baidu_*.py` 的实测逻辑收敛）：authorize_url()、exchange_code()、refresh_token()、list_dir(folders_only)、listall/recursive_enum()、filemetas_batch(fsids≤100, dlink=1)、download_stream(dlink, Range, 302 跟随（**重定向宿主做 `*.pcs.baidu.com/*.baidupcs.com` 后缀白名单校验**——dlink 毕竟来自外部 API 响应字段，一行代码量级的 SSRF 防御）, UA=pan.baidu.com, **read timeout ≤15s（≤ 租约/4）**)。统一错误对象（百度 errno/HTTP → 友好分类：`auth_expired` / `rate_limited` / `link_expired` / `not_found` / `baidu_permission_denied` / `unknown` 六类，分类规则见 §5.3）。**错误对象进入 `last_error`/日志前必须对 URL query 脱敏**（百度请求 URL 携带 `access_token`，原样落日志即泄密——统一剥除 query 后再输出）。
- `api/app/services/token_crypto.py`：Fernet 对称加密（依赖 `cryptography`，`python-jose[cryptography]` 已间接带入，需在 pyproject 显式声明）。密钥来源：settings `BAIDU_TOKEN_ENC_KEY`；未配置时由现有 `settings.session_jwt_secret`（settings.py:75）经 sha256 派生 Fernet key。**轮换影响**：更改派生源（如 JWT 密钥）后旧密文解密失败 → 绑定按 `expired` 处理需重新授权，须写入运维注意事项。
- `api/app/services/baidu_backup.py`：任务域服务（创建校验、manifest 重试/覆盖/取消/删除的原子状态机、§6 派发/认领/续期 CAS）。
- 文件夹链创建：抽取 `ensure_folder_chain(project_id, root_folder_id, rel_path_parts)` 服务（参照 `routers/folders.py:49` create_folder 的 minio_prefix 计算与 `services/permissions.py:206` bootstrap_folder）。约束：①同名子目录已存在则**复用，且复用分支同样幂等 ensure parent tuple**（直接 write、`is_already_exists_error` 幂等跳过——先例 permissions.py:79-89；**runner 进程内按轮 memoize 已 ensure 的 folder_id 集合**——20k 文件×多层链若逐文件逐层 ensure 会产生数万次 OpenFGA 写放大，memo 后每 folder 每轮仅首次写一次，重试=新轮 memo 失效自愈；"复用"语义 = DB 行存在 **且** tuple 就位——否则崩溃窗口留下的无 tuple 夹会被权限复查永败，形成无自愈循环；不得撞 `uq_folder_project_prefix`，tables.py:124-127；**并发同名建夹竞态用 IntegrityError 兜底**——仿 folders.py:115-119 捕获后回滚改查复用重试；**tuple 写失败（非 already_exists）→ 该行 `failed('folder_tuple_error')` 可重试，重试必须重走 tuple ensure**）；②**不截断原则**：目录名单段超 `folder.name`(255) 字符或 255 UTF-8 字节、或链上 `minio_prefix` 累计超 1024 → 该行 `failed('name_too_long'/'key_too_long')`（截断会让"预计导入路径"与实际落位不一致，与 ③ 统一为不截断）；③**总长校验**：目标 `minio_prefix + rel 目录链 + filename` 超出 §4 的 key 护栏（字符/字节双口径）时**不截断直接该行 `failed('key_too_long')`**（截断会破坏 `key = minio_prefix + '/' + filename` 全局不变量，与 complete_upload 按前缀反验 folder 的逻辑冲突）；④防御断言：链上任何节点不得为 sensitive folder（命中 → 该行 `failed('target_sensitive_chain')` 并置 `non_retryable`）；⑤**路径穿越断言**：段名 ∈ {`.`,`..`} 或含 `/`、`\` → 该行 `failed('invalid_name')` 置 `non_retryable`（网盘侧通常不允许，但 key 拼接是安全敏感汇聚点，一行断言闭合）。
- 资产清除业务流：`purge_asset_storage`（同步 boto3，`services/asset_cleanup.py:25`，重试+超时最坏数分钟）**已存在**；需新抽的是"**活跃 asset 物理删除**"业务流（删行 → purge_asset_storage → **`head_object` 断言 NoSuchKey 证实删除**——purge_asset_storage 对 delete_object 异常仅 log 不抛（asset_cleanup.py:26-30），未证实 → 视为 purge 失败处理 → FGA tuple 清理 → `asset_purged` 审计）供 router 与 worker 共用——不能直接调 `delete_asset` router 端点（硬删分支有"先软删再彻底清除"两步制前置，assets.py:771-773，对活跃 asset 会 409）。**worker 内调用一律 `asyncio.to_thread` 包裹**（同步 boto3 直呼会冻住事件循环，router 侧先例 assets.py:791-794）。

### 5.2 路由（新 `api/app/routers/baidu_backup.py`，挂 `/api/v1/baidu`；受 settings `BAIDU_BACKUP_ENABLED` 开关门控（**默认 false**），未启用时统一返回 **404**；`/auth/me` 响应新增扁平字段 `baidu_backup_enabled`（对齐现有 Me 类型扁平风格，web/src/api/types.ts；批次 1 同步 types.ts）供前端显隐菜单；分页参数对齐仓库惯例 **limit/offset**，assets.py:256-257）

**复活型接口统一前置**：`binding.status='active'`（expired/unbound → 409 提示先重新绑定）且**同绑定无其他活动中任务**（应用层检查 + `uq_baidu_task_active` 撞约束统一转 409）且**任务 `target_folder_id` 非 NULL**（目标夹已删 → 409 提示删除任务重建）且**未跨账号换绑**（`task.bound_baidu_uid` ≠ 当前 `binding.baidu_uid` → 409「绑定账号已更换，请删除任务重建」——创建时快照列，与 §5.3 not_found 文案甄别双保险——与在途自动重建（§6 步骤 1，仅限自动创建的承接夹）不对称属**刻意取舍**：终态复活若自动重建，用户感知不到目标已换位，宁可显式拒绝）；执行「文件行复位（**含 `attempts=0` 重置、`retry_count+=1`、importing 行→pending）+ **`cancel_requested=false, cancel_reason=NULL, fail_reason=NULL` 复位**（防上一轮残留取消位把复活任务"秒取消"）+ 任务目标状态按 §4 `enum_done` 规则（false→enumerating 重枚举 / true→running）+ §6 派发步入队」。在此之上：
- **retry-failed / 单文件 retry**：前置 `task.status='failed'`（cancelled 是用户终态不得复活）。
- **overwrite**：前置 `task.status IN ('failed','completed')` 且行 `skipped_exists`——completed 任务回摆语义：completed→running（重新占用活动名额、暂停删除），行导入完成后任务回 completed（计数**按 §6 聚合重算口径的净效果**：skipped−1、success+1、done 不变——done=success+skipped 下行在 done 集合内部迁移；勿做增量维护）；**回摆期间该行再次失败 → 任务按通用终态判定转 failed**（failed_files>0）。

| 方法 | 路径 | 入参 → 返回 | 说明 |
|---|---|---|---|
| GET | /backup/binding | → `{bound, status, expires_at}` | 绑定状态 |
| POST | /backup/binding/authorize-url | → `{url}` | 生成授权链接(oob) |
| POST | /backup/binding | `{code}` → `{bound:true}` | code 换 token 落库（加密；**应用层限流**：按用户维度 Redis 计数（先例 local_auth）防接口滥用——测试态有百度侧 10 次/小时兜底，正式态放开后需本地防线；**并发双请求撞 unique(user_id) → 回滚改走覆盖更新路径**（folders.py:115-119 同款范式，等价重新授权语义）；**防错绑**：绑定页文案明示「仅粘贴本人百度账号的授权码」——oob 复制码流程无 state 回传，v1 接受粘贴他人授权码的社会工程风险并记录）；**重新授权=覆盖同一 user 行（原子覆盖两 token + uinfo 身份）**，覆盖前处置（**uinfo uid 与旧值相同=同账号重授权 → 仅清 dlink 缓存、跳过①②**）：①取消名下活动中任务（置 `cancel_requested`+`cancel_reason='binding_replaced'`，在途 runner 于检查点消费；无 runner 则 API 侧直接终态化）②**作废全部断点：名下终态任务中仍保留 `minio_upload_id` 的行**（**统一口径（三处用户触发路径——换绑/解绑、cancel、DELETE 任务——共用同一 helper `abort_leftover_sessions(rows, budget)` 与统一 budget 常量**：≤20 行内联 `asyncio.to_thread` 分批 abort（10 行/批）成功后清列并清零 `bytes_done`；>20 行（高失败率任务行级 failed 保留会话，存量可达数十至数百）只 abort importing 行、其余交 sweeper 30d 孤儿通道与 bucket 30d lifecycle 兜底并在响应注明清理异步跟进；BackgroundTasks 若实现为 async def 直调同步 abort 会冻住事件循环，禁用）**（防换绑不同账号后从旧字节偏移续传新账号内容，产出静默损坏文件）** ③**清全部 dlink 缓存**（`UPDATE task_files SET dlink=NULL, dlink_expires_at=NULL WHERE task_id IN (名下任务)`——旧账号 dlink 配新 token 常表现为 403，会被误归类 rate_limited 白耗重试）**；audit `baidu_bind` |
| DELETE | /backup/binding | → 204 | **软解绑**：处置同上（取消+作废断点），再置 status=`unbound` 并清空两列 token 密文（行保留，历史任务 FK 仍引用）；audit `baidu_unbind` |
| GET | /backup/netdisk/folders | `?path=/` → `{list:[{path,name}]}` | 网盘目录树懒加载（folder=1，仅目录；**后端按 start/limit 循环聚合同目录全部子目录**——单页上限 1000，>1000 子目录的网盘目录静默截断不可接受；聚合页数/耗时设上限（超出提示「目录过大，分批浏览」），且**该请求前端单独放宽 timeout**——client.ts 全局 30s，频控退避+多页聚合可能超限）；绑定非 active 返回 **409**（错误码 `binding_inactive`，与创建/复活接口同码同义，前端免特判） |
| POST | /backup/tasks | `{source_dir, project_id, target_folder_id?}` → task | 校验：绑定 active、`source_dir` 须为以 `/` 开头的绝对路径且非根（`/` 不允许——承接夹无名，400 提示选具体目录；相对路径/坏格式在创建期 400，勿留到枚举期才失败）且 ≤600 字符、`target_folder_id`（若传）归属 `project_id`（先例 folders.py:64-66）、`can_upload`(复用 `PermissionsService.check`, 同 folders.py:75-90)、**显式选择 sensitive 目标 → 403+`access_denied` 审计（仓库惯例 403 才落审计）；沿 `parent_folder_id` 链向上核查敏感祖先——普通子夹挂在 sensitive 夹下是被允许的形态（folders.py:67-88 只限制 sensitive 直挂一级），命中敏感祖先同样 403 快败，勿留到导入期逐行 non_retryable**；目标解析：传 `target_folder_id`=该目录，传空(项目根)=自动创建承接夹（名=source_dir **rstrip('/') 后末段，≤255 字符**（Folder.name 列限，超长 400「网盘目录名过长，无法作为目标文件夹名」），**同名复用前校验非 sensitive**——命中敏感同名夹 → 400「目标文件夹名不可用，请改名或另选目标」——**文案不含"敏感"字样**，防无 can_view 者借报错探测敏感夹存在性）后落 `target_folder_id`；活动中互斥=应用层检查 + `uq_baidu_task_active` 唯一约束兜底(撞约束转 409)；**用户维度频控**（Redis 计数，如 10 次/小时，防反复建删任务白耗枚举配额与派发——与 binding 路由同范式）；创建成功即按 §6 派发步入队；audit `baidu_task_create` |
| GET | /backup/tasks | `?limit,&offset` → 分页（**`ORDER BY created_at DESC, id DESC` 稳定排序**，防翻页重复/漏行——先例 assets.py:288 注释） | 仅本人；含进度统计与 ETA |
| GET | /backup/tasks/{id} | → task detail | 本人校验 |
| GET | /backup/tasks/{id}/files | `?status,&limit,&offset` → 分页 manifest | 预计导入路径在此拼装（行级 folder 为 NULL 时回退按 `tasks.target_folder_id`+rel_path 拼；两者皆 NULL 显示源路径并标注「(目标已删除)」） |
| POST | /backup/tasks/{id}/cancel | → 202 | **前置：仅活动中任务可取消，已终态 409**（防回落路径给终态任务留脏 cancel_requested 标志）；置 `cancel_requested`+`cancel_reason='user_cancel'` 交 worker 消费；**API 侧直接终态化的 UPDATE 自带 CAS 谓词并同步 `SET runner_id=NULL, lease_until=NULL`**（`WHERE ... AND status IN('enumerating','running') AND (lease_until IS NULL OR lease_until<now())`，0 行=有活跃 runner/已被并发处理 → 回落为仅置 cancel_requested（**回落 UPDATE 亦带 `AND status IN('enumerating','running')`**，杜绝给终态任务留脏标志）；**必须清 runner**——否则卡在长 purge（to_thread 数分钟无续期）里的旧 runner 恢复后，其收尾写谓词（lease_seq+runner_id）仍命中，交错窗口没关上），终态化后按统一口径清理残留 multipart（内联 `asyncio.to_thread` 分批 abort），不等 sweeper；**202 响应带 `{finalized: bool}`** 区分"已终态化"与"交 worker 消费"两条路径（集成断言用） |
| DELETE | /backup/tasks/{id} | → 204 | 仅终态任务可删；**删除语句自带终态 CAS 谓词 `WHERE id=:t AND status IN('completed','cancelled','failed')`（rowcount=0 → 409「任务状态已变化」）**——防与 overwrite 回摆（completed→running）的并发交错删除活动任务；status='running' 一律 409；**残留 multipart 清理统一口径（与 cancel/换绑共用 helper 与 budget）**：`abort_leftover_sessions(rows, budget)`——≤20 行全量内联分批 abort（10 行/批）、>20 行仅 abort importing 行（**至多 1 行 importing 持活跃会话；failed 行亦可长期持会话、存量可达数十至数百，全量内联会拖垮请求**）后再删 DB 行；**>20 分支行删除后 sweeper 孤儿通道不可达（task_files 级联已删），残留会话依赖 §11 lifecycle 30d（该路径 lifecycle 从兜底升为依赖）** |
| POST | /backup/tasks/{id}/retry-failed | → 202 | 复活型接口；failed 且 `non_retryable=false` 的行→pending（**`enum_done=false` 的任务走重枚举复活不受此限；否则 0 行可复位 → 409「无可重试文件」**）；audit `baidu_task_retry` |
| POST | /backup/tasks/{id}/files/{fid}/retry | → 202 | 复活型接口；单文件 failed→pending；audit `baidu_file_retry` |
| POST | /backup/tasks/{id}/files/{fid}/overwrite | → 202 | 复活型接口（failed/completed 见前）；skipped_exists→pending 且置 `overwrite=true`；audit `baidu_file_overwrite` |

### 5.3 错误映射与 token 刷新（百度 → 任务行为）

| 百度侧信号 | 分类 | 行为 |
|---|---|---|
| HTTP 403 + 权限/路径类 errno（-7 等，批次 1 矩阵核定） | baidu_permission_denied | 行 failed 置 `non_retryable`、last_error 直译 errno——**不进退避**（403 一刀切会把权限错误烧光退避并产出误导性"频控"失败原因；命名区别于目标侧可重试的 target_permission_denied） |
| HTTP 403 + 频控特征 / 5xx | rate_limited | 指数退避自动重试（单文件上限 5 次；**单次退避封顶 ≤20s（≤ 租约/3）或 sleep 分片（每 ≤10s 醒来做一次续期+取消检查）——无上限退避会跨过 60s 租约触发 sweeper 接管，叠加枚举无游标续接会反复从第 0 页重枚举形成振荡**；**耗尽后该文件转 `failed('rate_limited')` 交手动重试**（手动复活时 `attempts` 归零重新计），不无限等待；枚举分页间同样退避（同封顶约束），耗尽则任务 failed；**遇 403 先甄别：该行 `dlink_fetched_at` 若早于 `token_rotated_at`（任何 token 覆盖写入都刷新该列，见 §4 bindings），先重取一次 filemetas 换新 dlink 再归类**——旧账号 dlink 配新 token 常表现为 403，直接归 rate_limited 会白耗重试；`last_error` 文案保留原始 HTTP/errno 以区分"永久性 403"与"频控"） |
| errno 31360（dlink 过期）/ 31045（语义待定） | link_expired | 重新 filemetas 批量取 dlink 后重试；**31045 批次 1 实测确认前先按 auth_expired 试一次 refresh 再回落 link_expired**（官方下载文档与调研脚本注释均指向"token 校验未通过"，直接按链接类处理会白耗退避配额） |
| HTTP 401 / errno -6 / 111（鉴权失效类） | auth_expired | 触发 refresh（单飞，见下）；refresh 确认失效→binding=expired，任务终态 failed(binding_expired) |
| 文件不存在(-9/31064 等) | not_found | 单文件终态 failed，**以一次全新 filemetas 复核确认（两次均 -9 才落 non_retryable=true——抖动期偶发 -9 不可逆置位会让文件永久失去任务内重试入口）**（retry-failed 排除该行、单文件 retry 返回 409、UI 重试按钮置灰）；**文案甄别**：若 `task.bound_baidu_uid` ≠ 当前 `binding.baidu_uid`（换绑过账号，快照列比较），last_error 改为「原绑定账号已更换，建议删除任务重建」——fs_id/source_dir 仍属旧账号语境，直译"文件不存在"会误导 |
| 其他 | unknown | 计入 attempts，达到上限标 failed |

**refresh 单飞**：worker 与 API 两侧均可能触发 refresh，收敛为——对 binding 行 `SELECT ... FOR UPDATE` 后复查 `access_token_expires_at`（**提前 60s 余量判过期**，防时钟偏差）：未到期直接复用现存 token；到期才真正调百度并**原子覆盖两个 token 与过期时间**。**吊销兜底**：同一任务内连续 2 次 auth_expired 且 `access_token_expires_at` 未到期（token 被提前吊销而非自然过期）→ 强制走一次 refresh，仍失败才置 `expired`。**行锁事务内打百度 HTTP 必须带 ≤15s 短超时**（PG MVCC 下读者不阻塞于行锁，风险在写-写长事务持锁；短超时防锁持有放大；**§11 运维项：对该行锁等待 >5s 配告警**——或实现改用 `pg_advisory_xact_lock(binding_id)` 语义等价且无行锁持锁外呼，二选一）。refresh 调用失败先按可重试处理（退避重试**在行锁外进行**——每次重试重新拿锁、复查 `access_token_expires_at` 后再试，防锁持有被放大到分钟级），连续 3 次失败才置 `binding=expired`（防止单次网络抖动误杀绑定、白白消耗单次有效的 refresh_token）。**已知接受限制**：refresh HTTP 成功与 DB 原子落库之间崩溃会丢失新 refresh_token（无法跨 HTTP/DB 原子），绑定将走 `auth_expired → refresh(111 失败) → expired → 引导重绑` 收敛。

## 6. worker 设计（arq，`api/app/workers/` 新增模块并入 `main.py`）

**入队与超时约定**：现有 worker 全局 `job_timeout=60s`、`max_tries=5`（arq 默认）、`max_jobs=4`（workers/main.py:650 区段）。arq 的超时/重试**只能在 functions 定义处 per-function 覆盖**（`enqueue_job` 不接受超时/重试/job_id 之外的语义参数，未知 kwargs 会被当作 job 函数实参传入导致 TypeError）：

```python
from arq import func
functions = [..., func(baidu_backup_run, timeout=3600, max_tries=1)]
```

**不设 48h 级 arq 超时**——arq 的 `in_progress_timeout_s` 按**全部注册 function 的最大超时**计算（worker.py: `max_timeout + 10`），注册 172800s 会让崩溃/重启瞬间在途的**其他普通 job**（缩略图等）的 in-progress key 残留 48h、重启后被无限跳过（现状 ~70s 自愈）；设 3600s 的残余副作用（全部 job 的 in-progress TTL ≈ 3610s）写入 §11 运维预期。改为 **55 分钟接力模式**（**启动断言：`BAIDU_RELAY_AFTER_S + 300 ≤ 3600`**——RELAY 调到 ≥arq 超时则接力永不触发、任务每小时被硬断退化到 sweeper 接管，噪音无告警）：**接力锚点 = runner 进程内自记的 job 启动时刻**（非 DB 列，不受接管影响），检查点发现 `now()-job_started_at ≥ 55min` → 执行**接力派发变体**（见下）入队新 job 后**正常 return**（正常结束即时清理 in-progress key；multipart 断点保证接力无缝）——48h 轮 ≈ 52 段接力；`max_tries=1` **不依赖 arq 自动重试**，重试语义完全由自家状态机+租约接管实现。**预期日志（告警排除规则按此配置）**：优雅重启（SIGTERM cancel）后重入队 job 二次拾取即 **"max retries 1 exceeded"**（warning 级，函数不执行，正是预期——告警排除围绕此关键字配置）；硬杀（kill -9）后 in-progress key 残留期内的跳过日志（"already running elsewhere" 等）为 **debug 级、默认日志级别下不可见**（job 被静默跳过 ≤~1h；**key 过期后旧 job 被重新拾取时会同样打一次 "max retries 1 exceeded" warning，属预期**——任务恢复实际靠 sweeper 新 seq 派发），排障时需临时调 DEBUG。入队一律 `enqueue_job('baidu_backup_run', task_id, expected_seq, _job_id=f"baidu_backup_run:{task_id}:{expected_seq}")`（**`_job_id` 带下划线**；arq `enqueue_job` 的专用下划线参数仅 `_job_id/_queue_name/_defer_until/_defer_by/_expires/_job_try`——**无 per-job timeout/max_tries 通道**，其余 kwargs 一律变成 job 函数实参）；arq job/result key 带 24h/300s TTL 去重效应，故每次派发 `lease_seq+1` 用全新 job_id，arq 层不承担互斥；**入队返回 None 或抛错需重试派发步**（再次自增 seq），Redis 队列整体丢失由 sweeper 兜底接管；arq `retry_jobs` 默认 True 会在 worker 重启后把 CancelledError 的 job 重入队一次，`max_tries=1` 下二次启动直接 "max retries exceeded" 不执行函数——属预期日志，勿据此告警。

**派发/执行分离的租约 CAS（互斥唯一凭证）**：
- **派发步**（API 创建 / 复活接口 / sweeper 接管）：原子 `UPDATE tasks SET lease_seq=lease_seq+1, runner_id=NULL, lease_until=NULL, dispatched_at=now() [,复活时 status/计数/fail_reason/cancel 位复位] WHERE id=:t [AND status IN('enumerating','running') AND (lease_until IS NULL OR lease_until<now())]`（仅 sweeper 带活动+无租约/过期条件），成功后按上式入队。**`round_started_at=NULL` 仅复活型派发步复位**（retry/overwrite = 新一轮；sweeper 接管与接力派发**不复位**——轮起点跨越接力与接管持续累计，48h 判停才可达）。**接管/复活分支必须同步复位在途行**：`UPDATE task_files SET status='pending' WHERE task_id=:t AND status='importing'`（保留 `bytes_done/minio_upload_id/attempts`——单 runner 下至多 1 行；否则导入循环只选 pending 行、卡在 importing 的行将永远无人认领并阻断终态判定，部署重启即触发）。**派发不写未来租约**（否则取消 API 的"无租约→直接终态化"快路径会被伪装租约挡住而回落 cancel_requested，且 sweeper 接管窗口虚增 60s）。
- **接力派发变体**（55min 检查点触发，带所有权守卫）：`UPDATE tasks SET lease_seq=lease_seq+1, runner_id=NULL, lease_until=NULL, dispatched_at=now() WHERE id=:t AND lease_seq=:expected_seq AND runner_id=:uuid`——0 行=已失去所有权（被 sweeper 接管等），直接 return 不入队；影响 1 行才入队新 job。**不可复用 sweeper 条件**（自持新租约恒不匹配，接力永不成功）；**不可无条件执行**（purge 的 to_thread 窗口内失去所有权后会互踩 sweeper 刚写的派发）。**成功后必须同事务复位在途行**（`UPDATE task_files SET status='pending' WHERE task_id=:t AND status='importing'`，保留断点字段）——0.08MiB/s 下单个 16MB part 约 200s，任何 >~264MB 的文件都必然跨越 55min 接力点且正处于 importing，不复位则新 job 选不到该行、终态判定永不满足（与接管分支同一失效模式）；旧 runner 派发后立即 return，无并发写窗口。**enqueue 返回 None/抛错时不重试、直接 return 交 sweeper**（≤10-15min 后接管，断点无损）——UPDATE 已置 `runner_id=NULL`，"再次自增 seq 重试派发步"的所有权守卫在本分支永不命中（该重试策略仅适用于 API 创建/复活/sweeper 三个派发步调用方）。
- **job 启动认领**：`UPDATE tasks SET runner_id=:uuid, lease_until=now()+60s, round_started_at=COALESCE(round_started_at, now()), speed_bps=0, speed_anchor_bytes=0, speed_anchor_at=NULL WHERE id=:t AND status IN('enumerating','running') AND lease_seq=:expected_seq AND runner_id IS NULL`——影响 1 行才执行；0 行=已被更高 seq 取代，安静退出。**`round_started_at` 语义 = 轮起点（两次复活之间），`COALESCE` 保证接力/接管的新 job 认领不刷新它**（否则 55min 接力会把它刷成 now()，48h 判停永不可达）；speed 锚点随认领清零重采。
- **续期/所有权检查**：`UPDATE tasks SET lease_until=now()+60s WHERE id=:t AND status IN('enumerating','running') AND lease_seq=:expected_seq AND runner_id=:uuid`（**含 status 条件**——终态化后立即失去所有权）。执行位置：①下载流内 ≤5s 检查点（同时查 `cancel_requested`/`cancel_reason` 与功能开关）；②**每次 upload_part 之前**（0 行=已被接管，立即中止本文件——防双 runner 交写同一 multipart；**中止路径仅停写，不修改行状态/计数**——所有权已移交新 runner，旧 runner 任何写都会互踩）；③枚举分页间/文件间。硬约束：租约时长 ≥ 2×检查点周期；下载读超时 ≤15s（≤ 租约/4，防单次读阻塞跨过租约）。runner 任何退出路径不再续期即可（接管派发步已置 runner_id=NULL）。
- **48h 超时兜底（runner 检查点自判为主，sweeper 判停为兜底）**：`round_started_at` 是 DB 列且经认领 COALESCE 跨接力/接管持久保留，**runner 在每个检查点（下载流 ≤5s / 每 part 前 / 文件间 / 枚举分页间）自判 `now()-round_started_at ≥ 48h` → 按归位表 `failed('timeout')` 分支自终态化（importing/pending→failed('task_timeout')、保留 multipart）后 return，不再接力**——健康接力链上 sweeper 永远看不到可派发窗口（接力清租约+刷新 dispatched_at 后新 job 秒级认领，10min 节流恰好盖住），主路径判停必须由 runner 自己完成。55min 接力检查点按**固定优先级顺序判定：`cancel_requested` → 急停 flag → 48h 超时 → 接力**（取消意图恒最高——与"取消路径恒 cancelled 优先于聚合判定"一致，任何消费路径同帧命中时结果确定）。sweeper 侧判定保留作故障路径兜底（崩溃/Redis 丢失后接管时先判停再派发）。**排队期豁免**：48h 语义 = **活跃运行时间**（非墙钟）——并发门控退出（未真正运行）时复位 `round_started_at=NULL`，重新认领时 COALESCE 重置轮起点，"排队 47h 只跑几分钟被判超时"不会发生。runner 捕获 `asyncio.CancelledError`（arq 1h 取消/SIGTERM，协程内不可区分）时一律 re-raise 不落终态，交 sweeper 接管路径处理；**部署重启对在途任务无损**。
- **急停（`BAIDU_BACKUP_ENABLED=false` 的收敛链路）**：① `baidu_backup_run` **无条件注册进 functions**（不随开关裁剪——裁剪后重派 job 会报 "function not found" 被 arq 丢弃，任务永不收敛）；② **sweeper flag 感知分支**：活动中任务在开关为 false 时终态化 `failed('feature_disabled')`（**保留 multipart 断点**——回滚属非紧急运维动作，重开功能后用户可 retry-failed 续传，勿走 cancelled 不可逆分支；runner 检查点急停同口径）；③ worker 启动/每文件检查点读 flag 兜底。**注意：部署重启后旧 job 因 arq `max_tries=1` 不会恢复执行，"检查点终态化"只发生在 sweeper 重派发的新 job（≤15min）**——§11 措辞按此为准。
- **取消即时性**：见 §5.2 cancel（"无租约/租约过期"含 NULL 时 API 侧直接终态化，不等 sweeper）。

**任务终态化统一规则（文件行归位表 + 计数迁移）**：

| 任务终态 | pending 行 | importing 行 | multipart 处置 |
|---|---|---|---|
| cancelled（`cancel_reason`=user_cancel / binding_replaced） | → `cancelled` | → `cancelled`（**`overwrite=true` 的行加注 `last_error='原文件已被删除且本任务已取消，如需恢复请新建备份任务重新导入'`**——旧对象已物理清除而新对象未落库，且 cancelled 任务无重试入口） | abort + 清 `minio_upload_id`（放弃进度，用户意图明确） |
| failed('timeout') | → `failed('task_timeout')` | → `failed('task_timeout')`（overwrite 行加注"原文件已被删除"） | **保留** `minio_upload_id` 供下轮 `list_parts` 续传 |
| failed('binding_expired') | → `failed('binding_expired')` | → `failed('binding_expired')`（同上） | abort + 清空（换绑后断点必作废，见 §5.2——此终态大概率伴随用户重新绑定） |
| failed('feature_disabled')（回滚急停，非用户意图） | → `failed('feature_disabled')` | → `failed('feature_disabled')`（同上） | **保留** multipart（重开功能后 retry-failed 续传） |
| failed(enum_*)（枚举期失败：enum_rate_limited/enum_failed/manifest_too_large） | **pending 行原样保留**（复活按 §4 `enum_done=false` 走重枚举，机制自洽） | — | 无会话（枚举期不产生） |
| completed | —（无剩余） | — | 已全部 complete |

**回摆任务被取消**：与普通取消同构——行按归位表复位（已成功的回摆行保留 success、被中断行按 cancelled 归位带 overwrite 注记）；三条消费路径（runner 检查点 / API 直终态化 / sweeper cancel_requested 分支）**先按归位表复位在途行，再落终态：取消路径（cancel_requested=true）恒置 `cancelled`（优先于聚合判定——否则 0 行 manifest 的枚举期取消会被误判 completed）；聚合判定（failed_files>0→failed；cancelled_files>0→cancelled；否则 completed）仅用于非取消路径的终态收敛**——同一动作任何时点消费结果一致（状态机确定性）。

**行级 failed（非任务终态）**：保留 `minio_upload_id/bytes_done/attempts`，供单文件 retry 断点续传（同 timeout 分支口径）；**行级权限复查失败**（can_upload/can_admin 不通过）用 `failed('target_permission_denied')`（**可重试**——权限恢复后 retry 即可，不置 non_retryable；命名区别于百度侧 non_retryable 的 baidu_permission_denied，前端按失败原因区分置灰）。

completed 回摆（overwrite 复活）完成后的计数迁移：`skipped_files -= 1`、success +1、**`done_files` 不变**（done=success+skipped 口径下行在 done 集合内部迁移；行进入 importing 期间聚合重算会使 done 暂时 -1，属预期抖动，接口层对回摆任务平滑展示），无剩余 pending 行即回 `completed`。

**任务聚合计数（done/failed/skipped_files 等）一律由 manifest 行状态聚合重算**（终态化时与每次行状态变更后执行 `SELECT count(*) ... GROUP BY status`），不做增量维护——增量路径（retry 复位 N 行、overwrite 回摆、行再次失败）极易漂移，聚合重算幂等且可校验；**口径：`done_files = success + skipped_exists`（跳过视作已完成）、累计字节 = Σ(success **+ skipped**) 行 `source_size` + importing 行 `bytes_done`**（skipped 行的字节同样"已消化"，completed 任务字节进度才可满格；进度条与 `speed_bps` 锚点同口径——否则单个 57h 大文件下载期间字节进度与 ETA 全程静止）；批次 3 实现按此口径。

**覆盖导入时序取舍（记录）**：现设计为"复查 can_admin → 物理清除旧行/对象/派生对象 → 慢速重新导入"。备选"新 multipart 同 key `complete` 原子替换后再清旧 DB 行/tuple/缩略图"可把丢失窗口压到零，但引入新旧对象共存期的 DB/FGA 一致性问题与两阶段清理复杂度——v1 选简单序 + UI 明示「覆盖导入会永久删除原文件」；**统一规则：所有离开 `importing` 且 `overwrite=true` 的行，无论落何终态（failed/cancelled）一律在 `last_error` 补注『原文件已被删除，如需恢复请重试该行』**（归位表各分支同），让用户知晓需重新触发导入才能恢复。已知代价：长 purge（同步 boto3 最坏数分钟，`asyncio.to_thread` 执行期间无检查点）可能触发一次 sweeper 接管 churn——行为正确（旧 runner 在下一 upload_part 前检查点安全退出，幂等复用兜底），purge 前先做一次租约续期可缓解。

**单任务全流程 job** `baidu_backup_run(ctx, task_id, expected_seq)`：**枚举仅对 `status='enumerating'` 执行**（接管/续轮的 running 任务已有 manifest，直接进导入循环，避免整目录重枚举白耗网盘 API 配额）；枚举（`listall` 优先，失败退化逐层 `method=list` 分页；listall 未实测，批次 1 先验证；正式态 list 频控需批次 1 实测并定枚举退避参数）分页写 manifest，每页间续期+取消检查；**manifest 写入必须幂等**：`INSERT ... ON CONFLICT(task_id, rel_path) DO NOTHING`（冲突目标须匹配唯一键 (task_id, rel_path)，见 §4）（接管/重跑不得重置已有 success/skipped/failed 状态、不得因重枚举 IntegrityError 崩溃循环）；枚举完成置任务 `running` → **导入循环：每轮仅选取 `status='pending'` 的 manifest 行**（单文件 retry 不得触碰其他 failed 行；retry-failed 全量复位后逐行消化）：
1. **建链先行**：`ensure_folder_chain` 建出该文件行的落位目录（**链结果写回 `task_files.target_folder_id`**；每建一层 folder 同事务序内调用 `bootstrap_folder` 写 OpenFGA parent tuple——漏写则导入产物对非 admin 全员不可见且 admin 视角验收测不出；`tasks.target_folder_id` 为 NULL 时：`target_auto_created=true` → 从 project 根重建承接夹写回，显式目标 → 该行 `failed('target_deleted')`）；
2. **权限复查与同名处置**（对象=步骤 1 建链后的**文件行落位目录** `task_files.target_folder_id`——承接夹层查嵌套文件会漏判同名跳过）：复查 `is_org_admin(user_id=task.user_id, organization_tenant_key=<get_default_organization(db) 解析>) OR check(folder, can_upload)`——**必须含 org admin 直通**（仓库约 18 处惯例同款，如 assets.py:72/146/744、folders.py:74；org admin 在 FGA 中不必然持有 folder tuple，纯 check 会让系统管理员的任务全量失败；worker 侧需先经 `services/org.py get_default_organization` 解析 tenant key，先例 routers/auth.py:128-141——初始化脚手架含此项）；（对齐 complete_upload 完成时复查先例 assets.py:146-155，防任务创建后权限被撤仍写入；同一 (folder,user) 的 check 结果在 runner 会话内缓存一个检查点周期 ≤5s——OpenFGA 抖动缓冲，不改逐文件复查语义）；存在性检查（对象=步骤 1 建链后的**文件行落位目录**）：同 `folder_id + filename` 且未删除（`deleted_at IS NULL`）的 asset 已存在 → `skipped_exists`（承接夹同名≠子目录同名，嵌套文件按各自落位目录判）；行 `overwrite=true` 时走**清除-再导入**：先复查旧 asset：`can_admin`（对齐删除权限模型 assets.py:720-747）**且目标夹非 sensitive**（v1 三层禁敏感目标使 sensitive 分支正常不可达，作为防御断言保留：命中 → 一律 `failed('overwrite_forbidden')` 不做 org admin 豁免——assets.py:759-769 的"sensitive 仅系统 admin"口径在 v2 若开放敏感目标再评估） 且**跨资产 key 引用检查通过**（`SELECT count(*) FROM assets WHERE minio_bucket=:b AND minio_key=:k AND id<>:old_id` =0——**不区分软删**：其他行（含回收站软删行）共享同 key 时，purge+重写会让回收站恢复得到新内容的"假资产行"；`uq_folder_project_prefix` 是 `(project_id, minio_prefix)` 维度而 bucket 可跨项目共享，生产已存在跨项目同前缀目录树，跳过此查会静默毁掉他项目指向同对象的活跃资产）则调用 §5.1 抽取的资产清除业务流（`asyncio.to_thread` 包裹；**worker 侧写 `asset_purged` 审计不得带 `target_asset_id`**——行已删会 FK violation，循 assets.py:814-822 的 `target_minio_key + details.asset_id` 口径）——**不可走软删**：PG 默认 NULLS DISTINCT 下 `uq_asset_minio_object_version` 虽不拦截两条 `(bucket,key,NULL)`，但 bucket 未开版本控制，新对象写入同 key 会**物理覆盖**旧对象——软删旧行将变成指向新内容的"假回收站行"（回收站恢复得到错误文件、彻底清除会删掉在用对象）；**同 folder 同名多行活跃、或跨资产 key 引用计数>0 → 该行 `failed('overwrite_ambiguous')`**（逐行人肉消歧不做；**行落 `failed('overwrite_forbidden')` 时清 `overwrite` 标志**——**仅限「旧 asset 存在但权限/引用复查未通过」的情形**；否则 retry-failed 复位后残留标志会再次触发清除流程陷入循环）；不满足 → 该行 `failed('overwrite_forbidden')`；**清除业务流 purge 未证实（head 仍命中）→ 该行 `failed('purge_incomplete')`（可重试；行级 last_error 附结构化 details 快照 bucket/key，重试按快照直接 purge+head 断言，不依赖已删除的 asset 行反查）**；**overwrite 行复查发现旧 asset 已不存在（含 purge_incomplete 重试场景）→ 视为已清除完成、直接进入导入流程，且该行禁用 head 快捷路径直至 success**（防 size 巧合相等时旧对象被当新导入落库）；
3. 懒取 dlink（≤100/批，缓存 `dlink/dlink_fetched_at/dlink_expires_at`、8h 过期重取）；
4. **断点续传载体 = MinIO multipart**（**worker 侧用 aioboto3 异步原语**（已是依赖）——`PresignService` 是同步 boto3（其 list_parts/create/complete/abort 均为同步实现），**同步版禁止在 async 路径直调**（会阻塞事件循环）；批次 3 做 async multipart 封装（含 upload_part 直传与 list_parts paginator），与 download_stream 的 async httpx 同栈）：part_size 走 Settings `BAIDU_PART_SIZE_BYTES`（默认 16MB；**下限 5MiB——S3/MinIO complete 强制除末片外每片 ≥5MiB（EntityTooSmall），启动断言拦截**；list_parts 分页逻辑用 mock paginator 单测覆盖；集成层的分页用例以 **MinIO SDK 直 seed 死会话（1001×5MiB parts）+ mock 下载流**构造（5MiB 下限使最小 seed ≈5.3GB，不做真实下载））：默认 16MB（**单文件上限 = 10,000 parts × 16MB = 160GB**，超限标 failed('file_too_large')；**size=0 的空文件走 `put_object` 直传**——multipart 无法 complete 0 parts）；首次导入 `create_multipart_upload` 时**同事务落定 `minio_upload_id/minio_bucket/minio_key`**；下载流按 part 边界 `upload_part`，每 part 成功后更新 `bytes_done`；**恢复/重试前先 `head_object(bucket,key)`**（**`overwrite=true` 的行禁用本快捷路径**——purge best-effort 失败时旧对象仍在且常见同 size，命中即把旧内容当"新导入"落库、覆盖语义静默失效；覆盖行一律走 list_parts/重传）：对象已存在且 size==`source_size` → 跳过下载直接进步骤 5；**md5 旁证仅对单段形态 ETag（不含 `-N` 后缀，单次 PUT 落成）与 filemetas md5 严格比对**——multipart complete 的对象 ETag 是"分片 md5 的 md5"形态，与内容 md5 恒不相等，不可比对，此类对象只按 size + 步骤 5 跨资产 key 引用预检两道防线放行；**单段 ETag 且 filemetas md5 存在但不相等 → 该行 `failed('md5_mismatch')`（可重试：覆盖行走覆盖流程再 purge 自愈；**非覆盖行重试时先 `delete_object` 清掉该孤儿对象**——跨资产 key 引用预检已确保 count=0，删除安全——再从 0 重传；本仓上传全走 multipart（ETag 恒 `-N` 形态），单段对象的唯一入口是本功能的零字节 put_object 与外部写入）；md5 字段缺失/为空 → 退化为 size+预检两道防线**；否则接管/重启恢复时 **`list_parts` 分页取全（paginator 保留以兼容 AWS 端点；本仓 MinIO 官方 limits 单页至多 10000 parts——160GB 上限文件单页可取全，原"16GB 重下 57h"的 AWS 口径推算对本仓不成立，留档备查）**，从已完成 parts 总字节偏移 Range 续传；**`list_parts` 返回 NoSuchUpload（或 parts 为空且 bytes_done>0）= 死会话**（complete 之后 upload_id 即失效）→ 清空 `minio_upload_id/bytes_done`、重新 `create_multipart_upload` 从 0 重传；完成 `complete_multipart_upload`（**成功后同事务清空 `minio_upload_id`**——防孤儿 sweep/DELETE 任务对已死会话反复 abort；**普通导入（非覆盖）complete 前同样做跨资产 key 引用预检**（`count(assets WHERE bucket=:b AND key=:k AND id<>:new)>0` → 该行 `failed('overwrite_ambiguous')`）——共享 bucket 下静默物理覆盖他项目对象的既有全局风险，批量导入会放大暴露面，导入侧先拦一道）；终态处置按上文归位表（abort 按三元组直读，**无论成功与否 abort 后无条件清列**）。**实现约束：parts 严格按序号串行上传**（断点偏移 = 已完成 parts 总字节的前提是已列 parts 恒为连续前缀；不得并行化 part 上传，否则偏移算法静默失真——代码中留断言）。**不落本地临时文件**（容器重启即失，无法跨进程恢复）；
5. asset 落库：**所有落库路径（multipart complete / head 命中跳过下载 / 零字节 put_object）一律先做跨资产 key 引用预检**（同 §6 步骤 1 覆盖分支的 `count(assets WHERE bucket=:b AND key=:k AND id<>:new)`>0 → `failed('overwrite_ambiguous')`——快捷路径虽无 complete 调用，同风险类依然存在：同夹同名**软删**行不触发 skip、其对象仍在，直接落库即共享物理对象）；**insert 前最后一次租约所有权 CAS**（0 行=任务已被接管/取消，放弃落库并 abort——防"每个 upload_part 前检查"之后 ≤5s 窗口内任务被取消仍多落一个 asset）；复用 `complete_upload` 的字段拼装约定（object key=`{minio_prefix}/{filename}`、`head_object` 取 size/etag、bootstrap_asset tuple、按项目取 bucket `_project_bucket` assets.py:926）；**完整性校验：`head_object` 的 size 与 manifest `source_size` 不符 → 该行 `failed('size_mismatch')` 并留清理通道**（断点偏移错位会产出静默损坏文件，落库前必须拦下）；**multipart 已 complete 但 asset 落库失败**（key 超长/文件夹并发删除等）：文件行 `failed('asset_db_error')`，对象按现有先例记日志留清理通道（assets.py:177-194 口径）；`content_type` 按扩展名推导（filemetas 不返回 mime；Asset 无 md5 列，不涉及）；
6. 缩略图：复用 `complete_upload` 的**三分派**（livp→livp_thumbnail、image→thumbnail、video→video_thumbnail，assets.py:222-231）；
7. 更新单行与任务聚合计数 + `speed_bps`——**收尾写（行→success、聚合重算、计数落库）与步骤 5 的 insert 前最后 CAS 统一用完整谓词：`AND lease_seq=:expected_seq AND runner_id=:uuid AND status IN('enumerating','running') AND cancel_requested=false`**（0 行=任务已被直终态化/接管/取消，静默丢弃收尾写、**补一条 `baidu_task_auto_finalized` 审计（details 带 asset_id/task_file_id/reason=finalize_race）——asset 行已 commit 而非仅对象，无审计则违背资产可追溯**；该窗口的用户可见表现=目录里有文件而任务明细显示已取消，自愈路径=重导任务命中 skipped_exists；仅 lease_seq+runner_id 挡不住"直终态化未清 runner"窗口）。

**sweeper**：新增 cron `sweep_stalled_baidu_tasks`（参照 `mark_expired_approvals`，每 5min），对「活动中 且 无租约/租约过期（含 NULL）且 派发超时（`dispatched_at IS NULL OR < now()-10min`，含从未派发）」的任务分两支：**`cancel_requested=true` → 直接按归位表终态化 `cancelled` 并 abort（UPDATE 同步 `SET runner_id=NULL, lease_until=NULL`，理由同 §5.2 cancel；不再入队，白省一次派发）**；否则先按 48h 兜底规则判停，未超时才执行派发步（CAS `lease_seq+1`+清 runner+更新 dispatched_at；**不复位 round_started_at**——轮起点跨接管累计，否则反复崩溃可无限重置 48h 时钟）并入队。multipart 断点保证接管后续跑幂等；**孤儿清理（仅覆盖"任务行仍在、列未清"的终态残留——换绑/删任务的行已内联清理或级联删除，不经此通道）**：对终态超 30 天且仍有 `minio_upload_id` 的行补 abort（**经 `asyncio.to_thread` 执行，与 §5.1 同规则**）——**逐行 try/except（NoSuchUpload 视为已清理照常清列，防单行异常中断整批）**；**abort 成功后单独事务清空 `minio_upload_id/bytes_done`**（abort 是 MinIO 外部调用与 DB 无原子性可言；abort 抛错保留列由下轮重试、bucket 30d lifecycle 兜底；被清理的断点在用户 retry 时走 NoSuchUpload 路径从 0 重传，属预期并在 UI 文案提示）；**首选 `cron(sweep_stalled_baidu_tasks, timeout=300)` per-cron 覆盖**（arq cron 支持 per-cron timeout，且 300s 低于百度任务的 3610s、不影响全局 in-progress TTL）；≤50 行/批保留为兜底。**已知取舍（记录）**：4 槽被长任务占满时，排队未认领任务每 10min 获得新 seq 的新 job_id（48h 单任务最多 ~288 个排队 job；槽位空闲后被拾取的旧 seq job 认领失败**秒级 no-op 退出**，非静默堆积）；`round_started_at IS NULL` 豁免 48h 判停已防"从未运行被判超时"；**在途任务被接管的最大延迟 ≈ 60s 租约 + 10min 节流 + 5min cron ≈ 15min**（部署重启后进度恢复以此时长为预期）。

**吞吐语义（48h/轮）**：48h × 实测 0.08MiB/s ≈ **14GB/轮**；超限任务终态 failed（`fail_reason='timeout'`），用户可 retry-failed 续下一轮（断点继续）——量级写入前端文案（§3.3/§7）。**已知取舍**：48h 按"活跃运行时间"的近似——①门控排队期豁免（退出复位轮钟）；②崩溃后排队等待计入（接管不复位）；③**门控退出对曾运行过的任务同样清零轮钟**（拥塞期反复进出门控可延长实际上界）——48h 语义 = "自最近一次获得准入起"，验收按此口径；retry-failed 可续。

**槽位影响与并发门控**：长任务占用 `max_jobs=4` 一格，多用户并发时挤压缩略图任务**与既有 cron（`mark_expired_approvals` 每 5min）及 sweeper 自身**——arq cron 与 job 同 worker 池。**v1 缓解（确定性准入，防"瞬时全退"饥饿）**：job 认领成功后判定**本任务是否属"当前活动中任务按 `ORDER BY round_started_at NULLS LAST, created_at, id` 排序的前 2 名"**——每任务独立可判、无互踩（先查后断在 ≥3 任务同轮派发时可能出现"人人看到 2 个新 runner 而集体退出"的欠准入窗口，10min 节流后可复现）；非前 2 名 → 复位 `round_started_at=NULL` 并**清 `runner_id/lease_until`**（UPDATE 带 CAS 谓词 `AND lease_seq=:expected_seq AND runner_id=:uuid`，与全篇守卫风格一致；不留半租约干扰计数与接管判定）后安静退出，交已被 `dispatched_at` 节流（10min）的 sweeper 重派重试——**不可由 job 侧自派发**（新入队 job 按 score 立即可被拾取，会形成认领→退出→再拾取的自旋热循环；若未来确需 job 侧重派必须用 `_defer_by` 显式延迟）——实现百度任务并发**稳态恰 2**（判定口径唯一：活动中任务按 `round_started_at IS NULLS LAST, created_at, id` 排序取前 2；并发认领窗口存在 ±1 超限（最长持续至超限任务下一次认领，≤55min 随接力自愈）；保证缩略图/cron 至少 2 槽可用）；预案（不改代码，仅部署形态）：独立 queue + 独立 `WorkerSettings` 进程。

**进度/ETA**：任务行 `done_bytes` + `speed_bps` 直读，接口层计算剩余时间；runner 在检查点以 `speed_anchor_bytes/speed_anchor_at` 锚点差分更新 `speed_bps`（滑动窗口或 EMA，重启/接管后清零重采；**锚点写与收尾写同带所有权谓词**——被接管后旧 runner 的污染写被挡）；**`speed_bps<=0` 时 ETA 返回 null、前端显示「估算中」**（除零口径）。

**已知接受的竞态（v1 记录，v2 评估）**：①跨用户（不同绑定）并发向同一目标目录导入同名文件——现有 asset 模型无 `(folder_id, filename)` 活跃唯一约束，本功能不顺手改变全局上传语义；②"按绑定账号串行"实为**按绑定行串行**（`uq_baidu_task_active` 以 binding_id 为界）——两个系统用户绑定同一百度账号时可并行，受 §6 并发门控 ≤2 与百度账号级限速兜底，无害但勿误建账号级互斥；③**跨资产 key 引用预检为 check-then-write 非原子**——不同绑定并发导入同 key 可同时通过预检（如需收敛：PG advisory lock 或 bucket 生命周期兜底，v2 评估）；评估留 v2。

## 7. 前端设计（React 19 + antd 6 + react-query，全部新文件于 `web/src/`）

| 组件 | 说明 |
|---|---|
| `components/BaiduBackupDrawer.tsx` | 主抽屉：绑定状态区 + 任务列表（List/Pagination，参照 TaskCenterDrawer），react-query `refetchInterval` 5s（有进行中任务）/15s；菜单显隐读 `/auth/me` 的 `baidu_backup_enabled` |
| `components/BaiduBindModal.tsx` | 步骤式绑定：复制链接 → 粘贴授权码 → 提交；文案含「需在可上网设备上操作」 |
| `components/BaiduNewTaskModal.tsx` | 双栏：左=网盘树（懒加载 TreeNode loadData），右=项目选择（复用现有项目列表 hook，过滤口径=`me.is_system_admin || 我可上传`——org admin 的 my_roles 可能为空但后端允许直通（projects.py:288 返回全量），与 worker 侧双口径一致）+ `FolderTree` 复用；提交创建 |
| `components/BaiduTaskDetail.tsx` | 明细 Table（状态筛选 Tabs + 行操作 重试[失败任务失败行]/覆盖导入[失败或完成任务的跳过行]）；进度条与 ETA |
| `api/hooks.ts` 新增 | `useBaiduBinding/useBaiduAuthorizeUrl/useBaiduBind/useBaiduNetdiskFolders/useBaiduTasks/useBaiduTaskFiles/useBaiduTask*Action`（沿用 axios client `client.ts`） |
| `FolderTree.tsx` 小幅扩展 | 加"选择模式 + disabledIds"（现状仅 onSelect 导航语义、sensitive 仅视觉标识；antd Tree 原生支持节点 disabled），sensitive 节点**及其整棵子树**禁选（普通子夹挂在 sensitive 夹下同样不可作目标）；工作量计入批次 4；**注意 list_folders 不返回 `my_can_*`（models 默认 False，仅 get_folder 填充）**：不可上传目录不在前端预置灰，以创建期 403 报错兜底（或选中后调 `GET /folders/{id}` 取 `my_can_upload` 预判，v1 取前者） |
| `UserMenu.tsx` | 加菜单项（icon 用 lucide `CloudDownload`/`HardDriveDownload`；插入点见 §3.1 条件渲染提示） |

文案基调：明确「非会员限速约 0.08 MiB/s，大目录耗时较长」「单轮上限约 14GB/48h，超限可继续下一轮」「单文件上限 160GB（>130GB 须 30 天内完成，建议拆分）」「覆盖导入会**永久删除**原文件后重新导入（需管理权限；同一任务同时只能有一个覆盖在途——多行覆盖需等上一轮回摆结束后再触发，批量覆盖留 v2）」「overwrite_ambiguous 失败提示：目标位置存在同名文件（可能位于回收站），请先彻底删除后再重试」，ETA 直接展示小时级数字，不粉饰。

## 8. 权限与安全

- 目标目录写权限：任务创建时一次 FGA `can_upload` + **worker 每文件导入前复查**（对齐 complete_upload 先例），拒绝时该文件 failed 并计入审计；**覆盖导入（清除-再导入）需复查旧 asset 的 `can_admin` 且目标夹非 sensitive**（物理删除他人资产不得低于现有删除权限模型；v1 敏感目标被三层拦截，worker 侧再留防御断言：命中一律拒绝、不做 org admin 豁免——与 assets.py:759-769 的“sensitive 仅系统 admin”口径对齐留 v2）；**目标不得为 sensitive folder**（UI 禁选 + 创建校验 + ensure_folder_chain 断言三层）；任务与 manifest 全链路仅创建者可读/操作（user_id 过滤）。
- token 加密落库（Fernet，密钥来源与轮换影响见 §5.1）；日志与 audit **绝不**输出 token/授权码/dlink（含拼 token 前的原始 dlink）明文。
- audit 事件全集：`baidu_bind`（含重新授权切换）、`baidu_unbind`（含其触发的批量取消 `binding_replaced`）、`baidu_task_create/cancel/delete/retry`、`baidu_file_retry/overwrite`、`baidu_file_imported`（**per-file success 落一条**，target_asset_id=新 asset——对齐 complete_upload 每次落库写 `upload` 审计的惯例，资产来源可追溯；dedup_key 沿用轮次维度）；**403 拒绝路径按仓库惯例落 `access_denied`**（folders.py:81-88、assets.py:749-754 同款——权限不足/sensitive 禁选等；binding_inactive 走 409 业务状态、不落 access_denied）；**系统侧终态（sweeper 接管判停/48h 自判/急停）以 `actor_user_id=NULL` + `event_type='baidu_task_auto_finalized'` 落审计**（dedup_key 机制同款支持）。dedup_key 规则 `baidu_task:{task_id}:{event}:{file_id|all}:r{retry_count}:a{attempts}`（含**轮次 r 与 attempt 序号 a**——audit `ON CONFLICT DO NOTHING`：无 attempt 序号会吞同文件多次事件；手动复活 `attempts` 归零而 task_id 不变，无轮次维度则第二轮事件与首轮同键被静默吞掉）。
- 百度应用凭证（AppKey/SecretKey）走部署环境变量 `BAIDU_APP_KEY/BAIDU_APP_SECRET`（hh2 .env，不入库不入仓；`scripts/env/baidu.env` 仅供本仓调研脚本）。
- 解绑/切换账号：软解绑（§5.2）或重新授权覆盖绑定时，其名下活动中任务先取消（与用户取消同机制，`cancel_reason='binding_replaced'`，在途 runner ≤一个检查点周期内停止）并**作废全部残留断点**（§5.2），避免新 token 下到旧账号语境/旧断点续新账号。

## 9. 边界与风控

- 任务规模护栏：manifest 上限 **20,000 文件**（超出则任务失败并提示拆分目录）；**单文件上限 160GB**（multipart 10,000 parts × 16MB；受 lifecycle 30d 约束，>130GB 须 30 天内完成含等待）；路径/文件名/key 长度护栏见 §4（字符/字节双口径）。
- 频控（测试态 10 次/小时）：网盘目录浏览接口 `GET /backup/netdisk/folders` 做 60s (user_id,path) Redis 缓存；worker 枚举不使用该缓存（跨分钟级分页+退避下无收益）；**上线审核转正式态前，生产环境默认关闭入口**（BAIDU_BACKUP_ENABLED=false）。
- 同一目标目录重复导入：skip 幂等保证；覆盖导入为清除-再导入（物理 purge + `asset_purged` 审计）；跨用户同名竞态为已接受限制（§6 末）。
- 网盘端目录中途被删/改名：该子树文件标 not_found 终态，任务继续其余文件。
- **complete 后孤儿对象无自动清理**（收尾写被取消谓词抑制时对象已 complete，lifecycle 只清 incomplete multipart）——与 assets.py:177-194 既有先例同类，v2 评估 bucket 对账任务。
- **空目录不保留**：manifest 只含文件行、目标目录链按文件落位建出——网盘纯空子目录导入后不存在于目标侧（v1 明示，验收口径）。**已知副作用**：建链先于每文件权限复查，权限中途被撤的任务可能已建出部分空目录——v1 不回收（目录无害，可手动删）。
- 创建者权限中途被撤/账号停用：在途任务不中断，由每文件导入前的 `can_upload` 复查逐文件 failed（403 语义）自然收敛——属可接受行为，审计留痕。

## 10. 实施批次（建议按此拆分派发/验收；测试分两层——**纯逻辑单测层**（pytest + mock/内存对象；现有 tests/ 大多如此，但也有直连真实栈的既有先例如 test_notifications_e2e——两层在 tests/ 内并存，新增用例按标注归层）与**DB 容器集成层**（真实 PG/Redis/MinIO + 进程级故障注入，沿用本地 docker 栈方法；manifest 状态机、ON CONFLICT 幂等、partial index、FOR UPDATE、租约 CAS 等依赖 PG 特性的用例**全部归此层**）；标注〔集成〕的用例必须跑在容器集成层）

1. **后端基建**：settings/加密服务/baidu_client（含单测：错误映射、token 刷新单飞与原子性）+ binding 四路由（GET/POST binding、POST authorize-url、DELETE binding）+ **`/auth/me` 增量字段 `baidu_backup_enabled`**（批次 4 菜单显隐依赖）+ **migration `0013`（一次建三表含 partial unique index；同步更新 `tests/test_db_schema.py` 表名全集断言并补三表约束断言）**；**百度错误码分类实测确认**（31045/31360/-6/111/**403 携带的各 errno（含 -7）**用真实 token 触发或查官方错误码表核定，形成"HTTP×errno 分类矩阵"）+ **测试态配额数字（10 次/小时/10 用户）按开放平台官方文档核定（核定与后续 dev 冒烟共用应用配额窗口——用独立最小目录+最少调用完成，§11 冒烟排期避开同小时窗）** + **uinfo（xpan/nas?method=uinfo）字段实测确认（baidu_uid/nickname；nickname 缺失时 UI 回退展示 uid）** + **listall 验证与正式态频控实测**（list 与 filemetas(dlink=1) 分别核定——20k 文件任务每轮至少 200 次 filemetas，若与 list 共享配额会在 dlink 懒取阶段触顶；退避参数按接口维度分别入 Settings；退化方案已备）。
2. **任务域后端**：tasks 全套接口（含派发步 CAS 服务与复活型接口统一前置）+ FGA/sensitive/护栏校验（含 target 归属与 source_dir 非根、`is_org_admin or check` 直通口径）+ ensure_folder_chain 抽取（同名复用+IntegrityError 兜底/不截断护栏/总长跳过/断言四约束）+ **资产清除业务流抽取**（活跃 asset 物理删除，router/worker 共用，worker 侧 to_thread）+ 顺手更正 `tables.py:117-119` `is_sensitive` 的过时 Deprecated 注释（该字段仍是 FGA object_type 判定地基且本功能三层依赖，**禁止 drop**）。
3. **worker**：arq functions 定义（per-function timeout/max_tries）+ 租约认领/续期/取消/急停检查点 + **worker 侧 aioboto3 async multipart 封装（含 list_parts paginator）** + multipart 断点/退避/dlink 重取 + 终态化归位表与计数迁移 + 覆盖清除-再导入（含跨资产 key 引用检查，所有落库路径）+ sweeper cron（含 cancel_requested/flag 感知直终态化分支）+ asset 落库/缩略图三分派；**时延常量收进 Settings**（`BAIDU_RELAY_AFTER_S/BAIDU_ROUND_TIMEOUT_S/BAIDU_LEASE_S/BAIDU_SWEEP_THROTTLE_S`，生产默认 3300/172800/60/600——集成测试注入秒级值，否则接力/48h 用例不可执行）；**worker 侧需自行构造 `PermissionsService`/`AuditService` 实例**（现有 worker 无 OpenFGA 先例，`PermissionsService(settings)` 直构可行——初始化脚手架列入本批次）。
4. **前端**：入口 + 四组件 + FolderTree 选择模式扩展 + hooks + 轮询 + **`web/src/lib/labels.ts` 补新增 audit event_type 的 `tlabel()` 映射**（baidu_bind/unbind/task_* 等，仓库明文惯例：缺 key 不报错但 UI 裸显英文 token）。
5. **测试收口**（**前置交付物：集成测试基建**——容器栈 fixture + 进程级故障注入工具（SIGTERM/kill -9/双 runner 竞速编排）为净新增工程，仓库无现成夹具，验收标准=CI 本地一键起栈并注入上述故障；建议随批次 3 随做随建）：
   - 纯逻辑单测：**URL 脱敏断言（构造含 access_token 的错误 URL，last_error/日志输出不含 token）与重定向宿主白名单拒绝（非 *.pcs.baidu.com/*.baidupcs.com 的 Location 拒绝跟随）**、错误映射、加密/派生密钥、长度护栏判定（path/name/key 字节与字符口径、**文件名叶子段 UTF-8 >255 字节（MinIO 段限）**、file_too_large、**承接夹名 >255 → 创建 400**）、baidu_client 退避策略（含 5 次耗尽转 failed）、token 刷新单飞时序。
   - DB 容器集成（**P0 档=租约 CAS/接管续跑/回摆并发/kill -9 恢复四类必过，其余 P1 档可随批次摊入**）：绑定流、权限 403、sensitive 禁选 403、manifest 状态机 skip/retry/overwrite/cancel、**枚举频控耗尽失败 → 复活后重枚举补全 manifest（enum_done=false 路径）**、**manifest_too_large 复活后再次失败而非全量导入**、**部分文件退避耗尽 → 任务按终态判定落 failed、失败行可复活（终态判定规则）**、**cancelled 任务 retry/overwrite 返回 409**、**cancel_requested 与 48h 超时同帧命中 → 终态 cancelled（检查点优先级）**〔集成〕、**overwrite 回摆与 DELETE 并发：仅一侧生效（DELETE 终态 CAS）**〔集成〕、**completed 任务带残留 cancel_requested → overwrite 复活 → 正常跑完回 completed（取消位复位）**〔集成〕、**55min 接力：单 job 超时不中断任务（新 job 认领续跑）**〔集成〕、**单文件下载中途 55min 接力，新 job 从断点续传该行至 success（importing 行复位）**〔集成〕、**rel_path 带子目录的同名文件命中 skipped_exists（承接夹同名不误判）**〔集成〕、**非 admin 创建者对导入产物有可见性（建链写了 parent tuple）**〔集成〕、**直删 tuple 后重试可自愈（复用分支 ensure tuple）**〔集成〕、**显式目标夹被删 → 行 failed('target_deleted')；auto_created 目标 → 在途重建**〔集成〕、**completed 任务 overwrite 可用且回摆 completed（计数迁移正确）**、**复活型接口撞活动中任务（同绑定）返回 409**、**单文件 retry 后任务回 running 且其他 failed 行不被触碰**、**手动复活 attempts 归零**、**overwrite 无 can_admin 或（防御性）sensitive 目标 → 行 failed('overwrite_forbidden')（用例以直改 DB 构造 sensitive 目标，断言防御层生效）**、**overwrite 同名多行 → failed('overwrite_ambiguous')**、**覆盖导入走物理 purge（防同 key 对象被软删行共享/假回收站行）**、**换绑/解绑后名下残留 minio_upload_id 全部作废（abort+清零）**、**换绑后 retry 不复用旧 multipart**、**枚举重跑 ON CONFLICT 幂等**〔集成〕、**派发后 job 真正启动认领（expected_seq）**〔集成〕、**创建后未派发（dispatched_at=NULL）→ sweeper 接管**〔集成〕、**入队失败/Redis 队列丢失 → sweeper 下一轮必须接管**〔集成〕、**sweeper 对 cancel_requested+无租约直接终态化**〔集成〕、**同任务并发互斥（partial index+CAS 双层）**〔集成〕、**≥3 排队任务同轮派发：确定性准入恰 2 运行、其余排队可最终认领**〔集成〕、**旧 runner 被接管后续期 CAS 失败即中止（不得再写 part）**〔集成〕、**kill -9 后租约过期接管续跑（断言：中断时 importing 的行被复位 pending 并续跑至 success）**〔集成〕、**complete 后崩溃（upload_id 已死）→ 接管后 head_object 命中（size 一致+预检通过，multipart ETag 不做 md5 比对）直接落库成功**〔集成〕、**head 命中路径含同夹同名软删行占位 → failed('overwrite_ambiguous') 而非落库共享对象**〔集成〕、**死会话（NoSuchUpload）自动清零重传**〔集成〕、**零字节文件 put_object 直传**〔集成〕、**size 不符行 failed('size_mismatch') 拦截**〔集成〕、**>1000 parts 死会话接管续传不回退（MinIO SDK 直 seed 1001×5MiB parts + mock 下载流，≈5.3GB，不做真实下载）**〔集成〕、**健康接力链跨 48h 被 runner 检查点自终态化 failed('timeout')（主路径判停）**〔集成〕、**超时任务不被 sweeper 无限复活（故障路径兜底，从未认领豁免）**〔集成〕、**排队期豁免：门控退出的任务不被判超时（round_started_at 已复位）**〔集成〕、**retry 复活后 round_started_at 归零、排队期能正常认领续跑**〔集成〕、**部署重启（SIGTERM cancel）在途任务不误标 timeout、sweeper 接管续跑**〔集成〕、**急停落 failed('feature_disabled')：断点保留、重开开关后 retry-failed 断点续传成功**〔集成〕、**绑定切换时在途 runner ≤一个检查点周期停止**〔集成〕、**multipart 断点续传真实恢复**〔集成〕、**覆盖导入后旧对象已 purge、新 asset 可查**〔集成〕、**purge 失败（delete 抛错未证实）时覆盖行不得走 head 快捷路径、落 failed('purge_incomplete')**〔集成〕、**数百 failed 行任务的 DELETE 不超时、清理行为符合 budget 分支**〔集成〕、入队返回 None 分支〔集成〕。
   - 收口门槛：ruff / mypy（strict）零新增告警 + pnpm lint/build 通过 + `tests/test_db_schema.py` 更新后全绿。
   - 隔离栈 e2e：mock 百度客户端跑全链路 + dev 环境真目录小规模冒烟 + changelog 记账。

## 11. 上线前置与运维

- [ ] 百度开放平台「应用上线审核」通过（解除 10 用户/10 次每小时限制）→ 才允许生产 `BAIDU_BACKUP_ENABLED=true`
- [ ] **hh2 dev/prod 出网连通性预检**：容器内 curl 冒烟 `openapi.baidu.com`（OAuth）与 `d.pcs.baidu.com`（下载 CDN）——调研实测在开发机完成，内网环境外联策略变更会让问题在生产才暴露
- [ ] hh2 dev/prod `.env` 增补 `BAIDU_APP_KEY/BAIDU_APP_SECRET`（可选 `BAIDU_TOKEN_ENC_KEY`；注意 §5.1 密钥轮换影响）；**所有项目 bucket 及后续新建 bucket 必配 `AbortIncompleteMultipartUpload 30d` lifecycle**（bucket 是项目维度且存量多桶——核对存量桶清单并经建项流程/部署脚本统一挂规则，防新桶漏配；**窗口必须 ≥ 断点续传承诺**：该规则按会话**发起时刻**计龄且与活跃上传无关，7d 窗口下 >≈47GiB 单文件（0.08MiB/s×7d）每 7 天被清一次会话、从 0 重传永不收敛——30d 窗口下 160GB 上限文件约 22 天活跃传输可收敛（0.08MiB/s×22d≈148GB，取整口径），但**排队/隔天重试的墙钟同样计龄**，故 §3.3/§7 文案注明「超大文件（>130GB）需在 30 天内完成（含等待时间），建议拆分目录」；sweeper 孤儿清理窗口同步 30d）
- [ ] 部署顺序：migration → api/worker 重启 → SPA 发布 → dev 冒烟（真绑定+小目录）→ prod。**部署重启对在途任务无损**（SIGTERM 以 CancelledError 送达但不落终态，租约 60s 过期后 sweeper 接管断点续跑；无需人工干预）
- [ ] **运维预期**：⓪binding 行锁等待 >5s 告警（refresh 单飞持锁外呼的可观测项，§5.3）；①多用户长任务并发期，`max_jobs=4` 池内缩略图与既有 cron（approvals 过期标记等）会延迟（v1 并发门控 ≤2 缓解）——观察项；②注册 3600s function 后**全部 job 的 in-progress key TTL ≈ 3610s**——硬杀 worker 后残留的普通 job（缩略图等）会 "already running elsewhere" 跳过最长 ~1h 才自愈（现状 ~70s），排障时勿当回归；预案=百度任务切独立 queue+独立 worker 进程（部署形态调整，不改代码）；③`BAIDU_TOKEN_ENC_KEY` 未配置回退派生时**启动打 warning 日志**（跨用途复用 JWT 密钥应被运维感知，生产建议显式配置）
- [ ] **回滚预案**：置 `BAIDU_BACKUP_ENABLED=false` 并按部署流程重启 api/worker——路由即返 404、菜单隐藏、**在途任务由 sweeper（flag 感知分支，≤15min）终态化 failed('feature_disabled') 并保留断点**——重开功能后用户可 retry-failed 续传，无需重建任务（不再打百度 API/写 MinIO；`baidu_backup_run` 无条件注册不随开关裁剪，见 §6 急停）；**`alembic downgrade` 必须在 flag=false 且 sweeper 终态化完成之后执行**（跳过窗口直接回退旧代码+降级会使残留 multipart 会话成永久孤儿）；目标 bucket 的 `AbortIncompleteMultipartUpload 30d` lifecycle（§11 前置项）为最终兜底；三张新表独立可一级回退；SPA 按既有流程回退上一版本
- [ ] 待验证项（不阻塞 v1）：百度会员账号提速幅度；listall 接口行为（批次 1 验证）
