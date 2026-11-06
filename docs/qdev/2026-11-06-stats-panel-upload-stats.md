# Web 统计面板 + 文件上传数量统计(方案 + qdev 执行稿)

> 2026-11-06 撰写,基于 liuqi@826401b 全链路核实(qplan worktree `qplan/web-stats-panel`)。
> 需求(用户原意):
> ① web 端新增「统计面板」,默认只对管理员开放,可给用户组配权限,有权限即可见入口;
> ② 面板收纳多个统计模块:现有【使用统计】迁入 + 新增【文件上传数量统计】;子模块各自独立控权;组配置界面启用【统计】后展示子级功能按钮;
> ③ 【文件上传数量统计】新页面:项目多选(不选=全部)+ 日期范围(自动 00:00:00/23:59:59);按项目分行走分类计数 + 全选项目汇总行;已删除不计数;查询遵守数据权限。
> 分类口径:生活图文=图片+livp;口播视频=文件路径或名称含「口播视频」的视频;生活视频=其余视频;其他=三者之外。
> 约束:不动业务代码由 qplan 定稿后另派 qdev;App(Flutter)零改动;后端无 DB 迁移。

## 1. 现状链路事实(已核实,行号以 worktree qplan/web-stats-panel@826401b 为准)

### 1.1 使用统计现状
- 后端:`api/app/routers/usage_stats.py:27-63` GET `/api/v1/admin/usage/stats`,守门 `require_system_admin`(:38,仅 organization#admin,deps.py:226-245);聚合逻辑在 `api/app/services/usage_stats.py`(audit_events 单表 GROUPING SETS,daily 固定 Asia/Shanghai);router 注册 main.py:174-177,挂 `dependencies=gate`(MCP 并发闸)。
- Web 页:`web/src/pages/AdminUsageStatsPage.tsx`(RangePicker 默认近 30 天 + metric Segmented + daily 开关);路由 App.tsx:85 `/admin/usage`;PC 入口 chip 在 AppHeader.tsx:117,**位于 `me.is_system_admin &&` 包裹的 admin 块内**(:107-123);移动端 MobileTabBar moreItems 不含该入口(:47-63)。
- 页面守卫形态:前端 `useMe()` 体验层 Alert + 后端 403 兜底(App.tsx:48-52 全局静默跳过)。
- App 端:`app/lib/features/admin/admin_usage_page.dart` 共用同一端点,入口在 admin_home.dart:92-99(App 管理区自身按 admin 判定)。

### 1.2 组级权限体系(新权限的挂点,以 file_deleter/artist_account_creator 为完整先例)
- FGA model:`poc/openfga/store.fga.yaml:53-81`,组织级 relation 全部 `define xxx: [user, group#member]`,现有:admin / project_creator / project_deleter / folder_template_manager / artist_account_creator / file_deleter。
- 新增一个组级 flag 的全链七件套(逐处有先例):
  1. store.fga.yaml 加 relation(**并照 file_deleter 段落补齐 seed tuples(:181-204 形态)与 model 级 check 断言(:373-501 形态:组员 true/非组员 false/org admin 不蕴含)——现有 6 个组级 flag 均配齐,新三条不可只加 relation 裸奔**);
  2. `api/app/services/permissions.py`:`USER_DIRECT_RELATIONS` 追加组织级防御条目(常量在 :43,组织级条目 :49-66)+ 新 `is_org_xxx` check 方法(:641-719 一组);
  3. `api/app/routers/directory.py`:GroupCreateIn/GroupUpdateIn/DirectoryGroupOut 三 schema 加字段(:614-665)+ 列表回填 `_read_flag_group_ids`(:681-716,:800-804)+ create/patch 的 `_sync_group_org_flag`(:838-953)+ 审计 details(:954-984)+ 删组清 tuple 的 relation 列表(:1056-1057);
  4. `api/app/deps.py`:require_xxx(:274-304 模板,口径 `is_org_admin ∨ check(relation)`;default org 缺失 500,FGA 异常不上吞);
  5. `/me` 回显字段(auth.py:220-250,非 admin 才补查,FGA 异常回 False);
  6. 前端 types.ts(Me + DirectoryGroup)+ AdminGroupsPage 开关/徽标/touched + hooks.ts;
  7. `api/scripts/openfga_write_model.sh` 重推 model(先推 model 再上代码,否则 check 撞未知 relation 500)。
- 组配置 UI 级联先例(artist 方案 F4):子开关 `can_create_artist_account` 挂在父开关 `can_create_project` 下 —— 父 `Form.useWatch` 控制子开关渲染(AdminGroupsPage.tsx:357-366);父 true→false 转变瞬间 `setFieldValue(false)` + 强制置 touched,确保该次 PATCH 显式发 false 清 tuple(:344-353);弹窗挂载时父已 false 不做复位(防「仅改名保存」静默撤权,:267-269)。**仅 UI 级联,FGA relation 相互独立,后端无级联校验先例**。
- 组 flag 变更写审计(group_created/group_updated,{old,new});列表徽标硬编码(AdminGroupsPage.tsx:165-208)。

### 1.3 资产数据模型与分类判定
- `assets` 单表(tables.py:138-188):filename/minio_key/content_type(nullable)/deleted_at(软删)/created_at(timestamptz,server_default now,**=入库时刻**;百度导入资产 = 导入完成时刻,网盘原始时间未落库)/folder_id → folders.project_id(tables.py:117)、folders.is_sensitive。**无类型列**,分类只能由 content_type + filename/minio_key 推导。
- 分类常量单点:`api/app/services/thumb_exts.py` —— VIDEO_EXTS(12 扩展名,刻意不含 .ts)/IMAGE_EXTS(10,刻意不含 .svg)/`is_video_asset`(content_type `video/*` 前缀 OR filename 扩展名)/`is_image_asset`(`image/*` 且非 svg OR 扩展名)/`is_livp_asset`(.livp 后缀,**livp 不属于 image**)。上传派发优先级 livp > image > video(assets.py:353-369)。
- 软删两阶段:默认软删置 deleted_at;彻底删删行;正常查询一律 `deleted_at IS NULL`(列表 assets.py:433、盲搜 assets.py:702、folder 计数 folders.py:569)。
- 「口播视频」字样全仓零出现,匹配规则需新写;资产量级 prod ~2.5 万行(盲搜设计假设到百万行,assets.py:651)。

### 1.4 数据权限先例(盲搜零泄露口径)
`api/app/routers/assets.py:667-691`:非 admin 可达 folder 集合 =
`list_objects(can_view, folder)` ∪ `list_objects(can_view, sensitive_folder)` ∪ `public 项目非敏感 folder`;
系统 admin 直通恒 true;sensitive folder 不走 public 直通(零泄露)。
FGA folder can_view 从 parent project 继承(store.fga.yaml:116)——可见项目的全部非敏感 folder 天然可达,sensitive folder 需显式邀请。

### 1.5 时间窗口先例
usage_stats:from/to tz-aware ISO、naive 422、乱序 422、窗口上限 366 天(参数四分支与 422 校验在 routers/usage_stats.py:47-58)、SQL 半开区间 `>= from AND < to`(services/usage_stats.py:85-86);daily 分桶固定 `AT TIME ZONE 'Asia/Shanghai'`。存储全 timestamptz。

### 1.6 前端注册点与验证口径
- 新页面 = App.tsx lazy import + Route(:20-43/:85 模式)+ AppHeader chip(:117/:126 模式)+ 移动端 MobileTabBar moreItems(:51-62 可选)。
- web 无测试 runner:验证 = `pnpm build`(tsc -b + vite build)+ `pnpm lint`。

## 2. 方案总览

```
权限链(FGA,三个新组织级 relation,复刻 project_creator 模式):
  organization#stats_viewer        ← 组配置父开关 can_view_stats(面板入口)
  organization#usage_stats_viewer  ← 子开关 can_view_usage_stats(使用统计)
  organization#upload_stats_viewer ← 子开关 can_view_upload_stats(文件上传数量统计)
  守门口径 = is_org_admin ∨ (父 ∧ 子)   ← 系统管理员恒直通;父∧子合取防不一致 tuple

web:
  AppHeader/MobileTabBar 新 chip「统计」(三态门 is_stats_viewer ?? is_system_admin)
    → /admin/stats 统计面板页(两张模块卡片,按子 flag 显隐)
        ├─ 使用统计      → /admin/usage(既有页,守门从 require_system_admin 放宽)
        └─ 文件上传数量统计 → /admin/upload-stats(新页)
  AdminGroupsPage:父开关 can_view_stats + 级联两子开关(照 artist F4 模式)+ 徽标

api:
  GET /api/v1/admin/stats/uploads(新 router upload_stats.py,挂 gate 并发闸)
    ← require_upload_stats_viewer(is_org_admin ∨ (stats_viewer ∧ upload_stats_viewer))
    项目多选(缺省全部 in-scope)+ date_from/date_to → Asia/Shanghai 归一半开区间
    SQL:assets JOIN folders JOIN projects,deleted_at IS NULL + 项目活性
         + created_at 窗口 + 非盲搜同款 folder 级零泄露过滤(admin 直通)
         + 分类 CASE(livp > 口播视频 > 生活视频 > 图片;livp/图片=生活图文)
    响应:rows(按项目零填充)+ summary(汇总)
  /admin/usage/stats:仅换守门 require_usage_stats_viewer,路径/行为不变(App 零改动)
```

## 3. 权限模型设计

### 3.1 FGA model(store.fga.yaml organization type 追加三条)

```yaml
    # ↓↓ 以下为示意缩进;实际须并入 store.fga.yaml 的 `model: |` 字面块内
    # ↓↓ type organization 段(现有 relation 后追加,同段 6 空格缩进)
    # 组级「统计面板」父权限(2026-11-06 统计面板方案 §3.1):同 project_creator
    # 模式 —— UI 只写组主体,组员判定由 check 自动展开 group#member;仅控面板
    # 入口,不单独授任何数据;应用层子模块守门 = is_org_admin ∨ (stats_viewer ∧ 子)
    define stats_viewer: [user, group#member]
    # 组级「使用统计」子权限:父开关开启后 UI 才展示;守门合取父 relation
    define usage_stats_viewer: [user, group#member]
    # 组级「文件上传数量统计」子权限:同上
    define upload_stats_viewer: [user, group#member]
```

三条相互独立(不写 derived 蕴含),父子约束由「UI 级联 + 守门合取」双保险落实,与 artist 先例的「model 正交、应用层组合」哲学一致。

### 3.2 permissions.py / deps.py / auth.py

- `permissions.py`:`USER_DIRECT_RELATIONS`(:43)追加组织级防御条目三项;新增 `is_org_stats_viewer` / `is_org_usage_stats_viewer` / `is_org_upload_stats_viewer` check 方法(照 :641-719 一组)。
- `deps.py` 新增两个守门 + 三个 bool(照 require_project_creator/get_is_project_creator :274-333 模板):
  - `require_usage_stats_viewer`:`is_org_admin ∨ (is_org_stats_viewer ∧ is_org_usage_stats_viewer)`,否则 403;
  - `require_upload_stats_viewer`:同构,403 文案区分;
  - `get_is_stats_viewer` / `get_is_usage_stats_viewer` / `get_is_upload_stats_viewer`:bool 版(default org 缺失 → False、FGA 抖动 try/except → False),**仅作口径单一事实源与未来端点备用——/me 沿现状内联 try/except 逐 flag 补查形态追加(auth.py:162-218),勿改成 Depends 注入重构**(get_is_project_creator 同样无路由消费,是既有先例)。为消「/me 内联与 get_is_* 两份手写合取」的漂移面,合取判定抽成 **deps.py 层**单一私有 helper(组合判定历来在应用层——permissions.py 每个 is_org_* docstring 明文「这是 check 半边,应用层守门完整口径」,故不进 permissions 层,勿破既有分层),/me 与 get_is_* 共用同一份。**口径与同名 require 完全一致,写死不许漂移**:`is_stats_viewer = is_org_admin ∨ check(stats_viewer)`;`is_usage_stats_viewer` / `is_upload_stats_viewer = is_org_admin ∨ (stats_viewer ∧ 对应子)`——否则不一致 tuple 下前端显卡片而 API 403。
- `auth.py /me` 追加回显(非 admin 才补查):`is_stats_viewer` / `is_usage_stats_viewer` / `is_upload_stats_viewer`。注:补查次数的前提是 **`is_stats_viewer` 的 check 结果计算一次、供两个合取子项复用**(5 → 8 次串行;若按 flag 粒度独立实现会到 10 次,勿);/me 是前端冷启动热路径,新增三项与既有项一并 `asyncio.gather` 并行化**列入包 A 交付项**(实现细节 qdev 自由)。
- **为什么守门要「父∧子」合取**:组配置 UI 级联只在保存路径保证父子一致,直改 FGA/并发 PATCH 可能产生「子开父关」的不一致 tuple;合取使不一致态下接口不可达(最多丢入口、不会绕过面板直接取数),安全性单调。

### 3.3 组配置界面(directory.py + AdminGroupsPage)

- schema(按现有分型,勿把 tri-state 抄进 Create/Out):`DirectoryGroupOut` / `GroupCreateIn` 追加 `can_view_stats` / `can_view_usage_stats` / `can_view_upload_stats`(普通 `bool = False`,照既有五 flag);`GroupUpdateIn` 追加同三字段(tri-state `bool | None = None`,None=不动);列表回填 `_read_flag_group_ids` 增读三条 relation(组列表的串行 FGA read 由 5 次增至 8 次,组量小可接受;可 `asyncio.gather` 并行化,与 §3.2 /me 同款可选优化,勿当性能问题误修);create/patch `_sync_group_org_flag` 增三个 flag;审计 details 纳入;删组清 tuple 的 relation 列表追加三条。
- AdminGroupsPage(照 artist F4 级联,父开关 = can_view_stats,两子开关同款复位):
  - 父开关「允许组成员查看统计面板」(建组/编辑均展示);
  - `const canViewStats = Form.useWatch('can_view_stats', form) === true;` 控制两子开关渲染;
  - 父 true→false 转变瞬间 `setFieldValue('can_view_usage_stats', false)` + `setFieldValue('can_view_upload_stats', false)` 并强制置两个 touched;
  - 三套 `statsFlagTouched` / `usageStatsFlagTouched` / `uploadStatsFlagTouched` tri-state;新建 POST 全量传三字段;
  - 徽标:父 flag 置位时展示一枚「统计」accent 徽标(子权限详情在编辑弹窗可见,不逐枚加徽标防拥挤)。
- 后端 PATCH **不做**跨字段父子校验(与现状一致,tri-state 交叉校验复杂且收益低);一致性靠 UI 级联 + §3.2 合取守门。

## 4. 文件上传数量统计端点

### 4.1 API 契约

新 router `api/app/routers/upload_stats.py`,注册 main.py(usage_stats 注册块后,prefix `/api/v1/admin/stats`,`dependencies=gate`——PAT=D1 全账号身份,漏挂即出现不过并发闸的 PAT 通道,main.py:144-150 铁律):

```
GET /api/v1/admin/stats/uploads
  ?project_ids=<uuid>[,<uuid>...]   可选;缺省=全部 in-scope 项目;不可见/归档/已删 id 静默丢弃
  &date_from=YYYY-MM-DD             必填
  &date_to=YYYY-MM-DD               必填
  守门:require_upload_stats_viewer
  实现注记:project_ids 按单参数 str + 手工 split(',') 解析(勿声明 List[UUID] =
  Query(None)——那是重复参数形态 ?a&b,逗号串会直接 422 与契约不符);**空串
  `?project_ids=` 视同缺省=全部**(strip 后为空 → None,防第三方调用踩 422);
  重复参数形态 `?project_ids=a&project_ids=b` 在 str Query 下 starlette 静默取
  末值——非正式契约、行为不保证,正式调用只用逗号串;单次上限 200 个 id(超限
  422);非法 UUID → 422(§7.3)
响应 UploadStatsOut:
{
  "rows": [
    {"project_id","project_code","project_name",
     "life_images","voice_videos","life_videos","others","total"}   // int,零填充
  ],                                        // 排序 total desc → project_name asc
  "summary": {"life_images","voice_videos","life_videos","others","total"}
}
```

模型加在 `api/app/models/__init__.py`(UploadStatsTotalsOut / UploadStatsRowOut / UploadStatsOut)。

### 4.2 时间归一(D5)

`date_from`/`date_to` 按日粒度传入(前端 RangePicker 只选日期),**后端统一按 Asia/Shanghai 归一**(与 usage_stats daily 固定时区同口径):

```python
# 固定 +08:00 偏移而非 ZoneInfo("Asia/Shanghai"):不依赖运行环境 tzdata 的
# 完备性与版本漂移(Python 侧 zoneinfo 全仓零先例);Asia/Shanghai 自 1991 年
# 起无夏令时,固定偏移语义等价、零新依赖。与 usage_stats daily 的 SQL 内
# AT TIME ZONE 'Asia/Shanghai' 同偏移口径(机制不同:那边吃 PG 时区库)。
CN_TZ = timezone(timedelta(hours=8))
from_dt = datetime.combine(date_from, time.min, tzinfo=CN_TZ)
to_dt   = datetime.combine(date_to + timedelta(days=1), time.min, tzinfo=CN_TZ)
# SQL 半开区间:created_at >= from_dt AND created_at < to_dt
```

- 等价于「起始日 00:00:00 ~ 结束日 23:59:59」,服务端归一避免客户端时区/格式漂移,天然规避 usage_stats 的 naive-422 一族问题;
- 校验(**顺序写死 + 溢出守卫**):
  1. `date_from > date_to` → 422;
  2. `date_to - date_from > 365 天`(纯 date 减法,不会溢出;窗口最长 366 自然日,**较 usage 紧一天**——usage 是 `to - from > 366 天` 才 422,允许半开窗口 367 自然日,差异明示勿「对齐」)→ 422;
  3. **combine 步骤包 `try/except OverflowError → 422`**——前两步拦不住 `date_from=9999-01-01 & date_to=9999-12-31`(差 363 ≤ 365 通过校验,但 `date_to + timedelta(days=1)` 越过 `date.max` 抛 OverflowError,不兜则 500)。守卫只用 try/except 主方案,勿写「`date_to >= date.max - 1天` 先行 422」之类的替代表述(会误伤 9999-12-30 这一可正常处理的日期,off-by-one)。

### 4.3 分类判定(D4,与 thumb_exts 单一事实来源)

service 新文件 `api/app/services/upload_stats.py`;分类布尔表达式在 SQL 内构建,扩展名清单**由 `thumb_exts.VIDEO_EXTS/IMAGE_EXTS` 生成**(改常量即两侧同步,不手抄清单):

```python
VIDEO_EXT_RE = r"\.(" + "|".join(sorted(e.lstrip(".") for e in VIDEO_EXTS)) + r")$"
# 口播关键词单点常量
VOICE_OVER_VIDEO_KEYWORD = "口播视频"

video_expr = content_type.like("video/%") | filename.op("~*")(VIDEO_EXT_RE)
image_expr = (content_type.like("image/%") & (content_type != "image/svg+xml")) \
             | filename.op("~*")(IMAGE_EXT_RE)
livp_expr  = filename.op("~*")(r"\.livp$")
voice_kw   = filename.ilike(f"%{VOICE_OVER_VIDEO_KEYWORD}%") \
             | minio_key.ilike(f"%{VOICE_OVER_VIDEO_KEYWORD}%")
# 注:minio_key = folder.minio_prefix + '/' + filename(assets.py:197),filename
# 分支天然被 minio_key 分支覆盖;保留双分支作防御性冗余(两字段理论上独立演进),
# 勿删——后读者勿误以为必须两字段同时含关键词。

# 优先级:livp > 口播视频 > 生活视频 > 图片(见 §4.4 CASE;livp/图片并入生活图文)
life_images_expr = livp_expr | image_expr
```

口径说明:
- 视频/图片判定与 `is_video_asset/is_image_asset` 完全同构(mime 前缀 OR filename 扩展名),扩展名刻意沿用 thumb 清单;**边界口径与夹具前提**:`.ts` 落「其他」仅当 content_type 非 `video/*`(mime 是 video/* 时按 mime 落「生活视频」),`.svg` 落「其他」仅当 content_type 非 `image/*`(image/png mime 的 .svg 落「生活图文」)——§7 用例的夹具 mime 前提即此,tooltip 口径照此措辞,勿写成无条件结论;
- 「口播视频」只作用于视频:非视频文件名含关键词仍按自身类别归类(图片含「口播视频」字样 → 生活图文);
- **2026-11-06 用户拍板**:口播视频路径匹配改为按**当前位置**(`folder.minio_prefix + filename`,SQL 侧 `func.concat` 拼接,join folders 在计数 SQL 本就存在);落库 `minio_key` 为上传时刻快照(D1-B 文件夹改名/移动只重算 prefix、不回填存量 key)会过期,**不参与匹配** —— 目录即分类:移动/改名文件夹即时生效,挪出「口播视频」夹即不再计口播;
- **asset 级单文件授权不在计数面**:盲搜对 asset#explicit_downloader(单文件临时 grant)本就「宁漏勿泄」不纳入(assets.py:648-649 docstring),本端点沿同一保守口径——持单文件授权者可下载该资产但其不计入统计,记此处防后来者当 bug「修」;
- ILIKE 对 CJK 无大小写问题;`~*` 大小写不敏感匹配扩展名。

### 4.4 SQL 聚合与数据权限(D3/D6/D7)

```
-- 桶互斥:单条 CASE 按优先级落桶。不用四条独立布尔 FILTER——content_type 是
-- 客户端可控值(上传直传),content_type=image/png + .mp4 文件名的资产会同时
-- 命中图片桶与视频桶,致 total ≠ count(*);CASE 恰好落一桶,恒相等。
-- livp 分支置于 video 之前:与上传派发优先级 livp > image > video 同构
-- (assets.py:353-369),.livp 恒落生活图文(需求:livp 算生活图文),
-- 即便客户端给了 video/* mime 也不抢跑。
cat = CASE WHEN livp_expr             THEN 'life_images'    -- livp 最先
           WHEN video_expr & voice_kw THEN 'voice_videos'   -- 口播视频次之
           WHEN video_expr           THEN 'life_videos'
           WHEN image_expr           THEN 'life_images'     -- 普通图片
           ELSE 'other' END
SELECT f.project_id,
       count(*) FILTER (WHERE cat = 'life_images')  AS life_images,
       count(*) FILTER (WHERE cat = 'voice_videos') AS voice_videos,
       count(*) FILTER (WHERE cat = 'life_videos')  AS life_videos,
       count(*) FILTER (WHERE cat = 'other')        AS others
FROM assets a
  JOIN folders f ON a.folder_id = f.id
  JOIN projects p ON f.project_id = p.id
WHERE a.deleted_at IS NULL                  -- 软删不计数(D6;彻底删已无行)
  AND p.is_archived = false                 -- 归档/软删项目不计(D3;admin 分支
  AND p.deleted_at IS NULL                  --   同样适用,不因直通而放宽)
  AND a.created_at >= :from_dt AND a.created_at < :to_dt
  AND <folder_filter>                       -- 见下
GROUP BY f.project_id, p.code, p.name
```
(GROUP BY 须带 p.code/p.name——PG 函数依赖推断只在 GROUP BY 表自身主键时生效,只按 f.project_id 分组直接 SELECT p.* 会 42803;code/name 与 project_id 1:1,加入分组不改语义。SQLAlchemy 侧 `cat` 用 `sa.case(...)` 构建一次、四个 FILTER 复用同一表达式;total = 四桶之和 ≡ count(*)。**注意**:盲搜先例的 public 分支只过滤 visibility+is_sensitive、不过滤项目活性(assets.py:679-687),本端点刻意收紧——归档/软删项目不进任何口径,偏离点在此明示。)

- `folder_filter`(数据权限,与盲搜 assets.py:667-691 同款 + 项目活性收紧):
  - 系统 admin:`true()` 直通(活性过滤已由上方 JOIN projects 承担);
  - 非 admin:`folder_id IN (list_objects(can_view, folder) ∪ list_objects(can_view, sensitive_folder) ∪ public 项目非敏感 folder)`;其中 public 分支**同加项目活性条件**(is_archived=false 且 deleted_at IS NULL,即上文偏离点);sensitive 口径分主语:**未受邀**的 sensitive folder 资产不计入(不进 public 分支、list_objects 不返回未受邀对象,对未受邀者零泄露);**受邀**的 sensitive folder 资产照常计入(与盲搜浏览面同口径,§7.6 有正反两用例)。零可达 folder → 跳过计数 SQL,rows 仍按宇宙零填充(rows 字段恒返回数组,宇宙为空时为 [],勿造 sentinel)。
- 行集合(rows universe,分两层再并集):
  - **项目宇宙**(零填充基准,与 GET /projects 同口径):admin = 全部 `is_archived = false AND deleted_at IS NULL` 项目;非 admin = `list_objects(can_view, project) ∪ public` 同口径过滤归档/软删;
  - **计数面补充**(修正死角):folder 级 explicit grant 独立于项目级 can_view(store.fga.yaml:112-114)——存在「项目不可见但 folder 可见」的用户(如仅被授予某私有项目内某目录)。这类项目的资产已进 folder_filter 计数,若 rows 严格按项目宇宙左连会双双漏出 rows 与 summary,违反 D3「计数面=浏览面」不变量(盲搜对这些资产本就回显项目名,无新增泄露面)。故行集合**额外纳入「计数结果中出现、且未被 project_ids 过滤掉」的活性项目**(不零填充,**有数即现**——显式选中一个仅 folder 级可达且窗口内计数为 0 的补充项目时不产生行,行数可少于所选数,与宇宙项目零填充语义刻意不同);**显式传入这类补充项目 id 同样合法**(按 folder 可达口径计数——下拉不含它,但手打/拼 URL 传入不视为越权);
  - `project_ids` 显式给出时:对宇宙与补充项目一律取交集,**静默丢弃**不可见/归档/软删 id(与盲搜一致,不 403 防探测);**非法 UUID 字符串 → 422**(格式错误属参数校验,不属权限静默)。
- rows = 项目宇宙按计数结果零填充(窗口内无资产的项目返回全 0 行,表格诚实)∪ 补充项目行;summary = rows 逐列求和(后端为准,前端 Table Summary 同显)。
- 性能:2.5 万行全表扫无碍(assets 无 created_at 单列索引;复合 ix_asset_folder_created 仅非 admin 的 `folder_id IN + created_at` 分支可能局部受益,admin 直通分支不适用,量级内无差别);若未来量级涨,仿 migration 0018 补单列 btree 即可,本期不加(记 §12 遗留)。

### 4.5 使用统计守门放宽(D2)

`usage_stats.py:38` 的 `require_system_admin` → `require_usage_stats_viewer`。路径、参数、响应、聚合行为零变化。**注释同步**:usage_stats.py 模块 docstring 与端点 docstring 的「仅 system admin」(usage_stats.py:3,:40-41)、main.py:174 注册注释、hooks.ts useAdminUsageStats 附近注释、App.tsx:84 路由注释、AdminUsageStatsPage.tsx:9 模块 docstring 一律改为新口径,防后来者按旧注释误判。App 端共用此端点:App 管理区入口自身按 admin 判定(admin_home),App **零改动**;端点放宽后持权组员理论可直调 API,但 App 无入口,行为不变。

## 5. Web 前端设计

### 5.1 入口与面板页

- `web/src/api/types.ts`:Me 追加 `is_stats_viewer? / is_usage_stats_viewer? / is_upload_stats_viewer?`(可选,消费侧 `?? is_system_admin` 回落,同 is_folder_template_manager 惯例——旧后端无字段时 admin 行为不变);DirectoryGroup 追加三 can_view_* 字段。
- `web/src/api/hooks.ts`:新增 `useUploadStats(params)`(GET /api/v1/admin/stats/uploads,params 整体进 queryKey + keepPreviousData,照 useAdminUsageStats :1410-1419;**序列化铁律**:`project_ids` 是单参数逗号串契约,hook 入参处须先 `projectIds.join(',')` 成 string 再交 axios params——直接把数组交给 axios 默认序列化为 `project_ids[]=a&project_ids[]=b`,后端键名不匹配拿到 None → 按「缺省=全部项目」返回,**用户选了项目却查全部的静默错误**);`useCreateGroup`/`useUpdateGroup`(hooks.ts:835-879)入参类型补三 can_view_* 字段。
- AppHeader:admin 块内「使用统计」chip(:117)**移除**,块外新增三态门 chip `{(me.is_stats_viewer ?? me.is_system_admin) && <NavChip to="/admin/stats" label="统计" …/>}`(挂 :124-128 目录模板 chip 同区);admin 因 `?? is_system_admin` 回落恒可见,行为无缝。
- MobileTabBar moreItems:同三态门补「统计」入口(BarChart3 图标),挂目录模板条目后(:60-62 模式);移动端由此首次可达使用统计(面板页与上传统计页均做自适应,表格 scroll.x)。
- 新页 `AdminStatsPanelPage.tsx`(路由 `/admin/stats`):模块卡片列表(图标+标题+一句话描述+进入);「使用统计」卡片按 `me.is_usage_stats_viewer ?? me.is_system_admin` 显隐,「文件上传数量统计」按 `me.is_upload_stats_viewer ?? me.is_system_admin` 显隐;两者皆不可见时渲染 Alert「无可用的统计模块,请联系管理员开通」(体验层,后端 403 兜底同现状);面板页自身入口已由 chip 三态门控制,直达 URL 者同款 Alert 守卫。

### 5.2 文件上传数量统计页

新页 `AdminUploadStatsPage.tsx`(路由 `/admin/upload-stats`,lazy import):
- 筛选行:项目 `Select mode="multiple"`(数据源 **`useAllProjects`**——hooks.ts:119-126 循环 offset 拉全;`useProjects` 默认 limit=100 会静默截断,hooks.ts:95-99,>100 项目时下拉缺项;两者权限过滤口径相同均走 GET /projects,天然排除归档;placeholder「全部项目」允许清空=查全部)+ `RangePicker`(picker="date",必填,默认近 30 天)+ 查询按钮(手动触发。**注意先例形态**:AdminUsageStatsPage 本身是参数一变即自动取数、无按钮,页面形态勿照抄;手动触发复用 hook 签名层的 null/enabled 门——`useUploadStats(params | null)`,查询前 params 恒 null(enabled=false 不发请求),点「查询」才 setState 传参);
- 时间传参:取所选日期的 `format('YYYY-MM-DD')` 两枚,**00:00:00/23:59:59 语义由后端归一**(§4.2),前端不拼时间;
- 结果 `Table`:列 = 项目(code + name 同格)/生活图文/口播视频/生活视频/其他/合计;首行或 Table.Summary 固定「全部项目汇总」(summary 字段);`scroll.x` 自适应;loading/empty/error(message.error 兼容数组型 detail,antd v6 铁律)随 react-query 状态;
- 页面守卫:`!(me.is_upload_stats_viewer ?? me.is_system_admin)` → Alert 提示(照 AdminUsageStatsPage :76-86 形态)。

### 5.3 AdminUsageStatsPage 微调

守卫条件从 `!me.is_system_admin` 改为 `!(me.is_usage_stats_viewer ?? me.is_system_admin)`,文案同步;其余(筛选/图表/表格)零改动。

## 6. 决策点汇总

| # | 决策 | 取舍理由 |
|---|------|----------|
| D1 | 三条独立 FGA relation(父 stats_viewer + 两子),守门 `is_org_admin ∨ (父 ∧ 子)` | 父开关持久化符合管理员心智;合取防「子开父关」不一致 tuple 绕面板直打接口;弃「纯两子、父为 UI 派生」——父无落点则组配置语义破碎 |
| D2 | /admin/usage/stats 仅放宽守门,路径行为不变 | App 共用端点零改动;前端仅入口重挂 |
| D3 | 数据权限 = 盲搜同款 folder 级零泄露(admin 直通);项目宇宙同 GET /projects(排除归档/软删) | 「查询同样需要数据权限」按最严口径落实;计数面与浏览面口径一致;sensitive folder 不走 public 直通为先例铁律 |
| D4 | 分类优先级 **livp > 口播视频 > 生活视频 > 图片**(livp 与图片并入「生活图文」);扩展名清单由 thumb_exts 常量生成;「口播视频」只作用于视频文件 | livp 分支置顶与上传派发优先级 livp>image>video 同构(assets.py:353-369),.livp 恒落生活图文(需求原意),客户端伪造 video/* mime 也不抢跑;单一事实来源;非视频含关键词不误吞 |
| D5 | date_from/date_to 日粒度入参,后端 Asia/Shanghai 归一半开区间;366 天上限 | 用户不选时刻;服务端归一杜绝 naive/时区漂移;口径对齐 usage_stats |
| D6 | 软删不计(deleted_at IS NULL);恢复后重新计数;百度导入按导入完成时刻计(created_at 语义) | 全仓同款;网盘原始时间未落库,无可替代列(口径注记在页面 tooltip 说明) |
| D7 | rows 零填充全量 in-scope 项目 + summary;排序 total desc → name asc | 空项目行诚实显示 0;汇总=选中(或全部)项目合计 |
| D8 | 新 router `upload_stats.py`,prefix `/api/v1/admin/stats`,挂 gate;usage 端点不迁路径 | 管理侧统计域语义;PAT 并发闸全 router 铁律;usage 迁路径会破 App |
| D9 | 组 UI 级联照 artist F4 模式(父 useWatch + true→false 瞬间复位子开关并强制 touched);徽标只加一枚「统计」 | 完整先例复刻,不发明新形态 |
| D10 | 移动端补「统计」三态门入口 | 与 PC 口径一致,成本一枚 moreItems 条目 |
| D11 | 统计查询本身不写 audit_events(与 usage stats 读操作对齐);组 flag 变更照旧写审计。注:放宽后持权组员可查全量项目上传分布,属新增敏感读面;若后续要求可追溯,最小方案=仅对非 admin 调用写一条 read 审计 | 读操作不埋点为现状惯例,取舍显式化 |

## 7. 测试计划(后端 pytest;模板 test_group_file_deleter.py / test_directory.py)

新文件 `api/tests/test_upload_stats.py`(**前置**:跑测前新 relation 须先重推到测试 store——照 test_group_file_deleter.py:12-14 的 ⚠️ 说明;未重推则全部组开关用例必挂。另:存量 test_usage_stats.py 的断言含响应体(totals/by_platform/daily 等)与权限矩阵(admin-200/无权-403),守门放宽后逐字仍成立,无需改动):
1. 分类矩阵:普通图片(jpg/heic+octet-stream)/livp(.livp + 空 mime)/口播视频(filename 含关键词)/口播视频(minio_key 路径段含关键词)/普通 mp4/mov/mime video 无扩展名/zip/mp3/svg/.ts 视频 → 期望桶;.ts 与 .svg 落「其他」用例**夹具 content_type 须为空或非视频/非图片 mime(如 octet-stream)**——若配 video/* mime,按同构口径会落「生活视频」,口径才自洽;**桶互斥**:content_type=image/png + .mp4 文件名的冲突资产恰好落「生活视频」一桶,total == count(*);**livp 置顶**:.livp + video/* mime 仍落「生活图文」;
2. 软删不计:窗口内软删资产不计数;恢复后重新计数;**项目活性**:归档(is_archived=true)/软删(deleted_at 非空)项目的资产对 admin 与非 admin 一律不计、行不出现;
3. 窗口与归一:上海时区边界(2026-11-01 00:00+08 的资产计入 date_from=2026-11-01)、结束日 23:59 边界、from>to 422、日期差 >365 422、**恰差 365 天(=366 自然日窗口)放行**(边界正例,**夹具勿取 9999 年份**)、**date_to=9999-12-31 → 422(OverflowError 守卫)**、缺参 422、project_ids 含非法 UUID 字符串 422、**空串视同缺省=全部**、project_ids 超 200 个 422、**恰 200 个放行**(边界正例);
4. 项目过滤:多选只统计所选;不可见/归档/软删 id 静默丢弃;缺省=全部 in-scope;
5. 权限矩阵:无 flag 403 / 仅父 403 / **仅子无父 403(合取防不一致 tuple 的核心性质,显式钉死)** / 父∧子上传 flag 200 / 父∧子(上传)但查 usage 端点 403 / **父∧子(usage)组员 → /admin/usage/stats 200(usage 侧非 admin 正例——缺它则 require_usage_stats_viewer 误 check 错 relation 也全绿,本需求核心交付物静默坏)** / org admin 直通全量;
6. 零泄露与死角:非 admin 对可见项目内未受邀 sensitive folder 资产不计数;public 项目非敏感 folder 计入;零可达 folder 时 rows 为宇宙零填充全 0 行(非空集);**仅 folder 级 grant、项目不可达**(store.fga.yaml:112-114 场景):该项目行照常出现且计数(不零填充),显式 project_ids 含它时同样合法计数,不含它时不出现,**窗口内计数为 0 时不产生行**(有数即现语义);**仅 sensitive folder 受邀(:127-134)、项目不可达**同走此路径,补一例防实现者只测普通 grant 分支;
7. 聚合自洽:summary == rows 逐列和;零填充项目返回 0 行值;排序正确。

扩展 `test_directory.py`:三 flag 的 tri-state PATCH / 建组全量 / 审计 details / 删组清 tuple;级联复位属前端行为不在后端测。
扩展 /me 测试:三字段回显(admin true / 组员 true / 无关用户 false / FGA 抖动 false)。
前端:无 runner,`pnpm lint` + `pnpm build` 绿即门槛,行为验收走 §9 清单。

## 8. 部署顺序(dev → prod 各自完整走一遍)

1. **先推 FGA model**:`cd material-storage/api && bash scripts/openfga_write_model.sh`(脚本头部注明的既定跑法;CWD 必须在 api/ 下,脚本按相对路径找 `../poc/openfga/store.fga.yaml`;store.fga.yaml 新三条 relation;旧代码不引用新 relation,推后即无害);随后按脚本惯例重启 **ms-api 与 ms-worker**(worker 不引用新 relation,不重启亦安全,按仓库惯例写全);
2. 部署 ms-api 代码(无 DB 迁移;prod 部署前照例对账 alembic current vs head);
3. SPA 构建 + **单独分片推**(deploy_lan 不同步 SPA,既有惯例);
4. 验证:三入口指纹一致;§9 验收矩阵抽测;
5. `scripts/changelog.md` 当天记条。
回滚:api 还原代码 + SPA 还原分片即可(FGA model append-only 遗留三条 relation 无害);无迁移、无数据变更,风险低。

## 9. 验收清单(真机/dev)

- [ ] admin:chip「统计」可见 → 面板两卡片 → 使用统计与上传统计页均可用(原使用统计行为无回归);
- [ ] 建组开「统计」+仅「文件上传数量统计」:组员 chip 可见 → 面板只见上传统计卡片;直开 /admin/usage 呈 Alert、API 403;
- [ ] 建组开「统计」+「使用统计」:组员经面板进使用统计页可用、/admin/usage/stats API 200;
- [ ] 关父开关保存:两子开关被复位,组员 chip 消失;
- [ ] 上传统计页:项目多选(**含 2+ 项目同选——单选下验不出数组序列化退化**)、全选、日期范围、四列+合计、汇总行;数字与手工 SQL 抽对一致;
- [ ] 软删资产不计(删一条刷新核对);sensitive folder 计数口径(未受邀组员 vs admin 数字差异符合预期);
- [ ] 移动端「更多」可见统计入口,页面自适应可用;
- [ ] App 端使用统计无回归(App 侧零改动确认)。

## 10. qdev 分包建议(契约 = 本文档 §3-§5,API/字段名冻结)

- 包 A(后端):FGA model + permissions/deps/auth + directory 七件套 + upload_stats router/service + models + 测试;
- 包 B(前端):types/hooks + AppHeader/MobileTabBar + 面板页 + 上传统计页 + AdminGroupsPage 级联 + AdminUsageStatsPage 守卫微调。
两包可并行(字段契约已冻结),合流后走 §8 部署。

## 11. 风险与边界

- FGA 部署顺序违反(model 后推)→ require_* 500:§8 第 1 步铁律,已在 deps 先例注释与本文档双处钉死;
- 非 admin folder_id IN 列表极大(数千 folder)时 SQL IN 变长:当前量级无碍,增长后可改 VALUES join(记 §12);OpenFGA `list_objects` 无分页兜底,可达对象超单响应上限会静默截断致漏计(permissions.py:158-177,盲搜继承的既有行为,非新引入)——统计对漏计更敏感,量级上涨后改带 continuation 的枚举(记 §12);
- 口播视频依赖命名约定,归类随资产自身 filename/minio_key 即时计算(非快照):**资产改名(批量前缀)会同步重写 filename+minio_key(assets.py:851/969/1019)→ 改变其归类**;文件夹改名/移动**不重写存量 assets.minio_key**(folders.py:205-207,仅重算 folder.minio_prefix)→ **不影响存量归类**,但此后再对资产做批量改名时新 key 按新 prefix 拼接(间接交互)。页面 tooltip 按此口径注记,勿写「文件夹改名导致归类漂移」;
- **2026-11-06 用户拍板(修订上条)**:口播视频路径匹配改为按当前位置(folder.minio_prefix+filename);落库 minio_key 为上传时刻快照不参与匹配 → 文件夹改名/移动**即时改变**存量资产的口播归类(目录即分类,挪出「口播视频」夹即不再计),上条「不影响存量归类」自本日起不再成立,页面 tooltip 口径注记已同步;
- 百度导入资产的「上传时间」= 导入完成时刻(非网盘原始时间),同上注记;
- .ts/.svg 等刻意排除项落「其他」:与 thumb 派发同口径,避免两套清单漂移;
- 补充行(项目不可见仅 folder 可达)回显 project_code 略超盲搜先例(盲搜回显不含 code,models/__init__.py:171-176)——泄露量级可忽略,**该取舍已记录于本文档,上线后勿当缺陷回报**;tooltip 口径注记带一句「行内项目编码以当前库为准」,保持「宁漏勿泄」论证严谨;
- 前端项目多选无硬上限:>200 项目的组织全选会直吃后端 422,§5.2 查询前对 >200 选择给 message.warning + placeholder 提示「查全部请清空选择,勿逐个手选」(截断/分批查询记 §12 遗留)。

## 12. 遗留与后续

- assets.created_at 单列索引(量级增长后仿 0018 补);
- folder_id IN 大列表 → VALUES join 优化;OpenFGA list_objects 分页枚举(防静默截断);
- 前端项目多选 >200 的截断提示已做轻量 warning,分批查询/Hook 截断另期;
- 统计结果导出(CSV)/按用户维度拆分:未在需求内,不做;
- 面板未来新子模块:照 §3 模式加一条 relation + 一张卡片 + 一个守门,扩展路径已验证。
