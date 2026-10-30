# MCP 素材服务(方案 + qdev 执行稿)

> 2026-10-30 定稿;同日晚经外部评审(DeepSeek)修订为 v2,提议人反馈补 v2.1(内网直达双入口),再经第二轮外部评审补 v2.2(执行细节),最后经 qplan 盲审循环定稿(当前有效值与修订史摘要见文末)。
> 目标:让 AI(AI 编程助手/agent)通过 MCP 协议,以**用户本人身份**在素材库中搜索、查看缩略图、下载、上传素材。
>
> 总原则:**MCP 服务是 API 的薄代理——不直连 DB/Redis、不持有任何 MinIO 凭证**;MinIO 仅允许按 API 返回的 **presigned URL** 读取缩略图字节(D7 唯一例外)。权限(OpenFGA)、审计、风控全部复用现有后端,一层不重写。

## 背景与目标

素材库(医美素材库 material-storage)现有 Web / App 两个客户端。新增第三渠道「MCP」:

- 用户在网页登录后**自助签发个人访问令牌(PAT)**,把令牌配置给 MCP 客户端;
- MCP 客户端(Streamable HTTP 传输,团队共用部署)通过 MCP 服务调 API,身份=该用户,**素材列表/搜索/下载受该用户可见性约束**(缩略图为既有组织内信任口径:thumbnail-url 不做 per-asset FGA 校验,任意登录用户凭 UUID 可取——存量行为,ID 不可枚举);
- 管理员可**一键禁用** MCP 通道,并对令牌流量**限流**,防止大量 AI 涌入影响真人体验;
- 审计日志区分「常规操作(session)」与「令牌操作(PAT)」,可筛选;
- AI 挑选素材的主路径 = 搜索 + 看缩略图(240 小图 / 1024 大图由 AI 自行抉择)。
- **客户端形态边界**:本方案只支持**能配置静态 `Authorization: Bearer` 头**的 MCP 客户端(如 ZCode/Claude Desktop 的 HTTP 配置、或 `mcp-remote` 之类代理);**不支持仅 OAuth 2.1 的托管客户端**——本服务无 `/.well-known/oauth-protected-resource` 等元数据端点,OAuth 接入列二期。

## 总体架构

```
AI 客户端(ZCode / Claude / 自研 agent)
   │  MCP 协议(Streamable HTTP,Authorization: Bearer mspat_xxx)
   ├─ 内网入口:hh2 nginx 直连(内网 IP/域名,/mcp)——内网 AI 主路径,LAN 速率
   └─ 公网入口:跳板机 nginx 443 → 隧道 → hh2 nginx(出差/外部场景)
   ▼
hh2 nginx(新 location /mcp;公网路径上跳板机+hh2 两层都是 L7,SSE 配置两层都要)
   ▼
ms-mcp 容器(新,官方 mcp 包 FastMCP;单副本;env 仅 `MS_API_BASE_URL`(prod=`http://ms-api:8000`,dev=override 中的 dev 服务名/别名,须实测解析)与非敏感的入口白名单/TLS 信任配置,无任何 DB/Redis/MinIO 凭证)
   │  HTTP 转发(带 PAT;UA=msmcp/<ver>;剥离 Cookie 头强制走 PAT 分支;转发超时 30s;日志不落 Authorization)
   │  ★ 反向代理语义透传 Host + X-Forwarded-Proto(入口白名单守门)—— api 按客户端真实入口动态签 presigned URL
   ▼
api 容器(现有 FastAPI,/api/v1/*)
   ├─ get_current_user 新增 Bearer PAT 分支(查 hash → 校验过期/吊销/用户态)
   ├─ 认证链五步(在 get_current_user 内,顺序钉死):通道闸 → 前置 IP 桶 → 令牌查表 → 用户态 → 每令牌 RPM
   ├─ 第六步并发闸在独立 `mcp_gate`(router 级 yield 依赖,覆盖全部需认证 router;session 请求 no-op)
   ├─ Redis 故障一律 fail-closed
   ├─ presign 维持既有动态 Host 行为(与 web 同机制):内网入口签内网直达 URL,公网入口签公网 URL
   └─ 权限/审计/预签名语义零改动(显式例外见 D9 归属绑定、`/auth/me` 挂闸、上传三步 boto3 包 `to_thread`)
```

关键链路事实(已核实):

- 缩略图端点 `GET /assets/{id}/thumbnail-url?size=small|large` 现成,small=240 优先缺失回落 1024,响应带 `variant` 说明实际规格(assets.py:2069);
- 下载 `POST /assets/{id}/download-link`(presigned GET,TTL 15min)、搜索 `GET /assets/search?q=`(文件名/标签/备注,权限过滤内建)、上传三步 `POST /assets/uploads` → `GET /uploads/{id}/parts/{n}` → `POST /uploads/{id}/complete` 全部现成;
- 预签名 URL 的 base 跟随请求的 Host 头与 scheme(`request_base_from`,presign.py:63)。**素材服务器在公司内网,内网 AI 客户端直连 hh2 nginx 即可,不经跳板机**——ms-mcp 按反向代理语义把客户端请求的 `Host` 与 `X-Forwarded-Proto` 透传给 api,api 既有动态预签名机制原样生效:内网入口签内网 URL(LAN 速率),公网入口签公网 URL。单纯伪造 Host 会踩 scheme=http 坑(容器内网直连时必现),故必须连 XFP 一起透传(见 D12);
- **审计现状已核实**:search / thumbnail-url 端点本就不写 audit(assets.py search_assets 全函数无 audit.write;thumbnail-url docstring 明示「无审计」)。AI 高频读操作天然不产生审计行,不会淹没审计表;
- 登录态现状:session JWT(HS256,7 天)仅走 httponly cookie `ms_session`;生产不认 `X-User-Id`(仅 dev)。**目前无任何可交付外部程序的 token 机制,是本方案唯一后端缺口。**

## 模糊点与决策记录

- **D1 令牌=用户本人身份,不做 scope 子集(v1)。** PAT 通过后即该用户,能做什么由 OpenFGA 既有边界决定(和网页同一套)。不做「只读 token」子集——FGA 已是权限正本,再加 scope 会造出第二套权限语义。未来若有需要再加只读档。
- **D2 token 形态:`mspat_` + `secrets.token_urlsafe(32)`(43 字符),落库只存 SHA-256;明文仅在创建响应里回显一次(响应带 `Cache-Control: no-store`);列表页显示前 16 字符前缀(`mspat_`+10)。** 每用户活跃 token 上限 5 个(创建端点内 per-user advisory lock 防并发竞态超限)。
- **D3 有效期:创建时可选 1~365 天,默认 90 天。** 支持随时吊销;吊销/过期立即失效(stateless 校验+查库,无缓存窗口)。
- **D4 审计区分走新列,不塞 details JSON:`audit_events` 加 `auth_method`(session|pat,应用层 Literal 校验;按仓库惯例不引入 DB enum/CHECK)与 `auth_token_id` 两列。** SQL 级可索引可筛选——**输出面三处齐**:①`AuditOut`(admin.py:80-100)加 `auth_method`/`auth_token_id` 字段(NULL 前端归一为 session);②CSV 表头(admin.py:307-340)追加 `auth_method` 列(列位加末尾,不破坏既有消费方;**NULL 一律写 `session`**,与列表筛选口径一致,不写空串);③列表加过滤参数。管理后台/审计页加「全部/常规/令牌」筛选。存量行 NULL 视为 session。`token_created` / `token_revoked` 的 details 里存 **token_prefix 快照 + token_id**(同前缀多令牌时才能定位被吊销的那一条;账号 CASCADE 删除后仍可读前缀)。
- **D5 限流与开关 = 绝对配额两级闸 + 前置 IP 桶,不按常规流量动态算比例(用户原始提议的修正,见下)。** 管理旋钮:`enabled`(bool)、`max_concurrency`(全局在途上限,**默认 8**,定位=防雪崩粗闸)、`per_token_concurrency`(每令牌在途上限,默认 4,定位=用户间公平,防单 agent 占满全局挤掉别人)、`per_token_rpm`(默认 120)、`per_ip_rpm`(**默认 600**,前置 IP 桶总请求粗上限)。**默认全关(enabled=false),管理员显式打开才放行** —— 安全默认,上线即可控。**★ 覆盖边界(必须写进用户预期)**:本方案的通道开关/IP 桶/RPM/并发闸**只作用于 PAT 认证请求**;用户用账号密码登录拿到的 session cookie(或从浏览器取出)交给 AI 直接调业务端点时,这些闸**全部不生效**,且服务端无法与真人 web 区分。要彻底封住该旁路需「非浏览器客户端必须 PAT」之类的策略,列二期;本期以「令牌公开面 + 审计可见 PAT 用量」为准。**`max_concurrency` 默认 8 的硬约束**:api DB 连接池 `pool_size=10 + max_overflow=20 = 30`(session.py:16)。每请求**持有** 1~2 条(get_audit 独立 session 使带审计的端点持 2 条,deps.py:59-63),并**瞬时**再开 1 条(`_load_active_user`/`require_admin`/`require_system_admin`/`get_is_system_admin`(deps.py:86/181/204/228)),故峰值近似 **3×并发**;10 并发 ≈ 30 条=正好吃满池、web 余量为 0,**8 并发 ≈ 24 条留 6 条**。**max_concurrency 只约束过闸后的端点执行**——闸前的 PAT 查表与 `_load_active_user` 不受它约束(由 IP 桶限速但**不限并发**),必要时再加覆盖整条 PAT 链的进程内信号量。**32 会申请近百条→排队至 pool_timeout 30s 后 500,反噬 web**。上调须同步评估/上调 pool 与 PG max_connections。
- **D6 禁用由独立开关承载(原「拖到 0 即禁用」的语义保留在开关上)**:前端 max_concurrency 滑杆(**合法域 1~8**(与默认一致;10 是 3×并发=30 的理论极限、web 余量为 0,不推荐),要更大须先上调 pool 并同步改校验)+ **独立开关**;关闭(enabled=false)时滑杆置灰(滑杆域不含 0,禁用语义由开关承载)。**跨字段校验(PUT 422 强制)**:`per_token_concurrency ≤ max_concurrency`(否则单令牌配额无意义)、`per_ip_rpm ≥ 2 × per_token_rpm`(**保证同出口至少容纳 2 个单令牌 agent**;按用户公平需 per-user 桶,二期);`per_token_rpm` 1~**450**(0 非法;上限由 `2× ≤ per_ip_rpm 900` 反推)、`per_ip_rpm` 1~900(与边缘 `limit_req` 15r/s 对齐,免边缘先拒而指标看不到)。**seed 与默认值必须能通过 PUT 校验器与跨字段校验**(否则管理员一开通道就处于非法默认态)。
- **D7 文件字节永不穿 MCP 服务与 API**:下载=返回 presigned URL(客户端经入口 nginx 代理至 MinIO 取,内网入口即 LAN 速率);上传=返回分片 presigned PUT URL(客户端经入口 nginx 代理直传 MinIO)。**唯一例外:缩略图**——MCP 服务取回图片字节并以 MCP image content 返回(几十~几百 KB 级,这正是给识图 AI 看的通道,设计为穿行;GET 超时 15s)。**★ 该 URL 只被 ms-mcp 自己消费,故 ms-mcp 调 `thumbnail-url` 时 Host 固定取 env `MS_MCP_INTERNAL_BASE_URL`(须在白名单内)而非透传客户端 Host**——否则公网入口会签出 `https://公网域名/ms-thumbs/...`,ms-mcp 在 hh2 内网须出公网→跳板机→隧道回环才能取到字节,公网入口的缩略图会依赖 hairpin(部署验收②只覆盖了可达性,没覆盖回环失败)。**下载/上传的 URL 仍透传客户端 Host**(那才是客户端要用的)。**取字节 GET 必须用独立 HTTP 客户端、不携带 Authorization/PAT/Cookie,仅凭 URL 查询串签名**——S3/MinIO 对「query 签名 + Authorization 头并存」回 400(Only one auth mechanism allowed),复用带 PAT 默认头的客户端必挂。
- **D8 MCP 工具无状态**(无 cwd 会话态)。AI 挑素材主路径是搜索(用户拍板),树状浏览靠参数传 id 即可,无状态最稳。工具参数上限:search limit ≤50(默认 20)、list_files 每页 ≤100、list_folders 全量组树(项目内文件夹量级可控,超大项目再议分页)。
- **D9 上传 v1 单分片(≤5GiB)。** MinIO multipart 单 part 上限 5GiB,库存最大单文件 4.29GB,已覆盖;超大文件多分片留二期。配套 `abort_upload` 工具(AI 重试/放弃前显式中止,不留半成品)。**★ 归属绑定(v1 必做)**:`create_upload` **端点内**(拿完 upload_id 之后,PAT 分支)写 **`mcp:upload:{upload_id} = user_id`**(`SET NX EX 86400`)——**不能放在 `mcp_gate`**:gate 在端点执行前进入,拿不到 upload_id。**PAT 写失败 = fail-closed**:中止该 multipart(该 abort 调用**同样要 `asyncio.to_thread`**)并返回 503「上传会话初始化失败,请重试」,否则会「create 成功、后续 sign/complete 全 403」+ MinIO 孤儿;session 路径不写键、亦不校验。`sign_part`/`abort_upload`/**`complete_upload`** 对 **PAT 请求**校验 owner==当前 user,不匹配 403(**complete 才是「创建资产」那一步**;**键缺失一律 403**;session 维持现状,二期一并纳入)。**★ `complete` 的校验键必须是 path 里的 `upload_id`**(`assets.py:169-171`),**不是** `payload.upload_id`——后者全仓零引用、端点实际用的是 path 参数(`assets.py:209-211`);按 body 校验时「path=受害者、body=自己」即可绕过。**必须**在端点内断言 `payload.upload_id == upload_id` 否则 400(测试会按此断言,不是可选项);**owner 校验三处(sign_part/abort/complete)统一放在 `mcp_gate`**(path_params 可直接取,勿在端点重复查)。**MinIO 孤儿 multipart 清扫属未实施的存量缺口**(prod MinIO 曾拒 lifecycle abort 配置,livp 周期裁定延后做 cron 清扫但代码未写)——本期靠 abort 工具+失败路径引导,cron 清扫列二期候选首条,MCP 不新增处理。
- **D10 ms-mcp 独立容器、独立进程、v1 单副本**:与 api 部署解耦,MCP 被打挂/重启不影响真人;api 反向也不受 MCP 进程拖累。MCP server 自身再加一道**按工具调用粒度**(非连接粒度,SSE 长连接不占名额)的进程内并发信号量作纵深防御,正本闸在 api 层。多副本水平扩展(需 nginx sticky 或 Redis session store,Streamable HTTP 的 Mcp-Session-Id 会话态默认内存维护)留二期。
- **D11 渠道标识:UA=`msmcp/<ver>`**(照 App `msapp/<ver>` 惯例)。使用统计(usage-analytics)新增 mcp 渠道桶——**口径注明:使用统计依托 audit_events,而 search/thumbnail 零审计,mcp 桶只反映审计可见操作(上传/下载签发/download_denied)的渠道占比,会低估 AI 读流量;「令牌管理事件恒 session」仅指自助三端点(被 PAT 403),管理端(/admin/tokens、/admin/mcp-settings)操作按实际认证方式标注**。**通道真实流量观测以管理端 mcp-settings 页的闸实时指标为准**(在途并发=`ZCOUNT mcp:conc:global now +inf`——勿用 ZCARD,已过期未裁剪成员会被高估最长 lease+5s);今日成功数/拒绝量(关闭类·配额类分列)=Redis 三键 `mcp:stats:requests|rejected_policy|rejected_quota` + 进程内 `rejected_infra`(**纯 ASGI middleware 按 `mcp_reject_reason` 分桶**);**UTC 日口径**——注意使用统计页 daily 是北京时间日(app/services/usage_stats.py:102),两者口径不同,页面文案分别标注)。注:RPM 扣减在并发闸之前,被并发闸 429 的请求也消耗 RPM 额度——绝对配额口径下刻意接受(重试风暴受双重惩罚反而是防抖),不改序。ms-mcp 转发时**剥离 Cookie 头**——否则浏览器里调试 MCP 会因 cookie 优先走 session,绕开限流和渠道统计。
- **D12 presign base 跟随客户端真实入口(双入口动态,不静态覆盖):ms-mcp 按反向代理语义把客户端请求的 `Host` 与 `X-Forwarded-Proto` 原样透传给 api,api 既有动态预签名机制(2026-10-12 周期)原样生效。** 内网 AI 客户端配 hh2 内网地址 → 下载/上传/缩略图 URL 全部内网直达(LAN 速率,不走跳板机);公网客户端配公网域名 → URL 走公网入口。曾被评估的两个替代方案均否决:①ms-mcp 固定伪造公网 Host——踩 scheme=http 坑(内网直连必现)且内网用户被迫绕公网;②api 加 `presign_pat_base_url` 静态覆盖(v2 曾采纳)——确定性更好但单基地址无法同时服务内外网,同样回退「内网直达」,提议人反馈后废弃。透传的脆弱性(任一层丢 Host 即签错)用验收第 5 条双入口硬测兜住。**透传前置守门:ms-mcp 转发前校验 Host ∈ 入口白名单,白名单外直接 403 拒绝(不放行不回落——回落会以容器名动态签名出客户端不可达的 URL 还白占 signer 名额)**。**白名单须枚举全部真实可用入口的 Host 拼法**:内网 IP(带/不带端口)、内网域名、公网域名、**公网 IP 的 `:18080`/`:8080`(跳板机反代)与 bare IP 的 `:443`(未切域名的 https 入口)**,以及 localhost 本地调试——漏配任一拼法=该形态全量 403 且不回落(列部署 1 双入口验收前置检查;**并核对 prod `.env` 的 `MINIO_ENDPOINT_PUBLIC`**:动态 signer 打满后新入口回落该静态值,若它指内网/旧栈,MCP 客户端会拿到不可达 URL——部署前置检查 + `cap_hits>0` 页面标红)。此守门既兜住 SDK host 校验的绕过面,更是**收窄 MCP 通道对动态 signer 缓存的放大面**(presign.py `MAX_DYNAMIC_SIGNERS=16` 且无淘汰,达上限后**新入口**回落静态 endpoint(已缓存的入口仍用动态 client);脚本化客户端轮换 16 个合法字符集 Host 即可打挂同 worker 的动态预签名,连累 web 用户 https 入口 mixed content 回归——直调 /api/v1/* 的该滥用面今日已存在属存量,本方案收窄的是「MCP 使其零成本」这层放大;api 侧缓存加淘汰列二期)。
- **D13 强制改密(must_change_password)与 PAT 互斥**:处于强制改密态的用户禁止创建与使用 PAT——**PAT 分支无豁免清单(勿照抄 session F15 的 me/change-password/logout 豁免),强制改密态一律 403**。**且任何密码变更 ⇒ 吊销该用户全部活跃 PAT:四处密码变更 + 一处禁用 = 五处挂钩**(实现抽单一收口 **`revoke_user_tokens(db, user_id, reason) -> list[TokenRef]`**(★ **函数内禁止任何 audit 写入**,否则必然落在调用方 commit 之前),各写点调用):①自助改密 `POST /auth/change-password`(auth.py:413);②管理后台重置 `POST /api/v1/admin/directory/users/{user_id}/reset-password`(directory.py:490,置临时密码+must_change_password——**此端点实存,前期「admin 无重置端点」的核实结论有误,已纠正**);③容器内 `set_password.py` 应急工具(:103);④容器内 `set_initial_admin.py`(:129,**可对既有用户改密,是 runbook 里生产重置密码的另一入口,前期漏列**)。`user_provisioning.py:145` 为建新号(尚无 PAT)无需挂钩。钉子:**`grep -rn "password_hash\s*=" --include=*.py app scripts`**(生产路径 4 处赋值 + 1 处构造参数 = 5 处;不加路径会命中 tests),后续新增写点须同步。**事务边界(安全不变量,务必照做)**:`revoke_user_tokens()` 的 UPDATE 与 `password_hash` 写入**必须在同一事务内、同一次 commit 之前完成**(现状:两处 Web 路径是「写 hash → commit → 再写审计」(auth.py:413-415、directory.py:490-492),两处 CLI(scripts/set_password.py:103-105、set_initial_admin.py:129-131)**只 commit 不写审计**——四种情形都必须把吊销放进 commit 之前);`token_revoked` 审计放在 **commit 之后**写,失败只 log 不回滚(否则会出现「密码已改而 PAT 未吊销」或「审计说已吊销但实际未吊销」的静默失效)。五处各补一条测试:commit 前抛错 → 密码/用户状态与 PAT 状态**均不变**。**审计语义:五处均「有活跃 PAT 时」才写,且每个被吊销的 token 一条 `token_revoked`**(含该 token 的 token_id/token_prefix;**`reason` 按路径**:密码变更=`password_changed`、禁用=`user_disabled`、自助吊销=`self_revoked`、管理员吊销=`admin_revoked`;**`actor` 按路径**:自助=`self`、后台=`admin`、CLI=`cli`),无活跃 PAT 则跳过。
- **D13b PAT 与改密端点**:`/auth/change-password` 纳入「PAT 一律 403」清单(与 A 节令牌三端点同守卫)——否则持 PAT 者可用旧密码自助改密,绕开「改密须由 session 发起」的语义(D11「令牌管理事件恒 session」因此成立)。
- **D14 MCP 服务用官方 `mcp` 包内置的 `mcp.server.fastmcp.FastMCP`(streamable-http),不用第三方 fastmcp 包**(同名不同物,API 与供应链风险都不同);**ms-mcp 独立镜像,在 material-storage/mcp/ 自建独立 constraints 锁版本:Python 3.12 + `mcp==<具体版本>` + 传递依赖闭包全 pin,并附 import/启动 smoke test**(api 的 constraints 闭包管不到 mcp/,勿混塞)。
- **D15 PAT 管理入口只做 Web(App 不做)。** Web 新增 **`/settings` 页**(现 App.tsx 无此路由,需新建)含「访问令牌」区;管理后台另加:全部用户 token 列表+吊销、MCP 通道设置页。**创建页文案明示「令牌=账号级全权限凭证,等同你的密码;内网入口为明文 http,勿配置到不可信机器」**——D1 不做 scope 的另一面:工具白名单只是 ms-mcp 层约束,持有 PAT 者可自带 HTTP 客户端直调任意 /api/v1/*(闸仍在,但能力面=完整账号),用户须知情。

### 关于「MCP/常规访问比例」的结论(回答提议人)

「管理员可调、拖到 0 即禁用」——**对,保留**。但「按常规流量实时动态算比例」——**不建议,改为绝对配额**,理由:

1. 常规流量是真人点击,天然极低 QPS(百人级公司峰值也就每秒几次);AI 流量的风险特征是**突发高频**(一个 agent 循环里连打几十个请求)。要防的是「AI 突发打满 API/DB」,设绝对上限(两级并发 + 每令牌 RPM)即可精准命中。
2. 比例模型在真人空闲(如夜间)时会把容量几乎全让给 AI,AI 反而能打到很高——与保护目标背离;绝对上限则恒定保护。
3. 动态比例要实时统计常规流量并做公平排队调度,实现复杂度和出错面都大,收益为零。

效果对照:每令牌并发 4 + RPM 120 时,单个 AI 用户最多 2 请求/秒、4 个在途;全局并发 8 是防雪崩粗闸(受 DB 连接池 30 约束,见 D5——共享连接池故有上限保护,AI 打满时 web 仍留余量);真人(session 路径)零新增开销,恒定不受影响。公平性以**单令牌 agent** 为前提(per_token 按 token 计;一个用户可持 5 个活跃 token,多开即可绕过——要按用户公平需加 per-user 桶,列二期):**至少可同时容纳 2 个满速 agent**(per-token 4 / global 8),第 3 个满速 agent 需等名额——这是 global=8 的既定容量,要更多满速用户就调高 global(受 pool 约束)。管理员觉得多/少,改数字即可;关开关 = 全禁。注:RPM 是固定窗口,分钟边界前后理论上可 2 倍突发——精确防突发靠两级并发闸兜底,RPM 只是粗上限。

## 数据库修改(迁移 0020)

> ⚠ 部署钉子:prod 部署第一步必对账 `alembic current` vs `head`(0019 教训);deploy_lan 无 alembic 步骤,落后先 upgrade 再 restart。

1. **新表 `personal_access_tokens`**:
   - `id UUID PK`
   - `user_id UUID FK users.id ON DELETE CASCADE`(索引)
   - `name String(128)`(用户自定义,如「我的 ZCode」)
   - `token_hash String(64) UNIQUE`(SHA-256 hex)
   - `token_prefix String(16)`(明文前缀,列表识别)
   - `created_at / last_used_at(nullable) / expires_at(nullable=False)`
   - `revoked_at(nullable)`;活跃 = revoked_at IS NULL AND expires_at > now()
2. **`audit_events` 加两列**:`auth_method String(16) NULL`、`auth_token_id UUID NULL`(**建 FK 且 ondelete=SET NULL——照仓库审计惯例钉死此一种,勿 CASCADE/RESTRICT/不建两可**:CASCADE 删用户连带删审计行,RESTRICT 删用户直接失败;tables.py:256/263 惯例)。不建索引(v1 按事件时间+类型过滤已够;若筛选慢再加表达式索引 `COALESCE(auth_method,'session')`(部分索引服务不了 session/NULL 分支))。**注:`auth_token_id` 的 SET NULL 在删 token 时会全表扫 `audit_events`。本期虽无 token 物理删除端点,但 `personal_access_tokens.user_id ON DELETE CASCADE` 意味着「删用户」会级联删 token 并逐条触发全表扫——故 `auth_token_id` 首版就建索引**;**建法定为 `op.get_context().autocommit_block()` + `CREATE INDEX CONCURRENTLY`**(prod 第 3 步是在旧代码在线时 upgrade,普通 `CREATE INDEX` 持 SHARE 锁会阻塞全站 `audit.write`,与本文反复强调的 500 面同源);docstring 写明「CONCURRENTLY 失败会留 INVALID 索引,需 DROP 后重跑」的处置步骤。
3. **新表 `system_flags`**(`key String(64) PK, value JSONB` + **`TimestampMixin`**(created_at+updated_at,tables.py:40-46)):迁移内幂等插入默认行(`ON CONFLICT DO NOTHING`)`mcp_channel` = `{"enabled": false, "max_concurrency": 8, "per_token_concurrency": 4, "per_token_rpm": 120, "per_ip_rpm": 600}`。DB 为正本,管理端写时同步刷 Redis 缓存(`mcp:flag`,**TTL 60s**——关闭是安全动作,短 TTL 让陈旧窗口更小;miss 回源 DB)。**「行缺失」「表缺失」「DB 连不上」在读侧同待遇(写侧不同:表缺失时 PUT 无法 upsert,见测试)**:配置读取统一捕获 **`DBAPIError` 全集**(`UndefinedTableError`/`ProgrammingError`(迁移未跑)、`OperationalError`/`InterfaceError`(连接故障)),**先 `await db.rollback()` 再回落默认值 `{enabled:false,8,4,120,600}`**(失败事务处于 aborted 态,不 rollback 会让后续查询连带 `InFailedSQLTransaction`)——只 catch `ProgrammingError` 时 DB 连接故障会变 500,`mcp:flag` 双挂 403 分支与测试「DB 也挂时 403」都不可达——**行缺失语义钉死(防「代码先上、迁移后跑」窗口期与 0019 同类事故)**:`mcp:flag` 与 `GET/PUT /admin/mcp-settings` 遇行缺失一律**视为默认值 `{enabled:false,8,4,120,600}`**(不自动插入);GET 正常返回默认,PUT 在行缺失时 upsert,管理员可自救;fail-closed 分支仅在**读不到默认值**(Redis+DB 双错)时触发。
   **写侧失败**:PUT 写 DB 成功后刷 Redis 失败 → `DEL mcp:flag`;**若 DEL 也失败,清本地缓存并不够**——下次读仍先命中 Redis 旧值再装回本地缓存。**正确做法:PUT 成功后把新值直接写穿本进程缓存**(或双失败时 `SET mcp:flag <新值> EX 60` 再清本地缓存)。口径:**Redis 写成功或 DEL 成功 → 本进程 ≤5s;双失败 → 本进程也 ≤65s**(其他 worker 同样 ≤65s)。
4. **downgrade 写全**(drop 两列、drop 两表;仓库惯例,0019 先例)。**注:`system_flags` 属配置数据,downgrade→再 upgrade 会回落到默认行**(管理员已调配额丢失,纯新功能期可接受,迁移 docstring 写明,对齐 0019「纯偏好数据」写法)。0020 为纯增量迁移:**audit_events 两列均 nullable**、新表独立,**旧代码(0019 head)与新 schema 兼容共存**——这是回滚流程的基石(见部署节)。

## 接口定义

### A. 后端新增(auth 域,session 认证,给网页用)

| 端点 | 说明 |
|---|---|
| `POST /api/v1/auth/tokens` | body `{name, expires_in_days?(1~365)}` → 201 `{id, name, token(仅此一次), token_prefix, expires_at}` + `Cache-Control: no-store`;上限 5 个活跃(并发竞态用**事务级** `pg_advisory_xact_lock(hashtext('pat:user:'||uid))`——复用 get_db 同一 session,勿用 session 级锁泄漏);强制改密态 403;审计 `token_created`(details 含 token_prefix 快照+token_id) |
| `GET /api/v1/auth/tokens` | 本人 token 列表(无明文),含 last_used_at;**默认只回活跃(未吊销未过期);`?include_revoked=1` 才含历史行并标 revoked_at/expired** |
| `DELETE /api/v1/auth/tokens/{id}` | 吊销 204;**归属契约:仅限本人 token,非本人/不存在一律 404(不泄露存在性);重复吊销幂等 204**;**幂等情形不重复写 `token_revoked`(只对首次生效的吊销写一条)**;审计 `token_revoked` |

> **本组端点 + `POST /auth/change-password` 对 PAT 一律 403「令牌不允许管理令牌/改密」**(**逐路由**挂 guard——**勿给整个 auth router 加**,否则 `/auth/local/login`、`/auth/callback` 一起被挡;补「登录仍正常」回归):防泄露的令牌自我续期(拿旧 PAT 再签新 PAT,吊销失去意义)与持 PAT 自助改密(绕开「改密由 session 发起」语义,D11 口径依赖此);其余业务端点维持 D1 全权限口径。入测试锁死。

> 审计钉子(新增 `token_created` / `token_revoked` / `mcp_settings_changed` **三个**事件类型)。**四处计数基线**=下文 1/2/4/5;第 3 条是统计标签,不属于审计计数:
> 1. **web `AdminAuditPage.tsx`**:过滤下拉现「61 项+全部=62 行」→ **64 项+全部=65 行**;`DETAIL_KEY_LABEL` 补 `token_prefix`/`token_id`/`actor` 三个新键(`reason`/`changes` 已有);`mcp_settings_changed` 的 details 用既有 `changes` 结构,勿新造 `old`/`new` 裸键;
> 2. **web `lib/labels.ts`**:导出名是 `EVENT_TYPE_LABEL`(不是 `AUDIT_EVENT_LABELS`);「55 种」注释在 **:9**,实测 **65 键 = 61 真实 + 4 个历史死键**(`approval_card_updated`/`approval_notified`/`asset_tag_updated`/`invite_notified`——**勿删**,它们只用于历史行显示、不在过滤下拉);新增 3 后为 **68 键 / 64 真实**;
> 3. **web 统计标签**:`components/admin/usage_shared.tsx` 的 `PLATFORM_LABEL` + `UsageStatBars.tsx` 的 `PLATFORM_CLASS_LABEL`/`BAR_COLOR` 补 `mcp`;
> 4. **App `lib/features/admin/audit_labels.dart` 三处**(`kAuditEventTypes` 62 项 / `kAuditEventLabels` 61 键 / `kAuditDetailKeyLabels`)——与 web 的 65 键**不同**(无 4 个死键),勿互抄数字;仅改代码、本轮不发版(App 审计筛选缺这 3 个事件属已声明缺口);
> 5. **附录 A**(`rushes-spec/material-storage/prod-observability-fix-plan.md`,按「55 种」语义出现在 **:14/:98/:112/:217**;`:139` 的 55 是 `tables.py:546-550` 的源码行号引用,勿改)属**历史计划文档**:按「55(当时口径,原算式 22+33)→ **61(2026-10-30 实数)** → 本批 +3 = **64**」改写,保留原分解作历史、勿破坏同行算式;该文件归包 C。
>
> 先例=风控模块教训:漏更正会被后续盲审打回。
### B. 后端新增(admin 域)

| 端点 | 说明 |
|---|---|
| `GET /api/v1/admin/mcp-settings` | 读通道配置(require_system_admin);**响应附实时指标字段(命名即口径:success/policy-reject 分开)** `in_flight`(`ZCOUNT mcp:conc:global now +inf`——与闸判定同口径;勿用 ZCARD,已过期未裁剪成员会被高估最长 lease+5s)/ `today_success` / `today_rejected_policy` / `today_rejected_quota`(mcp:stats:*) / `rejected_infra_since_start`(进程内,重启清零)/ `dynamic_signers_cap_hits`(presign 服务进程内计数,打满回落静态的次数)**——管理端「今日成功数/在途并发/拒绝量(分列)/signer 缓存健康」的承载,零新端点。**指标读取失败(Redis/计数异常)字段置 null,配置体正常返回,勿让指标故障拖死设置页** |
| `PUT /api/v1/admin/mcp-settings` | 写 `{enabled, max_concurrency(1-8), per_token_concurrency(1-8,且 ≤ max_concurrency), per_token_rpm(1-450), per_ip_rpm(1-900)}`;禁用由 `enabled=false` 承载(滑杆 1~8 不含 0,关闭时置灰;跨字段校验见 D6);写 DB+刷 Redis(刷失败 `DEL mcp:flag`);审计 `mcp_settings_changed`(details 带新旧值)。并发写=最后写赢,不做乐观锁 |
| `GET /api/v1/admin/tokens` | 全部用户 token 列表(**回 `user_id` + `user_name`/`username` 便于后台直接展示**;**require_system_admin**,与 mcp-settings 同款;支持按 user 筛;`limit`(默认 100,`le=500`)+ `offset`,排序 `created_at DESC, id DESC` 稳定序) |
| `DELETE /api/v1/admin/tokens/{id}` | 管理员吊销任意 token(**require_system_admin**;审计同 token_revoked,details 用统一键 `actor="admin"`) |
| `GET /api/v1/admin/audit` 与 `GET /api/v1/admin/audit/export.csv`(既有端点改造) | 加 `auth_method` 过滤参数,**查询参数类型钉死 `Literal["all","session","pat"]`**(默认 all;NULL 视为 session;**前端须把既有「全部」的空串显式映射为 `all`,否则 422**),供审计页「常规/令牌」筛选(_build_audit_query 改造);慢则补表达式索引 `COALESCE(auth_method,'session')`(只做部分索引 `WHERE auth_method IS NOT NULL` 对 session 分支无效) |

### C. `get_current_user` 新增 PAT 分支(deps.py)

**顺序钉死(实现必须照此,勿再调换)**:**认证链前五步**在 `get_current_user` 内 = `通道闸 → IP 桶 → token 查表 → 用户态 → 每令牌 RPM`;**第六步(两级并发闸)在独立的 `mcp_gate`(yield 依赖,router 级挂载)**。理由:通道闸必须最先(双挂 403 才可达);IP 桶其后(关闭期不做 Redis 计数);RPM 需 token_id 故必须在查表之后。

认证优先级:cookie session(现状不变;**仅 decode 失败回落 PAT,decode 成功但用户态 401(禁用/删除)直接抛勿回落**——F5「禁用立即下线」语义)→ `Authorization: Bearer mspat_...`(scheme 大小写不敏感;非 `mspat_` 前缀的 Bearer → 401)→ dev X-User-Id(不变)。PAT 分支校验链:

1. **通道闸(读 `mcp:flag`,置于 PAT 链最前;5s 进程内缓存使关闭期几乎不触 Redis/DB)**:读 `mcp:flag`(**进程内 5s 本地缓存** → Redis,miss 回源 DB 并回填 **TTL 60s**);**Redis 与 DB 都失败 → fail-closed 403,`mcp_reject_reason=channel_unavailable`(只进 `rejected_infra`,不得计入 `rejected_policy` 的 `channel_closed`)**——双挂(Redis+DB 都读不到)只有在闸最先时才真正可达 403;若放到 IP 桶/令牌查表之后,Redis 挂时前面先 503、DB 挂时先 500,该分支永不可达。本地缓存保证 Redis 故障期 flag 查 DB 至多每 worker 5s 一次(含失败负缓存),不会被 AI 流量打成每请求一次的 DB 风暴。enabled=false → 403「MCP 通道当前已由管理员关闭」(此时无效 token 也回 403 而非 401——不泄露 token 有效性,且关通道期零 DB 查询,廉价拒绝);
2. **认证前置 IP 桶(先于 token 查表)**:Redis 固定窗口 `mcp:rl:ip:{client_ip}:{epoch分钟}`(client_ip = nginx W2a 还原后的 XFF 单值)。**定位=「总请求/IP 粗上限」而非单用户配额**——它先于 token 查表,无法区分有效/无效令牌,故阈值须远高于单令牌 RPM 才不误伤合法用户:默认 **`per_ip_rpm=600`(5×per_token_rpm,足以容纳同出口 NAT 下数个合法用户)**,超限 → **429 + Retry-After**(与限流语义一致,不用 401)。**该键与 RPM 共用同一段 Lua:`INCR`,然后「仅当 `TTL<0` 才 `EXPIRE 120`」**——(键名含分钟,无条件 EXPIRE 只会让旧键多活 2min;规定的做法仍必要:**固定窗口统一 TTL 防 key 堆积 + 省掉每请求一次 TTL 往返**)——键名含分钟但 Redis 不会自动过期,**漏掉 TTL 会无限增长,且与 arq/登录防爆破共用同一 Redis,会连带伤到队列**。**动机**:RPM 键为 `mcp:rl:{token_id}`,而无效 token **没有 token_id**,故 token 查表之前不存在任何限流——伪造者每次换随机 `mspat_` 串即每次一次唯一索引查询;IP 桶是唯一能覆盖该面的廉价前置闸。**仅在通道开启后才执行**(关闭期由通道闸直接 403,不做 Redis 计数;匿名假 `mspat_` 流量由 nginx `/mcp` 的 `limit_req` 在边缘挡掉)。合法用户正常量级(单令牌 ≤120/min)远达不到 600,故 IP 桶不与之互斥;
3. token_hash 查表(UNIQUE 命中,**走 `get_sessionmaker()` 独立短 session,与端点 `get_db` 事务隔离**——不得把认证查询写进请求事务);未命中/已吊销/已过期 → 401「令牌无效或已过期」(**未命中另做进程内短 TTL 负缓存[常数容量+LRU],仅防「重复同一伪 token」的重复命中,不承担洪水防护——洪水面由步骤 2 的 IP 桶兜**)。
4. 复用 `_load_active_user`(is_active 禁用即 401;强制改密态 403,**PAT 分支无 F15 豁免清单,一律拦截**);
5. **每令牌 RPM**(仍在 `get_current_user` 内):Redis 固定窗口 `mcp:rl:{token_id}:{epoch分钟}`(与并发闸同款)**单 Lua:`INCR`;若 `TTL<0` 则 `EXPIRE 120`**(固定窗口,不续期)——避免两步间崩溃留无 TTL 永久键、也省去 `EXPIRE NX` 的 Redis ≥7.0 版本前提,超 per_token_rpm → **429 + `Retry-After`**;
6. **两级并发闸(★ 在独立的 `mcp_gate` 中,不写进 get_current_user;ZSET 滑动窗口,单个 Lua 脚本内完成检查+回滚,两次 round-trip 禁止)**:
   ```
   -- KEYS[1]=mcp:conc:tok:{token_id}  KEYS[2]=mcp:conc:global
   -- ARGV: now(ms), lease=600_000, max_tok, max_global, req_id
   ZREMRANGEBYSCORE KEYS[1] 0 now; ZREMRANGEBYSCORE KEYS[2] 0 now
   if ZCARD(KEYS[1]) >= max_tok then return 0 end
   ZADD KEYS[1] (now+lease) req_id
   if ZCARD(KEYS[2]) >= max_global then ZREM KEYS[1] req_id; return 0 end   -- ★ 全局拒必须回滚 per-token,否则被拒请求把自己的配额塞满
   ZADD KEYS[2] (now+lease) req_id
   PEXPIRE KEYS[1] (lease+5s); PEXPIRE KEYS[2] (lease+5s)
   return 1
   -- 释放:两闸各 ZREM req_id(对已过期成员幂等,多删无害)
   ```
   **租约 600s 只覆盖 11 个 MCP 工具映射的端点;其余 PAT 可达的 admin 批量端点不保证在 600s 内(见下残留清单)**。**成员 score 过期即被清理,若某个在跑请求超过租约,闸会把它当已释放、并发被低估**;故除工具映射端点外,下列慢端点要么排除、要么封顶:
   - **PAT 排除清单(D1 的显式安全例外)**:**判定方式**——按 **(method, route 模板) 二元组 + 与 Pydantic 同源的 bool 解析**(`(request.method, request.scope["route"].path)`——**method 不可省**:`GET/PATCH/DELETE /folders/{folder_id}` 共用同一模板,只按 path 会把文件夹读取/改名也 403;`hard` **取 `request.query_params.get("hard")`(与 FastAPI 同源,保留最后一个值)**再用 `TypeAdapter(bool)` 解析;**多值(`?hard=false&hard=true`)一律 400**,防 gate 与端点取值不一致被绕过)**;自行白名单 `1/true/yes/on` 会漏 `t/y/TRUE/ON`,PAT 即可绕过执行 `purge_asset_storage`;解析失败(`?hard=maybe`)→ 放行给端点返回 422,gate 不得自行 403/500;勿在 gate 里声明 `hard: bool = Query(...)`(会污染该 router 全部端点 OpenAPI)**。**排除项(七处;admin 批量为「不决策即留洞」,本期一律 session-only)**——**1** `POST /admin/grant-templates/apply-default`(满批串行 FGA/DB 分钟级);**2** `POST /admin/directory/users/{user_id}/disable`(逐对象 `revoke_user_completely`);**3** `GET /admin/usage/stats`(366 天 GROUPING SETS)——**AI 挑素材用不到,全部要求 session**;4 `POST /assets/batch-prefix`(mass-scale,`asset_ids` 上限 1000,copy/delete 在 assets.py:902/1014);5 `DELETE /assets/{id}?hard=true`(**单资产**,`purge_asset_storage` 同步删对象,assets.py:2305——排除理由是「同步删对象可能慢」而非千级规模);6 `GET /admin/audit/export.csv`(5 万行流式,整段占用名额)。**不排除的**——`POST /assets/batch-move`(无 boto3,仅 DB + 逐资产 FGA;`asset_ids` 封顶 200 以控租约)、`DELETE /assets/{id}` 软删分支:这两类 PAT 正常可用。**`DELETE /folders/{id}` 也排除**(folders.py:820-838 对全部 tuple 逐条 FGA write,**无上界**,可能超租约;AI 挑素材用不到)。被排除的七处 PAT 返回 **403「令牌不支持该操作(批量改名/彻底删除/审计导出/admin 批量)」**(session 不受影响)。此例外是刻意的安全收窄,若未来确需,改为心跳续租再放开。
   - 工具映射的其余端点(列表/搜索/签发/上传三步/恢复等)均为亚秒~秒级,租约 600s 覆盖且余量充足。正常请求靠 finally `ZREM` **即时**释放。**缩略图字节 GET 走 nginx→MinIO,不经此闸**。饱和 → **429 + `Retry-After: 1`**。**★ 上传三步的同步 boto3 必须包 `asyncio.to_thread`**:`create_multipart_upload`(assets.py:144)、`complete_multipart_upload`(assets.py:209)、`head_object`(assets.py:214)**未包**(1530 那处 head 已用 to_thread),`abort_multipart_upload`(assets.py:206/302)亦未包(同仓 902/1014 已有 to_thread 铁律),8 并发上传会把事件循环卡住、连累网页与 `/healthz`——这是「业务端点零改动」的**显式例外**。**闸的实现与挂载点(★ 勿挂 app 级)**:
   - **形态**:yield 依赖 `mcp_gate`,`依赖于 get_current_user`(FastAPI 同请求内依赖缓存,不重复认证;依赖序保证认证先完成,才能读到 `request.state.token_id`);`auth_method != "pat"` → 立即 `yield`(无害 no-op,session 请求零开销);PAT → acquire 两闸 → `yield` → finally 各 `ZREM` 释放(**finally 内 ZREM 必须 try/except 只 log**——Redis 抖动不能让已成功的响应变错误;成员靠租约自愈)。崩溃请求靠成员 score 过期自然回收(租约 600s+margin 自愈),无「永久泄漏」与「整 key 清零」两坑;
   - **挂载点**:**挂全部需要认证的业务 router**(projects/folders/assets/approvals/share/users/groups/notifications/request-links **+ admin/directory/usage_stats/risk/baidu_backup**——PAT=D1 全账号身份,这些 router 的端点同样可被 PAT 直调,漏挂即出现「不过并发闸的 PAT 通道」:`baidu_backup` 整 router 15 个端点(5 GET + 10 写)、`admin/*` 写端点等),经 `include_router(..., dependencies=[Depends(mcp_gate)])`)+ **只在 `@router.get("/me")` 装饰器加 `dependencies=[Depends(mcp_gate)]`**(勿给整个 auth router 加,否则 `/auth/local/login` 一起被挡)。**严禁挂 app 级**(实测 FastAPI 0.143.1 下 app 级依赖对 `/healthz`、`/auth/local/login`、`/maintenance/banner` 同样执行 → 闸一开就锁死登录与存活探测,整站不可用);严禁逐端点挂(破坏「业务端点零改动」)、勿把闸挂在 `get_current_user` 内部。**实测口径:未挂载的 router 无并发闸(通道/IP/RPM 仍在 get_current_user 内生效),文档不可宣称「PAT 全量过并发闸」**;
   - **key 设计注**:本仓 Redis 为单机(cache+arq 同一 Dsn),CROSSSLOT 不适用;若未来 Cluster 化,两 key 须加 hash tag 同 slot。**通道统计计数(★ 纯 ASGI middleware——禁 `BaseHTTPMiddleware`;INCR 一律 try/except 只 log,绝不影响响应)**:依赖**拿不到最终 response.status**,且**上游**(`get_current_user`)抛 403/429/503 时 `mcp_gate` 根本不进入(yield 能捕获的是下游/端点异常,不是上游)。故用**一层 ASGI middleware 按最终 response.status 计数**:**只认 PAT 分支显式写入的 `request.state.auth_method=="pat"`**(勿按 `Authorization` 头判定——「有效 session + 手带 mspat 头」会被误计;头部仅在「认证未完成即被拒」时作兜底);2xx → `INCR mcp:stats:requests:{yyyyMMdd}`;**拒绝量**按 `request.state.mcp_reject_reason` 分桶(状态码不可靠:业务权限不足也是 403,不能算通道关闭)**——`channel_closed`(通道关闭)、`quota_ip`/`quota_rpm`/`quota_conc`(配额)、`forced_change`(强制改密)、`pat_forbidden`(令牌禁用端点)、**reason → 键映射钉死**:`channel_closed`/`pat_forbidden`/`forced_change` → Redis **`rejected_policy`**;`quota_ip`/`quota_rpm`/`quota_conc` → Redis **`rejected_quota`**;`channel_unavailable`(**配置读不到而回落默认值,与「管理员主动关通道」区分**,免运维误判)与 `redis_down` 都进进程内 `rejected_infra`;**9 个 reason 定版**:`channel_closed`/`pat_forbidden`/`forced_change` → Redis `rejected_policy`;`quota_ip`/`quota_rpm`/`quota_conc`/`quota_batch`(batch-move 超限)→ Redis `rejected_quota`;`channel_unavailable`/`redis_down` → **只进程内 `rejected_infra`(不写 Redis)**。**每个 reason 都有生产点**:通道闸/IP 桶/RPM/并发闸/mcp_gate 两类 403/**auth 三端点 + change-password 的 PAT 守卫(须显式置 reason=`pat_forbidden`)**/强制改密(不加 Redis 键——Redis 挂时 INCR 必失败,该指标会在唯一该计的场合恒为 0),metrics 直读进程内值(精度=单 worker);**业务 403(无 can_upload/can_download 等)不计入任何拒绝键、401 也不计**(400/404/422/500 同样不计);均 EXPIRE 8 天,`yyyyMMdd` 取 **UTC**。中间件开销仅一个 dict/INT 判断,session 请求零影响。**流式响应**:FastAPI 的 `AsyncExitStack` 在 `await response(scope, receive, send)` **之后**才关闭,故 yield 依赖在**响应发送完成后**退出——`StreamingResponse`(`/admin/audit/export.csv`)期间名额**持续占用**(更保守,不是低估);慢客户端会拉长占用,由 600s 租约兜底,`in_flight` 含在途响应。**★ 必须覆盖整条 PAT 链而非只挂并发闸**:通道默认全关,上线首日所有请求在第 1 步即 403,若只计并发闸则拒绝量恒 0,与「拒绝量用于调配额」矛盾;
7. **Redis 故障策略(限流/并发闸/IP 桶同款):Redis 异常 → PAT 请求 fail-closed 503**(但若通道闸已从 DB 取到 flag 且 DB 可用、只是 Redis 挂 → 503;Redis 与 DB 双挂 → 步骤 1 直接 403;**注意双挂测试须先让 5s 本地 flag 缓存过期**,否则会走到 IP 桶才 503)(session 请求完全不受影响);绝不 fail-open,否则 Redis 一抖 AI 突发直接打穿;
8. `last_used_at` 节流回写:`SET mcp:lastused:{token_id} 1 NX EX 300` 成功才 UPDATE DB;**整个节流写(Redis + DB UPDATE)都包 try/except 只 log**(非限流组件、不参与 fail-closed;DB 抖动也不能把已通过认证的请求变 500);
9. 产出 CurrentUser + `auth_method="pat", token_id` 注入 request.state → **经 `get_audit` 注入的写点自动带上**(自建 `AuditService(db)` 实例如 `services/notifications.py:272/288/308` 无 request 上下文——**本期用 contextvar 改造**(后台任务与请求同 task 执行、context 可继承,故不再产生 NULL);**worker(arq)侧保持 NULL**):`get_audit` 已接收 request(deps.py:59,现未用)——把 request 传入 AuditService 构造,在 **write() 内部延迟读取** request.state 取 auth_method / auth_token_id 默认值(write 的可选参数仅作显式覆盖)。**必须在 write() 内延迟读**:router 级 `mcp_gate` 通常先把认证跑完,但**依赖顺序会随挂载方式/端点参数顺序变化**(create_upload/complete_upload/download-link 的 `audit` 参数排在 `user` 之前),且未挂闸的端点仍可能先构造 audit——统一在 write() 读,避免隐式顺序耦合把「PAT 上传/下载签发」误标成 session。**默认值规则钉死:有 request 且非 PAT → 写 `"session"`(新行不留 NULL);无 request 上下文(worker/CLI/后台任务) → NULL**——注:**worker(arq)侧仍会持续产生 NULL 行;notifications 本期已用 contextvar 改造,不再产生**(不是「只有存量行」);筛选与 CSV 一律把 NULL 归入 session,口径即「非令牌操作」。

状态码语义(评审采纳,拆开):**401=PAT 无效/过期/用户禁用;403=管理员策略性关闭通道 / 强制改密 / 令牌禁用端点(含批量排除)/ Redis 与 DB 双挂 fail-closed;429=瞬时限流(IP 桶/RPM/并发饱和),应退避重试;503=Redis 故障(DB 仍可用)或上传会话初始化失败;500=DB 连接故障且 Redis 正常(token 查表/用户态查库阶段;配置读不到已回落默认值不会 500)**。

### D. MCP 工具(ms-mcp 服务,Streamable HTTP)

每个 HTTP 请求带 `Authorization: Bearer <PAT>`;ms-mcp 原样转发给 API(UA=`msmcp/<ver>`,**剥离 Cookie 头 + `X-User-Id`(dev 环境该头可冒充身份)**),**不在本地落盘 token**,日志一律不记 Authorization 与创建响应体。**会话与 token 的绑定(定稿)**:Streamable HTTP 部分客户端只在 initialize 带一次 Authorization,后续请求不带——ms-mcp **在内存里按 `Mcp-Session-Id` 绑定 PAT**(与「不落盘」不冲突,进程重启即失效;另 `initialize` 必须携带 Authorization 才建会话);对只在首请求带 PAT 的客户端,ms-mcp 首请求即绑定后续复用;绑定缺失的后续请求 401;**同一 Session-Id 后续请求携带不同 PAT → 401(不自动换绑),须重新 initialize**;Session-Id 与绑定 PAT 都要日志脱敏。工具错误统一包装 `isError=true` + 可读文案,不透堆栈。单副本部署(**进程内量——负缓存、`dynamic_signers_cap_hits`、会话表——均是单 worker 局部值;若未来上多 worker 须聚合,负缓存退化为每 worker 一份**,Dockerfile:33 现无 `--workers`,main.py:7 示例的 `--workers 4` 是另一形态,部署时对齐)。

| 工具 | 映射 | 说明 |
|---|---|---|
| `whoami()` | GET /auth/me | **白名单字段**:id/name/is_system_admin/权限标记(不透 open_id/union_id/email);/auth/me 无 cookie 副作用已核 |
| `list_projects(page?, limit?)` | GET /projects | 可见项目(自动按用户过滤);**API 有 `limit`(默认 100)与 `offset`(projects.py:634-635)但无 total、**limit 无上下界且每项目要串行查一次 OpenFGA**(projects.py:564-569)——故工具侧必须硬封 `limit≤100`**,并在结果注明「可能还有更多,未返回 total」 |
| `list_folders(project_id)` | GET /folders?project_id | server 侧组好 children 树返回,附 subtree/direct 计数;**响应剔除 minio_prefix/is_sensitive 等内部字段** |
| `list_files(folder_id, page?)` | GET /assets?folder_id | 分页文件列表(每页 ≤100;文件名/大小/类型/标签/备注) |
| `search_assets(q, limit?)` | GET /assets/search?q | **主路径**;limit ≤50 默认 20;结果带项目/文件夹归属 |
| `get_thumbnail(asset_id, size)` | GET thumbnail-url → 取字节 | size="small"(240)/"large"(1024);以 **MCP image content** 返回,附 variant 实际规格;GET 超时 15s;无缩略图→明确报「尚未生成或非图片」 |
| `get_download_url(asset_id)` | POST download-link | 返回 presigned URL(15min TTL,host 跟随客户端入口)+ **`DownloadLinkOut` 仅 url/expires_in/is_sensitive(models/__init__.py:310-313),不含文件名/大小——需文件名请先 list/search 取 AssetOut**;**提示 AI:字节自取,勿反复续签**。**能力边界:上传/下载都依赖 MCP 客户端具备 HTTP 能力**(能发 GET/PUT);纯对话型客户端只能 search + thumbnail |
| `create_upload(folder_id, filename, size_bytes, content_type?)` | POST /assets/uploads + GET parts/1 | **工具层先拒 `size_bytes > 5GiB`(API 不校验上限)**;返回 upload_id/key/bucket/首分片 PUT URL;客户端直传 MinIO;同名 409 原样透出;**描述注明:PUT URL 15 分钟内有效,拿到即传** |
| `get_part_url(upload_id, key, bucket, part_number)` | GET /uploads/{upload_id}/parts/{n} | PUT URL 过期重签(同一 multipart 续传,勿重跑 create_upload 另起孤儿)。**注:该端点仅要求认证、无 can_upload/归属校验(assets.py:148-165),工具描述同 abort 口径「仅传自己刚创建的三元组」** |
| `abort_upload(upload_id, key, bucket)` | DELETE /assets/uploads/{upload_id} | 中止 multipart(重试/放弃前显式调用,不留半成品)。**注:该端点现无 owner 校验(存量 IDOR,assets.py:293-302);**PAT 请求 v1 即校验 owner(D9 归属绑定),session 维持现状**,二期把 session 一并纳入** |
| `complete_upload(upload_id, folder_id, key, bucket, etag, part_number=1)` | POST complete | **API 契约 `UploadCompleteIn.parts` 是数组**(models/__init__.py:298-306),单 `etag` 构造不出请求体(必 422)——ms-mcp 映射为 `{"upload_id","folder_id","bucket","key","parts":[{"PartNumber":part_number,"ETag":etag}]}`;ETag **须取自分片 PUT 的响应头 `ETag`**(不是本地算的 MD5 的十六进制裸串,也不必自行加引号——API 侧 presign.py:357 已 strip('"'))。落库成资产;失败原样透出。**★ 同夹同名窗口**:create 期查重在 `assets.py:126-139`,到 complete 之间 Web 是秒级、MCP 可达分钟级;库上唯一约束 `uq_asset_minio_object_version` 在 version NULL 时允许两行同 key。**complete 期补一次复查只能缩小窗口、不是原子保证**——要真正守住「一夹一名」须 `pg_advisory_xact_lock(hashtext('asset_name:'||folder_id||':'||filename))` 包住检查+插入,或加部分唯一索引 `(folder_id, filename) WHERE deleted_at IS NULL`(须先清存量重复);**本期按 best-effort 复查,文档不宣称强不变量**;**复查只在 ms-mcp 侧做(complete 前 search 一次),不改端点**——那会改变 web/App 的「响应丢失后重试」语义(从重复入库变 409),属另一议题。**超时幂等**:30s 转发超时可能发生在 API 已 complete 之后——工具描述要求「先 search/list 确认资产是否已入库,再决定重试或 abort」。**配套**:complete/abort 成功后 `DEL mcp:upload:{upload_id}`,端点捕获 `NoSuchUpload`(abort 幂等 204、complete 返回 409/已有资产),否则成功后再 abort/complete 会 500 |

工具描述里写清:挑选素材推荐 `search_assets` → `get_thumbnail`(先 small,需要细节再看 large);单分片 ≤5GiB、PUT URL 15 分钟内有效、ETag 取自 PUT 响应头;同夹同名会 409。**现实边界:5GiB/900s ≈ 5.7MiB/s 持续上行,公网入口大概率跑不完**——工具层对 `size_bytes > 1GiB` 时提示「预计时长,建议走内网入口」,失败即 abort(孤儿 multipart 无 cron 清扫)。**结构化字段做白名单**(不透 minio_key/minio_bucket/tags/open_id/email;**但 presigned URL 的路径本身含 bucket/key,无法避免**),防内部标识经 AI 扩散;**唯一例外:upload 三元组 `upload_id/key/bucket` 必须回传**(它是 complete 的入参,models/__init__.py:287-291)。

> complete 的**跨目录**越权面已按现有代码核实:端点强制 key 前缀 == 目标 folder 的 minio_prefix、bucket == 项目 bucket、complete 期重查 can_upload,**客户端回传值无法把分片「完成」到别的桶/夹**。但**跨用户**维度不设防(可完成他人 upload_id,只要自己有目标夹的 can_upload)——故 D9 的 PAT 归属绑定额外覆盖 `complete_upload`。补回归用例:错误桶/夹 → 400;他人 upload_id(PAT)→ 403。

## 工作包拆分(qdev 并行,文件边界互斥)

- **包 A · api 后端(是 B/C 的契约前置,实际串行;可内部拆 A1 迁移+token 域 / A2 认证链+闸+统计 / A3 读侧+usage_stats)**
  1. **迁移 0020**:含完整 downgrade 与 `system_flags` 默认行 seed;`audit_events` 两列 FK `SET NULL`,**必须写成 `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID` 且不做 `VALIDATE`**(`NOT VALID` 才是跳过初始全表校验;普通 `ADD CONSTRAINT` 默认校验、持 **SHARE ROW EXCLUSIVE**(阻塞写、不阻塞读),而 prod 第 3 步是在旧代码仍在线时 upgrade——会把全站 `audit.write` 阻塞,比 0019 事故面更大);**如确需强校验,另起迁移做 `VALIDATE CONSTRAINT`(SHARE UPDATE EXCLUSIVE,不阻塞写)**;docstring 写清锁级别;同步 `tests/test_db_schema.py` 的精确表集合断言(新表/新列/约束);
  2. **PAT 域**:表 + service + `POST/GET/DELETE /auth/tokens`;**五处吊销挂钩**(change-password / directory reset-password / set_password.py / set_initial_admin.py / directory disable),统一收口 `revoke_user_tokens(db, user_id, reason) -> list[TokenRef]`(**签名不含 audit**;调用方 commit 后逐条写 `token_revoked`);
  3. **认证链前五步**(deps,`get_current_user` PAT 分支):通道闸 → IP 桶(单 Lua `INCR`+`EXPIRE 120`)→ 查表(独立 `get_sessionmaker` session + 负缓存)→ 用户态 → RPM(单 Lua `INCR`+按需 `EXPIRE`);Redis 故障 fail-closed;
  4. **`mcp_gate`**(独立 router 级 yield 依赖,**勿写进 get_current_user**):两级 ZSET 闸(单 Lua 含全局拒回滚、`MCP_CONC_LEASE_SECONDS` 可注入)+ finally `ZREM`(try/except 只 log)+ **PAT 排除七项**——`POST /api/v1/assets/batch-prefix`、`DELETE /api/v1/assets/{asset_id}`(hard 真值)、`GET /api/v1/admin/audit/export.csv`、`POST /api/v1/admin/grant-templates/apply-default`、`POST /api/v1/admin/directory/users/{user_id}/disable`、`GET /api/v1/admin/usage/stats`、`DELETE /api/v1/folders/{folder_id}`(**模板串一律用 `request.scope["route"].path` 实测,勿手抄;判定键是 `(method, path)` 二元组**;启动自检校验这 7 个模板存在:**失败只 `log.error` 并把 MCP 通道视为关闭(PAT 一律 403),不得让 ms-api 启动失败**——否则一次路由改名会让全站(含网页/App)崩溃循环,与「MCP 出问题不影响真人」的取舍相反**)+ **batch-move `asset_ids>200` → 403(★ 机制:gate 只在该 `request.scope["route"].path` 命中时 `await request.body()` 自行解析 JSON 数 `asset_ids`;`request.body()` 有缓存,与后续端点解析不冲突。**禁止在 gate 签名里声明 body 模型**——那会把 body 参数塞进该 router 全部 endpooint,GET `/assets` 等无 body 请求直接 422,网页/App 列表与缩略图全挂)** ;`main.py` 挂到全部需认证 router + `/auth/me`;**upload 归属:写键在 `create_upload` 端点内(不在 gate)、读校验全在 `mcp_gate`;`complete` 端点只保留 `payload.upload_id == path upload_id` 断言(不一致 400)**;**complete/abort 成功后 `DEL mcp:upload:{upload_id}`,并捕获 `NoSuchUpload`(abort 幂等 204、complete 返回 409)**;
  5. **统计**:纯 ASGI middleware 按 `mcp_reject_reason` 分桶(Redis 三键 + 进程内 `rejected_infra`);
  6. **审计写侧**:`AuditService` 持 request,`write()` 内**延迟读** state(auth_method/auth_token_id);`get_audit` 已收 request(deps.py:59);
  7. **读侧与统计**:`AuditOut` 加两字段 + CSV 追加 `auth_method` 列 + `Literal["all","session","pat"]` 过滤;`admin mcp-settings` 含 `ZCOUNT` in_flight / today_success / today_rejected_policy / today_rejected_quota / rejected_infra_since_start / cap_hits;`admin/tokens`(回前缀与用户名,**永不回 token_hash**);`usage_stats._PLATFORM_CASE` 新增 `%msmcp%` 且排在 `web_desktop` 前;`presign.py` 打满处进程内 `dynamic_signers_cap_hits`;
  8. **阻塞修复**:`create_multipart_upload`/`complete_multipart_upload`/`head_object`/`abort_multipart_upload` 包 `asyncio.to_thread`;
  9. **测试**:persign 双入口 / auth_method 筛选三态 / 强制改密 PAT 403 / upload 归属 / 排除清单与 `hard` 真值 / 禁用不复活 / metrics 读数 / `DBAPIError` 回落与 rollback / 闸自愈(注入短租约);
  10. **门禁**:`uv run ruff check .` + `uv run mypy app`。
  **注**:审计事件计数注释/labels 映射属 web/app 文件,整体归包 C(含附录 A 的「55 种」更正),包 A 只产出后端事件类型与 usage_stats;避免并行覆盖。
- **包 B · ms-mcp 服务(新目录 material-storage/mcp/,自建独立 constraints)**:官方 `mcp` 包 FastMCP Streamable HTTP(**两个不同的 host 概念不要混**:①**监听地址**必须是容器内 `0.0.0.0`(否则 nginx 连不上);②**DNS-rebinding 的 `allowed_hosts`/`allowed_origins` 白名单**才配双入口地址+localhost,不配则 initialize 直接 403;**注意:`MS_MCP_ENTRY_ALLOWLIST` 是 ms-mcp 自己的 Host 守门;FastMCP 的 `allowed_hosts` 另按 SDK 的 hostname 口径配(是否含端口按版本实测)**——若 SDK 按 hostname 比较,带端口条目不会命中,initialize 直接 403;参数名以所锁 SDK 版本为准,并加 initialize 冒烟用例;**initialize 必须携带 Authorization 头,且 ms-mcp 先调一次 `GET /auth/me`(带该 PAT)确认有效才建会话**——仅做前缀检查时匿名者可反复 initialize 填满会话表/占 SSE 连接(会话上限是全局量);经 /auth/me 校验即顺带受通道闸+IP 桶+RPM 约束。另在 nginx `/mcp` 加 `limit_req`(**须高于 api `per_ip_rpm` 换算值,片段用 `rate=15r/s` + `burst=30`;注意边缘 429 不到 API,不计入任何 `mcp:stats:*` 指标、也无 JSON 文案——故边缘只防会话洪水,额度语义以 API 为准**) + 会话数上限 + 空闲 TTL(如 30min,淘汰即清)`——防会话洪水与长跑内存只增不减**)、11 个工具(含参数上限)、UA/剥离 Cookie/**Host 入口白名单守门**:配置为 **`host=scheme` 映射对**(env `MS_MCP_ENTRY_ALLOWLIST`,逗号分隔),按 `rushes-spec/material-storage/ops-manual.md` **§11.2(§8.1 是已过时的旧栈,勿参考)** 与 `.agents/skills/deploy-hh2/SKILL.md` 的当前入口:`ms.local=http,` + `bucket.taoxiplan.com=https,bucket.taoxiplan.com:443=https,47.108.196.211=https,47.108.196.211:443=https,47.108.196.211:18080=http,47.108.196.211:8080=http,192.168.110.221=http,192.168.110.221:80=http,192.168.110.221:8090=http,localhost=http,localhost:<dev端口>=http,127.0.0.1=http,127.0.0.1:<dev端口>=http`(`rusheslab.taoxiplan.com` 属旧栈/另一套服务,**不列入**——放行会签出指向别处的 URL)(未切域名时公网 HTTPS 是 `https://47.108.196.211/`,故 bare IP 与 `:443` 两种拼法都要列);**条目数 ≤14(当前示例 14 条)**;**dev 与 prod 的 allowlist 必须按环境裁剪**(否则 dev ms-mcp 放行 prod Host、反之亦然,把跨环境签名变成零成本);硬约束是**去重后的 `scheme://host` 全集 ≤16**(`_dynamic_signers` 按 `scheme://host` 计键、全进程共享,presign.py:60/133——web/app 与 MCP 同 Host 时**共用同一缓存项**,故约束对象是并集不是求和);部署前用 `docker compose config` + 人工核对 allowlist 条目数=白名单行数——命中条目取其 scheme(供 XFP 归一缺省用),**未命中 403 不回落**(回落会以容器名签名出不可达 URL 还占 signer 名额)。内网入口若同存 IP/**内网域名(如 ops-manual 示例的 `ms.local`)**/带端口多种拼法,**条目与 Host 均 `lower()` 后比较**(presign 侧 host 已 lower,大小写不一致会被判白名单外);**须按实际可用入口全部拼法全量枚举,含显式默认端口**(`:80`/`:443`——presign.py:63-81 的 Host 含端口,客户端带 `:443` 而白名单只有裸域名即 403;漏配任一拼法=该形态全量 403),列部署 1 双入口验收前置检查;**并核对 prod `.env` 的 `MINIO_ENDPOINT_PUBLIC`**:动态 signer 打满后新入口回落该静态值,若它指内网/旧栈,MCP 客户端会拿到不可达 URL——部署前置检查 + `cap_hits>0` 页面标红**)+Host+XFP+XFF 透传(XFP 值须归一:**与白名单命中条目的 scheme 冲突时以条目为准(不采信客户端自带值,防内网 http 客户端自报 https 签出不可达 URL)**,仅合法且一致时透传;缺失/不合法按条目 scheme 置默认;XFF=入口 nginx 按 server 级 real_ip 还原后的真实客户端 IP 单值,ms-mcp 原样透传——uvicorn --proxy-headers 按 XFF 取链首重写 request.client;单测断言转发请求的 Host/XFP/XFF 与上述语义一致,勿只 mock)/**取 MinIO 字节(缩略图)用独立 HTTP 客户端且不带 Authorization/PAT/Cookie——S3 query 签名与 Authorization 头并存即 400,复用带 PAT 默认头的客户端必挂,单测断言之**/转发超时 30s/日志脱敏、httpx **两套客户端(转发 + 取缩略图字节)共用同一 CA/verify 配置**(内网 http 不校验;公网自签阶段 `verify=False` 或挂 CA,证书转正后切回)、按工具调用粒度的进程内信号量、健康检查端点、Dockerfile(非 root;**同步 api Dockerfile 的清华 APT/PIP 源 build arg,避开 GFW**)、compose 接入、nginx `/mcp` conf 片段:
  ```nginx
  # http 层(文件顶部,与既有 map 同级):
  #   limit_req_zone $binary_remote_addr zone=mcp_limit:10m rate=15r/s;
  # hh2 层(隧道与内网直连都在这层进来);用 ^~ 前缀匹配,防后人新增正则 location 抢占 /mcp
  # ★★ 必须用【变量 upstream】而非静态 proxy_pass:default.conf 是 dev/prod 共享的 bind-mount 单文件
  #    (poc/minio/docker-compose.yml:119-120;deploy_lan.sh 同步整棵 material-storage/),
  #    静态 `proxy_pass http://ms-mcp:8000` 在 ms-mcp 尚未 up 时会让 nginx 启动即
  #    [emerg] host not found in upstream "ms-mcp" → nginx 起不来 → 整站不可用。
  #    变量写法把 DNS 解析推到请求期(同文件既有 `resolver 127.0.0.11` 与 `$root_backend` 变量 proxy_pass 先例;`ms-api` 那处是静态)。
  location ^~ /mcp {
      resolver 127.0.0.11 valid=30s;                 # docker DNS(server 级已有可省略)
      set $mcp_upstream http://ms-mcp:8000;
      proxy_pass $mcp_upstream;
      proxy_set_header Host $http_host;              # ★ 勿用 $host(剥端口);nginx 默认 $proxy_host 会打断透传链;与既有 api location 同惯例(presign.py:66 同源)
      # ★ XFP 在 hh2 层必须【透传上游】不得用 $scheme 覆盖:公网流量 TLS 终结在跳板机,
      #   hh2 层 $scheme 恒为 http,写 $scheme 会把跳板机传来的 https 压成 http,
      #   api 无条件信任 XFP(Dockerfile:33)→ 公网入口签出 http URL(2026-10-12 修过的 prod 事故形态)。
      #   照抄现役 api location 的 $xfp map(default.conf:7-10 已定义,缺失回落 $scheme)。
      #   ★ map 只能放 http 层且现役已有同名 $xfp——复用,勿重复定义(nginx -t duplicate)。
      proxy_set_header X-Forwarded-Proto $xfp;
      # ★ XFF 按本仓 W2a 惯例——勿用 $proxy_add_x_forwarded_for 追加(客户端可伪造):
      #   real_ip 还原(set_real_ip_from 网关单 IP + real_ip_header XFF)现役在 server 级(default.conf:28-30),
      #   ★ 勿在 location 内重复声明;此处只需覆写 XFF 单值。
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_http_version 1.1;  proxy_set_header Connection "";
      proxy_buffering off;  proxy_read_timeout 1800s;  proxy_send_timeout 1800s;  # SSE(read+send 双放大,照本仓 /ws 先例)
      limit_req zone=mcp_limit burst=30 nodelay;   # 边缘挡板(仅防洪水;额度拒绝以 API 为准,边缘 429 不入指标)
      limit_req_status 429;                        # 默认 503 会与「Redis 故障 503」混淆
  }
  # 跳板机层(TLS 终结层):现役为单 proxy_pass(零缓冲 + read/send 3600s,见 `rushes-spec/material-storage/ops-manual.md` / `.agents/skills/deploy-hh2/SKILL.md`),
  #   ★ 先核对现役 3600s/零缓冲是否已覆盖 /mcp;已覆盖则本层无需新增 location。需新增时:
  #   proxy_set_header Host $http_host;  proxy_set_header X-Forwarded-Proto $scheme;   # $scheme 在这层才是 https
  #   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;                      # 这层追加没问题,hh2 层 server 级 real_ip 会还原链尾真实 IP
  #   proxy_http_version 1.1;  proxy_set_header Connection "";
  #   proxy_buffering off;  proxy_read_timeout 3600s;  proxy_send_timeout 3600s;
  ```
  以及工具层单测(mock API)。
- **包 C · web(含审计/统计标签文件与路由)**:**`App.tsx` 加 `/settings` Route + 头像/菜单入口**(现通配 `*` 会重定向,不加路由则页面不可达)并新建 `/settings` 页「访问令牌」区(创建/列表/吊销,创建弹窗明文只显一次+no-store+「令牌=账号级全权限凭证」警示文案);管理后台 MCP 设置页(开关+滑杆(1~8)+RPM;**关闭时滑杆置灰**;**闸实时指标:在途并发/今日成功请求数/今日拒绝量(关闭类·配额类分列),标注「UTC 日,使用统计页为北京时间日」**)+全部 token 管理;审计页加「常规/令牌」筛选 + 行内展示 auth_method + 导出行(**行内展示要用这两字段,须先在 `src/api/types.ts` 的 `AuditEvent` 声明 `auth_method?/auth_token_id?`——现无此字段,直接引用会 `tsc -b` 报错**;AdminAuditPage.tsx 计数注释 61+全部=62 → 64+全部=65);标签映射(AdminAuditPage.tsx `EVENT_TYPES`、**lib/labels.ts `EVENT_TYPE_LABEL`**(计数注释按实际键数重核,勿删历史死键)、**components/admin/usage_shared.tsx `PLATFORM_LABEL` + UsageStatBars.tsx `PLATFORM_CLASS_LABEL/BAR_COLOR` 补 mcp**)、**`AppHeader.tsx`/`MobileTabBar` 加管理后台 MCP 设置/令牌管理入口 + `App.tsx` 加 `/admin/mcp-settings` 等 Route**;**App `lib/features/admin/audit_labels.dart` 三处 + `admin_usage_page.dart` 的 `_platformLabels['mcp']`**(`kAuditEventTypes`/`kAuditEventLabels`/**`kAuditDetailKeyLabels`(新 details 键否则 App 详情裸显示)**;仅代码,本轮不发版);使用统计页 mcp 渠道显示(标注口径:仅审计可见操作)。

App(Flutter)**本周期不发版**;仅同步审计标签数组(包 C),下次发版生效。

## 部署(dev 先行 → prod)

1. dev(**与 prod 同序:先同步 → 再迁移 → 最后 restart**):
   - **① server 端 `docker-compose.override.yml` 只覆盖**(`container_name: ms-mcp-dev`、`MS_API_BASE_URL`=dev 服务名、**在 override 的顶层 `networks.poc-net.name` 重映射到 dev 网络**(service 下的 `networks` 不接受 `name`,写错 `docker compose config` 直接报错;ms-mcp 的 service 只写 `networks: [poc-net]`);dev 网络名以 `docker network ls` 实测为准(changelog 记 `msdev-poc_poc_net`、runbook 记连字符,落地前核实);service 定义本身只在 `api/docker-compose.yml`)——dev/prod 同机,不覆盖会与 prod 同名容器撞车;
   - ② `bash scripts/deploy_lan.sh dev`(**不带 `--restart`**;这步才是把含 0020 迁移的新代码送到目标机——**漏了它,迁移在目标机上不存在,`upgrade head` 是 no-op**);
   - ③ `ssh hh2 'cd /home/msdev/ms/api && docker compose exec -T ms-api alembic upgrade head'`;
   - ④ `ssh hh2 'cd /home/msdev/ms/api && docker compose restart ms-api ms-worker'`;
   - ⑤ `ssh hh2 'cd /home/msdev/ms/api && docker compose up -d --build ms-mcp'`;
   - ⑥ nginx conf 改动**提交仓库**(勿在服务器手改:default.conf 全仓唯一,下次 deploy 会覆盖)→ 随 deploy 同步后 `docker exec poc-nginx-dev nginx -t && docker exec poc-nginx-dev nginx -s reload`;
   - ⑦ **验收前置 1:管理员在 `/admin/mcp-settings` 置 `enabled=true`**(通道默认全关,不开则后续 MCP 请求全 403);**验收前置 2:上机核对跳板机 443 vhost 是否覆盖 `/mcp`**(conf 不在仓库,见 ops-manual §11.1)——不覆盖则按包 B 片段新增(`Host $http_host`、XFP `$scheme`、零缓冲、3600s)并 `nginx -t`;回滚时同步撤除。

   **★ 双入口可达验收**:内网入口(hh2 内网地址直连)与公网入口(跳板机 443 透传)各连通一遍。**验收项**:① ms-mcp 透传的 X-Forwarded-Proto 在 api 生效(api Dockerfile 即 `--proxy-headers --forwarded-allow-ips '*'`);② ms-mcp 经 `MS_MCP_INTERNAL_BASE_URL` → 入口 nginx → `/ms-thumbs/` 取到缩略图字节(LAN 直达,**不依赖公网 hairpin**);hairpin 只影响「公网客户端自取下载 URL」,属另一条;③ `curl /ms-healthz`(nginx 路径,default.conf:107)与登录正常(闸未误挂)。**内网入口协议形态照抄现网(当前 http)**;ms-mcp 重启会断所有 MCP 会话(单副本内存 session),运维择时。**localhost/127.0.0.1 调试注记**:签出的 URL 指向开发者本机,取字节/下载在该形态不可用属预期(白名单须同时含 `localhost`、`localhost:<port>`、`127.0.0.1`、`127.0.0.1:<port>`)。
2. prod:**先对账 alembic current vs head;并核对跳板机 443 vhost 已覆盖 `/mcp`(同 dev ⑦-前置 2);再 upgrade,最后 restart**。**★ 顺序不可反**:新代码 + 旧 schema(0019)时,`AuditService.write` 只要 insert 带 `auth_method` 就 `UndefinedColumn`,而 upload/download/share 主链路都 await 它 → **全站审计写入失败(500),不是仅 MCP 不可用**(比 0019 事故面更广)。deploy_lan.sh 无 alembic 步骤(与有 alembic 的 deploy_server2.sh:176 不同),故升级须人工先跑。**prod 部署可复制步骤**(目标机 `/home/msdev/ms` / `/home/huanhua/ms`,见 deploy_lan.sh:22-23):
   **★ 分两段执行:「本地」步在仓库 `material-storage/` 下跑,**其余步都要 ssh 到目标机**(`/home/msdev/ms` for dev、`/home/huanhua/ms` for prod)——本地没有 ms-api/ms-redis 容器,直接 `docker compose exec` 必失败。`deploy_lan.sh` 用 `[[ -d api && -d poc ]]` 校验 cwd,且同步时**排除** `docker-compose.override.yml`(override 是环境差异来源,不会被覆盖)。
   ```bash
   # ──【本地】仓库根 ──
   cd material-storage

   # 1 对账(升级前)——以下均为【目标机】命令
   ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose exec -T ms-api alembic current && docker compose exec -T ms-api alembic heads'
   # 2 【本地】★ 先同步文件、【不带 --restart】:--restart 会立刻加载新代码,而新代码 + 旧 schema
   #    ⇒ AuditService.write insert auth_method → UndefinedColumn → 全站审计 500(见上)
   bash scripts/deploy_lan.sh <env>

   # 3 【目标机】迁移(必须在 restart 之前完成)
   ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose exec -T ms-api alembic upgrade head && docker compose exec -T ms-api alembic current'

   # ★ 窗口期注意:ms-api 是 restart: unless-stopped,step2~step3 之间若崩溃/OOM/宿主重启
   #   会自己拉起新代码 + 旧 schema → 全站审计 500。故 step2 之后应尽快 step3;
   #   若窗口内发生重启,先补跑 alembic upgrade head 再继续
   # 4 【目标机】现在才 restart,加载新代码
   ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose restart ms-api ms-worker'

   # 5 【目标机】ms-mcp 首次/更新(独立镜像,restart 不会 build)
   ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose up -d --build ms-mcp && docker ps --filter name=ms-mcp'

   # 6 【目标机】nginx 校验并热载(★ poc-nginx 属 poc/minio 的 compose 项目;先 -t 勿直接 restart)
   ssh hh2-prod 'cd /home/huanhua/ms/poc/minio && docker compose exec -T poc-nginx nginx -t && docker compose exec -T poc-nginx nginx -s reload'
   ```
   注:若 nginx conf 含 `/mcp` 而 ms-mcp 尚未 up,变量 upstream 写法可保证 nginx 仍能启动(静态写法会 `host not found in upstream` 起不来)。
3. **Web SPA 部署(独立通道,deploy_lan 不同步)**:`deploy_lan.sh` 显式 `--exclude 'static/web'`(deploy_lan.sh:61/71/86/90),故 web 必须单独构建与替换 —— **构建源必须是「含本次改动的代码」+「主仓 node_modules」**——worktree 的 `web/` 无 node_modules(自装耗时,且须保证与主仓锁定版本一致;`pnpm-lock.yaml` 锁 antd 6.4.2)。二选一:**(a) dev**:把 worktree `web/src` 同步到主仓 `web/src` 后构建,或给 worktree `web/node_modules` 建指向主仓的 junction;**(b) prod**:**必须先合并到 `liuqi` 再在主仓构建**,否则主仓源码没有 `/settings`,构建出来照样没有该页→ 备份现有 `static/web`(命名 `web.bak-<日期>-mcp`)→ 分片/原子替换 → **校验新指纹 `index-*.js` 与三入口一致**;dev 同样走该通道(`deploy_lan` 也排除 `static/web`,产物落 `api/app/static/web`),否则 dev 也没有 `/settings` 页。**PM 验收 1 之前必须完成此步**,否则网页无 `/settings` 页、无法创建令牌。
4. **回滚流程(评审 P0-9 修正后;本仓 lan 部署=rsync + bind-mount,无镜像切换)**:enabled=false 关通道 → **rsync 回旧 commit + `compose restart ms-api ms-worker`**(★ 必须含 worker:worker 也挂 bind-mount,只重启 api 会让 worker 继续跑新逻辑;镜像不变)。0020 是纯增量迁移(可空列+独立新表),旧代码与新 schema 兼容共存,**DB 无须 downgrade**——deploy_lan 无 boot 期 alembic,不存在「旧代码起不来」;仅当迁移本身有错才 `alembic downgrade 0019`(downgrade 已写全;**执行须用完整 revision id:`alembic downgrade 20261028_0019` 或 `-1`,不可只写 `0019`——revision 是 `20261028_0019`,`0019` 是**后缀**不是唯一前缀**)。**另需三步收尾**:①nginx conf 回滚后必须 `nginx -t && nginx -s reload` 才会撤掉 `/mcp` location;②**先删容器:`docker rm -f ms-mcp`(prod)/ `docker rm -f ms-mcp-dev`(dev)**——必须用 `docker rm`:rsync 回旧 commit 后 compose 里已无该 service,`docker compose rm` 会报 no such service;③再重启 nginx 生效。web 回滚照旧 SPA 备份替换。
5. 新 Python 依赖(官方 `mcp` 包):**在 material-storage/mcp/ 自建独立 constraints 文件锁版本**(须写明:Python 3.12、官方 `mcp` 包具体版本号 + 全部传递依赖 pin;先例=api constraints.txt——70 pin、per-image 单文件闭包,**勿塞进 api 闭包**;升降级流程=改 pin → build → 套件 → dev → prod)。**门禁:api 包 A `uv run ruff check .` + `uv run mypy app`;web 包 C `pnpm build`(含 `tsc -b`);App 仅 `flutter analyze`(本轮不发版);**`material-storage/mcp/` 也须 `uv run ruff check .` + 工具层 pytest(mock API)**。
6. ms-mcp 容器:资源限制(mem/cpu limits)、非 root、健康检查、**不 publish 宿主端口(仅内网网络,防绕过 nginx 伪造 XFF)**;**挂业务网络(prod `poc-pigsty-minio_poc-net`;dev 名以 `docker network ls` 实测为准——changelog 记 `msdev-poc_poc_net`、conf 注释记连字符,与各自 nginx 同网;api/docker-compose.yml:89-92 是 prod 名)否则 nginx 解析不到 `ms-mcp`**;**compose 落位定稿:service 定义只在 `api/docker-compose.yml`;dev 的 `docker-compose.override.yml` 只覆盖 `container_name: ms-mcp-dev`/`MS_API_BASE_URL`/`networks.*.name`(重映射到 dev 网络)**(勿在 override 里重复定义整个 service,否则 prod 的 `up ms-mcp` 找不到服务);验收前跑 `docker compose config` 核对两环境。**★ 禁止给 ms-mcp 写 `env_file: .env`**(新增服务最易照抄 ms-api 的 env_file,api/docker-compose.yml:48)——那会把 DB/Redis/MinIO 凭证灌进 ms-mcp,直接违反架构红线;ms-mcp 只允许显式 `environment:` 四项(`MS_API_BASE_URL`、`MS_MCP_ENTRY_ALLOWLIST`、**`MS_MCP_INTERNAL_BASE_URL`(D7 取缩略图字节用的固定内网入口,如 `http://192.168.110.221`;dev 用 `:8090`)——没有它,ms-mcp 只能猜用哪个白名单条目,dev/prod 必有一侧签错 Host**、可选 CA 配置、可选 `MS_MCP_SESSION_TTL`;会话数上限为编译常量,仅测试构建可注入)。dev 环境按本仓惯例加 `-dev` 后缀容器名并改 `MS_API_BASE_URL` 指向 dev 服务名。**ms-mcp 是独立镜像,`deploy_lan.sh --restart` 只 restart 不 build ⇒ 必须 `up -d --build ms-mcp`**(见部署 2 步骤 5);**deploy_lan.sh 只管 ms-api/ms-worker,ms-mcp 同步/重启须按部署 2 手动步骤或并入脚本**(deploy_lan.sh:138 现状只 restart 两容器)。
7. **运维正本与记账**:更新 **`rushes-spec/material-storage/ops-manual.md`**( `/mcp` 入口、Host 白名单维护步骤、ms-mcp 启停与重启影响面)与 `CLAUDE.md` 相关条目——否则后续运维无正本;并按 AGENTS.md 约定写 `scripts/changelog.md`(当天节,逐项+commit hash)。

## 测试功能点(按包归属:API=包 A / ms-mcp=包 B / 双端联合)

> **运行位置**:后端测试在 dev 容器内跑(docker cp tests 进容器,先 `rm` 防嵌套;`-o asyncio_mode=auto`),**不在本地起栈**(仓库硬规则);ms-mcp 单测在本地 venv;web `pnpm build`、App `flutter analyze`。

- PAT 生命周期:创建(明文只显一次/上限 5 个含并发竞态/advisory lock/强制改密态拒绝/**expires_in_days 边界:0 与 366 → 422**)/列表/吊销后立即 401/**横向越权负例:用户 B 吊销用户 A 的 token → 404 且 A 的 token 状态不变;重复吊销 → 204**/过期 401/禁用用户 401/**密码变更后全部 PAT 立即 401(四路径:自助改密 / directory reset-password / set_password.py / set_initial_admin.py)**/**PAT 调 /auth/tokens 三端点 与 /auth/change-password → 403(防令牌自我续期/自助改密)**。
- **[包 B] 工具层映射**:list_folders 组树(children/direct+subtree 计数对齐 API)、list_files 翻页(offset)、get_part_url 过期重签(同 multipart 续传)、abort_upload、**complete_upload 请求体断言 `parts=[{PartNumber,ETag}]` 形状(非单 etag)**。
- /admin/tokens 与 /admin/audit+export.csv:`auth_method=pat` 只回 PAT 行、session 归并 NULL、**csv 与列表同参**;管理员吊销任意 token → 204。
- PAT 分支:Bearer 有效→身份与 session 同人同权限;scheme 大小写(`bearer`/`Bearer`);**cookie 回落边界:仅 decode 失败(ValueError/KeyError)回落 PAT;decode 成功但用户态 401(禁用/删除)直接 raise 勿回落(F5「禁用立即下线」语义)**;非 `mspat_` 的 Bearer → 401;cookie 与 Bearer 同发时 cookie 优先(现状语义不变)。
- 四段闸(通道闸/IP 桶/RPM/并发闸):enabled=false → 403 且文案正确;RPM 超限 → 429+Retry-After;并发饱和 → 429+Retry-After;**ZSET 闸不泄漏不清零**(杀进程模拟崩溃;**自愈窗口 = 租约 600s+margin,故该用例须跑 >11min,或测试期注入短租约(可配置)后按注入值断言**——10 分钟跑不出自愈);**全局闸拒绝后 per-token 配额不被自塞**(全局饱和期连打 N 次后全局空闲,同 token 应立即可进);**Redis 故障注入三场景**(flag miss 回源/Redis down 时限流与闸 503 fail-closed/DB 也挂时通道关闭 403;**Redis down 期 flag 查 DB 频率 ≤ 每 worker 每 5s 一次**);单 Lua 脚本原子性(检查+回滚不拆两次 round-trip)。
- 审计:PAT 路径写审计 auth_method=pat+token_id;session 路径恒 session;存量行 NULL=session;**PAT 连续 100 次 search → 审计表零新增行**(锁死现状语义)。
- **缩略图取字节**:公网入口客户端 → `get_thumbnail` 仍返回 image content(ms-mcp 走内网 Host 自取,不依赖 hairpin);内网入口同样走内网直达。
- 通道开关与限流不影响 session 请求(关通道+打满并发时网页全功能正常);**★ gate 挂载回归:挂上 `mcp_gate` 后 `GET /assets?folder_id=…`、`/assets/{id}/thumbnail-url`、`GET /folders` 仍 200(session 请求;证明 gate 未污染 body/query 校验)**;**★ 闸挂载点回归:关通道(enabled=false)+打满并发时 `GET /healthz`、`POST /auth/local/login`、`GET /maintenance/banner` 均正常(闸不得挂在 app 级/app 级会让这些端点被 401/403 挡死)**。
- **前置 IP 桶**:同 IP 超 per_ip_rpm → 429(非 401);不同 token 累计同样计入(证实是「总请求/IP 上限」);阈值 ≥ per_token_rpm 不误伤单令牌。
- **配置缺失自救(分两条)**:①**行缺失**(表在)→ `GET` 回默认值、`PUT` upsert 成功;②**表缺失**(迁移未跑)→ `GET` 回默认值、**`PUT` 返回 503 并提示「先跑 alembic 0020」**(无表可写,不可自救);两种都须先 rollback 再回落,不得 500。
- **测试钩子**:租约/会话 TTL/白名单条目数须可配置注入(短租约→秒级验证自愈;短 TTL→分钟级验证淘汰)。`in_flight` 与并发占用**不能靠 `enabled=false` 构造**(关通道时 PAT 在 `get_current_user` 首步即 403),须**直接向 `mcp:conc:global` 注入成员**或「先开通道占满再关」;batch-download 是亚秒级(重活在 worker)不可用作长请求;`dynamic_signers_cap_hits` 用直调 api 轮换 >16 个 Host(不经 ms-mcp,属预期)。补测:`同一 Session-Id 换 PAT → 401`/`Host 白名单未命中 → 403`/`ms-mcp 剥离 Cookie 与 X-User-Id`/`flag DEL 失败 → ≤65s`/`Redis 挂时 metrics 字段为 null`。
- auth_method 筛选执行计划:`auth_method=pat` 无时间窗的 EXPLAIN 记录基线(为「慢则补 COALESCE 表达式索引」决议留判据)。
- **PAT 身份=用户本人的负例**:用户 B 的 PAT 请求无 `can_download` 的资产 → 403(与同人 session 同码);**PAT 的 list/search 结果集与同人 session 逐条一致**(D1 核心断言);管理员 PAT 可调 admin 端点(预期,非越权)。
- **upload 归属**:PAT 用他人 upload_id 调 sign_part/abort/**complete(path 参数)** → 403;自己的 → 正常;**`complete` 的 path 与 body `upload_id` 不一致 → 400(负例,验证校验键用的是 path)**;session 路径维持现状。
- **PAT 排除清单精确性**:`POST /assets/batch-prefix` → 403;`DELETE /assets/{id}?hard=true` → 403;**`?hard=1`/`t`/`y`/`on`/`TRUE`/`Yes` 一律 403(与 Pydantic 同源解析)**;**`POST /assets/batch-move`(≤200 项)、`DELETE /assets/{id}`(软删)→ 正常可用**(不得误伤);**`GET /folders/{id}`、`PATCH /folders/{id}` 对 PAT 仍 200(证明按 method 判定生效)**,`DELETE /folders/{id}` → 403;**batch-move `asset_ids` 201/1000 → 403**;`GET /admin/audit/export.csv` → 403;**`POST /admin/grant-templates/apply-default`、`POST /admin/directory/users/{user_id}/disable`、`GET /admin/usage/stats` → 403**。
- **禁用吊销**:disable 用户后其 PAT 立即 401;重新 enable 后旧 PAT **仍 401**(已吊销,不复活)。
- **initialize 校验**:伪造 `mspat_` 前缀串 initialize → 拒绝且不建会话;合法 PAT → 建会话并复用;超会话上限/空闲 TTL → 淘汰。
- presign 双入口:同一 PAT 分别经内网地址与公网域名调 api → 签出的 URL host 各自跟随入口(内网=内网地址,公网=公网域名),XFP 透传下公网入口签出 https。
- complete 越权回归:构造错误 bucket/key 回传 → 400(以 folder 归属为准,现有校验)。
- usage_stats:UA msmcp/* 归入 mcp 桶。

## PM 验收清单(端到端,不采信自报)

0. **前置:管理员在 `/admin/mcp-settings` 开启通道 `enabled=true`**(默认全关,不开则 1-9 全部 403)。
1. 网页登录 → 设置创建 token → 明文仅弹窗一次,列表显示前缀;
2. `curl -H "Authorization: Bearer …" /auth/me` → 200 身份正确;列项目结果与网页一致;
3. MCP 客户端(如 ZCode)配 /mcp 地址+token → initialize → whoami;
4. search_assets 搜到目标 → get_thumbnail small(240)/large(1024)vision AI 能看清,variant 回报正确;
5. get_download_url → URL 在外网 GET 到字节(魔数对);**双入口各验一遍**:内网地址入口签出内网 URL(不走跳板机,LAN 速率),公网域名入口签出**公网 https** URL(检查点:hh2 层 XFP 必须透传上游不得 `$scheme` 覆盖——覆盖则此处签出 http URL 即打回);
6. create_upload → PUT 分片 → complete → 网页刷新看到新文件,缩略图正常派生;
7. 吊销 token → 下一次调用立即 401;改密码 → 该用户全部 token 立即 401;
8. 管理员把通道关掉(enabled=false)→ MCP 全部 403、**拒绝量(policy 键)递增**、网页全程无感(`/healthz`、登录正常);**关闭与恢复生效 ≤5s(单 worker 且 Redis 写/DEL 成功;双失败时本进程与其他 worker 均最坏 65s)**;
9. 快速连打 → 触发 429+Retry-After,文案可读;单 agent 打满 per-token 并发时,第二个用户的 MCP 请求照常成功(公平性);**PAT 打满期间 web 列表/下载不出现 5xx 与 pool timeout(共享 DB 连接池;量化 P95 阈值不作硬断言——8 并发下余量本就有限)**;
10. **管理端 token 全量列表能显示用户姓名与前缀;管理员吊销他人 token → 204 且对方下一次调用 401;`PUT /admin/mcp-settings` 改配额生效(关闭→403);非法组合(如 per_token_concurrency > max_concurrency) → 422**;
11. **dev 走一遍回滚五步**(关通道 → rsync 回旧 commit → restart api+worker → `docker rm -f ms-mcp` → nginx -t/reload)并确认 `/mcp` 下线、web 正常;ms-mcp 与闸的 5xx/401 激增有观测项(日志或指标);
12. 审计页筛选「令牌」→ 只见 PAT 的**上传/下载签发/download_denied 等**审计可见操作;行内显示 auth_method;**导出 CSV 含 auth_method 列且 pat 行标 pat**;**自助**令牌管理事件属 session,凭 details.token_prefix 快照在「全部」视图按事件类型追溯(管理端操作按实际认证方式标注);PAT 搜 100 次审计无新增;**经 ms-mcp 调用后 `GET /admin/audit` 该行 request_ip 为客户端真实 IP(非 ms-mcp 容器 IP)**;使用统计出现 mcp 渠道(标注仅审计可见口径);管理端 mcp-settings 能看到今日成功数/在途并发/拒绝量(关闭类与配额类分列;闸占用时 in_flight=ZCOUNT 读数正确)/signer 缓存健康(dynamic_signers_cap_hits 字段存在)。

## 风险与钉子备忘

- **presign 双入口动态(D12)**:ms-mcp 透传 Host+XFP,api 动态预签名机制原样生效(与 web 同语义);session 与 PAT 流量动态行为一致,2026-10-12 周期红线「勿回退」天然满足;脆弱性(任一层丢 Host)由验收第 5 条双入口硬测兜住;
- SSE 长连接过**两层** L7 nginx(跳板机+hh2)的 buffering/timeout 配置是常见坑,验收用真实 MCP 客户端连公网入口测;**header 透传分工**:Host 两层都 `proxy_set_header Host $http_host`,**XFP 只在跳板机(TLS 终结层)配 `$scheme`,hh2 层透传上游不得覆盖**(hh2 层 $scheme 恒 http,覆盖即打挂公网 https 动态预签名),conf 见包 B;
- **FastMCP host allowlist**:双入口地址+localhost 都要加,否则 initialize 403(部署即踩,不是理论风险);
- **租约 600s 只保证覆盖 11 个工具映射端点**;超出租约面的端点**一律对 PAT 排除(共七处)**:batch-prefix、`DELETE /assets/{id}?hard=true`、`admin/audit/export.csv`、admin 的 apply-default / directory disable / usage stats、`DELETE /folders/{id}`;batch-move 封顶 200(**batch-prefix 在请求内串行 1000 项 copy/delete,虽 to_thread 仍占请求时长;hard 单项但 purge 含重试可能数分钟;batch-move 无 boto3 故不排除**——见 C.6)。
- **ms-mcp v1 单副本**:Streamable HTTP 会话态内存维护,水平扩展前勿加副本;**Session-Id 等价于绑定后的凭证**:拿到 `Mcp-Session-Id` 者可冒用该会话,ms-mcp 日志须脱敏 Session-Id 与其绑定的 PAT;
- **Host 入口白名单守门(D12)**:ms-mcp 转发前校验 Host ∈ 双入口白名单,收窄动态 signer 缓存放大面(presign.py MAX_DYNAMIC_SIGNERS=16 无淘汰,轮换 Host 即可打挂同 worker 动态预签名连累 web;直调 api 的存量滥用面不在本方案射程);api 侧缓存加 LRU/TTL 淘汰列二期;
- **SSE 空闲断连**:hh2 层 1800s、跳板机现役 3600s,**实际瓶颈是 hh2 的 1800s**(空闲 >30min 即断,客户端须重连 initialize);如需更长,两层一起放大——运维注记;
- 审计事件计数注释基线**四处**(web AdminAuditPage.tsx / web labels.ts / App audit_labels.dart / 附录 A)同步(见 A 节钉子;App 只改代码本轮不发版);
- prod alembic 对账钉子(见迁移节);
- mcp 依赖 pin;ms-mcp 容器不得挂任何 DB/Redis/MinIO 凭证(架构红线,部署时检查 env);**ms-mcp 不 publish 宿主端口、只加入 nginx 可达的内网网络**——「原样透传 XFF」的可信前提是客户端只能经 nginx 到达 ms-mcp,网内直连者可自带 XFF 伪造审计 request_ip(部署检查项);
- **ms-mcp 网络位置(本期接受,理由写明)**:它与 api/db/redis/minio 同网(Redis 无 password),「不持凭证」≠ 网络隔离。**本期接受该风险的依据**:单副本自有代码、非 root、不 publish 端口、仅 nginx 可达、日志脱敏;若后续要多副本或接受外部贡献代码,须改为「只与 nginx 共享的专用网络」或给 Redis 加认证;
- **session 旁路(已知、本期不解决)**:闸只覆盖 PAT;session cookie 交 AI 可绕过全部 MCP 限流。故「防止大量 AI 涌入」实际只对走 MCP/PAT 的流量有效;
- **admin PAT 的 DoS 面(已知、可接受)**:D1 下 PAT=全账号身份,管理员 PAT 可调 `/admin/tokens`(吊销他人令牌)、`PUT /admin/mcp-settings`(改配额)、**`POST /admin/directory/users/{id}/reset-password`(重置任意用户密码并连带吊销其全部 PAT)**——`.../disable` 已在排除清单里对 PAT 403,不在此列——非提权(本就是该管理员的权限),但属可被 AI 误触的破坏面;若要收紧,可对这两组写端点要求 session(列二期);
- **worker/队列不在闸的约束面**:`complete_upload` 成功会入队缩略图/视频/ livp 派生(assets.py:280-288)、batch-download 的重活在 worker——**闸只管请求期,worker 负载需另行观测**(本期声明不覆盖);
- **前置 IP 桶是 PAT 洪水的唯一防线**:RPM 键依赖 token_id,无效 token 无此键;负缓存只挡重复同一伪 token。IP 桶(client_ip 由 nginx W2a 还原)须在实现中落实,不可只靠负缓存;
- 上传孤儿 multipart 属**未实施的存量缺口**(prod MinIO 曾拒 lifecycle abort 配置,cron 清扫计划未写码),本期靠 abort_upload 工具+失败引导;cron 清扫见二期候选;
- **禁用/离职必须一并吊销 PAT**:`directory.py:390` 的禁用是 **`revoke_user_completely` + `is_active=False`**(PAT 认证会 401),但 `directory.py:428` 重新启用后旧 PAT **复活**——故 **disable 同一事务内调 `revoke_user_tokens(reason="user_disabled")`**(纳入 D13 挂钩点与包 A/测试);
- 通道默认关:上线后管理员需显式开启 + 建议首周配额从紧(如全局 6 / per-token 2 / RPM 60 / per-IP 300),观察使用统计再放宽(全局上限受 DB 连接池约束,见 D5)。

## 二期候选(本期不做)

MinIO 孤儿 multipart cron 清扫(存量缺口);token 只读档;>5GiB 多分片上传;ms-mcp 多副本水平扩展(sticky/Redis session store);按项目的 MCP 白名单;MCP 专用只读审计报表;App 端 token 管理;api 动态 signer 缓存 LRU/TTL 淘汰。

## 当前有效值(执行唯一口径)

> 本表收敛**可调旋钮 + 关键键名/顺序**;其余固定值(如 token 1~365 天/默认 90 天、每用户 5 个、单分片 5GiB、缩略图 TTL 1800s)以正文为准。若与本表冲突,按本表。历轮评审的过程记录见文末「修订史摘要」——那里只保留"改了什么方向",**不保留任何旧数值**,避免被误当执行口径。

| 项 | 当前值 |
|---|---|
| 通道开关 | `enabled=false`(默认全关),flag Redis TTL **60s** + 进程内 5s 缓存;`UndefinedTableError`/行缺失/`DBAPIError` → 先 rollback 再按默认值 |
| 全局并发 `max_concurrency` | 默认 **8**,合法域 **1~8**(3×并发 ≤ pool 30;10 是理论极限、web 余量为 0,不推荐) |
| 每令牌并发 `per_token_concurrency` | 默认 4,合法域 1~8 且 ≤ max_concurrency |
| 每令牌 RPM | 默认 120,合法域 1~**450**(受 `2× ≤ per_ip_rpm 900` 约束) |
| 前置 IP 桶 `per_ip_rpm` | 默认 **600**(≥2×RPM),合法域 1~**900**(与边缘 limit_req 15r/s 对齐) |
| 认证链顺序 | 通道闸 → IP 桶 → token 查表 → 用户态 → RPM(get_current_user 内);**第六步并发闸在独立 `mcp_gate`** |
| 并发闸租约 | **600s**(释放靠 finally ZREM;租约只决定崩溃回收上限。**只保证覆盖 11 个工具端点**;admin 批量/流式端点另作要求) |
| PAT 排除端点(7) | batch-prefix、`DELETE /folders/{id}`、`DELETE /assets/{id}?hard=true`、`admin/audit/export.csv`、admin 三处批量/流式(apply-default / directory disable / usage stats);batch-move `asset_ids` 封顶 200 |
| 缩略图 GET 超时 / 转发超时 | 15s / 30s |
| 工具数 | **11** |
| 审计事件 | 新增 3 个:`token_created`/`token_revoked`/`mcp_settings_changed` |
| 密码/禁用吊销挂钩 | **四处密码变更 + 一处禁用 = 五处**,统一 `revoke_user_tokens(db, user_id, reason) -> list[TokenRef]`(函数内不写 audit) |
| 计数键 | `mcp:stats:{requests|rejected_policy|rejected_quota}:{yyyyMMdd}`(UTC)+ 进程内 `rejected_infra_since_start` |
| 在途并发指标 | `ZCOUNT mcp:conc:global now +inf` |
| 迁移号 | **0020** |
| SSE 超时 | hh2 **1800s**;跳板机现役 **3600s**(实际瓶颈=hh2 的 1800s) |
| ms-mcp | 单副本、无宿主端口发布、**禁 `env_file`**、Python 3.12 + `mcp` 包具体版本 pin;白名单 **14 条(≤14)且按环境裁剪**,去重 `scheme://host` ≤16 |

## 修订史摘要(过程记录,不构成执行口径)

> 2026-10-30 一天内经历:外部评审两轮(DeepSeek)+ qplan 独立盲审 17 轮(每轮全新子智能体、只读、逐条到代码求证)。**只记方向,不记旧数值**——任何数值以「当前有效值」表为准。

- **架构定稿**:MCP 做 API 薄代理(不直连 DB/存储);PAT 作为外部程序身份(FGA 为权限正本,不做 scope);双入口(内网直连 hh2 / 公网走跳板机)动态预签名,否决静态 base 与伪造 Host;
- **否决项**:按常规流量动态算比例限流(改绝对配额);app 级挂闸(会锁死登录与 `/healthz`);nginx 静态 upstream(容器未起则 nginx 起不来);`BaseHTTPMiddleware`(改用纯 ASGI);原始 query 串匹配 `hard`(可被 `?hard=1` 绕过);全局静态 presign 覆盖(回退内网直达);
- **改对的坑**:ZSET 滑窗与全局拒回滚;审计 `write()` 延迟读 state(依赖顺序);`DBAPIError` 全集覆盖;nginx 变量 upstream + `$http_host` + `$xfp` 逐层 + W2a 单值 XFF;FastAPI host allowlist 双入口;S3 query 签名与 Authorization 并存即 400;`UploadCompleteIn.parts` 是数组;`revoke_user_tokens` 不含 audit;租约只定崩溃回收上限(不可当作"最坏耗时");
- **代价换来的结论**:PAT 排除重批量端点(租约无法给 1000 项同步 boto3 定上界);禁用必须连带吊销 PAT(否则重新启用会复活);initialize 必须调 `/auth/me` 校验(否则匿名可占满会话);`mcp_gate` 与认证链分离(前者 router 级、后者在 get_current_user 内);
- **代理服务器细节**(逐轮订正):`deploy_lan.sh` 需 `--restart` 才重启、且排除 `static/web` 与 override;prod 顺序必须"先迁移后重启";`poc-nginx` 属 `poc/minio` compose;dev 容器带 `-dev` 后缀且 override 手工维护;
- **文档自身教训**(值得带给后续方案):(1) 修订记录里保留旧数值会被后续审查当作执行口径反复挑错 → 本版改为「只记方向」;(2) 每轮修完必须回读自己刚写的约束(部署顺序、闸顺序两处都曾自造矛盾);(3) 宣称「已核实」前必须 grep 全仓(admin 重置密码端点、第 4 个密码写点、cron 清扫计划都曾漏)。
