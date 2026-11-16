# iOS 3.2 拒审处理：改走 Unlisted（不公开上架）

> 触发：App Store 审核 3.2 - Business，`Rushes 素材库` v0.1.12 (17)
> 拒审理由原文核心：App 面向特定企业/组织，但选了公开分发。
> 本文给：判断依据 / 可粘贴的回复 / 操作顺序 / 备选方案。

---

## 1. 结论

**不要争「面向公众」。** 这个 App 客观上就是单机构内部工具，硬答公众会被二次驳回，
并且留下「元数据与实际不符」的坏记录。

正解：**申请 Unlisted（不公开上架）**——App 仍在 App Store 分发、可用链接安装，
但不出现在搜索、榜单、分类、推荐里。Apple 官方文档把
「合作伙伴销售工具、员工资源、研究项目」列为 unlisted 的典型适用场景。

- 官方说明：https://developer.apple.com/support/unlisted-app-distribution/
- 申请入口：https://developer.apple.com/contact/request/unlisted-app/

## 2. 事实核对（本仓库可证，回复里可以直接用）

| 苹果会问 | 事实 | 依据 |
| --- | --- | --- |
| 是否限单一组织 | 是。账号由管理员发放，App 内无注册入口 | `api/` 无 `register/signup` 端点；登录只有 `POST /api/v1/auth/local/login` |
| 是否面向有限组织 | 是。工作室自有 + 手工开通的合作方 | 部署形态：内网生产 + 公网反代，一套环境一个客户 |
| 有无公众功能 | 无。所有页面需登录，无公开内容区 | App 路由全部在登录态之后 |
| 账号怎么来 | 管理员在后台建号（`scripts/set_initial_admin.py` / 用户管理页） | 无自助注册 |
| 有无付费内容 | 无。无 IAP、无订阅、无站外付费解锁 | 无 StoreKit 依赖 |

> 填表/回复时**不要写内网 IP、账号密码、真实客户名到公开渠道**；账号密码只进 App Review Information。

## 3. Resolution Center 回复模板（英文，直接粘，方括号处替换）

```
Hello,

Thank you for the review. We have read Guideline 3.2 and agree that this app is not
intended for public distribution. We are switching this app to unlisted distribution and
have submitted an unlisted app distribution request. We have also added a note in the
Review Notes of our submission.

Answers to your questions:

1. Yes. The app is used only by employees of Huanhua Technology Co., Ltd.
   (浣花科技有限公司) and by contractors working on our projects. There is no sign-up
   inside the app; an account must be provisioned by our administrator.

2. The app is designed for a single organization only: Huanhua Technology Co., Ltd.
   It is not offered for sale, and no other company can sign up, become a client, or
   obtain an account in order to use the app.

3. None. Every screen requires an authenticated account. There is no public content
   section, no guest mode, and no feature usable without an account.

4. Accounts are created by our administrator in the app's user management console.
   Users cannot register themselves. A review account (username and password) is
   provided in the App Review Information section of our submission.

5. There is no paid content. The app is provided free of charge to authorized users.
   There are no in-app purchases, no subscriptions, and no payment required to open an
   account or to use any feature.

Optional paragraph — include only if users install the app on their own devices:

   Most of our users install the app on iPads they own themselves. These devices are
   not managed through Apple Business Manager or any MDM solution, which is why
   custom app distribution is not applicable in our case.

Please let us know if you need any further information.

Best regards,
[NAME]
```

要点：
- 五个问题**逐条编号回答**，不要写成一段散文。
- 第一句先认同苹果的判断（`we agree`），再给动作（`switching to unlisted`）——顺序反过来会被当成辩解。
- 账号密码只填 ASC 的「App 审核信息」两个字段（用户名 / 密码），**不写进本文档、不写进 commit**——本仓库公开。
- 若审核员回「单一机构请走自定义分发」，补一句：Apple unlisted 文档把
  `employee resources` 和「员工自有、不走 MDM 的设备」明确列为 unlisted 适用场景，
  我们的情况正是后者；仍不通过再转 ABM 自定义分发。

## 3.1 unlisted 申请表单：业务问题怎么答

表单字段原文：`Describe in detail the business problem your app solves and why unlisted
app distribution helps solve this problem. Please provide specific examples.`

### 业务问题

We operate a medical aesthetics studio. Each treatment produces a set of before/after
photos and, frequently, a short video. Our staff need those images at three moments:
during a consultation, when they show comparable past cases to the client in the chair;
right after a treatment, when the new set has to be filed under that client; and when
preparing material for the studio's own channels. Today that material lives in personal
phone albums, chat groups, and consumer cloud drives. In a consultation this means
minutes of scrolling to find one case; across staff it means duplicate and outdated
copies; and because these are clients' faces, every copy that leaves a controlled
library is a privacy exposure.

The app replaces that with a single permission-scoped library: projects, folders and
assets, preview for images, videos and Live Photos, tag search, batch download to the
device photo library, upload straight from the camera roll, an approval flow for access
requests, and an audit log. A consultant signs in on an iPad, opens the project for a
treatment area, opens the client's folder, and shows before/after side by side. A nurse
uploads the post-treatment set from the same device. Only staff granted access to that
project can see those images.

### 为什么 unlisted 解决这个问题

1. **受众本身就是封闭的。** 账号只能由我们的管理员创建，App 里没有注册入口。
   公开上架等于把一个只能看到登录页的 App 摆给所有人。
2. **内容是敏感影像。** 库里是可识别的客户面部与术前术后照片，我们不希望它出现在
   搜索、榜单、推荐里被无关用户发现和下载。
3. **设备是员工自有的 iPad / iPhone，不走 Apple Business Manager 或 MDM。**
   自定义分发不适合；TestFlight 也不能当日常工具——每个 build 90 天过期，
   会在季度中途打断门店使用。
4. **unlisted 保留了真正需要的部分**：一条能发给新员工的稳定安装链接、正常的
   App Store 更新、以及对公众不可见。苹果自己的文档把「员工资源」和
   「员工自有、无法纳管的设备」列为该模式的适用场景。

### 具体例子

- 咨询师面诊前搜索「鼻部 · 6 个月」，一分钟内在 iPad 上调出三个可比案例并排看，
  而不是翻手机相册。
- 治疗结束后护士当天把照片直接传进该客户的文件夹，打好标签，咨询师立刻可用；
  全程没有一份副本经聊天软件流出。
- 新员工拿到 unlisted 链接，像装普通 App 一样在 App Store 装好；账号管理员早已建好，
  不需要 IT 介入。

## 3.2 表单字段：为什么选 unlisted 而不是公开上架

字段原文：`Why do you prefer unlisted app distribution over public distribution on the
App Store?`

这题和 §3.1 的分工：§3.1 答「业务问题是什么」，这题只答**分发方式的选择理由**，
不要重复业务背景，重点放在「公开分发与这个受众不匹配」+「为什么不是别的分发方式」。

Because public distribution and this app's audience are a mismatch in both directions.

Public distribution is built for apps that anyone can discover, install and use. This
app cannot be used without an account created by our administrator: there is no
registration, no guest mode, and no public content. Listing it publicly would put an app
in front of users whose only possible experience is a login screen, which is misleading
to them and generates support requests we cannot serve.

At the same time we do need the distribution mechanics of the App Store: a stable link we
can send to a new hire, installs without Xcode or an MDM, and normal over-the-air
updates. Custom app distribution through Apple Business Manager requires the devices to be
managed, and ours are employee-owned iPads and iPhones. TestFlight expires every 90 days
and would interrupt daily clinical work. The Enterprise Program is not intended for this
kind of use. Unlisted is the only option that keeps the install and update path while
removing public discoverability.

There is also a privacy reason. The library holds identifiable client faces and
before/after photos. We have no interest in the app being ranked, recommended, or found
through search — the smaller its public footprint, the better. To be clear, we are not
asking to skip review: we expect the app to be reviewed in full, and we have provided a
review account and will supply any documentation you need.

## 3.3 表单字段：为什么不用 ABM/ASM 私有分发

字段原文：`Why do you prefer unlisted app distribution over private distribution to
specific organizations via Apple Business or Apple School Manager?`

关键点：ABM 的前提是**接收方组织纳管设备并按人分配许可**；我们的设备是员工自有的、
没有 MDM，正好是苹果文档里「不适合纳管」那一档。别写成「我们没注册 ABM」——
那听起来像嫌麻烦；要写成「ABM 的模型和我们的设备形态不匹配」。

Apple Business Manager and Apple School Manager distribution assumes an organization
that manages devices and assigns apps to its users. Our situation is the inverse: we own
no device fleet. Our staff use iPads and iPhones they bought themselves; those devices are
not enrolled in MDM, not supervised, and not assigned apps through Apple Business Manager.
To use custom distribution we would have to bring personal devices under a management
system, take on MDM administration, and assign a license per person — for an app whose
only job is to show our own photo library. That is disproportionate, and asking employees
to enroll a personal device in company management is not something we want to require for
this.

Operationally the same argument holds. Licenses have to be assigned, revoked and
reassigned as people join and leave, and part of our team works on specific projects for a
few months at a time. With unlisted distribution our administrator creates or disables an
account and sends a link; there is no second system to keep in sync.

What we actually need from distribution is what unlisted provides: install from a link,
no public discoverability, full App Review, and normal updates. Apple's documentation
names employee resources and employee-owned devices that are not eligible to be managed
through Apple Business or Apple School Manager as appropriate for unlisted distribution,
which is exactly our case. If we ever issue company-owned, managed devices, we would
revisit custom distribution at that point.

## 4. 操作顺序

1. **补审核可用性**（不做这步，unlisted 也会因 2.1 卡住）
   - App Review Information 填审核账号，提交前自己按这四条过一遍：
     - 从**公网入口**能登录（不是只有内网能登）；
     - 登录后能看到素材（空账号审核员会判「无内容」）；
     - `must_change_password = false`（否则审核员卡在改密页）；
     - 没被限流锁住（连续 5 次密码错误锁 15 分钟，提交前别试错）；
   - 用普通成员账号即可，系统管理员不是必须；
   - 确认审核员从公网能连上后端（App 冷启动探测顺序：`192.168.110.221` → `https://bucket.taoxiplan.com`，
     审核员只能走后者；见 `mobile-app-full-version-plan.md` §4）。
2. **Review Notes 写一句**：`This app is intended for unlisted distribution.`
3. **重新提交这个 build**（被拒的 build 不在审核中，unlisted 申请要求「已提交审核」）。
4. **提交 unlisted 申请**：https://developer.apple.com/contact/request/unlisted-app/
   表单要填：App 名称 / Apple ID / 是否已在 App Store / 目标受众说明 / 为什么需要 unlisted。
   受众说明可复用上面第 1–2 条的英文。
5. **Resolution Center 回复**：粘 §3 模板，说明已提申请。
6. 批准后：ASC →「价格与销售范围」的分发方式会变成 **Unlisted App**，
   生成一个直达链接，之后的版本沿用。

## 5. 备选方案（按成本排）

| 方案 | 适用 | 代价 |
| --- | --- | --- |
| **Unlisted（推荐）** | 单一机构、设备是员工自有/不统一管理 | 0 元；一次申请 + 一次重提；仍要过审核 |
| ABM 自定义分发 | 只用自家员工、设备统一 MDM 管理 | 客户组织需有 Apple Business Manager；每加一个组织手工配；要维护 MDM |
| TestFlight 外部测试（过渡） | 现在就要能装 | 每个 build 90 天过期，要持续重发；不是长期方案 |
| 补公众功能做成真公开 App | 打算对外卖 SaaS | 要自助注册 + 公众可用内容，产品改造量级 |

**不要走** Apple Developer Enterprise Program（企业计划）：只允许发给自家员工，外部合作方一用就违规，
且申请门槛（100+ 员工、D-U-N-S）比 unlisted 高得多。

## 6. 下一轮可能被挑的（顺手一起修）

- App 图标若仍是 Flutter 默认占位图 → 4.2 / 2.3 会被挑（`app-testflight-release-runbook.md` §4 已有记录）。
- 隐私政策 URL 必须可公网访问且内容对得上（App 会取相册/相机/定位）。
- 登录页若出现 `dev / prod / 自定义` 切换 UI → 审核员会当成内测入口（方案 v2.2 已删除，确认线上包一致）。
- 审核账号若 `must_change_password=true`，审核员会被强制改密卡住 → 给一个不需要改密的号。
