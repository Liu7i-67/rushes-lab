# qdev 需求文档:六项优化实施(W1/W2a/W2b/W3/W4/W5/W6 一期)

> 需求来源:`rushes-spec/material-storage/admin-audit-folder-mobile-optimization-plan.md`
> (13 轮盲审定稿,下称「方案」)。本文档是唯一需求依据;方案细节(行号/先例/风险)以原文为准,
> 本文只锁定**本轮交付范围、接口契约、事件命名与决策记录**。
> 分支:`feat/six-optimizations`(基于 2071feb = liuqi@1e7f774 + 方案文档)。

## 0. 决策记录(2026-10-17)

派发时决策问询未获用户应答,按方案 §7 推荐项执行,交付后用户可推翻重调:

| 项 | 决策 |
|---|---|
| 实施范围 | **全六包,W6 只做一期(项目内移动)**;二期跨项目(物理迁移不可逆)另期拍板 |
| 决策 8(D1 prefix 策略)+14(绑定) | **B:DB 重算子树 prefix 不动物理对象 + 同 PR 补上传侧 (folder_id, filename, 未软删) 同名查重(409)** |
| 决策 16/17(入口处置) | **a 收敛双通道,但本轮仓库内不改 `default.conf`**(防止 routine 部署把 ② 先于跳板机 ① 推上线打开伪造窗口)——交付物改为 ops-manual W2a 落地节(含完整 conf 片段、⓪ 实测步骤、①/③ 上机步骤、硬顺序、回滚、验收用例),激活留部署阶段 |
| 其余(1/2/3/6/7/9/10/11/12/15/18/19) | 全按方案推荐:IP 连带清=是;重置密码顺带解锁=是;补 `local_login_locked` 审计=是;审计 chip 收进 admin 块=是;顺带补目录模板移动端入口=是;目录移动限同项目=MVP;带 grant 一级夹禁移=MVP;W6 拆两期=是;项目内 key 不迁=是;同名 skip(排除软删)=是;二期 >5GiB 先 skip(n/a 本轮);移动用 can_upload 不复用删除闸门=是 |

## 1. 背景与目标

方案六包:W1 管理员重置登录锁定 / W2a 审计真实 IP / W2b 审计项目名补全 / W3 移动端备份任务入口 / W4+W5 目录改名与拖拽层级 / W6 一期 文件项目内批量移动。目标与根因见方案 §0-§6,不赘述。

## 2. 数据库修改方案

**不涉及**(六包全部零 migration;方案已逐包验证:users 无锁字段、audit 列已在、folders/assets 无新列)。

## 3. 接口定义(契约,前后端以此为准)

### 3.1 W1 解锁(后端包1)

- `POST /api/v1/admin/directory/users/{user_id}/unlock`,守门 `require_system_admin`。
  - 入参:path user_id(uuid)。
  - 返回 200:`{"cleared_user_forms": ["<lower 形态>...], "cleared_ips": ["<ip>"...], "was_locked": bool}`。
  - 行为:DEL `auth:lock:user:{u}`+`auth:fail:user:{u}`,u∈{username,email,name} 非空去重 lower();
    IP 连带清=审计反查近 24h `local_login_failed`(details-username 按 lower 比对)的 request_ip 去重集 → DEL `auth:lock:ip/fail:ip:{ip}`;404 用户不存在;写审计 `user_login_unlocked`(details 记形态与 IP 集)。
- `DirectoryUserOut` 增 `login_locked: bool`(列表端点批量 pipeline MGET 三形态 user 锁 key;只反映 user 维度)。
- `reset-password` 端点顺带调同一清理逻辑。
- `record_failure` 返回是否触发锁;登录 router 在触发时补写审计 `local_login_locked`(details: username/维度)。
- 服务层新增 `LocalAuthService.clear_locks(...)`;**一切 key 必须 lower()**。

### 3.2 W2a 真实 IP(后端包1,**不改 default.conf**)

交付物 = `rushes-spec/material-storage/ops-manual.md` 新增「W2a:审计真实 IP 落地」一节,内容照方案 §2.2/§2.3/§2.4 全量转写:⓪ 三入口实测步骤(含 dev、网络名核实 `poc-pigsty-minio_poc-net` vs `<project>_poc-net`)、① 跳板机 conf 追加 XFF(现役跳板机 47.108.196.211,runbook:65 旧 IP 已失效;conf 备份落仓库根 scripts/env/,受 scripts/.gitignore 保护,ops-manual 记指令清单摘要作灾备)、③ hh2 侧 jump-tunnel `-R` 改绑 127.0.0.1(**取消 180s tunnel-rollback 定时器**,取消步骤 runbook:117-119)+ dev :8080 同款处置与「dev 外网入口将关闭」明示、② default.conf 变更**完整片段**(server 级 `set_real_ip_from <⓪实测网关单 IP>; real_ip_header X-Forwarded-For;` + 各 ms-api location `proxy_set_header X-Forwarded-For $remote_addr;`,只信网关单 IP 勿放宽网段)、硬顺序 ①→③→②(② reload 后立即 18080 伪造复核)、回滚反向、验收 4 条、dev 退化依赖(共享网桥则只能 a)。**仓库内 default.conf 与跳板机 conf 本轮均不动。**

### 3.3 W2b 审计项目名(后端包2)

- `GET /api/v1/admin/audit` 的 `AuditOut` 增 `target_asset_filename: str|null`、`target_project_name: str|null`;页内 target_asset_id 集合一次批量反查(assets JOIN folders JOIN projects,**LEFT JOIN/差集回填**,勿在主查询上 JOIN;purge 后回 null)。
- `GET /api/v1/admin/audit/export.csv` 同口径补名(单次 limit 50000,按 500-1000 分批反查)。
- 写入面补全 `target_project_id`(对账口径=全仓 grep `target_asset_id=` 重拉 + 非 asset 分支点名):方案 §3.1 清单全量(restore/delete/live-preview/download_denied/signed_url/asset_deleted/asset_purged×2/share×3/approvals×2),**assets.py 内的全部写入点归后端包2**(与 batch-move 同文件);asset_deleted/restored 软删时事务内先取;purge 写审计前先取;审批与 share 的 folder/sensitive/project 分支取法复用 target_resolve 分派。
- 不加新 event_type。

### 3.4 W3 移动端入口(前端包1)

`MobileTabBar.tsx` moreItems 的 `is_system_admin` 数组追加备份任务(排权限模板后,CloudDownload 图标);目录模板条目**独立三态展开**(`is_folder_template_manager ?? is_system_admin`,不进 admin 数组);顺手更新「后三个仅系统管理员可见」注释;`AdminBaiduTasksPage.tsx` 主表与 Drawer 文件表按 compact 条件注入 `scroll={compact ? { x: 'max-content' } : undefined}`(hooks 置顶);PC 分支零改动。

### 3.5 W4+W5 目录改名/移动(后端包3)

- `PATCH /api/v1/folders/{id}`,守门同目录写操作体系;入参 `{name?: str, parent_folder_id?: uuid|null}`(至少传一)。
- 权限:普通夹 `can_upload`(系统 admin 直通)、sensitive 夹 `can_admin`;**reparent 额外要求目标夹(非敏感)can_upload**;`parent_folder_id=null`(移为一级)合法,前端目标含项目根。
- 校验:name 过 `check_segment_name` + **拒首尾空白**(422);同父同名 409;新 prefix 逐夹过 `check_prefix_budget`(400);同项目(跨项目 400);防环=按 uuid 定序对源+目标双行 `FOR UPDATE` 后做后代检测(**显式栈迭代禁递归**);sensitive 三句式(源 sensitive 禁/目标 sensitive 或其子树禁/移出敏感子树允许);带 explicit grant 一级夹禁 reparent 409;自拟 prefix 存量冲突预检 409。
- D1-B:子树 minio_prefix 两段式 UPDATE(先临时前缀再目标)重算,不动物理对象;`['folders']` 语义后端无需处理。
- FGA:**单次 WriteRequest(writes=[新],deletes=[旧])** 原子交换,DB commit 成功后执行;形态按方向分派(一级→嵌套删 `project:<pid>`;嵌套→删 `folder:<旧父>` 即便旧父 sensitive;移为一级删 `folder:<旧父>` 写 `project:<pid>`);失败重试+审计 details 记结果。
- 审计:`folder_renamed` / `folder_moved`(details:old/new name、parent、prefix)。
- 请求/响应模型加 `models/__init__.py`。

### 3.6 W6 一期 批量移动(后端包2)

- `POST /api/v1/assets/batch-move`,入参 `{asset_ids: [uuid] ≤1000 必填, target_folder_id: uuid 必填}`;守门 get_current_user + 逐组 FGA。
- 校验:目标夹存在;整批恰属一个项目否则 400;`target_folder.project_id == 批次 project_id` 否则 400;单资产同夹 skip=`duplicate_location`;软删行不迁;**上传侧同名查重(D1-B 前置)**:`create_upload` 对 (folder_id, filename, 未软删) 已存在 → 409。
- 权限:逐源夹 can_upload 分组 check(batch-prefix 模板);sensitive 源/目标一律 can_admin;目标=sensitive 夹本身允许(can_admin),目标=sensitive 后代普通子夹禁。
- 物理:object_key 不动,UPDATE folder_id;同名进目标夹 skip=`duplicate_filename`(查重排除软删,百度口径)。
- FGA:每资产 write+delete 同一 WriteRequest,按服务端上限(约 50 资产/批)分批;失败批次进 `fga_pending` 清单,响应恒等式 `成功 + skipped + fga_pending = 提交数`;DB 已 commit 后 FGA 失败不得 500。
- 返回 200:`{"moved_count": int, "skipped": [{"asset_id": uuid, "reason": str}], "fga_pending": [uuid]}`;审计 `asset_batch_moved`(details:from/to folder、成功数、skipped 汇总)。
- 全程照 batch-prefix(assets.py:647-961)模板:尽力而为+严格对账、单事务、`asyncio.to_thread` 不涉及(一期无 MinIO 操作)。

## 4. 事件命名(全局契约,后端写入/前端回填两处必须一致)

| event_type | 中文 label |
|---|---|
| `user_login_unlocked` | 解除登录锁定 |
| `local_login_locked` | 触发登录锁定 |
| `folder_renamed` | 目录改名 |
| `folder_moved` | 目录移动 |
| `asset_batch_moved` | 批量移动资产 |

前端须同步补 `web/src/lib/labels.ts` 的 `EVENT_TYPE_LABEL` **与** `AdminAuditPage.tsx` 的 `EVENT_TYPES` 下拉(两处,漏一处=历史事故同款)。

## 5. 测试功能点(测试用例包依据)

- W1:连错 5 次→429;unlock 后正确密码立即可登录;审计 user_login_unlocked/local_login_locked;三形态 key 清理;reset-password 顺带解锁;列表 login_locked 只反映 user 维度。
- W2b:新触发下载/分享/审批/软删/恢复/purge 事件带 target_project_id(全量对账非抽点);列表与 CSV 的项目名/文件名;purge 行回落 null 不报错;项目筛选。
- W3:前端项(tsc/lint+构建)。
- W4/W5:改名 200+新上传落新 prefix;段名/空白/预算 400;同父 409;reparent 权限/防环(并发双端恰一成一 409)/sensitive 三句式(含移出正例)/带 grant 一级禁移/目标 can_upload 403;FGA tuple 形态分派与原子交换;folder_renamed/moved 审计。
- W6:对账恒等式;混批 400;目标异项目 400;同名/同夹 skip(排除软删);sensitive 目标规则;fga_pending 路径;asset_batch_moved 审计;上传同名 409。
- 回归:既有 pytest 全量(容器内跑,隔离栈见 api/docker-compose.feat-ms.yml 惯例)。

## 6. 分工与文件边界(并行派发,越界即回退)

| 包 | 允许改 | 禁止碰 |
|---|---|---|
| 后端1(W1+W2a 文档) | api/app/services/local_auth.py、routers/auth.py、routers/directory.py、models/__init__.py(仅 DirectoryUserOut 区)、rushes-spec/material-storage/ops-manual.md | 其余一切 |
| 后端2(W2b+W6一期) | api/app/routers/assets.py、routers/admin.py、routers/share.py、services/share_service.py、routers/approvals.py、services/approval_service.py、services/asset_purge.py、models/__init__.py(仅新模型区) | folders.py、local_auth 等 |
| 后端3(W4/W5) | api/app/routers/folders.py、services/permissions.py、services/folder_chain.py(只读复用,如需 helper 另加)、models/__init__.py(仅 folder 区) | assets.py、admin.py 等 |
| 前端1(W1+W2b+W3 UI) | AdminUsersPage.tsx、AdminAuditPage.tsx、MobileTabBar.tsx、AdminBaiduTasksPage.tsx、hooks.ts/types.ts/labels.ts(仅追加各自段落) | FolderTree/ProjectDetailPage |
| 前端2(W4/W5/W6 UI) | FolderTree.tsx、ProjectDetailPage.tsx、新组件(重命名弹窗/移动到弹窗/批量移动弹窗)、hooks.ts/types.ts/labels.ts(仅追加各自段落) | Admin 系页面 |
| 测试用例 | api/tests/ 下新文件 | 产品代码 |

共享文件(models/__init__.py、hooks.ts、types.ts、labels.ts)有并行同伴,只追加/修改自己的契约区块;Edit 报「文件已变更」时重新 Read 再改,勿动他人区域。

## 7. 项目约定(所有包遵守)

- 后端:`cd material-storage/api && uv sync && uv run ruff check . && uv run mypy app`(strict);audit.write() 自带 commit 勿重复;FGA 改写一律 DB commit 后;权限判定系统 admin 直通与 permissions.check 成对;新 event_type 无需后端白名单(任意字符串精确匹配)。
- 前端:`cd material-storage/web && pnpm install && pnpm build`(产物输出 ../api/app/static/web/,随构建走,不手工改);hooks 置顶;antd v6 铁律(Tree 懒加载 setTreeData/422 数组 detail 兼容/Link 内勿包 Popconfirm);每 endpoint 一个 react-query hook 进 hooks.ts。
- 汇报:结束时给改动文件清单+每处说明+自测命令与真实输出。
