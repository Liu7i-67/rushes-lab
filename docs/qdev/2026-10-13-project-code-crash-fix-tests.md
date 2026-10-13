# 测试用例:新建项目编码前端拦截失效 + 422 数组 detail 白屏 修复

- 日期:2026-10-13
- 需求依据:[2026-10-13-project-code-crash-fix.md](./2026-10-13-project-code-crash-fix.md)(§1 根因链路、§4 修复方案为唯一实施依据;§5 六条验收用例已细化为本文 TC-01~TC-13 等)
- 分支/工作区:`fix/project-code-crash`(worktree `E:\qbb\github_not_me\rushes-lab-fix-project-code-crash`)
- 说明:前端无测试框架,本文档全部为**人工/浏览器操作用例**,不含可执行代码。「控制台」指浏览器 DevTools Console。本 bug 的原始失败形态是 React error #31 整树白屏,因此**每条用例的通用硬性观测点:Console 无 `Minified React error #31`、页面不白屏**;标注「不发请求」的用例还须观测 Network 无新增 `POST /api/v1/projects`。

## 0. 执行说明

| 项 | 说明 |
| --- | --- |
| 执行环境 | dev `http://47.108.196.211:8080`(部署修复后构建)。部署后先核对 bundle 指纹 `index-*.js` **≠** `index-C8lv4fpD.js`(deploy-hh2 坑 C:指纹没变 = 没发上,直接停测)。本地验证等价路径:`pnpm --dir web build` + `docker compose up -d` 本地全栈 |
| 账号 | evan(契约 seed 账号,org admin,`is_project_creator=true`),密码向 PM 索取。管理后台用例(TC-19/20)同账号。TC-18 为纯前端校验**不发请求、不会真的改密**,可安全执行;**禁止在共享账号上跑改密成功路径** |
| DevTools 观测 | ① Console:看 `React error #31` / 任何 TypeError(本修复的失败信号);② Network 面板:过滤 `projects`,每个「不发请求」用例提交前先清一次记录,提交后确认无新增 XHR;③ 字段级错误提示 = 字段下方红色文本(antd Form.Item error 区) |
| 通用前置 | 已登录;弹窗从首页「新建项目」打开;除被测字段外其余字段一律合法:名称填 `用例-TCxx`(与用例号对应)、MinIO bucket 默认 `ms-dev`、项目管理员保持默认(自己) |
| 通用通过标准 | 预期结果全满足 + 通用硬性观测点无违反。字段错误提示文案以本文为准;toast 文案若与 Pydantic 英文 msg 措辞有细微差异,以「纯字符串、可读、非 `[object Object]`、不白屏」为通过线 |

功能点编号:F1 = 修复 1(NewProjectModal 编码 rules 三条拆分);F2 = 修复 2(errorMessage 兼容数组型 detail,恒返回 string);R = 回归(既有表单与全局行为不变)。

需求文档 §5 → 本文用例映射:§5#1→TC-01;§5#2→TC-02;§5#3→TC-03;§5#4→TC-05;§5#5→TC-12(errorMessage 四分支细分 TC-14~16);§5#6→TC-13/TC-19。

---

## 1. F1 项目编码前端校验(11 条)

> 行为基线(已对照 `@rc-component/form@1.8.1` / `@rc-component/async-validator@5.1.0` 源码核实):拆分后三条 rule 全部执行;某值同时命中多条 rule 时,**错误提示按 rule 声明顺序全部堆叠显示**(required → 长度 → pattern)。校验先于 `v.code.trim()` 执行,含空格的编码在校验层即被拦,trim 不会生效。

**TC-01|编码填 `1` 被前端拦截,只出长度提示|P0**
- 对应功能点:F1(= 需求 §5 验收 1,原始线上事故场景)
- 优先级:P0
- 前置条件:通用前置;dev 已部署修复后构建(指纹已变)。
- 操作步骤:
  1. 打开新建项目弹窗,Network 过滤清空;
  2. 编码填 `1`,其余字段合法;
  3. 点「创建」。
- 预期结果(观测点):
  1. **不发请求**(Network 无新增 `POST /api/v1/projects`);
  2. 编码字段下方出现红色提示「**长度 2-64 个字符**」且**仅此一条**(`1` 匹配 pattern,故无 pattern 文案——修复前该场景直接放行发请求);
  3. Console 无 error #31,弹窗不关闭。

**TC-02|大写 `A` 被拦,长度与 pattern 两条提示堆叠|P1**
- 对应功能点:F1(= 需求 §5 验收 2)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:编码填 `A`,点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 编码字段下**两条提示堆叠**:「长度 2-64 个字符」在上(rule 顺序)、「**小写字母/数字/-,以字母数字开头**」在下。注意:§5 只要求 pattern 文案出现,拆分后长度文案同屏属**预期行为**,不是 bug;
  3. Console 无 error #31。

**TC-03|编码为空被 required 拦截,只出 required 文案|P0**
- 对应功能点:F1(= 需求 §5 验收 3)
- 优先级:P0
- 前置条件:同 TC-01。
- 操作步骤:编码留空,其余字段合法,点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 编码字段下提示「**请输入项目编码**」且仅此一条(修复前空值会误显示 pattern 文案);
  3. Console 无 error #31。

**TC-04|全角数字 `１` 被拦,长度提示先出|P1**
- 对应功能点:F1(长度与 pattern 双重命中的边界形态)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:编码粘贴全角数字 `１`(U+FF11,注意不是半角 `1`),点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 两条提示堆叠,顺序为:「长度 2-64 个字符」**先**(长度 rule 在声明序靠前)、pattern 文案在后;
  3. Console 无 error #31。

**TC-05|合法 2 位编码创建成功|P0**
- 对应功能点:F1 + R(= 需求 §5 验收 4)
- 优先级:P0
- 前置条件:同 TC-01。
- 操作步骤:名称 `用例-TC05`,编码 `11`,点「创建」。
- 预期结果:
  1. 请求发出且返回 2xx(Network 可见 `POST /api/v1/projects` 200);
  2. 绿色 toast「项目 "用例-TC05" 已创建」;
  3. 弹窗关闭,项目列表出现新项目;Console 无错误。

**TC-06|长度上边界 64 位合法编码创建成功|P1**
- 对应功能点:F1(max 边界)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:控制台执行 `"a".repeat(64)` 并复制结果,粘贴到编码框(64 个小写 a),点「创建」。
- 预期结果:校验通过,请求发出,创建成功(同 TC-05 形态,toast 项目名为「用例-TC06」);无任何字段错误。

**TC-07|长度 65 被拦,只出长度提示|P1**
- 对应功能点:F1(max 越界)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:粘贴 `"a".repeat(65)`(65 个小写 a,注意粘贴框可能截断,以输入框实际长度为准),点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 编码字段下提示「长度 2-64 个字符」且仅此一条(65 位全小写字母通过 pattern,无 pattern 文案);
  3. Console 无 error #31。

**TC-08|`-` 开头编码被 pattern 拦截|P1**
- 对应功能点:F1(pattern 首字符约束)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:编码填 `-abc`(长度合法),点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 编码字段下提示「小写字母/数字/-,以字母数字开头」且仅此一条(长度合法故无长度文案);
  3. Console 无 error #31。

**TC-09|纯 `-` 单字符被双重命中|P2**
- 对应功能点:F1(长度 + pattern 同时失败的最短输入)
- 优先级:P2
- 前置条件:同 TC-01。
- 操作步骤:编码填单个 `-`,点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 两条提示堆叠:「长度 2-64 个字符」在上、pattern 文案在下(与 TC-04 同序);
  3. Console 无 error #31。

**TC-10|首尾空格提交被 pattern 拦截,trim 不触发请求|P1**
- 对应功能点:F1 + 提交链路顺序(校验先于 `v.code.trim()`)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:编码粘贴 ` ab1 `(首尾各一个半角空格),点「创建」。
- 预期结果:
  1. **不发请求**(空格不过 pattern,`validateFields` 先 reject,`v.code.trim()` 不可达——不存在「trim 后变成合法值悄悄发出请求」的路径);
  2. 编码字段下提示 pattern 文案「小写字母/数字/-,以字母数字开头」;
  3. Console 无 error #31。

**TC-11|空名称 + 非法编码同时出错,滚动定位到第一个出错字段|P1**
- 对应功能点:F1 + scrollToField(`submit` catch 中 `form.scrollToField(err.errorFields[0].name)`)
- 优先级:P1
- 前置条件:同 TC-01;浏览器窗口高度使弹窗内容出现滚动(或至少两字段错误提示同时可见可判)。
- 操作步骤:名称留空,编码填 `1`,点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 两个字段**各自**出现错误:名称字段「请输入项目名称」(antd v6 zh_CN 默认模板,2026-10-13 实测修订;旧版模板为「'项目名称'为必填项」,勿按旧文案判失败),编码字段「长度 2-64 个字符」;
  3. 弹窗滚动定位到**项目名称**字段(errorFields[0] 按 Form.Item 注册序,名称先于编码),不出现「只滚到编码」或页面抖动/报错;
  4. Console 无 error #31。

## 2. F2 errorMessage 四分支(5 条)

> 原则:errorMessage 返回值恒为 string。任一分支的失败形态都是 toast 渲染对象/数组 → React error #31 → 白屏,故每条都重点观测 toast 文案形态与 Console。

**TC-12|数组型 detail:422 显示后端校验 msg,不白屏|P0**
- 对应功能点:F2(= 需求 §5 验收 5,本次白屏事故的核心场景;四个分支中优先级最高)
- 优先级:P0
- 前置条件:同 TC-01。触发方法三选一,A 无需任何 hack,推荐。
- 操作步骤:
  - **方法 A(推荐,纯 UI)**:名称粘贴**两个半角空格** `  `(antd required 对纯空格放行),编码填合法值 `demo-a`,点「创建」。提交时 `v.name.trim()` 变空串 → 后端 Pydantic 422(name min_length=1)→ 数组 detail 走真实 UI 链路(axios → errorMessage → toast);
  - **方法 B(后端契约独立复核,不产生 toast)**:控制台执行
    `fetch('/api/v1/projects',{method:'POST',headers:{'Content-Type':'application/json'},credentials:'include',body:JSON.stringify({code:'1',name:'replay',organization_id:'',minio_bucket:'ms-dev',admin_user_id:'x'})}).then(r=>{console.log(r.status);return r.json()}).then(console.log)`
    → 观察返回 422 且 `detail` 为对象数组、含 `String should have at least 2 characters`;
  - **方法 C(需求 §5 原意,需临时改代码)**:本地把修复 1 的 rules 暂时回退为单条混写(**不提交 commit**),build 后 UI 提交编码 `1`。
- 预期结果:
  1. 方法 A:请求发出、返回 422;弹出**纯字符串** toast,内容为后端 msg(如 `String should have at least 1 character`);**不白屏、Console 无 error #31**;
  2. 方法 B:HTTP 422 + 数组 detail(证明后端兜底未动,契约不变);
  3. 方法 C:toast 含 `String should have at least 2 characters`,不白屏;
  4. 通过线:toast 为纯文本可读(各条 msg 以 `; ` 拼接),绝不能出现 `[object Object]` 或白屏。

**TC-13|string 型 detail:409 文案原样显示,无回归|P0**
- 对应功能点:F2(detail 为 string 分支;= 需求 §5 验收 6 的项目表单变体)
- 优先级:P0
- 前置条件:已存在一个项目编码(用 TC-05 建的 `11` 或任意已有项目,记下其编码)。
- 操作步骤:
  1. 打开新建项目弹窗,名称填 `用例-TC13`,编码填**已存在的编码**,点「创建」。
- 预期结果:
  1. 请求发出、返回 **409**;toast 显示 detail 原文「**项目 code 已存在**」;
  2. 不白屏、无 error #31(detail 是 string,走第一分支,行为与修复前一致);
  3. 弹窗不关闭,可改编码后重新提交。

**TC-14|无 response:网络层失败显示 err.message,不白屏|P1**
- 对应功能点:F2(detail 缺失且无 response → `err.message` 兜底分支)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:
  1. DevTools → Network 面板 → 右键任意一条 `POST /api/v1/projects` 历史 → **Block request URL**;
  2. 关闭重开弹窗,填全部合法值,点「创建」;
  3. 观察后取消 Block。
- 预期结果:
  1. 请求显示被 block(Network 红色,无 status)→ toast 显示「**Network Error**」(axios err.message);
  2. **不白屏、无 error #31**;弹窗不关闭;
  3. 解除 block 后重新提交可正常创建。

**TC-15|HTTP 状态码兜底:有 status 无 detail 显示 `xx(HTTP nnn)`|P1**
- 对应功能点:F2(detail 缺失但有 response → `${fallback}(HTTP ${status})` 分支;生产等价场景 = 反代 502/504 HTML 错误页)
- 优先级:P1
- 前置条件:同 TC-01。此分支 UI 无天然触发路径,用控制台 XHR mock 构造(进阶方法)。
- 操作步骤:
  1. 控制台执行以下 patch(拦下创建请求,伪造 status 502 + HTML body):
     ```js
     (() => {
       const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
       XMLHttpRequest.prototype.open = function (m, u, ...r) { this.__u = String(u); return open.call(this, m, u, ...r); };
       XMLHttpRequest.prototype.send = function () {
         if (this.__u && this.__u.includes('/api/v1/projects')) {
           const x = this;
           setTimeout(() => {
             Object.defineProperty(x, 'readyState', { value: 4, configurable: true });
             Object.defineProperty(x, 'status', { value: 502, configurable: true });
             Object.defineProperty(x, 'responseText', { value: '<html>502 Bad Gateway</html>', configurable: true });
             x.dispatchEvent(new Event('readystatechange'));
             x.dispatchEvent(new ProgressEvent('load'));
           }, 100);
           return;
         }
         return send.apply(this, arguments);
       };
       console.warn('mock on; 测完 location.reload() 恢复');
     })();
     ```
  2. 填全部合法值,点「创建」;
  3. 测完 `location.reload()` 恢复。
- 预期结果:
  1. 请求被 mock 截获 → toast 显示「**创建失败(HTTP 502)**」(fallback=「创建失败」由调用点传入);
  2. **不白屏、无 error #31**;
  3. 兼容性备注:若 axios 版本行为差异导致 mock 不生效,记录实际现象,以 toast 恒为字符串、不白屏为通过线,并回退用 TC-14 覆盖的 no-response 分支佐证。

**TC-16|非 axios 错误:走 fallback 原文,恒 string|P2**
- 对应功能点:F2(最后一道 fallback:非 axios 错误 → 返回调用方 fallback)
- 优先级:P2
- 前置条件:同 TC-01。真实 UI 中进入 errorMessage 的几乎都是 axios 错误,此分支为纯防御,用控制台构造。
- 操作步骤:
  1. 控制台执行 `const __origOpen = XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open = function () { throw new TypeError('non-axios boom'); };`
  2. 填全部合法值,点「创建」;
  3. 测完刷新页面恢复。
- 预期结果:
  1. toast 显示「**创建失败**」(fallback 原文,非 TypeError 文案、非 [object Object]);
  2. **不白屏、无 error #31**(Console 允许出现被浏览器记录的 TypeError,不算失败);
  3. 刷新后功能恢复正常。

## 3. R 回归(6 条)

**TC-17|正常业务路径全流程 + 弹窗关闭重开表单重置|P1**
- 对应功能点:R(创建成功主路径 + open 翻转重置,需求文档回归重点)
- 优先级:P1
- 前置条件:同 TC-01。
- 操作步骤:
  1. 打开弹窗,名称填 `用例-TC17`,编码填 `regress-demo`,再随手在描述里填些文字;
  2. **不提交**,点取消/X 关闭弹窗;
  3. 重新打开弹窗;
  4. 再次填合法值(名称 `用例-TC17`,编码 `regress-demo`)提交。
- 预期结果:
  1. 步骤 3 重开后:所有字段为空、bucket 回到 `ms-dev`、项目管理员回到「自己」、**无残留错误提示**(resetFields + destroyOnClose);
  2. 步骤 4 创建成功:toast + 弹窗关闭 + 列表新增(与 TC-05 同形态);
  3. 全程 Console 无错误、无白屏。

**TC-18|修改密码弱密码:纯前端提示,不发请求|P1**
- 对应功能点:R(其他表单正常报错场景,需求 §5「回归重点」指定场景)
- 优先级:P1
- 前置条件:已登录 evan;**安全性:此用例被前端拦下,不会真的改密**。
- 操作步骤:
  1. 右上角用户菜单 → 「修改密码」;
  2. 原密码填任意非空值,新密码填 `123456`(纯数字弱密码),确认密码同;
  3. Network 清空后点「设置密码/确认修改」。
- 预期结果:
  1. **不发请求**(Network 无 `POST .../change-password`);
  2. 新密码字段下提示「**至少 8 位,且同时包含字母和数字**」(该页 rules 本就拆分正确,文案不变);
  3. 不白屏、无 error #31。

**TC-19|管理后台建用户重名:409 string detail 原文显示|P1**
- 对应功能点:R(= 需求 §5 验收 6;errorMessage 全局调用点抽测)
- 优先级:P1
- 前置条件:evan(org admin)登录。
- 操作步骤:
  1. 管理后台 → 用户 → 「新建本地用户」:登录名 `tcuser01`、姓名 `回归-TC19`,创建(成功,留作后续重名素材,dev 环境可接受);
  2. 再次新建:登录名仍填 `tcuser01`,姓名任意,提交。
- 预期结果:
  1. 步骤 2 请求发出、返回 **409**;toast 显示 detail 原文「**登录名已存在:tcuser01**」;
  2. 不白屏、无 error #31;弹窗不关闭。

**TC-20|管理后台建用户非法登录名:前端 pattern 拦截不受影响|P2**
- 对应功能点:R(AdminUsersPage 的拆分写法是本次修复的参照范本,确认未被误改)
- 优先级:P2
- 前置条件:同 TC-21。
- 操作步骤:新建用户弹窗,登录名填 `张三!`(含中文与 `!`),点「创建」。
- 预期结果:
  1. **不发请求**;
  2. 登录名字段下提示「**仅字母/数字/._- 组成**」;
  3. 不白屏、无 error #31。

**TC-21|401 会话失效:登录重定向行为不变|P1**
- 对应功能点:R(修复 2 所在 `client.ts` 同文件还承载 401 拦截器,确认未被误伤)
- 优先级:P1
- 前置条件:已登录 evan,处于项目列表页。
- 操作步骤:
  1. DevTools → Application → Cookies → 删除 `ms_session`;
  2. 回到页面触发任一请求(如切换页面、或打开新建项目弹窗——弹窗打开会拉用户/模板列表);
  3. 观察跳转与 URL。
- 预期结果:
  1. 整页跳转到 `/ms-static/web/login?next=<原路径编码>`(next 带回原地址);
  2. 是**正常跳转**而非白屏/报错;重新登录后回到原页面。

**TC-22|403 无权限文案不回归(可选)|P2**
- 对应功能点:R(需求 §5「回归重点:抽测 401/403/409」;403 需低权限账号,标记可选)
- 优先级:P2
- 前置条件:备有一个无该项目权限的普通账号(如契约 outsider 账号);无法准备则本条跳过并记录。
- 操作步骤:用普通账号直接访问其无权限的项目详情 URL。
- 预期结果:toast 显示后端 403 detail **字符串原文**(与修复前一致);不白屏、无 error #31。

---

## 4. 执行顺序建议与统计

建议顺序:TC-05(先建素材)→ TC-17(重置行为)→ TC-01~04、06~11(校验组,互不依赖可连续跑)→ TC-13 → TC-12 → TC-14/15/16(需 DevTools hack 的放最后)→ TC-18/19/20/21/22(跨页面回归)。

| 分组 | 用例 | 数量 | P0 | P1 | P2 |
| --- | --- | --- | --- | --- | --- |
| F1 编码校验 | TC-01~TC-11 | 11 | 3(TC-01/03/05) | 7(TC-02/04/06/07/08/10/11) | 1(TC-09) |
| F2 errorMessage | TC-12~TC-16 | 5 | 2(TC-12/13) | 2(TC-14/15) | 1(TC-16) |
| R 回归 | TC-17~TC-22 | 6 | 0 | 4(TC-17/18/19/21) | 2(TC-20/22) |
| **合计** | | **22** | **5** | **13** | **4** |
