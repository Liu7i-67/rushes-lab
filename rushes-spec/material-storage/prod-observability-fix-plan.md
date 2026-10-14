# prod 三问题治理方案:livp 预览修复 / 审计事件过滤补全 / 管理员备份任务视图

> 2026-10-14 调研定稿。调研全程未动代码;prod 只做了只读取证(容器内 import 探测、启动日志、数据库统计 SQL)。
> 三个问题同源于「百度备份上线后缺少面向管理员的观测面 + 一处部署期依赖遗漏」,拆为三个工作包:
> **W1(纯运维,可立即执行)/ W2(前端小改)/ W3(新功能,后端+前端)**。W1 与 W2/W3 无依赖,可并行。

---

## 0. 调研结论摘要(证据见三份调研记录,此处只列结论)

| # | 问题 | 根因 | 性质 |
|---|------|------|------|
| 1 | 蕾蕾/图文素材/生活美照 大量 livp 无法预览(含历史数据) | ① prod `ms-worker` 容器缺 `pillow-heif`,HEIC 静态图(iPhone「高效」格式默认)解码抛 `UnidentifiedImageError` → 无缩略图 → `thumbnail-url` 404 → 前端弹「还在生成(或生成失败)」;② 21 个 2026-09-03/04 网页直传的历史 livp 从未入队(livp 分派代码 09-03 才上线),且 `backfill_thumbnails.py` 在 dev/prod 都从未执行过 | 运维修复 |
| 2 | 审计有「备份文件导入」事件但过滤下拉没有 | 前端硬编码数组 `EVENT_TYPES`(AdminAuditPage.tsx:39-50,24 项)漏 `baidu_file_imported` 等 33 项(后端实际写入 55 种,前端只列了其中 22 种 + 2 个从不写入的死选项);后端 `event_type` 参数是任意字符串精确匹配无白名单,**后端零改动** | 前端小改 |
| 3 | 管理员无途径查看全系统备份任务 | 15 条 `/api/v1/baidu/backup/*` 端点全部「仅本人」(`get_current_user` + `_own_task`),无任何 admin 端点;管理后台无对应页面 | 新功能 |

**prod 实测基线(2026-10-14,修复验收对照用)**:
- 全库未删除 livp 共 485:**442 个失败于 `UnidentifiedImageError`(0 个有缩略图)、22 个成功(JPEG 静态图,连实况视频都有,证明 ffmpeg/MinIO/链路其余部分正常)、21 个从未处理**(无缩略图无失败标记,审计来源 `upload`);
- 目标目录「生活美照」(23 个同名夹中唯一带 livp 的):167 个 livp,161 失败 / 6 正常;
- `ms-worker` 启动日志明示「pillow_heif 不可用,HEIC 静态图的 livp 预览将失败」(workers/main.py:45 预警如期触发);ffmpeg 7.1.5 在容器内正常。

**根因背景**:部署方式是 rsync 代码 + restart 容器、镜像从不重建;`pillow-heif` 是随 livp 功能(2026-09-03,77640de)新增的 pip 依赖,只在镜像构建时装入。dev 于 2026-09-04 部署时手动进容器装过(changelog 2026-09-04 节有记录),**但 2026-10-14 实测 ms-worker-dev 里已复丢(容器曾被 recreate,手动 pip 安装随容器层丢失)**——即两环境当前都缺;prod 自 2026-09-07 首次部署起的历次部署都没装过。同类隐患:任何 `--force-recreate` 都会丢手动 pip 安装。

---

## 1. W1:livp 预览修复(纯运维,建议立即低峰执行)

### 1.1 步骤(prod,dev 顺带核查)

```bash
# 步骤 0:预检基线 —— 跑附录 B 的 SQL-1/SQL-2 记录修复前数字(对照上文基线);
#         dev 依赖核查(2026-09-04 装过的已因容器 recreate 复丢,2026-10-14 实测无 pillow-heif,
#         即两环境都要装,dev 先跑作演练):
ssh hh2 'docker exec ms-worker-dev python -c "import pillow_heif; print(pillow_heif.__version__)"'

# 步骤 1:prod worker 容器装依赖(容器 pip 已配清华源;ms-api 无 import 依赖可不装)
#   装前记录 Pillow 版本防连带升级(2026-10-14 实测 prod/dev 均 12.3.0 ≥ pillow-heif 1.8.1
#   要求的 11.1,正常不会动 Pillow;若 pip 输出显示将 Upgrade pillow → 中止人工评估):
ssh hh2-prod 'docker exec ms-worker pip show pillow | grep -E "^Name|^Version"'
ssh hh2-prod 'docker exec ms-worker pip install "pillow-heif>=0.13"'
#   兜底:若容器无外网 egress —— 本机(Windows)下载须指定 Linux 平台,否则得到
#   win_amd64 wheel 容器内装不上;⚠ 单写 manylinux2014 会静默解析到旧版 1.0.0
#   (新版只发 manylinux_2_27/2_28 tag,2026-10-14 本地实测),须双平台并列取新版:
#   pip download "pillow-heif" --no-deps -d wheels/ \
#     --platform manylinux_2_28_x86_64 --platform manylinux2014_x86_64 \
#     --python-version 312 --only-binary=:all:
#   → docker cp wheels ms-worker:/tmp/ → docker exec ms-worker pip install /tmp/wheels/*

# 步骤 2:重启生效(import 发生在进程启动;compose 服务名无后缀,按容器名重启)
ssh hh2-prod 'docker restart ms-worker'

# 步骤 3:验证 worker(顺带留痕 Pillow 版本,防连带升级)
ssh hh2-prod 'docker exec ms-worker python -c "import pillow_heif, PIL; print(pillow_heif.__version__, PIL.__version__)"'
ssh hh2-prod 'docker logs ms-worker --since 2m 2>&1 | grep -i heif'   # 应无"不可用"告警

# 步骤 4:回填历史 + 失败存量(默认模式 = 入队所有无 thumbnail_key 的
#         image/*/video/*/.livp 资产:442 个失败 + 21 个未处理的 livp 为主,
#         也可能含少量图片/视频存量,均幂等无害;成功时会清掉 thumbnail_failed 标记)
ssh hh2-prod 'docker exec ms-api python -m scripts.backfill_thumbnails'

# 步骤 5:监控(WorkerSettings max_jobs=4,main.py:676;~463 个 livp job,
#         单 job=拉几 MB+解码+ffmpeg≤45s,预计 0.5~1.5 小时)
#   排空判据 = 复跑附录 B SQL-1,thumbnail_key 覆盖率不再增长即收尾
#   (grep 日志只作辅助:纯静态图 livp 的成功路径业务日志不含 "livp" 字样)
ssh hh2-prod 'docker logs ms-worker --since 5m 2>&1 | grep -c livp'
```

**dev 演练(必跑)**:dev 与 §4「dev 先跑作演练」对齐——步骤 0 核查已实测 dev 同样缺依赖,按同款步骤 0-5 在 dev 先执行一遍,命令差异仅三处:`ssh hh2-prod` → `ssh hh2`,容器名 `ms-worker`/`ms-api` → `ms-worker-dev`/`ms-api-dev`,验证 SQL 连 `ms-db-dev`。

### 1.2 验收标准

1. 附录 B SQL-1 复跑:`UnidentifiedImageError` 行**消失**(硬判据);修复成功会清掉 `thumbnail_failed` 标记(workers/main.py:372),442 行将并入「(无标记)」行——该行 total 应从基线 43 涨至 ≈485 且 `has_thumb ≈ total`(已知的 >200MB 跳过等特例除外);若个别源文件真实损坏,装依赖后仍解码失败会落**新** fail token,逐条人工归因(源文件损坏)后可例外通过,但不得再出现 `UnidentifiedImageError`;
2. SQL-2:目标目录 livp `ok` 数 ≈ 167(6 个既有 + 161 个修复);
3. UI 抽查:以蕾蕾账号打开「生活美照」中之前失败的 livp——静态图显示 + 「播放实况」可播;
4. `docker logs ms-worker` 无新增 `livp thumbnail fail ... UnidentifiedImageError`。

### 1.3 风险与注意

- **重启会打断在途 job**:百度备份任务有租约 + sweeper(5min cron)自愈;livp/缩略图 job 幂等,即使被打断 backfill 语义也会再覆盖 → 建议低峰执行;
- backfill 与在线业务共享 arq worker(单进程并发 max_jobs=4),livp 单 job 为「拉几 MB + 解码 + ffmpeg ≤45s」量级,低峰无感;
- **不重启不生效**;装完不跑 backfill 则 442+21 个存量依旧失败(失败路径被 worker 内部捕获正常返回,**arq 不会自动重试**,workers/main.py:414-423);
- **回收站(软删)livp 不在本次范围**:backfill 硬编码只扫 `deleted_at IS NULL`(backfill_thumbnails.py:50),而 restore 不重新入队缩略图(既有行为)——回收站里的 livp 恢复后仍无缩略图,恢复后再重跑一次 backfill 即可覆盖(恢复行会命中默认模式),记入 §8 遗留;
- 执行后记账:changelog 追加;deploy-hh2 技能补一条 prod 实例的「新增 pip 依赖须手动装容器」检查项。

### 1.4 可选代码加固 W1-B(小,建议并入 W2/W3 分支)

`AssetPreviewModal.tsx` 对 livp 且 `asset.tags.thumbnail_failed` 非空时,文案从「实况照片预览还在生成(或生成失败),请稍后刷新重试。」(AssetPreviewModal.tsx:237 原文)改为明确失败态(「预览生成失败(原因标记:{token}),可下载原片查看,恢复请联系管理员」)。数据已随 AssetOut 下发(types.ts:269),纯前端小改,消除「永远稍后重试」的误导。

---

## 2. W2:审计事件类型过滤补全(前端小改,后端零改动)

### 2.1 改动点

| 文件 | 改动 |
|------|------|
| `web/src/pages/AdminAuditPage.tsx:39-50` | `EVENT_TYPES` 数组追加附录 A 的 33 项(含 `baidu_file_imported`);删除 2 个后端从不写入的死选项 `approval_notified`、`invite_notified`(见决策点 D1);顺带修正 :36-38 过时注释(Select 无 tags 模式,「可输自定义值」实际不可用) |
| `web/src/lib/labels.ts` | 附录 A 全部 33 项的中文映射**已全部备好**(baidu_* 在 :65-75,其余散布 :18-61),实施时抽查核对即可,无需新增;仅修正 :9 过时注释(「共 22 种 2026-05-18」→ 以后端写入点全集 55 种为准),顺带给 :14 `approval_card_updated` 加注释防后人误判(后端同样不产出该键;:25 `asset_tag_updated` 已带注释无需动;两者都不在 EVENT_TYPES 下拉里,不影响本次验收) |
| `AdminAuditPage.tsx:329-337` `eventColor()`(可选) | 为 `baidu_*` 加一个分组色,避免落到默认灰 |

后端不动:`GET /api/v1/admin/audit` 的 `event_type` 是任意字符串精确等值匹配(admin.py:92-93),CSV 导出复用同查询,前端加了选项即两头生效。

**删死选项前置核查**(防历史行失去过滤入口):当前代码无写入点,但库若历史版本曾写入过则保留选项。实施前 prod(ms-db)与 dev(ms-db-dev)各跑一次,结果为空再删:
```sql
SELECT event_type, count(*) FROM audit_events
WHERE event_type IN ('approval_notified','invite_notified') GROUP BY 1;
```

### 2.2 验收标准

1. `/admin/audit` 下拉含「备份文件导入」,选中后列表仅剩该类事件,CSV 导出同口径;
2. 下拉命名选项数 = 后端写入全集 55(既有保留 22 + 附录 A 新增 33),外加「全部」共 56 行;`approval_notified`/`invite_notified` 已不在下拉(单独回归检查:二者不再出现);
3. 原有 22 项(24 − 2 死项)过滤行为零回归。

---

## 3. W3:管理员备份任务视图(新功能)

### 3.1 后端(挂既有 admin 惯例:`admin.py` + `/api/v1/admin` 前缀 + `require_system_admin`)

无 DB 迁移、无 FGA model 变更(复用 `organization#admin`)。数据源 `baidu_backup_tasks` / `baidu_backup_task_files`(tables.py:498/585,字段完备)。

**① `GET /api/v1/admin/baidu-backup/tasks`(列表)**

- 权限:`Depends(require_system_admin)`(deps.py:194,OpenFGA `organization#admin`);
- Query:`status: str|None`(enumerating/running/completed/cancelled/failed,**白名单校验,非法值 400**,与 ③ 口径一致)、`user_id: UUID|None`、`q: str|None`(用户名/姓名/源目录 ilike 模糊)、`active_only: bool = False`、`limit: int = 20(le=100)`、`offset: int = 0`;排序固定 `created_at DESC, id DESC`(稳定排序,对齐用户侧任务列表惯例 `routers/baidu_backup.py:854`,防同秒任务翻页抖动);
- 200:`{ items: TaskItem[], total: int }`,`TaskItem`:

```jsonc
{
  "id": "uuid",
  "user": { "id": "uuid", "username": "…|null", "name": "…" },      // join users;username 可空(飞书账号无本地用户名),前端展示与 q 匹配须容忍 null
  "status": "running",
  "source_dir": "/蕾蕾/图文素材",
  "project": { "id": "uuid", "name": "…" },                          // join projects
  "target_folder": { "id": "uuid", "name": "…" },                    // 夹已删 → null
  "total_files": 100, "done_files": 80, "failed_files": 3,
  "skipped_files": 1, "cancelled_files": 0,
  "total_bytes": 0, "done_bytes": 0,   // total_* 与 done/failed/skipped/cancelled_files 均可空(tables.py:546-550,enumerating 阶段 NULL),仅 done_bytes NOT NULL default 0;序列化统一 0 兜底;前端 enumerating 时不渲染进度条(用户侧现状是渲染 0% 条,admin 页改为不渲染属改进)
  "created_at": "…", "updated_at": "…",
  "fail_reason": null,          // truncate 200 字符
  "cancel_requested": false
}
```

**② `GET /api/v1/admin/baidu-backup/tasks/{task_id}(详情)`**:`TaskItem` + `bound_baidu_uid`(任务表创建时快照列)+ `binding:{id, baidu_uid, status}`(`baidu_uid` 是 BaiduBinding 列名,tables.py:481)+ `cancel_reason`(取消原因 token:user_cancel/binding_replaced,tables.py:537)+ `retry_count / enum_done / dispatched_at / round_started_at / lease_until / runner_id`(调度观测字段)。404 = 不存在(不区分语义,admin 视角无归属隐藏需求)。

**③ `GET /api/v1/admin/baidu-backup/tasks/{task_id}/files`(文件明细,决策点 D2)**

- Query:`status: str|None`(pending/skipped_exists/importing/success/failed/cancelled,**白名单校验,非法值 400**,对齐用户侧口径 `routers/baidu_backup.py:891-892` 的 `FILE_STATUSES`)、`limit=50(le=200)`、`offset`;排序 `rel_path, id`(对齐用户侧 `routers/baidu_backup.py:900`,稳定防翻页抖动);
- 200:`{ items: FileItem[], total }`,`FileItem`:`{ id, source_path, status, bytes_done, attempts, non_retryable, last_error|null, asset_id|null, updated_at }`(`last_error` truncate 200,与 tags 同款脱敏口径)。

### 3.2 前端

- 新页 `web/src/pages/AdminBaiduTasksPage.tsx`,路由 `/admin/baidu-tasks`(App.tsx admin 路由组),AppHeader chip「备份任务」按 `me.is_system_admin` 显隐(AppHeader.tsx:104-119 惯例);
- 列表:用户 / 状态 Tag / 进度条((done+skipped+cancelled)/total;enumerating 不渲染——用户侧现状是渲染 0% 条,admin 页改不渲染属改进)/ 失败数(>0 红)/ 源目录(ellipsis+tooltip)/ 目标(项目名/夹名)/ 创建时间 / 失败原因(ellipsis)。状态色/文案与失败原因文案**直接复用 labels.ts 现成映射**:`BAIDU_TASK_STATUS_LABEL/COLOR`(:79-96)、`BAIDU_FILE_STATUS_LABEL/COLOR`(:99-116)、`BAIDU_FAIL_REASON_LABEL`(:119-127,fail_reason 是 7 个固定 token,勿裸串展示);admin 页展示后端**原始 status**,不做 `baiduTaskDisplayStatus`(:149-152)的 queued 派生态;
- 过滤:状态 Select + 搜索框(后端 `q`);分页服务端;
- 行点击 → 抽屉:详情字段 + 文件明细表(服务端分页 + 状态过滤,失败行展开 `last_error`);
- 活动任务(enumerating/running)15s 轮询刷新(对齐 BaiduBackupDrawer 的 5s/15s 惯例);hooks 放 `api/hooks.ts`,基址 `/api/v1/admin/baidu-backup`;
- 参考既有实现:BaiduBackupDrawer.tsx / BaiduTaskDetail.tsx(布局与状态色)。

### 3.3 测试功能点

- 后端:非 org admin 403;org admin 200 且跨用户可见(构造两用户任务);分页/排序/status/user_id/q 过滤;不存在 task 404;files 分页+status 过滤+非法 status 400;`last_error`/`fail_reason` 截断;
- 前端:tsc/build;菜单显隐(非 admin 不见);空态;进度/失败数渲染;抽屉文件明细分页;
- 回归:用户侧备份抽屉(BaiduBackupDrawer)零影响;`/admin/audit` 零影响。

---

## 4. 部署方案

- **W1**:纯运维,见 §1.1,不依赖任何代码发布;dev/prod 各执行一次(dev 先跑作演练)。
- **W2+W3**:同一分支 `feat/baidu-admin-observability`(基于 liuqi 切出),建议走 qdev 四角色(方案本文档可先过 qplan 盲审)。**无 alembic 迁移、无 FGA model 变更、无 .env/compose 变更** → 标准 deploy_lan.sh/分片通道:代码 rsync → `docker restart ms-api`(后端改动仅在 api;ms-worker 无改动,按惯例一并重启亦可)→ SPA 分片原子替换(备份 web.bak-YYYYMMDD)。dev 验收 → no-ff 合并 liuqi → prod(照 deploy-hh2 技能 §2 预检/§5 验证清单)。

## 5. 回滚

- W1:无需回滚——依赖安装与回填均为增量、幂等;若重启后服务异常,`docker restart ms-worker` 恢复进程运行即可(已装依赖与已生成缩略图无需也无必要回退);
- W2/W3:纯 additive(新端点/新页面/数组追加),revert commit 重推或代码切旧 commit + SPA 换回备份即回滚,无数据残留。

## 6. 决策点(待拍板)

| # | 问题 | 建议 |
|---|------|------|
| D1 | W2 范围:只加 `baidu_file_imported`(最小)/ 全部 33 项 + 删 2 死项 / 改后端 distinct 动态下拉 | **全部 33 + 删 2 死项**;动态下拉(新端点返回 `SELECT DISTINCT event_type`)列 backlog |
| D2 | W3 是否含文件明细端点 ③;admin 视图是否随 `baidu_backup_enabled` 门控 | **含**(排查价值大);**不门控**(管理观测面看的是存量事实,与用户侧功能开关语义无关) |
| D3 | W1 执行时机 | **立即低峰执行**,不等代码周期 |
| D4 | W1-B(livp 失败文案区分) | **并入 W2/W3 分支**(改动很小,消除误导文案) |

## 7. 工作量估计

| 工作包 | 内容 | 估计 |
|--------|------|------|
| W1 | 运维 + 验证 + 记账 | 0.5 人天 |
| W2 | EVENT_TYPES/labels/eventColor + 验证 | 0.5 人天 |
| W3 | 后端 3 端点 1 人天 + 前端页面/抽屉 1 人天 + 测试 0.5 人天 | 2.5 人天 |
| 合计 | | ~3.5 人天 |

## 8. 遗留 / 后续 backlog(本次不做)

1. **镜像重建根治**:pyproject 已含 pillow-heif,重建镜像即烧入,一劳永逸解决「recreate 丢手动 pip 安装」——触发条件:下次需要 `--force-recreate` 或镜像重建窗口;
2. 审计下拉动态化(distinct 端点 + 前端合并静态全集);
3. 管理员侧「缩略图失败资产」观测/重试入口(本次 W1 修完后价值降低,可并 W3 页面二期);
4. 既有遗留不受影响:bucket lifecycle 30d、上传侧跨引用缺失(另行周期);回收站(软删)livp 恢复后如需补缩略图,恢复后重跑一次 backfill 即覆盖(见 §1.3)。

---

## 附录 A:EVENT_TYPES 补全清单(33 项,加粗为本次报障项)

- 备份类(11):`baidu_bind` `baidu_unbind` `baidu_task_create` `baidu_task_cancel` `baidu_task_delete` `baidu_task_retry` `baidu_file_retry` `baidu_file_overwrite` `baidu_file_random_suffix` **`baidu_file_imported`** `baidu_task_auto_finalized`
- 文件类(8):`asset_deleted` `asset_restored` `asset_purged` `asset.tag_updated` `asset.batch_renamed` `download_denied` `proxy_download` `folder_deleted`
- 用户/组(7):`user_disabled` `user_enabled` `user_password_reset` `group_created` `group_updated` `group_deleted` `password_changed`
- 登录/通知(3):`local_login_success` `local_login_failed` `notification_sent`
- 权限模板/目录/授权(4):`folder_grant_added` `folder_grant_removed` `grant_template_changed` `grant_revoked`(projects.py:1261 写入,labels.ts:34 已有「授权撤回」)

删除死选项(2,后端从不写入):`approval_notified` `invite_notified`。
加全后下拉命名选项 = 后端写入全集 55(既有保留 22 + 新增 33),外加「全部」共 56 行。

## 附录 B:验收/排查 SQL(prod ms-db,`docker exec -i ms-db psql -U msuser -d material_storage`)

```sql
-- SQL-1:全库 livp 缩略图状态分布(修复前后各跑一次对照)
SELECT coalesce(tags->>'thumbnail_failed', '(无标记)') AS fail_token,
       count(*) FILTER (WHERE tags->>'thumbnail_key' IS NOT NULL) AS has_thumb,
       count(*) AS total
FROM assets
WHERE filename ILIKE '%.livp' AND deleted_at IS NULL
GROUP BY 1 ORDER BY 3 DESC;
-- 修复前基线:UnidentifiedImageError/0/442;(无标记)/22/43
-- 修复后预期:UnidentifiedImageError 行消失;(无标记) 行 has_thumb≈全部

-- SQL-2:带 livp 的目录明细(目标目录=生活美照,161/167 为修复前基线)
SELECT f.id, f.name,
       count(*) FILTER (WHERE a.tags->>'thumbnail_key' IS NOT NULL) AS ok,
       count(*) AS livp
FROM folders f
JOIN assets a ON a.folder_id = f.id AND a.deleted_at IS NULL
  AND a.filename ILIKE '%.livp'   -- ⚠ 勿漏:漏了会把目录内全部资产数进 livp 列(dev 演练实测踩过)
WHERE f.id IN (SELECT folder_id FROM assets WHERE filename ILIKE '%.livp' AND deleted_at IS NULL)
GROUP BY 1, 2 ORDER BY livp DESC;
```
