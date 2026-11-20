# qdev 需求文档:账号手机号自助绑定/换绑 + 短信找回密码(Web + App)

- 日期:2026-11-20
- qplan 正本:**`rushes-spec/material-storage/phone-bind-and-sms-password-reset-plan.md`**(13 轮盲审定稿,用户五项拍板)——接口契约/状态机步骤顺序/决策 D1-D18/测试功能点/实施钉子以该文档为**唯一权威依据**,本文档只做派发拆包与工程约束补充,两者冲突时以正本为准。
- worktree:`E:\qbb\github_not_me\rushes-lab-feat-phone-bind-sms-reset`,分支 `feat/phone-bind-sms-reset`(自 liuqi 62ad4cf 切出)。
- 可行性红线评估:可行,成本合理(零新依赖、迁移纯增量、复用既有审计/限流/脚本范式);qplan 阶段已确认,无不可行项。

## 1. 背景与目标

见正本 §0/§1(一句话:设置页绑定/换绑唯一手机号 + 登录页忘记密码=验证码通过后系统重置随机密码一次性展示账号+新密码 + 存量「username=手机号」自动绑定脚本)。

## 2. 功能点明细 / 接口定义 / 数据库修改方案 / 测试功能点 / 决策记录

全部见正本:功能点 §1.1(R1a-R4)、接口契约总表 §5.2(四端点,响应形状 `{"detail": "...", "retry_after": n}` 钉死)、迁移 0024 §4(显式 `op.create_unique_constraint`,勿用 unique=True 列定义/unique index)、决策 D1-D18 §3、测试功能点 §10。**派发与验收逐条对照正本,本文档不复制正文。**

## 3. 可复用资产盘点(直接复用,禁止重写)

| 资产 | 位置 | 用途 |
| --- | --- | --- |
| 阿里云短信实测签名代码 | 全局技能 `C:\Users\Administrator\.agents\skills\aliyun-sms-integration\scripts\sms_api.py` | B1 逐行对照移植,**不凭记忆重写** |
| 临时密码三类保底思路 | `app/services/passwords.py::generate_temp_password` | B2 reset 临时密码生成参照 |
| 登录限流 Redis 计数范式(含 PTTL 上取整) | `app/services/local_auth.py` | B2 冷却/配额实现参照 |
| audit.write(keyword-only,自带 commit) | `app/services/audit.py` | B2 五事件写入;需 auth_method 哨兵小改造 |
| 容器级路由测试范式 | `tests/test_local_auth_integration.py` | B2 两套 API 测试范式(无 DB 自动 skip) |
| FakeRedis 范式 | `tests/test_local_auth.py` | B2 扩建命令面(SET NX EX/HSET/HINCRBY/PTTL/eval 回调) |
| 脚本安全范式(dry-run 默认/--apply/--yes) | `api/scripts/backfill_thumbnails.py`、`api/scripts/set_password.py` | B5 批量绑定脚本 |
| react-query hooks 范式 | `web/src/api/hooks.ts::useChangePassword` | B3 四个新 hook |
| GrantCountdown(Timer.periodic 倒计时) | `app/lib/**`(搜索 GrantCountdown) | B4 验证码倒计时按钮实现参照 |
| api_harness fake dio 测试范式 | `app/test/` | B4 auth_api 契约测试 |
| 登录页品牌壳+表单+固定错误区范式 | `app/lib/features/auth/login_page.dart` | B4 忘记密码页 |

## 4. 组件拆分方案(工作包与文件清单)

派发顺序:**Round1 = B1 ∥ B3 ∥ B4**(前后端按 §5.2 契约并行,无文件交集)→ **Round2 = B2**(依赖 B1 代码)→ **Round3 = B5**(依赖 B1+B2)。子智能体一律不 commit;新文件单文件 ≤500 行;只 format 自己的文件;本地 docker 禁跑(容器级测试只写不跑,代码保证无 DB 自动 skip)。

### B1 后端基建(独立可合,端点未上无行为变化)

| 文件 | 动作 | 预估 |
| --- | --- | --- |
| `material-storage/api/app/settings.py` | 追加 §5.8 配置组(aliyun_sms_* + sms_* + `aliyun_sms_enabled` property) | +30 |
| `material-storage/api/app/services/aliyun_sms.py` | 新建:AliyunSmsService(httpx.AsyncClient 挂实例,timeout 5s,无重试);V3 ACS3-HMAC-SHA256 签名逐行移植技能脚本;`send(phone, template_code, code) -> BizId`;`SmsSendError(code,message)`/`SmsTransportError` 两类(D9);结构化日志不落 AK/SK/明文码;`aclose()` | ~220 新 |
| `material-storage/api/app/db/migrations/versions/2026_11_20_0024_user_phone.py` | 新建:revision=`20261120_0024`,down_revision=`20261119_0023`;upgrade=add_column(phone String(20) nullable)+**显式 create_unique_constraint("uq_users_phone")**;downgrade=drop_constraint(type_="unique")+drop_column(勿 drop_index) | ~30 新 |
| `material-storage/api/app/db/tables.py` | User.phone 列 + `__table_args__` 补 UniqueConstraint(name="uq_users_phone") | +5 |
| `material-storage/api/app/routers/auth.py` | `/auth/me` 回传 phone(响应模型+查询补列;其余端点不动) | +5 |
| `material-storage/api/app/main.py` | lifespan:`app.state.sms = AliyunSmsService(settings) if settings.aliyun_sms_enabled else None`;shutdown 时 None 守卫 aclose | +8 |
| `material-storage/api/tests/test_db_schema.py` | uq_users_phone 断言并入既有 contype='u' 段(unique constraint 非 index) | +10 |
| `material-storage/api/tests/test_aliyun_sms.py` | 新建纯单元:canonical query RFC3986 排序/头构造/TemplateParam JSON 串/签名字符串;两类异常分类(fake transport,零真实网络) | ~150 新 |

### B2 后端端点(依赖 B1;含 main.py 挂载与审计标签四处)

| 文件 | 动作 | 预估 |
| --- | --- | --- |
| `material-storage/api/app/services/phone_verification.py` | 新建:码生成(首位字母子集+全表去混淆,D3)/HMAC 存取(HKDF from session_jwt_secret,info=b"sms-code")/原子消费 Lua/尝试计数 Lua(单脚本 EXISTS+HINCRBY+条件 EXPIRE)/三层频控/冷却/日界 UTC+8 固定偏移;`normalize_phone`(D5,与 B5 脚本共用规格);`mask_phone`(前3+****+后4) | ~300 新 |
| `material-storage/api/app/routers/account_security.py` | 新建:登录态两端点(/account/phone/send-code、/account/phone/bind),require_session_auth(PAT 403),步骤顺序钉死正本 §5.3 | ~200 新 |
| `material-storage/api/app/routers/password_reset.py` | 新建:公开两端点(/auth/phone/reset/send-code、/auth/phone/reset/confirm),步骤顺序钉死正本 §5.4;confirm 响应 Cache-Control: no-store | ~230 新 |
| `material-storage/api/app/services/audit.py` | write() auth_method 哨兵改造(_UNSET 默认,None=显式落 NULL) | +10 |
| `material-storage/api/app/main.py` | 挂载两新 router | +4 |
| `material-storage/api/app/services/tokens.py` | 模块 docstring 写点清单 5→6(钉子 13) | +2 |
| `web/src/lib/labels.ts` + `web/src/pages/AdminAuditPage.tsx`(EVENT_TYPES+DETAIL_KEY_LABEL+计数基线注释)+ `app/lib/**/audit_labels.dart` | 新 5 事件+新 details 键,四处同步,**计数按当时代码实数** | +30 |
| `material-storage/api/tests/conftest.py` 或既有 fake redis 模块 | FakeRedis 命令面扩建(SET NX EX/HSET/HGET/HINCRBY/PTTL/条件 EXPIRE/eval 按回调分派) | ~120 |
| `material-storage/api/tests/test_phone_verification.py` | 新建纯单元(FakeRedis 注入):字符集/1000 采样无纯数字/HMAC 循环/5 次作废/三层配额边界/TTL 不续期 | ~180 新 |
| `material-storage/api/tests/test_phone_bind_api.py` | 新建容器级(照 test_local_auth_integration.py,FakeSms 替换 app.state.sms,无 DB 自动 skip):正本 §10.1 全条目含 D9 失败统一语义断言 | ~300 新 |
| `material-storage/api/tests/test_phone_reset_api.py` | 新建容器级:正本 §10.1 全条目(枚举/配额/原子消费/归属复核/首登强制改密/PAT 吊销) | ~300 新 |

### B3 Web(依赖 §5.2 契约,不依赖 B2 代码)

| 文件 | 动作 | 预估 |
| --- | --- | --- |
| `web/src/api/types.ts` | Me 加 `phone?: string \| null` | +2 |
| `web/src/api/hooks.ts` | useSendPhoneCode/useBindPhone/useResetSendCode/useResetConfirm(照 useChangePassword;send-code 按 200 判定) | +60 |
| `web/src/lib/phone.ts` | 新建:D5 前端同款归一化+格式校验工具(两页共用) | ~30 新 |
| `web/src/components/SendCodeButton.tsx` | 新建:可复用倒计时按钮(useCountdown 内聚;对外 start(seconds)/reset;请求与错误文案由页面层处理,页面拿到 retry_after 后调 start) | ~90 新 |
| `web/src/pages/ForgotPasswordPage.tsx` | 新建:三态页(正本 §6.2;结果态账号+密码 copyable、仅 name 提示钉死文案) | ~260 新 |
| `web/src/pages/LoginPage.tsx` | 密码框下右侧「忘记密码?」link 按钮 | +6 |
| `web/src/pages/SettingsPage.tsx` | 「账号与安全」区块(「偏好」之上):完整手机号/未绑定 Tag + Modal 表单(归一化+验证码+SendCodeButton;成功 invalidateQueries(['me'])) | +120 |
| `web/src/App.tsx` | lazy 路由 /forgot-password + onAuthPage 判定 | +4 |
| `web/src/api/client.ts` | 401 豁免名单加 /forgot-password | +1 |

### B4 App(依赖 §5.2 契约,可与 B3 并行)

| 文件 | 动作 | 预估 |
| --- | --- | --- |
| `app/lib/core/api/auth_api.dart` | 四端点(文件头契约注释同步;statusCode!=200 判错惯例;retry_after 经 ApiException.raw 读) | +50 |
| `app/lib/models/me.dart` | phone 解析(可空) | +4 |
| `app/lib/core/session.dart` | 抽公共 `refreshMe()`(**保留失败→日志+_meStale=true 兜底分支**,changePassword 改委托) | +25 |
| `app/lib/features/me/me_page.dart` | 账号与安全组「修改密码」上方加手机号行(subtitle `me.phone ?? '未绑定'`) | +10 |
| `app/lib/components/code_send_button.dart` | 新建:可复用发送验证码按钮(Timer.periodic 倒计时,retry_after 初值,禁用态;GrantCountdown 仅参照) | ~90 新 |
| `app/lib/features/me/account_phone_page.dart` | 新建:当前绑定展示+绑定/换绑表单+提交(refreshMe+pop);超 500 拆 sheets | ~300 新 |
| `app/lib/features/auth/forgot_password_page.dart` | 新建:三态页(登录页品牌壳范式;结果态复制+钉死提示文案) | ~300 新 |
| `app/lib/features/auth/login_form.dart` | 密码框与登录按钮之间右对齐「忘记密码?」 | +6 |
| `app/lib/app.dart` | 路由表加 /forgot-password、/account-phone | +8 |
| `app/test/*.dart` | 新建 widget/单测(§7.4:入口存在与跳转/三态流转/错误区/倒计时状态机注 clock/auth_api 四端点契约 fake dio/me.phone 解析) | ~400 新 |

### B5 脚本与运维(依赖 B1+B2;合并不早于 B2)

| 文件 | 动作 | 预估 |
| --- | --- | --- |
| `material-storage/api/scripts/bind_user_phones.py` | 新建(正本 §9.4:默认 dry-run/--apply/--csv/--yes;username 归一化扫描;冲突名单跳过;--csv 二跑对占用冲突拒绝;逐条审计 phone_bound actor="cli" source="backfill";独立 session) | ~280 新 |
| `material-storage/api/tests/test_bind_user_phones.py` | 新建(SQLite+桩,照 test_backfill_script.py:归一化折叠冲突/已有 phone 跳过/占用进冲突名单/--csv 双给/--csv 二跑拒绝/幂等/审计脱敏/dry-run 不写库) | ~220 新 |
| `material-storage/api/.env.example` + `.env.production.example` | 补 aliyun_sms 配置段注释(必填项+force-recreate 提示) | +15 |
| `rushes-spec/material-storage/ops-manual.md` | 新增「手机号与短信找回」节(配置/上线顺序/回滚/QuerySendDetails 排障/脚本手册/BUSINESS_LIMIT_CONTROL 释义) | +60 |
| `scripts/changelog.md` | 按仓库约定记账(合并时补 commit hash) | +6 |

## 5. 前端改动点 / 后端改动点

见 §4 各包文件清单;行为细节一律以正本 §5/§6/§7 为准。

## 6. 模糊点与决策记录

qplan 13 轮盲审+用户拍板已收口,无开放模糊点。关键拍板(详据见正本 §3):D1 绑定/换绑只凭短信验证码(用户拍板,接受会话劫持接管链残余风险);D2 重置=系统随机密码一次性展示+`must_change_password=true` 首登强制再改(用户拍板);D15 dev/prod 同一套真实凭证;D17 短信未配置四端点 503+前端入口常驻不隐藏。实施期如遇正本未覆盖的新模糊点,PM 按最通用最合理原则拍板并记录于验收报告。

## 7. 验证命令(各包自测与 PM 复跑)

- 后端:`cd material-storage/api && uv run ruff check app tests && uv run mypy app && uv run pytest tests/test_<相应文件> -q`(本地 .venv 已建;容器级测试无 DB 自动 skip 属预期,只验不红)
- Web:`cd material-storage/web && pnpm lint && pnpm build`(node_modules 已 junction 至主仓,勿 npm install;产物 gitignored)
- App:`cd material-storage/app && flutter pub get && flutter analyze && flutter test`(SDK `/e/qbb/soft/flutter`;镜像变量 `PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 按需)
- 迁移单头:`uv run alembic heads`(本地起不来则容器阶段复核,不阻塞)
