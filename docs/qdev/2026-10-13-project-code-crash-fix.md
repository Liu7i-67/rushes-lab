# 修复方案:新建项目编码填 "1" 未被前端拦截 → 422 → 整页白屏

- 日期:2026-10-13
- 状态:**qdev 实施中**(本文档即本轮 qdev 需求文档,§4 为唯一实施依据)
- 调研结论来源:dev 环境真机复现(浏览器自动化,证据截图+Console 捕获)+ 前端依赖源码级定位
- 涉及环境:dev / prod 已部署的 `index-C8lv4fpD.js` 与本地构建指纹一致,**两环境都带此雷**
- 分支/worktree:`fix/project-code-crash`(`E:\qbb\github_not_me\rushes-lab-fix-project-code-crash`,基于 liuqi 6bc9142)

---

## 1. 现象与复现

新建项目弹窗,「项目编码」填 `1`(名称等其余字段合法),点「创建」:

1. **前端表单校验直接放行**,没有出现任何字段级错误提示;
2. axios 发出 `POST /api/v1/projects`(body 含 `code: "1"`);
3. 后端 Pydantic 拒绝,返回 **422**,响应体 `detail` 是**对象数组**:
   ```json
   {"detail":[{"type":"string_too_short","loc":["body","code"],
     "msg":"String should have at least 2 characters","input":"1",
     "ctx":{"min_length":2}}]}
   ```
4. 页面**整树白屏**(DevTools Console 两次 `Minified React error #31`,参数明示
   `object with keys {type, loc, msg, input, ctx}` —— 与 422 响应体逐字段吻合);
   全局 ErrorBoundary 未兜住;刷新后恢复。

真机复现记录(dev,`http://47.108.196.211:8080`,evan 账号):填名称 + 编码 `1` → 点创建 →
捕获 error #31 ×2 → DOM 快照为空 → 截图白屏;`performance` 资源记录含打到 `/api/v1/projects`
的 XHR;事后重放同 body 得 422 及上述响应体。

## 2. 根因(两层叠加,缺一不会白屏)

### 2.1 雷点 ①:前端 `min: 2` 校验从未生效(为什么没拦截)

`NewProjectModal.tsx` 项目编码字段的规则是**一条 rule 混写** required + min + max + pattern:

```tsx
// material-storage/web/src/components/NewProjectModal.tsx:260-265(现状)
<Form.Item name="code" label="项目编码(URL slug,小写字母/数字/-)"
           rules={[{
             required: true, min: 2, max: 64,
             pattern: /^[a-z0-9][a-z0-9-]*$/,
             message: '小写字母/数字/-,以字母数字开头',
           }]}
```

antd v6(本仓 `antd@^6.4.2`)的表单校验器是 `@rc-component/async-validator@5.1.0`,其规则
分发机制:一条 rule 里只要存在 `pattern`(RegExp),`getType` 会把**整条 rule** 标记为
`type='pattern'`(见 `async-validator/es/index.js:255`),校验方法随之路由到
`validators/pattern` —— 而该校验器**只执行 required + 正则两项**(`es/validator/pattern.js`),
`min`/`max`(range 校验)根本不会运行。

因此 `min: 2` 从上线第一天起就是摆设:`1` 非空(过 required)+ 匹配正则(过 pattern)
→ 校验通过 → 放行发请求。**读代码时"同一条 rule 的所有约束都会执行"是错觉。**

正确写法的对照(代码库内已有范例,`AdminUsersPage.tsx:303-305`):

```tsx
rules={[
  { required: true, min: 2, max: 64 },                              // 无 pattern → type='string',range 生效
  { pattern: /^[a-zA-Z0-9._-]+$/, message: '仅字母/数字/._- 组成' }, // pattern 单独一条
]}
```

### 2.2 雷点 ②:`errorMessage` 把 422 的数组型 detail 当 string(为什么白屏)

```ts
// material-storage/web/src/api/client.ts:53-60(现状)
export function errorMessage(err: unknown, fallback = '请求失败'): string {
  if (axios.isAxiosError(err)) {
    const d = err.response?.data as { detail?: string } | undefined;  // ← 类型断言骗过 TS
    if (d?.detail) return d.detail;                                   // ← 422 时返回的是对象数组
    ...
```

FastAPI 校验失败(422)的 `detail` 是 `list[dict]`(Pydantic v2 格式,含 `type/loc/msg/input/ctx`),
不是 string。数组被 `message.error(...)` 拿去渲染 → React error #31("Objects are not valid
as a React child")→ 错误发生在 antd message 渲染中、未被 `App.tsx:306` 的全局 ErrorBoundary
捕获 → 整棵 React 树卸载 → 白屏。

**这是通用雷,不限本字段**:`errorMessage` 在 web/src 全库有 61 处调用,任何触发 FastAPI
422 的失败提交(任何表单字段踩后端 Pydantic 约束)都会同样白屏。本次只是 code="1"
恰好成了第一个被踩中的入口。

## 3. 影响面(全库扫描结论,2026-10-13)

| 位置 | 现状 | 是否中雷 |
| --- | --- | --- |
| `NewProjectModal.tsx:262` 项目编码 | required+min+max+pattern **混写一条** | **是**(雷点①唯一实例) |
| `AdminUsersPage.tsx:304` username | 已拆两条 rule | 否(可作范本) |
| `ChangePasswordPage.tsx:71-73` 新密码 | required 一条 + pattern 一条 | 否 |
| `errorMessage`(client.ts:53)→ 61 处调用 | 不兼容数组型 detail | **是**(雷点②,全局) |

后端无需改动:`ProjectCreateIn.code` 的 `min_length=2, max_length=64, pattern`
(`api/app/models/__init__.py:35`)是正确兜底,本次 422 行为符合预期。

## 4. 修复方案(两处,均为前端)

### 修复 1:NewProjectModal 项目编码 rules 拆分(治"没拦截")

```tsx
// material-storage/web/src/components/NewProjectModal.tsx(改后)
<Form.Item name="code" label="项目编码(URL slug,小写字母/数字/-)"
           rules={[
             { required: true, message: '请输入项目编码' },
             { min: 2, max: 64, message: '长度 2-64 个字符' },
             { pattern: /^[a-z0-9][a-z0-9-]*$/, message: '小写字母/数字/-,以字母数字开头' },
           ]}
           extra="提交后不可改;影响 MinIO 路径前缀">
```

要点:
- 长度一条(无 pattern,走 string 类型的 range 校验)、pattern 单独一条,三条都会执行;
- 每条配自己的 message,报错文案与真实原因对应(顺带消掉"提示说字符不合法、实际是长度
  不足"的误导——旧文案在 min 失败时也会显示 pattern 的提示);
- required 单独一条并给出明确文案(混写时空值也会显示 pattern 文案,同样误导)。

### 修复 2:errorMessage 兼容数组型 detail(治"白屏",61 处调用一次全覆盖)

```ts
// material-storage/web/src/api/client.ts(改后)
export function errorMessage(err: unknown, fallback = '请求失败'): string {
  if (axios.isAxiosError(err)) {
    const d = err.response?.data as { detail?: unknown } | undefined;
    if (typeof d?.detail === 'string' && d.detail) return d.detail;
    // FastAPI 422(Pydantic v2)的 detail 是对象数组:取各条 msg 拼接成人话
    if (Array.isArray(d?.detail)) {
      const msgs = d.detail
        .map((x) => (x && typeof x === 'object' && 'msg' in x ? String((x as { msg?: unknown }).msg) : ''))
        .filter(Boolean);
      if (msgs.length) return msgs.join('; ');
    }
    if (err.response?.status) return `${fallback}(HTTP ${err.response.status})`;
    if (err.message) return err.message;
  }
  return fallback;
}
```

要点:
- 返回值恒为 string,`message.error` 永远不会再收到对象/数组(React error #31 从根上断);
- 422 时展示后端各字段校验消息(如 `String should have at least 2 characters`),用户第一次
  能看懂失败原因;Pydantic msg 为英文属可接受,若后续要中文可在后端加
  `RequestValidationError` handler 统一转换(非必须,不纳入本次);
- 空数组/无 msg 的异常形态回落到 HTTP 状态码兜底分支,行为不劣化。

### 明确不做

- 后端不加 422 格式改写(handler):前端修复已根治,动后端响应契约影响面大;
- 不改其他表单(扫描结论只有 NewProjectModal 一处混写);
- 不给 message 包 ErrorBoundary:errorMessage 恒 string 后无崩溃路径,属多余防御。

## 5. 实施与验收清单

实施(纯前端两文件,无 migration / 无 .env / 无 FGA 模型变更):

1. 改 `NewProjectModal.tsx`(修复 1)与 `client.ts`(修复 2);
2. `pnpm --dir web install && pnpm --dir web build`,核对 `index-*.js` 指纹已变化
   (deploy-hh2 技能坑 C 防御);
3. 部署 dev(仅 SPA,无需 restart 容器),真机过下方用例后按需再发 prod。

真机验收用例(dev):

| # | 操作 | 预期 |
| --- | --- | --- |
| 1 | 新建项目,编码 `1`,点创建 | **不发请求**,编码字段下出现「长度 2-64 个字符」提示 |
| 2 | 编码 `A`(大写) | 不发请求,提示「小写字母/数字/-,以字母数字开头」 |
| 3 | 编码空,点创建 | 不发请求,提示「请输入项目编码」 |
| 4 | 编码 `11`,名称合法,点创建 | 创建成功(2 位合法编码) |
| 5 | 修复 2 兜底验证:DevTools 直接 `fetch` 重放 `code:"1"` 的 POST(或临时回退修复 1 后提交) | 页面**不白屏**,弹出含 `String should have at least 2 characters` 的错误 toast |
| 6 | 任一已有表单走一次正常失败(如建用户重名) | toast 正常显示原有 detail 字符串,无回归 |

回归重点:修复 2 触碰的是全局错误提示函数,抽测 2-3 个既有报错场景(如 401/403/409)
确认文案不变(这些场景 detail 本就是 string,走第一分支,理论零变化)。

## 6. 调研过程存档(关键证据,便于复核)

- 线上指纹:本地 build / dev / prod 三处均为 `index-C8lv4fpD.js`,线上 bundle 内 grep 到
  `min:2,max:64,pattern:...` —— 排除"版本旧/没构建上"假设;
- 校验器源码:`web/node_modules/.pnpm/@rc-component+async-validator@5.1.0/.../es/index.js`
  `getType`(pattern→type='pattern')与 `es/validator/pattern.js`(只跑 required+pattern);
- 真机复现:dev evan 账号,捕获 `React error #31 ×2`(args=`{type,loc,msg,input,ctx}`)、
  XHR 请求记录、DOM 快照空、白屏截图;重放 POST 得 422 及数组型 detail;
- 相关记忆:`antd-v6-three-pitfalls.md` 已补第 4 条铁律(rules 混 pattern 则 min/max 失效 +
  数组 detail 直塞 message.error 白屏)。

## 7. 模糊点与决策记录(qdev 实施轮)

| 模糊点 | 决策 | 依据 |
| --- | --- | --- |
| 是否同时修其他表单的 rules 写法 | 只修 NewProjectModal 一处 | §3 扫描结论:全库唯一混写中雷处,其余两处写法本就正确 |
| 422 文案中文化(后端 RequestValidationError handler) | 不做 | §4「明确不做」:前端修复已根治,动后端响应契约影响面大 |
| errorMessage 数组分支的文案格式 | 各条 `msg` 用 `; ` 拼接,空数组回落 HTTP 状态码分支 | §4 修复 2 已定稿,用户指令"结合方案开始修复"即按方案执行 |
| 前端测试方式 | 无前端测试框架(既有现状),用例全部为人工/浏览器自动化执行 | 仓库惯例:docs/qdev 下历次前端周期均为人工用例清单 |
| 数据库修改方案 / 接口定义 / 后端改动点 | 均不涉及 | 纯前端两文件,后端 422 行为是正确兜底 |
