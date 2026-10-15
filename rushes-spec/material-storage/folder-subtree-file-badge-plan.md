# Folders 侧栏「子树含文件」标记方案

> 2026-10-15 调研定稿。调研全程未动代码;**语义已由用户拍板:整棵子树下有文件即标记**;
> **D1 亦已拍板(同日):仅用实心填充的文件夹图标标识,不显示数字、不加 tooltip**。
> 本方案为纯文档,实施等用户明确指令。
> 背景:公司要求每个项目初始(经目录模板)批量创建多层文件夹,实际使用中用户无法分辨
> 哪些文件夹里有文件,只能逐夹点进去看——侧栏从未携带任何文件侧信息。

---

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 成本 | **低**:后端 ~40-60 行 + 前端 ~30 行 + 若干缓存失效点,合计 **0.5-1 人天**(含测试与部署) |
| DB 迁移 | **无**(纯读侧扩展,复用现有索引 `ix_asset_folder_created`) |
| FGA / 权限模型 | **无改动**(计数只对已过滤的可见夹列表计算) |
| 新端点 | **无**(`GET /folders` 出参加字段,默认值向后兼容) |
| 部署 | api restart + SPA 替换;无迁移、无 FGA、无 constraints 变更 |

改动三块:①`list_folders` 出参加子树计数字段;②`FolderTree` 图标实心化渲染;
③上传/删除/恢复的前端缓存失效补 `['folders']`(现状只失效 `['assets']`,不补则标记滞后)。

---

## 1. 现状数据流(调研证据)

- 侧栏数据源:`GET /api/v1/folders?project_id=` 一次性返回项目下**全部**文件夹的扁平列表
  (folders.py:169 `list_folders`,按 `minio_prefix` 排序;sensitive 夹按 OpenFGA can_view
  过滤,普通夹项目成员全见)。目录模板建的夹再多也只在这一个响应里,无分页。
- 前端 `FolderTree.tsx` 的 `buildTree`(FolderTree.tsx:35)在客户端按 `parent_folder_id`
  拼树;`FolderOut`(models/__init__.py:298)**没有任何文件侧字段**。
- 文件与夹的关系:`assets.folder_id` 外键直连(tables.py:141)+ `deleted_at` 软删;
  索引 `ix_asset_folder_created(folder_id, created_at)`(tables.py:172)前缀(folder_id)
  可用于按夹聚合(不含 deleted_at 列,非 covering,性能按 §7 评估)。
- 文件列表按夹分页拉取(`useAssets(folderId, page)`,assets.py:262 `limit≤500`)——
  这是痛根:文件是否存在只能逐夹点入才知道。
- 前端缓存:`useFolders` 的 queryKey 为 `['folders', projectId]`(hooks.ts:243);
  文件上传成功(upload-store.tsx:138/152 两处)与删除/恢复(hooks.ts `useDeleteAsset`
  /`useRestoreAsset`)目前**只失效 assets 族(`['assets']`/`['assets-trash']`),
  不失效 `['folders']`**。

## 2. 语义定档(已拍板)

**标记条件 = 该文件夹整棵子树(含自身直接子文件)存在活跃文件**
(`deleted_at IS NULL`),即 `subtree_file_count > 0` 则显示标记。

- 回收站文件不计(与「文件夹里有东西」直觉一致;回收站占位仍照旧挡删夹,互不影响)。
- 父夹自身无直接文件但深层后代有 → 父夹**仍标记**(模板多层结构下只标直接包含等于
  让用户继续逐层展开,失去意义)。
- **子树口径必须走 `parent_folder_id` 结构链回累,禁用 `minio_prefix` 前缀匹配**:
  `FolderCreateIn.minio_prefix` 允许客户端自拟(models/__init__.py:294),`name` 也未禁 `/`,
  前缀不是结构的可信投影;结构链是唯一真源。

## 3. 后端改动(工作包 WP-1)

### 3.1 `FolderOut` 加字段(models/__init__.py:298)

```python
    # 活跃文件子树计数(仅 list 端点回填;create/get 单条响应均为默认 0,见 §3.4)
    subtree_file_count: int = 0  # 整棵子树(含本夹直接)活跃文件数,>0 → 实心图标
```

默认 0 → 加字段向后兼容,既有消费方(含 `get_folder` 单条、BaiduNewTaskModal 的
useFolders)不破。`file_count`(本夹直接数)在 §3.2 查询里顺手可得,但 D1 定为纯
图标后前端无处使用,按 D3 建议不暴露(D3 若拍板要双字段再放开,零成本)。

### 3.2 `list_folders` 补一条聚合查询(folders.py:169)

拿到可见夹列表后(权限过滤**之后**,见 §6):

```python
    folders = res.scalars().all()
    direct: dict[uuid.UUID, int] = {}
    if folders:
        rows = await db.execute(
            select(Asset.folder_id, func.count())
            .where(
                Asset.folder_id.in_([f.id for f in folders]),
                Asset.deleted_at.is_(None),
            )
            .group_by(Asset.folder_id)
        )
        direct = {fid: cnt for fid, cnt in rows.all()}
```

### 3.3 子树回累(Python 侧,一次后序遍历)

文件夹列表本就全在内存,建 children 映射后**只从真根**(`parent_folder_id is None`)
后序遍历累加,O(夹数×深度),几十上百个夹可忽略不计:

```python
    children: dict[uuid.UUID | None, list[Folder]] = {}
    for f in folders:
        children.setdefault(f.parent_folder_id, []).append(f)
    subtree: dict[uuid.UUID, int] = {}
    visited: set[uuid.UUID] = set()        # 防御环(FK 自引用,正常无环,兜底即可)
    def _roll(fid: uuid.UUID) -> int:      # 后序:先算后代再自累
        if fid in visited:
            return 0
        visited.add(fid)
        total = direct.get(fid, 0)
        for c in children.get(fid, []):
            total += _roll(c.id)
        subtree[fid] = total
        return total
    for f in children.get(None, []):       # 只从真根起(普通根 + 可见 sensitive 根)
        _roll(f.id)
```

出参回填**必须用 `subtree.get(f.id, 0)`,禁止 `subtree[f.id]`**(缺键=孤儿行,见下)。

**孤儿行刻意不回填(输出默认 0)**:敏感夹下可建普通子夹(create_folder 允许,需
sensitive 父的 can_upload,folders.py:63-79)。当 sensitive 父对当前用户不可见而被
list_folders 过滤后,这些子夹(及其后代)的**行仍在返回列表里**,但它们的
parent 不在可见集内 → 不在真根遍历的可达集上,`subtree` 缺键 → 按默认 0 输出。
这是**刻意语义而非实现巧合**,理由见 §6.3/§6.4(受众信任边界口径)。被邀请进
sensitive 夹的用户能看到父夹(真根),其下子夹可达 → 正常回填(受信边界内,§6.4)。
测试 T8 钉死该口径。

### 3.4 `get_folder` 单条端点:不回填,维持默认 0

单条消费方 `useFolder`(FolderDetailPage)只取 `my_can_*` 权限位与 name 等展示字段,
无计数需求;给它补子树计数需额外按项目拉全夹,收益为零。**在 FolderOut 字段注释里
写明「仅 list 端点回填」**,防后来者误用。

## 4. 前端改动(工作包 WP-2)

### 4.1 `types.ts` Folder 加可选字段

```typescript
  subtree_file_count?: number;
```

### 4.2 `FolderTree.tsx` 图标实心化(D1 已拍板)

现有图标三分支(FolderTree.tsx:94-101):sensitive → accent 色 Folder;有子夹 →
FolderOpen;叶子 → Folder。改动 = `subtree_file_count > 0` 时给当前图标加 `fill`
(lucide 图标透传 SVG 属性,默认 `fill="none"`,实心/空心即形状级区分,色弱可辨):

```tsx
const hasFiles = (f.subtree_file_count ?? 0) > 0;
// 以叶子普通夹为例;三分支同法:
<FolderIcon size={14} strokeWidth={1.7}
            fill={hasFiles ? 'currentColor' : 'none'}
            style={{ color: 'var(--ms-ink-muted)' }} />
```

- fill 取描边同色(currentColor);具体观感(sensitive 夹实心是否降透明度、
  FolderOpen 形态实心效果)实施时真机微调。注:仓内 `lucide-react` 为较新
  major(^1.16.0),`fill` 透传是否覆盖默认 `fill="none"` 须实机确认一次;若不
  生效,兜底写法 `style={{ fill: 'currentColor' }}`(SVG 属性级,必然生效)。
- 无数字、无 tooltip(D1 定档:仅图标)。
- `selectMode`(百度备份目标选择树)同组件同数据,标记自动出现——帮助用户选到
  「真的有东西」的目录,无需特殊处理;`disabledIds` 禁选语义与标记正交。

### 4.3 FolderDetailPage 头部计数文案(决策点 D2,默认不做)

想法:点进某夹后,右侧文件列表顶部的夹名旁顺带一行小字,如「本夹 12 · 含子目录
共 34」。注意 FolderDetailPage 现只挂 `useFolder` 单条,做此项需补挂 `useFolders`
(列表端点本仓既有,命中缓存时零新请求)。D1 已定为纯图标不显示数字,为保持
一致**默认不做**;若想要数字提示再拍板开启(需同时放开 D3 的 `file_count` 字段)。

## 5. 实时性:缓存失效补点(工作包 WP-3)

标记数据随 `['folders', projectId]` 缓存走,以下操作会改变活跃计数、须补失效:

| 位置 | 现状 | 改动 |
|---|---|---|
| upload-store.tsx:138(upload-success 2s 防抖后) | 只失效 `['assets', folderId]` | 追加 `qc.invalidateQueries({ queryKey: ['folders'] })`(前缀匹配,store 只有 folderId 不必透传 projectId;防抖为 per-folder 计时器:单夹串行上传无放大,K 夹并行上传最坏各触发一次 folders 重拉,量级可忽略) |
| upload-store.tsx:152(批次 complete) | 同上 | 同上 |
| hooks.ts `useDeleteAsset`(软删,活跃数减) | 只失效 assets/assets-trash | 追加同款前缀失效 |
| hooks.ts `useRestoreAsset`(恢复,活跃数增) | 同上 | 同上 |
| hooks.ts `usePurgeAsset`(回收站彻底删) | — | **不必改**:purge 对象已是 `deleted_at` 状态,活跃计数不变 |
| FolderTrashModal「一键清空」(FolderTrashModal.tsx:73-83,裸 hard delete) | 只失效 assets-trash/assets | **不必改**:purge 族,活跃计数不变(点名防实施者误改) |
| 批量前缀 / meta 更新 / 标签 | — | 不必改(不改计数) |
| 百度导入/覆盖(worker 侧直写 DB;overwrite 链路会物理清除活跃资产使计数**减**,非只有增量) | — | 不做实时失效(前端无失效时机,与 assets 列表现状一致);刷新见下行边界 |

漏补的后果仅是标记短暂滞后,无正确性风险。刷新边界:全局 `staleTime=30s` 且
`refetchOnWindowFocus=false`(App.tsx:39)——重进页面且距上次取数 >30s 才重取,
常驻页面依赖上表失效点(无轮询、无 focus 重取)。

## 6. 权限与边界分析(为何无泄露)

1. **计数只在可见性过滤之后计算**(§3.2 查询的 `IN` 集就是过滤后的可见夹):
   不可见 sensitive 夹的文件数不出现在任何返回值里。
2. **sensitive 夹限定直挂项目一级**(建夹时 enforce,folders.py:91-92),**不可能成为
   普通夹的后代** → 任何可见夹的子树回累都不可能吸进不可见 sensitive 夹的计数。
3. **敏感夹下的普通子夹孤儿 —— 计数一律不回填(0),按项目 visibility 分述理由**:
   sensitive 父被过滤后(list_folders 的 sensitive 过滤不分 visibility),
   `is_sensitive=False` 的子夹及其后代仍在返回列表里(普通夹项目成员全见,
   folders.py:198-204)但前端拼树不可达。这类夹的 FGA 内容权限链是断的:
   create_folder 给敏感父下的普通子夹写的是 `folder:<子> parent folder:<敏感父>`
   (folders.py:135-147),而 FGA 图上 `folder:<敏感父>` 永远没有任何 tuple
   (bootstrap_sensitive_folder 只写 `sensitive_folder:<父> parent project`,
   permissions.py)→ 除系统 admin 外任何人 `can_view(folder:<子>)=false`。
   - **私有项目(绝大多数)**:链断即内容真不可见(`GET /assets?folder_id=<子>`
     403,assets.py:272-289),行却返回给全体项目成员——回填真实计数=向无
     sensitive 授权者暴露「此夹有 N 个活跃文件」,违背本仓反规模探测口径
     (folders.py:324-328 删夹文案不计数、assets 403 不暴露存在性)→ **必须 0**;
   - **public 项目**:非敏感夹有 public_browse 旁路(assets.py:269-285,任何登录
     用户可列),回填本无探测面(计数不新增信息);且计数的**唯一渲染面**是
     FolderTree,`buildTree` 从真根拼树、孤儿行永不渲染(FolderTree.tsx:35-105)
     ——0 少报无任何受众。统一 0 属「接受 API 层少报」,换取口径单简(不为窄场景
     按 visibility 分支回累)。注意:孤儿行**在返回列表里**,ProjectDetailPage 的
     纠正 effect(仅当 activeFolderId 不在列表时回落首夹)不会拦直链——public
     项目直链孤儿夹会看到文件网格本身(旁路,信息多于计数),但徽标只存在于侧栏
     树且树不渲染孤儿,计数 0 仍无受众,结论不变。T8 含 public 变体钉死。
   实现上孤儿不在真根遍历可达集,天然输出 0(§3.3)。孤儿行返回列表本身是既有行为,
   不因本方案扩大。
4. **回填口径统一按「受众信任边界」裁断(与 §6.3 同一原则的两面)**:敏感夹下的
   普通子夹内容权限链都是断的(§6.3 所述,被邀请者同样 can_view=false),区别只在
   **谁拿得到这行**:
   - 敏感父**不可见**(孤儿行):行返回给全部项目成员,受众含无任何 sensitive
     授权者 → **不回填(0)**;
   - 敏感父**可见**(仅被邀请者/系统 admin 的列表):行的受众全部在 sensitive 夹
     信任边界内(由 can_admin 者显式授予)→ **正常回填**,属边界内元数据——被邀请
     者本就能看到敏感区结构(子夹行就在其树里),子树聚合数未越出边界。
   对权限链完整的可见夹同理更无问题:能查看该夹(can_view)的用户本就能翻文件列表
   自己数出来。**显式承认一处张力**:被邀请者会看到其无权打开(can_view=false)的
   敏感区子夹的真实计数——这是受众信任边界裁断的有意接受(被邀请者已在敏感区
   授权圈内,能看到子夹行/结构),非疏漏,T8 钉死。依此口径,§3.3 的「结构可达即
   回填」**无需叠加逐夹 can_view 裁剪**
   (那会让 list 端点对每个夹各发一次 OpenFGA 查询,得不偿失);与删夹 409 文案防
   规模探测(folders.py:324-328,防御的是无 can_view 的 uploader)不冲突。
5. **软删不计**;恢复造成的计数变化由 §5 失效点覆盖;purge 只作用于已软删行,
   活跃计数不变,无需失效(§5)。
6. **口径依赖的现状前提**:§6.3/§6.4 的裁断依赖「敏感父下普通子夹 FGA 链断裂」
   这一**现状事实**(`folder:<敏感父>` 永无 tuple;permissions-model-v4.md 与
   decisions/ 均无背书,亦无用例钉住)。若未来有人「修复」该链(给
   `folder:<敏感父>` 补 tuple 或放开 sensitive 嵌套),孤儿口径、三态裁断与 T8
   全部须回审。T8 顺带断言链断(被邀请者对子夹 `GET /assets` 403)作回归锚。

## 7. 性能评估

- 每次 folders list 调用多一条 `GROUP BY folder_id` 聚合,命中 `ix_asset_folder_created`
  索引前缀(folder_id),项目级规模(几十夹/几千-几万文件)毫秒级;该接口只在进项目
  页/失效时调用,不是每夹一查。
- 出参多一个 int × 夹数,体积可忽略。
- 子树回累纯内存,见 §3.3。
- 上传失效与 assets 失效共用 per-folder 2s 防抖:单夹上传无放大;K 夹并行上传
  最坏 K 次 folders 重拉(react-query 前缀失效),量级可忽略。

## 8. 测试要点(工作包 WP-4)

后端新测试(建议 `api/tests/test_folder_file_counts.py`,沿隔离栈跑法):

- T1 子树计数精确:多夹多文件,各夹 `subtree_file_count` = 自身直接 + 全部后代之和;
- T2 深层回累:三层嵌套,文件只在最深层 → 三层祖先 `subtree_file_count` 全部计入
  该文件(爷爷=爸爸=最深层=1);
- T3 软删排除:软删后计数减,恢复后加;
- T4 空模板项目:全夹 `subtree_file_count` 为 0(原始痛点场景回归);
- T5 权限:不可见 sensitive 夹的文件不计入任何可见节点;被邀请者视角 sensitive 夹
  自身计数正确;
- T6 `get_folder` 单条 `subtree_file_count` 为默认 0(契约钉死);
- T7 客户端自拟 `minio_prefix` 与结构不一致时,子树口径仍按 `parent_folder_id`
  (防实现退化为前缀匹配);
- T8 孤儿结构(私有 + public 两变体):敏感夹下建普通子夹(含孙夹与文件),普通
  成员视角 list 200、可达节点计数正确、**孤儿行 `subtree_file_count=0`**(钉死
  §3.3/§6.3 口径;public 变体同为 0=接受 API 层少报);被邀请进敏感夹的成员视角
  下同批夹计数正常回填。造数注意:此类子夹 can_upload 链同样断(除系统 admin 外
  无人能传),文件须以系统 admin 上传(X-User-Id 通道,参照 test_v4_permissions.py
  现有跑法)或直写 DB——线上该结构的文件来源本就只有系统 admin 与百度导入两条,
  属窄场景。另含两个变体:邀请过期(explicit_invited_* 到期 → 敏感父重新不可见 →
  原回填计数回落 0,时间性边界)与链断回归断言(被邀请者对子夹 `GET /assets` 403,
  钉住 §6.6 前提)。

前端:web build 绿 + 真机抽测(上传后图标即时实心、软删/恢复后即时变化、三种图标
分支(sensitive/有子夹 FolderOpen/叶子)各验实心与空心一例、百度备份目标树同现标记、
移动端 Drawer 目录树同样生效)。

## 9. 工作量与部署

| 包 | 内容 | 估时 |
|---|---|---|
| WP-1 | 后端字段+聚合+回累+单条端点注释 | 1-2h |
| WP-2 | 前端 types+FolderTree 标记(+D2 头部文案) | 1-2h |
| WP-3 | 缓存失效 4 处 | 0.5h |
| WP-4 | 后端测试 8 例 + 真机抽测(T5/T8 需构造 OpenFGA 邀请与多视角) | 2-3h |

部署:dev 先行(restart ms-api-dev + SPA 替换)→ 真机验证 → prod 同款。无迁移/无 FGA/
无 .env/无 constraints 变更,可与其他功能同批发布。回滚 = SPA 换回备份 + 代码切旧
commit 重走通道(无状态残留)。发布前按 AGENTS.md 约定追加 `scripts/changelog.md`
当日条目(含 commit hash 可溯)。

## 10. 决策点状态

- **D1 视觉形式 —— 已拍板(2026-10-15)**:仅用实心填充的文件夹图标标识有内容的
  文件夹;不显示数字、不加 tooltip。原建议(圆点+title 数字)作废。
- **D2 详情页头部计数文字 —— 待拍板,默认不做**:内容=点进文件夹后,在右侧文件
  列表顶部的夹名旁显示「本夹 12 · 含子目录共 34」一行小字。既然 D1 选了纯图标
  (不出现数字),此项默认不做保持一致;要做需同时放开 D3 的 `file_count`。
- **D3 接口返回什么 —— 待拍板,建议只给 `subtree_file_count` 单字段 int**:标记
  本身只需要「子树有无文件」,但 SQL 聚合顺手就产出精确数字,int 与 bool 同价,
  将来显示数字/排查问题都用得上;`file_count`(本夹直接数)当前无消费方,不暴露。

---

*调研与方案:2026-10-15,纯只读调研(未动代码),实施等用户明确指令。*
