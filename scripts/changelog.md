# 更新日志

> 以天为单位记一节,二级标题为日期(`## YYYY-MM-DD`),最新的天在最前;每天内用列表记每一项更新,一句话说清 + commit hash 可溯。

## 2026-08-31

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
