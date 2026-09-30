# 目录导入(百度网盘中转)+ 批量文件名前缀 + 组织级三角色 · 实施方案

> Status: **盲审通过(2026-09-30,16 轮独立盲审收敛,末轮 P0/P1 清零)**
> 范围:material-storage(后端 `api/` + 前端 `web/` + OpenFGA model)
> 关联:`permissions-model-v4.md`(模型依据)、`ROADMAP.md` 已知坑、`ops-manual.md` §10(离线部署前提)
> 并行协调:`project-grant-templates-plan.md` 由他人跟进,见 §6 协调节
> 实施形态:3 个独立可上线的批次,与用户调研点一一对应

---

## 0. 背景与关键调研结论

| # | 需求(2026-09-30 调研点) | 现状结论(代码求证) |
|---|---|---|
| 一 | 百度网盘内容导入内网素材服务器指定项目,**保持原目录结构** | 上传链路一次一文件,`filename` 含 `/` 直接 400(`assets.py:90-91`);前端无文件夹选择,uppy 的 `file.relativePath` 未使用;**内网机 egress 待定**(ops-manual §10),服务器直连百度网盘 API 缺网络前提 |
| 二 | 批量选中文件统一加/去掉**文件名前缀** | 后端不存在任何改名 API;前端多选 + 批量操作栏骨架已齐(打标/删除/下载),但均为逐条循环且翻页清空选中 |
| 三 | 三种角色:艺人(只看自己项目,可传/下/看)、运营(全部项目,可传/下/看)、组长(全部项目,可管理 + **可新建项目**) | `users` 表无角色字段;「看全部项目」当前只有系统 admin(≡ `organization#admin`,权限过宽);建项目与系统 admin 硬绑(`projects.py:45` + 前端三处闸门),**UI 无任何入口可授予建项目能力** |

**选型总纲(业界常用做法)**:

- 需求一走**本地中转 + Web 目录导入**:不依赖服务器 egress、复用既有 multipart 上传通道、百度网盘官方客户端下载满速。服务端直接集成百度网盘开放平台列为留口(§6)。
- 需求二走**后端批量端点**(一次事务改 `assets.filename`,MinIO key 不动),前端批量栏加入口。
- 需求三走 **OpenFGA org 级角色 + project 派生**(ReBAC 标准做法):新增 `organization#operator`(运营)/ `organization#leader`(组长)两个 relation,project 的 `can_*` 派生追加 org 来源——**存量与未来项目天然全覆盖,全部既有 enforce 点零改动自动生效**;建项目守门改为「org admin 或 org leader」。

---

## 1. 批次一:Web 目录导入(保持目录结构)

### 1.1 操作流程(用户视角)

1. 运营在**能访问内网素材库、且装有百度网盘客户端**的办公电脑上,把目标网盘目录下载/同步到本地(客户端「同步空间」可半自动化)。
2. 浏览器打开素材库,进入目标项目的目标文件夹,打开上传抽屉:
   - **拖拽**:把整个本地文件夹拖入 uppy Dashboard;
   - **点选**:新增「上传文件夹」按钮(原生 `<input type="file" webkitdirectory>`)。
3. 目录结构自动重建:拖入 `素材A/原始片/xxx.mp4` → 目标文件夹下自动出现 `素材A/原始片/` 层级,文件落位。纯文件(无目录)行为与现状一致(平铺)。

### 1.2 后端改动

**请求模型**(`api/app/models/__init__.py:109-113` `UploadUrlRequest` 增加可选字段):

```python
relative_path: str | None = Field(None, max_length=1024)
                                   # 相对目标 folder 的完整 POSIX 路径(含文件名),如 "素材A/原始片/xxx.mp4"
                                   # 缺省/空 = 现行为(平铺);显式 max_length 让非法输入在 422 期拦截
```

**create_upload**(`api/app/routers/assets.py:55-96`)流程调整:

1. `relative_path` 存在时校验(**在 can_upload 权限检查通过之后**才做——敏感夹 400 若先于权限抛出,未授权者可借 400/403 差异探测 folder 敏感分类,本仓既有约定是 sensitive 门在权限之后,`assets.py:385-388`;**各段与 basename 先 NFC 归一、再做长度/字节校验**——NFD→NFC 存在少数膨胀用例,先校验后归一会让边界值段名 INSERT 时 500):
   - 用 `/` 分隔逐段检查(归一后):每段非空、**中间段 ≤255(落 folders.name)、末段 ≤512(落 assets.filename,与平铺上传同宽)**、不得为 `.` / `..`、不含 `\` 与控制字符(与 filename 现有的 `/` 拦截互补);
   - `filename` 与 `relative_path` 的 basename **两侧 NFC 归一后**必须相等,否则 400(防前端组装错位;macOS 拖拽时 `file.name` 与 relativePath 同为 NFD,只归一 basename 侧会让全部 macOS 文件误 400);
   - 组装出的最终 key(`目标folder.prefix/relative_path`)长度 **按 UTF-8 字节计 ≤1000**(`minio_key` 列限 1024 字符,但 MinIO/S3 对象 key 上限是 1024 **字节**——深中文目录按字符计 ≤1000 仍可能超字节限,须按 `len(key.encode("utf-8"))` 校验);
   - **目标 folder 是敏感文件夹 → 400「敏感文件夹不支持目录结构导入」**(model v4 中 sensitive_folder 无子夹概念,`asset.parent` 只挂 folder/sensitive_folder 两种)。
2. 目录链 get-or-create:新增 `api/app/services/folder_tree.py`:

   ```python
   async def ensure_folder_chain(
       db, permissions, audit, *, root_folder: Folder, segments: list[str],
       actor_user_id, ctx,
   ) -> Folder:
       """沿 segments 逐级取或建子夹,返回最终文件所属 folder。

       minio_prefix 沿用库内「恒以 / 结尾」约定(POST /folders 的生成规则:
       父prefix.rstrip('/')+'/'+段+'/',根夹 '段/',folders.py:104-112):
       查找键 = (project_id, minio_prefix=父prefix.rstrip('/')+'/'+段+'/'),
       与 uq_folder_project_prefix(tables.py:124)对齐——尾斜杠必须带,
       否则与 UI 建的同路径夹互不命中,目录树出现双份同名夹。
       不存在则 INSERT(name=段, parent_folder_id=前级, prefix=派生含尾斜杠)
       + permissions.bootstrap_folder tuple + audit folder_created(details 加
       "via": "upload_path")。**folder_created audit 行在最终 DB commit 成功
       之后补写**(AuditService 独立 session 即刻 commit——若写在前,rollback
       整批时会留下「目录未建成」的 audit 噪声行)。IntegrityError(并发同建)
       → rollback 后**整链重跑一次**(rollback 会丢弃本请求已 INSERT 的前序段,
       重跑即重新 get-or-create 全链;连续竞速下仍失败则 500,客户端可重试)。
       —— bootstrap_folder 是裸 write,盲目补写会让「往已有目录树导入」
       必 500。规则:本次新建的夹才写 tuple,命中既有行一律不写(避免每文件
       每段一次 FGA read 的调用量);历史孤儿夹修复走独立低频脚本(§6)。
       DB 回滚不连带已写的 FGA tuple 与 audit 行(孤儿 tuple 无害是本仓
       既有约定)。ensure_folder_chain 的事务顺序:**每段 INSERT 不 commit →
       bootstrap_folder 写 tuple → 全部段完成后一次 commit**;任一段的 FGA
       写失败 → rollback 整批新段,**DB 行零残留**(已写的 FGA tuple 无法随
       DB 回滚消失,留无害孤儿 tuple——UUID 主键不复用,重试会走全新 INSERT,
       不与孤儿冲突),用户重试即干净重建(若先 commit 再写 tuple,失败会留
       「行在 tuple 缺」的夹——后续重试走「命中不写」永久无法自愈,complete
       期 can_upload 复检必 403 死循环)。
       """
   ```

   两个必须的限定:
   - **查找不过滤 is_sensitive,命中后分类处置**(若过滤则自相矛盾:同名敏感夹永不命中 → INSERT 撞 `uq_folder_project_prefix`(`tables.py:124`)→ 过滤式重查仍查不到 → 二次 INSERT 再撞变 500,而非预期的 400)。规则:命中行 `is_sensitive=True` → 显式 400——真实风险是**受邀 downloader 静默把文件写进敏感夹**(sensitive 的 `can_upload = can_download`);未受邀者会在权限检查即 403,complete 期 403 也已 abort 分片不残留(`assets.py:152-155`);命中行非敏感但 `parent_folder_id` 与链上期望父不一致(UI 建夹名允许含 `/`,存在 prefix 相同但挂在别处的「异源同名夹」)→ 400 指明冲突;其余命中收养为链节点。
   - **路径段统一 NFC 归一化**(`unicodedata.normalize("NFC", seg)`),**末段(文件名)同样归一**:归一后的 basename 参与 `filename == basename` 校验与 key 拼接,新导入资产的 `assets.filename` 落库即 NFC(存量 NFD 文件名的兼容口径见 §2.1 两侧归一)。**建夹入口同步归一**:`FolderCreateIn.name`(`models/__init__.py:163-169`)现状无归一化,macOS 从 Finder 复制的 NFD 名建夹后,导入侧 NFC 查找仍不命中——只在导入侧归一只修一半;`POST /folders` 归一 **name 与自动派生的 minio_prefix**,**显式直传的 `minio_prefix` 保持原样不归一**(直传值常与既有 NFD 夹逐字节对齐——比如脚本迁移场景,归一后反而查不命中、INSERT 撞 `uq_folder_project_prefix` 变 409)。导入侧 INSERT 落库的 name 即归一化后的段(NFD/NFC 视觉相同,用户无感)。**存量 NFD 夹兜底**:uq 前缀按字节比较,NFD/NFC 两行可并存;NFC 查找未命中时补一次 NFD 兜底匹配,仍无才 INSERT(NFC 形式);**链式前缀一律以上一段命中行的实际 `minio_prefix` 续拼**(兜底命中时即 NFD 形式,保证后续段在该父夹下正确命中,不会并行再建一套目录);存量清洗脚本留口(§6)。

3. 响应 `UploadMultipartCreateOut`(`models/__init__.py:116-120`)**增加 `folder_id` 字段** = 最终落点(可能是新建的深层子夹)。旧客户端忽略新字段,向后兼容。
4. `filename` 的 basename 校验与 key 拼接改用**最终 folder**;`complete_upload` 的 key 前缀校验逻辑不变(它按传入 folder 的 prefix 校验,前端 complete 改传 create 返回的 `folder_id`,见 1.3)。

**权限语义**:can_upload 仍在**目标根 folder** 检查一次(现 :72-77 不动);「uploader 隐含创建 sub folder」是 v4 既有语义(permissions-model-v4.md §5),子夹创建不再逐级 check。新子夹 `bootstrap_folder` 后其 can_upload 自然从父链继承。

### 1.3 前端改动(`web/src/lib/upload-store.tsx` + `PersistentUploadDrawer.tsx`)

- `createMultipartUpload`(:90-101):请求体加 `relative_path: file.meta?.relativePath || undefined`;`filename` 继续传 `file.name`(relativePath 只活在 meta,见下条)。
- `completeMultipartUpload`(:113-121):`folder_id` 改用 create 响应返回的落点 id(setFileMeta 缓存),不再用外层目标 folderId;**create 响应缺 `folder_id` 字段时回落外层目标 folderId**(新前端遇旧后端的确定性行为)。列表刷新:除现有 `['assets', folderId]`(:138、:152)外,**必须追加 folders 树缓存失效**——upload-store 全局层只持有 folderId、拿不到 projectId,用前缀匹配 `qc.invalidateQueries({ queryKey: ['folders'] })` 即可(会连带失效其他项目的树缓存,有意取舍,实现处加注释防后人「优化」回去;FolderTree 的 useFolders 数据源;不加则导入完成后新建子夹在目录树上不出现,页面看似毫无变化,tester 必当「导入失败」报障)。
- PersistentUploadDrawer 加「上传文件夹」按钮:隐藏 `<input type="file" webkitdirectory multiple>`,`onChange` 时 `addFiles`,文件描述符 meta 里带 `relativePath: file.webkitRelativePath`。**读写统一走 `file.meta.relativePath`**(依赖源码事实:`@uppy/core` 4.5.3 的 `#transformFile` 以白名单重建文件对象,**顶层 `relativePath` 会被丢弃**;Dashboard 4.4.3 的拖拽路径本身就写 `meta.relativePath`)——`createMultipartUpload` 改读 `file.meta?.relativePath`,拖拽与点选两条入口同源。relativePath 均含顶层目录名 = 「保持原目录结构」。
- **顶层目录名与目标文件夹同名时**(把「素材A」拖进「素材A」夹 → 素材A/素材A/…):前端 toast 提示确认,路径在 Dashboard 文件列表可见、可移除重拖;不做自动去重。
- restrictions(:82):`maxFileSize` 5GB → **20GB**(视频原片可超 5GB;16MB 分片 × 10000 part 上限 = 160GB,20GB 安全),`maxNumberOfFiles` 10000 不动;PersistentUploadDrawer 的 Dashboard `note` 硬编码文案「最大 5GB」(`PersistentUploadDrawer.tsx:50`)同步改为 20GB,否则误导。

### 1.4 边界与取舍

| 情况 | 处理 |
|---|---|
| 同名重复导入 | 无 (folder_id, filename) 唯一约束,允许重复;**不要指望 `uq_asset_minio_object_version` 兜底**——version_id 为 NULL 时 PG 唯一约束对 NULL 不去重,同名重复导入实际无上限。**NFC 归一还会引入「异码点同名碰撞」**:zip 解压的 NFC 名与 macOS 拖入的 NFD 名归一后落同一 MinIO key,后传覆盖先传、两行 assets 并存(视觉同名,无法按名批量清理)。**本期不做去重/跳过**,依赖批量删除事后清理;记入 §6 留口 |
| 中途取消/失败重试 | uppy 自带 per-file retry;已建目录残留无害(空目录可删,folder delete 已 ship) |
| 子夹建行与 bootstrap tuple 的原子性 | 事务顺序见 §1.2:**INSERT 不 commit → 写 tuple → 一次 commit**,FGA 失败 rollback 零残留、重试自愈;命中既有行一律不写 tuple(避免每文件每段的 FGA 调用量);`POST /folders` 历史残留的「行在 tuple 缺」孤儿夹走独立低频脚本(§6),不在导入链路补偿 |
| 空目录不重建 | 目录链由文件路径派生,网盘里的**空子夹**导入后不会出现(无文件即无链);接受该取舍,确需空目录结构时在 web 里手点 |
| 并发同目录上传 | `ensure_folder_chain` 靠唯一约束 + 重查兜底(标准 get-or-create race 处理) |
| 大批量耗时 | 上传带宽受限于办公电脑上行;建议分批(如每次 ≤2000 文件),抽屉内有进度与失败列表 |
| 目录层级过深/名字过长 | 段长与总 key 长 400 拦截,报错指明第几段 |
| 顶层目录与目标夹同名 | 产生一层同名嵌套,前端提示确认(§1.3),不自动去重 |

### 1.5 测试

- `tests/test_upload_complete.py` 新增:带 `relative_path` create → 断言中间 folder 已建(parent 链与 prefix 正确)→ complete → asset 落最终 folder;不带 `relative_path` 的旧用例不动全绿(兼容);
- 敏感夹 + relative_path → 400;「链上命中敏感行」属防御分支——现实中仅「目标根夹本身敏感」可达(链段查找键恒比一级敏感夹的 prefix 深一层;含 `/` 的异源敏感夹名理论上可命中,且已被 parent 一致性校验同路径兜住),不单列必测用例;`filename` ≠ basename → 400;`..`/空段/超长 → 400;
- 手工冒烟(**两条路径各自的目录树完整性都是必测项**,防 relativePath 读写位置不一致导致点选静默平铺):真文件夹拖拽;webkitdirectory 点选;**导入完成后新子夹须立即出现在 FolderTree**(§1.3 的树缓存失效断言)。

---

## 2. 批次二:批量文件名前缀(加/去前缀)

### 2.1 API

`POST /api/v1/assets/batch-prefix`(assets.py 新端点):

```python
class AssetBatchPrefixIn(BaseModel):
    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=1000)
    action: Literal["add", "remove"]
    prefix: str = Field(..., min_length=1, max_length=128)   # 禁 "/"、禁控制字符、strip 后非空;服务端 NFC 归一化
                                                              #(与批次一口径一致,防 macOS 粘贴的 NFD 前缀
                                                              #  令 already_prefixed / remove 按码点比较不命中;
                                                              #  NFC 归一可能略增长度,归一后复检 ≤128)
```

语义(明确写死):

- `add`:`filename = prefix + filename`;**已以该 prefix 开头的跳过**(防重跑叠加双层前缀);结果长 >512 的跳过;
- `remove`:filename **恰好以 prefix 开头**(大小写敏感)才剥离一次,否则跳过(批量清理已加前缀的场景,不匹配=已无前缀,不应整批失败);剥离后为空串的跳过(计 `empty_result`);
- **前缀比较两侧 NFC 归一**:prefix 服务端归一(见字段注释),比较用 `unicodedata.normalize("NFC", asset.filename).startswith(prefix_nfc)`(add/remove/already_prefixed 同一口径)——存量资产 filename 多为 macOS 拖入的 NFD(`assets.py:167` 原样落库,全程无归一化),只归一输入侧会让 remove 报 no_match、already_prefixed 判空 → 重跑叠加视觉相同的双层前缀,恰是要防的事故。**remove 的剥离实现口径**:`remainder = NFC(filename)[len(prefix_nfc):]`,余量落库即 NFC 形式(NFC/NFD 码点数不同,不能对原串按长度切;与批次一「新导入落库即 NFC」口径合并后,库内 filename 逐步收敛为 NFC);
- 返回 `{renamed: int, skipped: int, skipped_reasons: {too_long: n, no_match: n, already_prefixed: n, empty_result: n, deleted: n}}`(键固定 ASCII,前端做中文映射;`deleted` 桶语义 =「已删除或已不存在」——软删行与跨页选中期间被彻底清除的 stale id 都归此桶,前端文案不细分)——**尽力而为 + 结果报告**,是批量操作业界常规。

**权限**:按 `folder_id` 分组,每组做一次 `can_upload` check(对齐 `update_asset_meta` 的权限语义,`assets.py:537-542`;敏感夹按 `sensitive_folder` 类型);系统 admin 直通。任一组无权限 → 403 整批不执行,**文案笼统**(「所选部分或全部文件无操作权限」,**不带 folder 名**,对齐既有反探测约定——`assets.py:278` 不暴露 folder 存在性);诚实拒绝避免改一半,本期前端形态是单目录内多选,跨目录混选非预期。

> 运营角色(批次三上线后)经 org 派生对全部普通目录具有 can_upload → 也可跨全项目批量改名/打标。这与「打标 = can_upload」的既有语义一致(`assets.py:537-542`),**有意为之**;角色矩阵中「不可管理」指成员管理/敏感夹邀请/删项目等 admin 能力。同理,**敏感夹里仅受邀 downloader(非 admin)也有批量改名能力**(sensitive_folder 的 `can_upload = can_download`,store.fga.yaml:104)——与该夹内打标权限同语义,接受;若产品要求收紧到 admin 再议。

**实现**(单事务,写死形态):
0. `asset_ids` 先 `dict.fromkeys()` 去重(SELECT 的 IN 语义天然按集合算,不去重会让「提交数 − 命中数」把重复 id 误计入 deleted);
1. `SELECT a.id, a.filename, a.folder_id, f.is_sensitive ... JOIN folders f WHERE a.id IN (...) AND a.deleted_at IS NULL`(folder_id/is_sensitive 供权限分组);
2. Python 端逐行按上述语义算新名(**两侧 NFC 归一**),得出「应改 / 各原因跳过」清单;`add` 的结果串同样按 `NFC(prefix + NFC(filename))` 落库(与 remove 余量口径一致,库内 filename 逐步收敛为 NFC);
3. 批量 UPDATE 用 Core 语句、**单事务内逐 id UPDATE**(**不用 ORM 脏对象 flush**——后者遇并发 hard purge 抛 StaleDataError 把整批变 500,`assets.py:561-565` 既有处理先例;也不写成单条 `update().WHERE id IN(...) RETURNING`——add 场景每个 id 的新名各不相同,单语句单 SET 表达不了,而 asyncpg 方言的 executemany 又不累积 RETURNING,会让对账全落归因分支;逐 id 最简且天然拿到 rowcount,与 remove 侧「按 id 粒度」统一口径;文件量上限 1000、单事务内逐行 UPDATE 可接受),每条 `WHERE id = :id AND deleted_at IS NULL`;**add 场景谓词再带 `NOT starts_with(normalize(filename, NFC), :prefix)` 二次防线**(并发双提交两侧 SELECT 都判「无前缀」会叠双前缀,谓词拦住后计入 already_prefixed;用 PG `normalize(filename, NFC)` 与 Python 判定同口径——裸 `starts_with(filename, ...)` 对存量 NFD 名字节不匹配拦不住;用 `starts_with()` 而非 `LIKE prefix || '%'`——后者 `_`/`%` 通配符会让 `final_` 误拦 `finalX01.mp4`,如须 LIKE 则转义 `\`/`%`/`_`,仓库先例 `_escape_like` `assets.py:902-904`);**remove 侧 WHERE 同为按 id 粒度、不加字节级 starts_with 谓词**(字节级谓词与两侧 NFC 归一口径不对称,存量 NFD 名会静默不命中;并发窗口的罕见 lost-update 可接受);
4. **对账**:未更新的 ids(逐 id UPDATE 的 rowcount 为 0)追加一次 SELECT 归因——`deleted_at IS NOT NULL` → deleted,`NFC(filename)` 以 prefix 开头 → already_prefixed,**兜底:原始字节 `starts_with(filename, prefix)` 命中 → also already_prefixed**(极端窗口:前缀末字符为可组合基字符时,Python 侧 NFC 判定与谓词的原始字节比较可能不一致,兜底保证任何差额都有归因桶);SELECT 阶段就查不到的 id(提交数 − 命中数)同样计入 deleted。保证 `renamed + skipped` 与提交数严格对账,§2.4 的逐原因断言可写。

403 时写 `access_denied` audit(变更类端点既有先例:`create_upload` `assets.py:79-87`、`update_asset_meta` :544-553 同款,记录「谁试图批量改名」的安全信号)。**MinIO key 不动**(下载文件名由 `assets.filename` 动态生成 Content-Disposition,纯 DB 改名即改变用户看到的文件名;对象 key 保持是既有架构约定,filename 与 minio_key 本就是分离字段)。

**audit**:一条聚合事件 `asset.batch_renamed`(details:`action` / `prefix` / `renamed` / `skipped` / 采样前 50 条 `{id, old, new}`,超出只计数不展开)。`web/src/lib/labels.ts` 补中文映射(「批量重命名」,#124 约定;**映射键与后端 event_type 逐字相等**——现存错位 `asset.tag_updated`(`assets.py:569`)↔ `asset_tag_updated`(`labels.ts:20`)的修法:**labels.ts 补点号键 `asset.tag_updated`,后端 event_type 不动**,避免历史 audit 行按 event_type 过滤时跨两个值)。

### 2.2 前端(`web/src/pages/ProjectDetailPage.tsx`)

- **跨页保留选中**(**两处**翻页清空都要删:compact :564 与桌面 :920):antd Table `rowSelection`(:877-880)加 `preserveSelectedRowKeys: true`,compact 卡片模式(:399、:501)选中 state 同规则;**切换 folder 仍清空**(:102 保留)——批量栏计数本身已按 `selectedIds.length` 显示(compact :591、桌面 :834/:841/:860),本项真正要改的只有「翻页不清空」;
- **自绘全选框改为「只增删当前页」**:桌面 actions-bar 与 compact 的自绘全选(:810、:501)现状是 `e.target.checked ? assetItems.map(a => a.id) : []`,preserve 下第 2 页点取消会清空全部页选中。改为对当前页 id 做**并集(勾选)/ 差集(取消)**,勾选态按「当前页 id 是否全在 selectedIds」计算。antd Table **内置**表头全选在 preserve 下天然就是该语义(v6 `useSelection` 的 onSelectAllChange 从全量已选 keySet 做并/差),**不要去改它**。
- **既有三个批量操作同步切换为 `selectedIds` 全量口径**——它们当前消费的 `selectedAssets` 只含当前页(`assetItems.filter`,:111-114),跨页保留选中后会「显示 N、实际只操作当前页」静默漏操作:批量下载(:156)与批量删除(:160)本就是按 id 逐条循环,改遍历 `selectedIds`;**跨页未加载的 id 没有 Asset 对象、取不到 filename**——下载场景**定案:占位名 `asset_<id前8位>.<按 content_type 推断的扩展名>`**(裸 UUID 无扩展名不可读,取不到 content_type 时回落 `.bin`),**403 且无对象时无法弹「申请权限」(需完整 Asset)——计入「需申请」聚合计数提示**,失败 toast 对未加载项**按 id 聚合计数展示**(不再逐文件 `${a.filename}: …`);`handleBulkDelete` 的空尾页回退判定(:168-170 以「当前页行数」为基准)随全量口径同步复核改写;BulkTagModal 提交同理按 id,**但其跨页合并语义必须后端化**——现状是前端用已加载行的 `user_labels` 做客户端合并(:951-963),后端对 user_labels 是整条替换(`assets.py:555-556`);跨页未加载的 id 前端没有旧标签,只发新标签会把旧标签**清掉**。改法:`AssetMetaUpdateIn` 增加 `labels_mode: Literal["merge", "replace"] = "replace"`,merge = 服务端与 DB 现值取并集(**顺序写死:DB 现值在前、新标签追加在后**,前端 chips 展示顺序因此确定),单文件现行为零变化;BulkTagModal 批量路径改传 merge,不再依赖已加载行。BulkTagModal「文件清单」展示改为「已选 N 个(清单为当前页已加载项)」。右栏 `AssetSummaryPanel selected={selectedAssets}`(:934)同为当前页口径,面板标题注明「(当前页)」与批量栏全量计数区分。批量下载跨页放大后加阈值确认(选中 >20 个先提示);zip/打包下载列 §6 留口。
- 批量栏加「批量前缀」按钮(**桌面与 compact 批量栏同加**——compact 现有批量操作栏在 `ProjectDetailPage.tsx:574-615`,运营/组长在移动端用批量前缀是合理场景;**disabled 门控随打标同款 = `folder.my_can_upload`**,桌面 :831-833、compact :596 同口径)→ Modal:action 单选(加前缀/去前缀)+ prefix 输入 + **预览**(基于当前页已加载的选中项取前 5 个文件名算改名前后对照,并明示「预览仅当前页,共已选 N 个」;提交按 `selectedIds` 全量分批,后端按 id 处理,不依赖前端持有文件名)+ 确认;
- 前端类型同步:`web/src/api/types.ts` 与 `hooks.ts` 的 meta update body 加 `labels_mode` 字段(§2.1 后端新增,前端不同步则 TS 拿不到);既有批量操作的失败 toast 对未加载页的 id 取不到 filename,**按 id 聚合计数展示**(不再逐文件 `${a.filename}: …`);
- 提交:选中 >1000 时前端按 1000 分批顺序调用(**任一批失败即中止**,toast 报「已完成 k/n 批」),汇总 toast「已重命名 N 个,跳过 M 个(原因)」;完成后刷新列表并清空选中。

### 2.3 边界与取舍

| 情况 | 处理 |
|---|---|
| 去前缀后与同目录现有文件同名 | 允许(系统本就允许同目录同名,key 不冲突);不额外拦截 |
| 误操作恢复 | 无 undo;`add` 的逆操作即 `remove`(同前缀),方案明示;audit 有采样记录 |
| 盲搜/标签索引 | filename 改动后 GIN trgm 索引由 PG 自动维护,盲搜(`GET /assets/search`)即刻生效 |
| **文件夹前缀** | **不做**——牵动 `minio_prefix` 子树级联与存量 key 迁移,ROADMAP D iter2 已标低优先级;文件名前缀已覆盖需求 |
| 回收站内文件 | `deleted_at IS NOT NULL` 的不在 SELECT 范围,天然跳过 |

### 2.4 测试

新 `tests/test_batch_prefix.py`(容器内,沿用 Evan/outsider fixture):
add 全成功;add 时已带前缀的跳过(already_prefixed);remove 含不匹配(部分 skipped);**NFD 存量文件名 + NFC 前缀两侧归一命中**(防 macOS 场景失效);无权限用户 403;>1000 拒绝(422);空结果名/超长跳过;软删文件跳过(含 SELECT 与 UPDATE 间并发软删);敏感夹文件按 sensitive_folder check;`labels_mode=merge` 并集生效且 replace 默认行为不变。
前端手工冒烟补:跨页勾选后全选/取消全选只影响当前页;翻页后批量操作按全量 selectedIds 生效;跨页批量打标不清空未加载页的旧标签。

---

## 3. 批次三:组织级三角色(运营 / 组长 / 艺人)与「可新建项目」

### 3.1 角色矩阵与落法

| 角色 | 语义 | 落法 |
|---|---|---|
| **运营** | 看全部项目;可上传/下载/查看;不可管理、不可建项目、不进管理后台 | OpenFGA `organization#operator`(`[user, group#member]`) |
| **组长** | 看全部项目;可管理(成员/敏感夹/删除/改名);**可新建项目**;不进管理后台 | OpenFGA `organization#leader` |
| **艺人** | 只看被授权的项目;可上传/下载/查看 | **不加任何组织级机制**——就是现有的项目级 viewer+downloader+uploader 授权(成员抽屉逐人/逐组配,现状能力),方案仅做映射说明 |
| 系统管理员 | 全权 + 管理后台 | 现状 `organization#admin`,脚本授予,不动 |

> 注:文件名前缀与打标属 **can_upload** 语义(§2.1),运营同样具备;矩阵中「管理」专指成员管理、敏感夹邀请、删项目等 admin 能力,验收时勿把「运营能批量改名」当缺陷。另三条边界口径:(a) 组长「管理」中的改名指**文件级**(批次二批量前缀)——文件夹改名 API 不存在(ROADMAP 低优先级),删除指文件删除与空夹删除,项目级删除/改名的 API 与入口亦不存在;(b) 组长可经 can_admin 自邀进敏感夹(invite 端点只查 can_admin,permissions-model-v4.md §6),与既有 project admin 完全同权,「默认不可见」指未自邀时;另 #109「最后一个 admin」不变量按**直接 admin tuple** 计数(`projects.py:521-534` 走 list_users admin,不含 org 派生)——组长在场时撤掉最后一个直接 admin 仍 409,语义保守无害,勿当回归修;(c) 运营可删普通**空**夹(空夹删除门槛是 can_upload,`folders.py:263-412`),属 uploader 既有隐含语义;(d) 运营(org 派生 can_upload)可在任意项目**新建敏感夹**且创建者自动获 invited_downloader(建夹门槛 = project.can_upload,`folders.py:84-89`,#87 语义)——与既有 uploader 行为一致、非新增暴露,验收时勿当缺陷;(e) 运营/组长经 org 派生可**创建分享链接**(asset 需 can_download、folder 需 can_view,`share.py`),也可**发起**下载/进夹申请(发起本身无权限门槛);但**审批需 can_admin**(`approval_service.enforce_admin_for_target`)——仅组长(及项目 admin/系统 admin)可审批,运营不能,验收时勿把「运营不能审批」当缺陷。

为什么用 FGA org 级派生而不是「每项目给运营组/组长组显式授权 + 建项目时自动授」:后者把「全部项目」这个不变量寄托在创建时钩子上,存量要回填、绕过 API 建项目即破,且与 project-grant-templates-plan 的 initial_grants 纠缠;org 级派生是 ReBAC 的标准形态,**存量/未来项目零回填全覆盖**。

**stealth 项目注意**:`visibility='stealth'` 的语义是「完全隐藏、只 admin 主动邀请」(`tables.py:93-98`);org 派生后 operator/leader 经 `list_objects(can_view)` 必然可见——stealth 对运营/组长失效。视为预期(组长本就全管);若未来出现「需对组长也隐藏的项目」,本期不支持(§6 留口)。
**单 org 前提**:org 派生只经 `project.org`(默认组织)生效,现网全部用户/项目挂在默认 org;若未来多 org,operator/leader 只覆盖默认 org 的项目——本期按单 org 设计,不处理跨 org 语义。

### 3.2 OpenFGA model 改动(`material-storage/poc/openfga/store.fga.yaml`)

```fga
type organization
  relations
    define admin: [user, group#member]
    define member: [user, group#member, department#member]
    define operator: [user, group#member]   # 运营:全部项目 可看/可传/可下
    define leader:   [user, group#member]   # 组长:全部项目 可管理 + 可建项目

type project
  relations
    define org: [organization]
    ...                          # admin/viewer/downloader/uploader/explicit_downloader 原样
    define can_view:     admin or viewer or downloader or uploader or explicit_downloader
                         or operator from org or leader from org
    define can_download: admin or downloader or explicit_downloader
                         or operator from org or leader from org
    define can_upload:   admin or uploader
                         or operator from org or leader from org
    define can_admin:    admin or leader from org
```

- **风险等级:加新 relation,零风险**(CLAUDE.md 约定:不改名、不加 condition,存量 tuple 不受影响);`project.org`(:50)已存在,`operator from org` 直接可用。
- folder/asset 的 can_* 全部从 parent 继承 → 运营/组长对全部**普通目录**的传/下/看、组长的管理,在所有既有 enforce 点(assets/folders/projects/share 的 `is_system_admin or check(...)`)**零改动自动生效**。
- **sensitive_folder 不改**:保持完全独立——运营/组长默认**看不到**敏感夹(仍需邀请),组长的 `can_admin` 从 project 继承可管理敏感夹但不可见,与现有「project admin 语义」一致。方案视为特性而非缺陷(敏感内容最小可见面)。
- yaml 的 tuples/tests 段补 operator/leader 用例(`fga model test` 应全绿)。
- **部署动作**:`cd api && bash scripts/openfga_write_model.sh` push(脚本在 `api/scripts/` 下,不在仓库根;**脚本默认 HOST=server2 公网机且经 `ssh root@$HOST` 直连——hh2 内网 dev/prod 各有独立 OpenFGA store,且开发机→hh2 走跳板反向隧道,脚本直连跑不通:须在目标机本地跑,或为 SSH 配 ProxyJump**)+ 重启对应环境的 ms-api/ms-worker(.env 未固定 MODEL_ID 自动取 latest)。

### 3.3 建项目守门(UI 可授予的「新增项目」权限)

- `api/app/deps.py` 新增:

  ```python
  async def require_project_creator(...) -> CurrentUser:
      """org admin 或 organization#leader(组长)可建项目;403 文案与 require_system_admin 区分。"""

  async def get_is_project_creator(...) -> bool:   # bool 变体,给 /me
  ```

  实现 = 现有 `is_org_admin` check OR 新增 `PermissionsService.is_org_leader`(仿 `permissions.py:433-440` 的写法,check `leader` on organization)。default org 缺失时的行为对齐现状:`require_project_creator` 报 500(同 `require_system_admin`,`deps.py:205-206`)、`get_is_project_creator` 回落 False(同 `deps.py:229-230`)。**不给 operator 单独建项目能力**(角色矩阵如此;若未来需要再拆 `project_creator` relation,留口 §6)。
- 组长经弱门 `require_admin`(`deps.py:170-190`,其 `has_any_project_admin` = list_objects(can_admin))在新 model 下自动通过 `GET /users` / `GET /groups`(`users.py:40`、`groups.py:37`)——组长用 SubjectPicker 管成员正需要这两个搜索接口,**期望行为**,勿当回归修掉。
- `create_project`(`projects.py:45`)守门由 `require_system_admin` 换 `require_project_creator`;`admin_user_id` 必填逻辑不变——组长自建时前端默认填自己,`minio_bucket` 沿用前端默认 `ms-dev`(NewProjectModal.tsx:44、:82),组长无需理解技术字段。
- `/me`(`auth.py:120-158`)响应增加 `is_project_creator: bool` 与 `org_role: "operator" | "leader" | None`,**leader 优先**:先 check leader,命中即返回 `"leader"`,未命中再 check operator——operator/leader 是两个独立 relation,同一 user/group 可能被同时配进两张角色卡,顺序不写死会让双角色用户拿到 operator 而丢掉全部 leader 闸门(建项目按钮、项目卡管理入口)。系统 admin 不标注 org_role(已有 `is_system_admin` 字段)。
- 前端闸门改造(三处,语义分开):
  - ProjectsPage.tsx:62-79 与 NewProjectModal.tsx:57:新建项目入口由 `me.is_system_admin` 改为 `me.is_project_creator`,提示文案同步;
  - AppHeader.tsx:107(管理后台菜单)**保持 is_system_admin**——运营/组长不进管理后台;
  - 移动端 `MobileTabBar.tsx:46` 的管理三 tab 同吃 `is_system_admin`,**保持不动**(点名防误改);
  - `web/src/api/types.ts` 的 `Me` 接口同步加 `is_project_creator` / `org_role`、`Project` 接口加 `org_role`(否则前端 TS 层拿不到新字段)。

### 3.4 授权操作面(管理后台「组织角色」页)

- 新页 `web/src/pages/AdminOrgRolesPage.tsx`,路由 `/admin/org-roles`,门控 `require_system_admin`(与 AdminGroupsPage 一致并入 AppHeader 管理菜单);移动端入口随批加入 MobileTabBar 的 moreItems(`MobileTabBar.tsx:46-50`,AdminUsersPage/AdminGroupsPage 同款,闸门同为 is_system_admin);布局:两张角色卡(运营/组长),每张 = `SubjectPicker`(user+group 多选,复用)+ 保存。
- API(`api/app/routers/directory.py` 风格,`require_system_admin`):
  - `GET /api/v1/admin/directory/org-roles` → `{operator: [{subject, name, missing?}], leader: [...]}`(读 store 现有 tuples + 解析显示名;**subject 与 store 内 tuple 的 user 字段逐字一致**——`user:<uuid>` / `group:<gid>#member`(`permissions.py` 的 `fmt_subject` 约定,含 `#member` 后缀),PUT 侧按同格式接收;主体已删的条目标 `missing: true`——组删除后 `group#member` tuple 不回收是既有约定,防角色卡出现「用户组 xxxx…」死条目。**用户被禁用即从角色卡消失属预期**——禁用会清直接授予的 org tuple(§3.4 离职闭环),GET 读的是 store 现存 tuple、无「置灰禁用者」的数据来源;页面顶部加一行说明文案「被禁用用户会自动移出本列表」防运维误判);
  - `PUT /api/v1/admin/directory/org-roles/{role}`(role ∈ operator|leader)body `{subjects: [...]}` → **幂等 upsert 语义**:不存在/非 active 的主体**静默跳过并在响应计数** `{added, removed, skipped_invalid}`(不整批 400——GET 回显的 `missing` 死条目被前端原样回传时不该炸;UI 把 missing 条目渲染为可移除项引导清理)→ **与现 tuples 全量 diff,不在 subjects 中的现存 tuple 一律删除(含 `missing` 死条目)** → 增删写 `organization#operator/#leader`,audit `org_role_changed`(details: role/added/removed);`labels.ts` 补 `org_role_changed` 中文映射(#124 约定,连同 §2.1 的 `asset.batch_renamed` 一起)。与禁用用户的并发窗口:diff 基于读时快照,竞态可把刚被 disable 清掉的 org tuple 短暂复活——无权限泄露(is_active=false 在认证层一票否决),仅审计/角色卡短暂失真,接受。
- **主体名称解析依赖**:优先复用 project-grant-templates-plan §2 的 `resolve_subject_names`(若其批次一已上线);未上线时本批次在 `directory.py` 内自带等价最小实现(users/groups 各一次 `WHERE id IN`),对方上线后合并去重——两条路径写清,避免实施时悬空。
- **离职/禁用闭环**:`USER_DIRECT_RELATIONS`(`permissions.py:43-61`)补 `("organization", "operator")`、`("organization", "leader")`——`revoke_user_completely`(:375-413)按此枚举清理全部 tuple,「禁用用户即清权限」(`directory.py:193` 触发)才不会漏 org 角色、重新启用不会静默恢复权限。该函数对未部署 relation 有 continue 容错(:391-392),model 未 push 也不会炸。
- 系统管理员本身**仍保持脚本授予**(`grant_org_admin.py`,有意无 UI):`/admin/org-roles` 页只能配运营/组长,提权面不扩大。

### 3.5 项目列表、徽章与前端能力闸门适配

- `GET /projects`(`projects.py:181-233`)与 `GET /projects/{id}`(:274-313,详情页 useProject 数据源)**同步**回填 `org_role`(后端 `ProjectOut`(`models/__init__.py:32-45`)加字段 + 前端 `types.ts` 的 `Project` 类型同步,防两接口口径漂移;与 /me 同一套判定逻辑,**各请求各执行一次** leader/operator check,不逐项目 check、不做跨请求缓存);普通用户分支 `list_objects(can_view, project)` 在新 model 下**自动**包含 org 派生 → 运营/组长无需任何代码即可看到全部项目。
- **`_fill_my_roles`(:236-271)不改**:它反映「直接授予的 project 角色」(成员抽屉/授权总览的语义基础),org 派生不会出现在其中。
- **前端能力判定改为 my_roles + org_role 双源**(不改则 org 派生用户的所有能力入口都点不亮——`canUploadProject`(`ProjectDetailPage.tsx:58-60`)= `my_roles.includes('admin'|'uploader')`,org 角色恒空 → FolderTree「新建根/子夹」(:631-633、:712-714)、空项目「新建第一个文件夹」(:225)对运营/组长全部隐藏;项目卡 `isAdmin`(`ProjectsPage.tsx:114`)同理):
  - `canUploadProject` → 追加 `|| me.org_role != null`(operator/leader 均可传),FolderTree 与空项目入口随之生效;
  - 项目卡 `isAdmin` → 追加 `|| me.org_role === 'leader'`(项目卡管理入口);
  - 前端项目卡:org_role 非空时显示「运营」/「组长」徽章(与现有 my_roles 徽章并列),解释「为何能看到该项目」。
  - **「我的权限」页适配**:`MyPermissionsPage.tsx:71-74` 按 `my_roles` 非空分桶,org 角色用户会被全部分进「仅访客」桶、页面近乎空白;分桶条件追加 `|| p.org_role != null`,org 角色显示对应徽章。
- 艺人视角无改动:未被授权的项目本就不出现在 `list_objects` 结果里。

### 3.6 测试

- `test_v4_permissions.py` 新增:给 user 授 `organization#operator` → 任意项目 can_view/can_download/can_upload ✓、can_admin ✗;授 `#leader` → can_admin ✓;敏感夹对 operator/leader can_view ✗(除非 invited);outsider 无 tuple 全 ✗ 回归。
- 建项目:leader POST /projects 201(admin_user_id=自己,bootstrap 正常);operator 403;**双角色(operator+leader 同持)用户 org_role=leader、建项目与管理闸门全亮**。
- org-roles API:GET/PUT 全 cycle、非系统 admin 403、subjects 解析名、死主体(不存在 user/非 active user/不存在 group)被跳过并计入 `skipped_invalid`(不整批 400)、missing 死条目经全量 diff 被清理、audit 落库。
- 前端 `pnpm build` + 手工冒烟:组长建项目、进项目页可见「新建文件夹」入口与项目卡管理入口;运营列表全见、可传不可管、无建项目按钮、无管理后台;艺人只见自己项目;my_roles 为空但 org 角色能力入口点亮。

---

## 4. 实施顺序与验收清单

### 顺序(3 批独立可上线,无相互依赖;建议按业务急迫度排)

| 批次 | 内容 | 部署注意 |
|---|---|---|
| PR-1 | §2 批量前缀(纯代码,无 migration) | 后端代码 rsync 后**必须重启 ms-api 才生效**(uvicorn 无 `--reload`;hh2 用 `deploy_lan.sh --restart`,server2 随 compose up);**新前端发 `labels_mode=merge` 而旧后端会静默吞掉该字段**(pydantic 默认忽略额外字段)按 replace 执行,跨页打标清空存量标签——发布顺序遵守下方「两段式发布」 |
| PR-2 | §1 目录导入(纯代码,无 migration) | 同 PR-1(新前端发 `relative_path` 被旧后端忽略 → 目录导入退化平铺、跨子目录同名互相覆盖);含 uppy 限制调整 |
| PR-3 | §3 三角色 | **前后端同批**;需 push FGA model + restart ms-api/ms-worker;无 alembic;**checklist 含 `USER_DIRECT_RELATIONS` 补 operator/leader 两项**(漏掉则禁用不清 org 角色、角色卡出现死条目,§3.4) |

> **两段式发布(消除「新前端 + 旧后端」窗口,PR-1/PR-2 必须遵守)**:StaticFiles 每请求读盘、前端产物落地即生效;Python 代码要等容器重启——两个环境分别:
> - **server2**(`deploy_server2.sh`):脚本把 `pnpm build` 产物随 api/ **一次 rsync**(含 `app/static/web`,#138 注释自证)再 `compose up --build`——rsync 完成到重启完成之间存在「新前端+旧后端」窗口。拆法:当次部署临时改两条 rsync(先 `--exclude=app/static/web` 同步后端 → 重启 → 再同步 `app/static/web`),或排维护横幅 + 无人时段并写进当次 PR 的部署 checklist。
> - **hh2**(`deploy_lan.sh`):脚本**全程排除 `static/web`**,前端产物本就单独走分片通道(deploy-hh2 skill §4)——天然两段式,守住顺序即可:先同步后端并 `--restart`,再走前端分片通道。

每批独立走:ruff + mypy(strict)+ 容器内 pytest + `pnpm build/lint` + server2 dev 部署 tester 验证 + `scripts/changelog.md` 记账(AGENTS.md 约定)。

### 用户可见验收清单

1. 运营电脑上把网盘目录下载到本地 → 拖入项目指定文件夹 → 目录层级完整出现在素材库,文件可下载。
2. 文件浏览器勾选多个文件(可翻页续选)→ 批量加/去前缀 → 列表与下载文件名统一变化,toast 报告成功/跳过数。
3. 管理后台「组织角色」给某用户授「组长」→ 他立刻:项目列表见全部、可进各项目成员抽屉管理、顶部出现「新建项目」且能建成功;授「运营」→ 见全部、可传可下,无新建按钮、无管理后台。(「立刻」以 /me 与项目列表的 react-query 缓存刷新为限,验证时重新进入页面即可。)
4. 敏感文件夹对未被邀请的运营/组长不可见(回归;注:组长可经成员抽屉自邀进敏感夹,与既有 project admin 同权——「不可见」指未自邀时)。
5. 艺人账号只看到自己被授权的项目,可上传下载(现状回归)。

---

## 5. 风险与已知取舍

| 风险/取舍 | 说明 |
|---|---|
| uppy `relativePath` 实际格式 | 实现时需以真实拖拽行为验证(含/不含顶层目录名),以前端实测为准对齐后端约定;已列为实现期验证点 |
| 20GB 单文件 | 分片数 1280(20GiB ÷ 16MiB)< 10000 上限,安全;但浏览器内存与断点续传体验需在 server2 实测大文件 |
| 批量前缀无 undo | 逆操作可抵消 add;remove 前建议用户先小范围试(预览 UI 缓解) |
| FGA model push 顺序与回滚 | PR-3 的 yaml 与代码同批上线(model 先 push 再放代码);回滚时代码与 model **必须同批回滚**——只回滚代码,新 model 下旧代码不受影响但派生权限已放开;只回滚 model,新代码的 operator/leader check 报 unknown relation |
| 新旧共存窗口的同名覆盖 | 新前端发 `relative_path` 而旧后端会忽略(pydantic 默认忽略额外字段)→ 目录导入退化为平铺,不同子目录的同名文件写同一 MinIO key 互相覆盖;PR-1/PR-2 按 §4「两段式发布」消除该窗口(server2 脚本一次 rsync 含 static/web、重启滞后;hh2 天然两段式,守住先后顺序) |
| PR-3 的 /me 字段窗口 | **PR-3 前后端同批上线**;另前端闸门写回落式判定 `me.is_project_creator ?? me.is_system_admin`——旧后端下 `is_project_creator` 为 undefined(falsy),不回落会连系统管理员的新建项目按钮一起消失 |
| org 角色误配 | 组长/运营可见面 = 全部普通目录,授予前在 UI 上有角色说明文案;仅系统 admin 可操作该页 |
| 历史孤儿夹被导入收养 | 命中「行在 tuple 缺」的历史夹时 complete 期 403 且无自愈(用户仅见通用 403);排查口径:access_denied audit 带 folder_id 可定位,修复走 §6 低频脚本;接受该罕见形态 |
| 大目录导入耗时 | 受办公电脑上行带宽限制,方案以「分批 + 进度可见」缓解,不承诺吞吐 |

---

## 6. 明确不做 / 留口

- **服务端百度网盘开放平台集成**(OAuth + 分享转存 + 服务器拉取):前置条件不满足——内网 egress 待定(ops-manual §10)、企业应用资质、非会员 API 限速;若未来确认 egress 且有资质,可二期做「网盘授权绑定 + 服务器侧导入任务」。
- **服务器本地目录直灌脚本**(`import_local_tree.py`,U 盘/移动硬盘迁移场景,boto3 直写 + 建行 + bootstrap,仿 seed_demo_data.py):留口,需要时半天工作量。
- **文件夹改名/前缀**:牵动 minio_prefix 子树级联,维持 ROADMAP「低优先级」结论。
- **导入去重/同名跳过策略**:(folder_id, filename) 唯一约束与增量导入去重,等真实痛点出现再立项。
- **独立的 `project_creator` relation**:组长语义已覆盖;未来若需「可建项目但非组长」再拆。
- **zip/打包批量下载**:批量下载仍是前端逐条 presigned 循环(现状),跨页保留选中放大规模后仅加 >20 确认提示;打包下载端点待真需求再立。
- **孤儿夹修复脚本**:历史「行在 tuple 缺」的夹(bootstrap 失败残留)低频巡检补 tuple(幂等写,`is_already_exists_error` 吞掉)。
- **存量 NFD 夹清洗**:`POST /folders` NFC 归一上线前建的 NFD 名夹,与后续 NFC 建的视觉同名夹可并存(uq 按字节比较);清洗脚本把存量 NFD 行归一(需同时改 minio_prefix 与资产 key 或做映射),落地前并存为已知状态。
- **艺人组织级角色**:项目级授权已覆盖,不加机制(加了反而引入「艺人默认可见什么」的新问题)。
- **stealth 项目对组长/运营隐藏**:org 派生使 stealth 对这两角色失效(§3.1);若出现「需对组长也隐藏的项目」再评估(如 list 侧对 leader 做 stealth 过滤的应用层收口)。

---

## 7. 与 project-grant-templates-plan 的协调(他人跟进中)

| 交点 | 约定 |
|---|---|
| `store.fga.yaml` | 对方不动 model 段(其批次一放开关卡是纯代码);本方案改 model 段。若两批并行,merge 后**一次** `openfga_write_model.sh` push,避免双 push 覆盖 |
| `resolve_subject_names` | 本方案 §3.4 优先复用对方 §2 的 helper;未上线则自带最小实现,后合并去重 |
| initial_grants / 默认权限模板 | 若对方模板里配了「运营组/组长组 → 每项目显式授权」,与本方案 org 派生**重复但幂等无害**;建议模板不再重复配运营/组长(派生已覆盖),减少 tuple 量 |
| 放开「用户组授管理」(对方批次一A) | 与本方案无冲突;org-roles 页的 SubjectPicker 同样受益 |
| `create_project` / `NewProjectModal.tsx` / `hooks.ts`(对方还改 ProjectMembersDrawer.tsx;ProjectsPage 仅本方案改) | 两方案都会改:对方在 create_project 插 initial_grants 校验与写入、给 NewProjectModal 加模板 Select + 初始权限区;本方案替换 create_project 守门、改 NewProjectModal 闸门与文案。**后合入者负责解决冲突并跑双方测试**(冲突点集中在 create_project 函数与 NewProjectModal 表单两处,量可控) |
| 共享导航/路由文件 | App.tsx 路由两方案都可能动(各新增管理页);AppHeader 管理菜单对方已列、本方案也要加;MobileTabBar moreItems 仅本方案——**后合入者一并解决,别漏** |
| 本方案内部:ProjectDetailPage.tsx | PR-1(§2.2 大改选中/批量栏)与 PR-3(§3.5 改 :58-60 闸门)同文件——**PR-1 先合,PR-3 rebase 后合**,冲突由后合入者解 |
