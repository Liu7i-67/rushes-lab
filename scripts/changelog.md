# 更新日志

> 以天为单位记一节,二级标题为日期(`## YYYY-MM-DD`),最新的天在最前;每天内用列表记每一项更新,一句话说清 + commit hash 可溯。

## 2026-09-04

- 第三轮 P0 审查收口(1×P0 + 4×P2):① P0 —— restore 并发竞态的「commit 后重查」守卫是死代码:asyncpg 方言对 0 行 UPDATE 同样抛 StaleDataError(审查 agent 容器内双 session 真实复现),且 expire_on_commit=False 下重查命中 identity map 不发 SQL —— 改为与 hard 分支同款 `except StaleDataError → 404`,软删分支同步补上;② sensitive 门(restore/hard purge 的仅系统 admin 判定)移到 can_admin 检查**之后** —— 零权限探测者只见通用 403 文案,不借文案差异得知"该资产是否敏感"(与 F2 堵的是同款分类元数据泄露);③ 视频 worker 失败日志 warning → exception(thumbnail_failed 只存类型名后 traceback 是唯一排查入口);④ 前端「清空回收站」循环改裸请求 + 结束统一失效缓存(原先每条触发两组列表重取,500 条 = 1000 次请求),条目被他人并发清掉的 404 计为"已被清"不再误报失败,total>0/窗口空的快照错位给刷新提示;本轮后本地容器已重启加载全部最新代码。测试:outsider 对敏感资产只见通用文案的断言入 sensitive 用例,容器内 13 + 28 例全绿(d0e0000)
- 安全审查(ASVS 视角)收口 2×P1 + 3×P2:① F1 —— 敏感资产的 restore / hard purge 补上「仅系统 admin」判定(项目 admin 从父项目继承 can_admin 但无 can_view,此前可对受邀制医疗照片盲恢复/不可逆销毁;软删为存量能力维持不变);② F2 —— 删夹 409 对敏感夹统一为无计数、不区分「有活文件 vs 回收站未清」的文案(项目 admin 可借报文探测敏感目录内容规模,是方向性元数据泄露);③ F3 —— hard purge 的 MinIO 删除改走 asyncio.to_thread(同步 boto3 重试+超时最坏阻塞事件循环冻结整个 API);④ F4 —— livp 静态图解压补真实流硬上限 `_read_livp_entry_capped`(此前只靠可伪造的 zip 声明值);⑤ F5 —— `tags.thumbnail_failed` 只存异常类型名(完整报错含容器内部路径且随 AssetOut 下发);审查 agent 黑盒实测过程数据已自清;测试:sensitive 用例扩到 restore/hard 403 + 删夹报文无数字断言 + 系统 admin 反向链路,capped read 单测 1 例,容器内 13 例全绿、v4 权限 28 例全绿(678d44a)
- 审查遗留 P2 三项收口:① 回收站列表改返 `{items, total}`(items 分页窗口上限 500,total 全量计数)—— 角标计数与「清空回收站」规模提示不再被静默截断误导,超 500 时前端提示「本次先清前 N 个,清完自动刷新」;② sensitive folder 的回收站**仅系统 admin 可见**(后端 enforce + 前端按钮门控)—— 敏感目录 can_view 不含项目 admin(受邀制),项目 admin 虽有 can_admin 但不能把回收站当窥探文件名/标签/备注的侧信道(「活的看不见、删掉的反而看得见」倒挂);③ 两个并发竞态 500 收口 —— 双管理员并发 hard purge 撞 ORM DELETE rowcount 校验(StaleDataError)改幂等 404,restore 与 purge 竞速(UPDATE no-op 后 audit 撞 FK)改 commit 后重查行存在再落 audit;集成测试新增 sensitive 回收站可见性一例(bob 借项目 admin 仍 403,注意 alice 在 dev_bootstrap 被设为 org admin 不能当非系统 admin 测试主体),容器内 12 例全绿;顺修 StaleDataError 导入路径兼容容器内旧版 SQLAlchemy(orm.exc)(c740bcd)
- P0 审查后续修复(2×P1 + 1×P2):① 彻底删除的派生对象(缩略图/livp 实况视频)此前经主 MinIO client 删独立 SSD 缩略图实例,分层部署(ADR-0008)下必打错实例被吞成 NoSuchBucket —— `PresignService` 新增内部缩略图 client(`delete_thumbnail_object`,endpoint 同 worker `_thumb_s3_client` 构型),`asset_cleanup` 派生对象改走它;② livp worker zip 炸弹防护 —— 条目挑选按 zip 声明大小设上限(图 100MB/视频 500MB)+ 解压落盘改计数拷贝硬限(声明可伪造),实况段整体 best-effort 化(解压超限/转码失败只跳过实况,不再误标 thumbnail_failed);③ `download-link` 补查软删行 404(此前 meta/live-preview/share 都拒,唯它漏查,软删原片仍可签 URL);worker 修复中发现并清除 `_pick_livp_entries` 重复定义残留(旧版覆盖新版致上限不生效);e2e 实证:purge 后原片 + 缩略图 + 实况视频三个对象全部从对应实例删除,单测补 zip 限额/计数拷贝 2 例、download-link 软删 404 断言,容器内 11 例全绿(c948007);顺手修 api/.gitignore 里 uv.lock 行尾注释致模式失效的问题
- 回收站三项体验修复(tester 验收反馈):① 删除文件后「回收站 N」角标不更新 —— `useDeleteAsset` 补失效 `assets-trash` 缓存;② 回收站列表里软删文件拉 `thumbnail-url` 404 —— endpoint 对软删行(deleted_at 置位)照常签发,彻底删除后行不存在才 404(回收站缩略图与既有"缩略图组织内可见"语义一致);③ 删除文件夹规则定档为「文件夹空 **且** 回收站空」—— 回收站非空时删夹 409(报错指向回收站),不再隐性连带清除,回收站弹窗新增「清空回收站」一键彻底删除(带二次确认);前端删夹按钮门控同规则(96053ac)

## 2026-09-03

- 新增文件回收站,修复「删了文件却删不掉文件夹」死路(tester 反馈:删文件后删夹报「请先彻底清空」,但系统根本没有彻底清空/恢复的入口,前端「可由管理员恢复」提示是空头支票):后端新增 `GET /assets/trash`(folder can_admin)、`POST /assets/{id}/restore`、`DELETE /assets/{id}?hard=true`(两步制防误删;DB 行 + MinIO 原对象 + 派生缩略图/实况 + OpenFGA tuple 一并清,purge audit 不带 target_asset_id —— 行已删会撞 audit_events FK);删文件夹判空放宽为「无**活跃**资产行」,回收站文件随夹一并彻底清除(folder_deleted audit 记 purged_assets 数);前端 folder admin 可见「回收站 N」按钮 + 弹窗(恢复/彻底删除),删除确认文案与实际语义对齐。容器集成测试新增 3 例,既有 6 例删除用例全绿(77640de)
- 新增 .livp(iOS Live Photo)在线预览:.livp 实为 zip(静态图 JPG/HEIC + 实况 MOV),浏览器既不能渲染也出不了缩略。新增 arq worker `generate_livp_thumbnail`:zip 内挑最大静态图出 1024 JPEG 缩略图(复用既有 thumbnail 链路,HEIC 解码新增 pillow-heif 依赖),实况短片 ffmpeg 转 H.264 MP4(≤3s + faststart)存缩略图 MinIO;新端点 `GET /assets/{id}/live-preview-url` 按 can_download enforce + audit 签发(实况接近原片内容,不享受「缩略图免 enforce」豁免);前端预览弹窗显示静态图 + 「播放实况」切换视频,列表缩略图自动生效;存量 .livp 可跑 `backfill_thumbnails.py` 补生成(已扩展识别 .livp)。真实 8.livp 端到端验证:静态图 768×1024 + 实况 mp4 690KB 浏览器可播(77640de)
- 修复发版后浏览器停留在旧页面的缓存问题:index.html 响应加 `Cache-Control: no-cache`(每次 revalidate,etag 304 代价小),带指纹的 assets 加 `immutable` 永久缓存(_SpaStaticFiles 子类 + SPA fallback 路由);nginx 只做反代,缓存策略在 ms-api 代码层统一修,server2 / 内网 dev / prod 一处生效。排查注记:`curl -sI`(HEAD)探测无尾斜杠路径会看到 307,属 `@app.get` 不含 HEAD 的正常兜底,GET 实际 200,非 bug
- 沉淀 deploy_lan.sh「假死」排查经验到长期上下文(ops-manual §6.6 新增 + CLAUDE.md 部署 D 提要):ssh_r 的 ConnectTimeout 只管建连,隧道建连后断流会让末尾回显无限挂起而实际部署早已完成;诊断口诀 = 探远端 DEPLOYED.md 事实源;待办根修 = ssh_r 加 ServerAliveInterval
- 修复审查发现的 4 个问题(F1-F4):① 前端删除排序第一的根文件夹后 UI 卡幽灵文件夹 —— 改为顺延到剩余列表第一个 + effect 加「选中项已不在可见列表则纠正」兜底;② `complete_upload` 并发窗口 INSERT 撞已删文件夹的 FK 裸 500 —— 包 IntegrityError → 409 明确文案,孤儿 MinIO 对象记日志留清理通道;③ 删除已提交后 `audit.write` 失败不再让客户端收到误导性 500(记 warning);④ sensitive 例外测试的 finally 不再 assert(避免掩盖原始失败,清理失败改告警)
- 修复 #177 删除文件夹并发竞态(发布门禁):① 判空/删除前先 `SELECT … FOR UPDATE` 锁 folder 行,并发窗口内落库的子夹/资产 INSERT 被 FK 锁阻塞后干净报错,不再 500/不再 CASCADE 静默删他人空子夹;② OpenFGA tuple 清理移到 **DB commit 成功之后**(原顺序在 DB 回滚时会留下"活对象+空权限图"断链且无自助修复入口);③ delete/commit 包 IntegrityError → 409 兜底;新增并发双删回归测试(恰好一个 204 一个 404)
- 新增删除文件夹功能(一期:仅空文件夹硬删):后端 `DELETE /api/v1/folders/{id}`(判空 = 无子夹/无文件[含软删],OpenFGA tuple 尽力清理,`folder_deleted` audit);前端文件夹 header 对有权限者显示「删除文件夹」按钮,非空禁用并提示;集成测试覆盖空夹删除/非空 409/无权限 403/硬删后同名可立即重建(0bb9853)
- 删除文件夹权限定档:普通夹 `can_upload`(与创建对称,uploader 自主管理目录结构)、sensitive 夹维持 `can_admin`(sensitive 的 can_upload 实为 downloader 级,当删除门槛太宽);前端按钮门控同规则,测试补 uploader 可删 / sensitive 例外两例
- 设计决策记录:文件夹删除不做软删 —— 空夹软删无收益且 `uq_folder_project_prefix` 全量唯一约束会让同名重建撞 409;非空删除二期方案(软删 + partial unique index)已写入 ROADMAP D iter2

## 2026-08-31

- 内网 dev 环境部署 liuqi 分支(b2054a7):deploy_lan.sh 增强 —— SSH 反向隧道抖动重试(ssh_r 包装,8×6s)、无 rsync 环境的 tar 流兜底(Git Bash 可跑)、目标机 sudo 缺省时自动降级为普通同步;前端 SPA 本地构建后单独同步(rsync 范围排除 static/web)
- PR #176 review 修复:① 重复 tuple 判定收敛为 `is_already_exists_error()`(SDK 异常类型 + 稳定子串,替代易随版本漂移的报错文案匹配;OpenFGA 镜像同步按 digest 固定);② 标签盲搜对 public 项目非敏感 folder 放开(消「列表看得到、盲搜搜不到」断层,敏感目录零泄露不变);③ `roles`/`levels` 参数先校验数组类型(误传字符串不再报费解文案);④ dev 未登录跳转补回 `next` 参数(登录后回跳原页);⑤ `set_password.py` 死 import 清理、local_up.sh 镜像源口径说明对齐
- 审批申请体验修复三连:① 有效期 Segmented 选中态全局加深(墨底白字,统一修掉所有 Segmented "看不出选了哪个"的问题);② 修「自定义」有效期点了没反应的 bug(默认秒数与预设重合导致弹回,现显式记录模式,自定义输入框正常弹出);③ 重复申请防护 —— 已拥有目标权限或已有同目标待审申请时提交会被明确拒绝(400 + 文案)
- 审批列表信息补全:每行显示**申请人姓名**,资源名可点击直接跳转到所在位置(后端列表接口补充 requester_name / folder_id)
- 审批入口可发现性修复:文件详情面板对无下载权限的用户显示「申请下载」按钮,点「下载」被 403 拒绝时自动弹出权限申请(原先只有报错没有入口);审批页提示语从指向不存在的「申请权限」按钮改为描述真实流程;「分享给飞书」按钮更名「分享」(飞书残留);清理 pytest 遗留的 12 条测试审批数据
- folder 授权(grant)面板与邀请面板同款优化:权限改为多选 toggle chips(选中=色块填充+勾号+描边),一次勾选多个 level 批量授予;后端 `POST /folders/{id}/grants` 接受 `levels` 数组(旧单 `level` 兼容)+ 重复授予幂等(原先重复 grant 同 level 会 500)
- 项目邀请面板重做:角色改为多选 toggle chips(选中=色块填充+勾号+描边,一眼可辨),支持一次勾选多个角色批量授予,不再逐个反复邀请;后端 `POST /projects/{id}/members` 接受 `roles` 数组(旧单 `role` 字段兼容),重复授予改幂等(原先重复邀请同角色会 500)

- agent 长期上下文维持 `CLAUDE.md` 为正本(尊重文件历史);新增极简 `AGENTS.md` 指针引用它,作 ZCode / Codex 等跨代理入口
- 本地开发全面切换账号密码登录:dev 与生产同链路(`/login` + session cookie,不再依赖 dev-login 通道),利于实测不同账号/角色;测试账号 alice / bob / evan / outsider 由 `local_up.sh` 自动设好固定 dev 密码(3c51b0c)
- 新增 `api/scripts/set_password.py`:给任意用户设密码 / 登录名;支持 `--list` 核对账号、`--must-change` 测首登强制改密、省略 `--password` 生成一次性临时密码(3c51b0c)
- 修:栈重建后浏览器残留的旧 session cookie 造成 401 循环弹回登录页 —— dev 模式下无效 session 自动回落 `X-User-Id`,生产行为不变(3c51b0c)
- 修:`seed_demo_data` 重跑把 outsider 升成 org admin 的权限泄漏(负向测试账号曾拿到全库可见性);已修查询并清理历史脏 tuple(3c51b0c)
- 前端操作按钮按权限禁用/隐藏:上传、打标、批量删除、新建目录不再"点了选完文件才 403"(d677b1a)
- 公开项目语义补齐:非敏感内容对组织内可浏览,消「看得到目录树、看不到内容」断层;下载仍走申请流,敏感目录仍邀请制(4d8e06b)

## 2026-08-28

- 新增 `api/scripts/local_up.sh`:一条命令完成本地 Docker 全栈部署(依赖栈 → OpenFGA store/model → 生成 `.env` → 构建启动 → 迁移 → seed),幂等可重跑(f5acec0)
- 修 vite dev 的 `/ms-static` 代理劫持 SPA 路由,导致 dev-login 页面打不开的问题(f5acec0)
- Dockerfile 的 apt / pip 镜像源抽成 build arg(默认清华源不变;对清华源包文件 403 的网络可切阿里云)(f5acec0)
- Windows + Docker Desktop 全栈部署验证通过,容器集成测试全绿
