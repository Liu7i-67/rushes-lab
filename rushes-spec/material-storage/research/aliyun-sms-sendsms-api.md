# 阿里云短信 SendSms API 调研(2026-11-19)

> 素材来源:用户提供的阿里云 OpenAPI 门户《SendSms - 发送短信》页面存档(Dysmsapi,版本 `2017-05-25`,
> 页面更新时间 2026-11-14)。本文只对存档中实际存在的内容做整理;存档里被折叠未展开的细节在 §6 单独列出。
> 结论先行:**发送一条短信最少需要 4 件事 —— RAM AccessKey(鉴权)+ 已审核通过的签名 `SignName`
> + 已审核通过的模板 `TemplateCode` + 手机号;提交成功后返回 `Code=OK` + `BizId`(回执 ID)**。

## 1. 接口定位

| 项 | 值 |
| --- | --- |
| API 名称 | `SendSms`(中文:发送短信) |
| 产品 | Dysmsapi(短信服务) |
| API 版本 | `2017-05-25` |
| 服务地址 | `dysmsapi.aliyuncs.com`(中国站) |
| 请求风格 | RPC |
| 请求方式 | POST / GET(**推荐 POST**) |
| RAM Action | `dysms:SendSms`(访问级别 Get,资源=全部资源 `*`) |
| 单用户 QPS | 5000/秒,超限被限流 |

用途:向单个手机号发短信;也支持**一次最多 1000 个手机号**群发,但群发只能用**相同签名 + 相同模板变量**,
且有一定延迟。若要给不同手机号发不同签名/不同变量,用 `SendBatchSms`(单次最多 100 个手机号)。

## 2. 发送前需要准备什么(前置清单)

从文档可推断出调用方必须先具备的资源(签名/模板的创建走 `CreateSmsSign` / `CreateSmsTemplate`,
查询走 `QuerySmsSign` / `QuerySmsTemplateList`):

1. **阿里云账号开通短信服务**,并创建 RAM 访问凭证(AccessKey ID / AccessKey Secret)——V3 签名机制用它算鉴权头。
2. **短信签名(`SignName`)已报备并审核通过**——如示例值「阿里云」;未审核通过的签名不可用于发送。
3. **短信模板(`TemplateCode`)已报备并审核通过**——形如 `SMS_15305****`;模板内容含变量时,
   变量名与个数必须和 `TemplateParam` 一一对应。
4. **计费认知**:SendSms 是计费接口,国内短信**按运营商回执状态计费**——调用提交成功但运营商回执失败的不计费。

## 3. 请求参数

| 参数 | 类型 | 必填 | 说明 | 示例 |
| --- | --- | --- | --- | --- |
| `PhoneNumbers` | string | **是** | 接收短信的手机号码(格式详见存档折叠部分,未捕获) | `1390000****` |
| `SignName` | string | **是** | 短信签名名称 | `阿里云` |
| `TemplateCode` | string | **是** | 短信模板 Code | `SMS_15305****` |
| `TemplateParam` | string | 模板含变量时必填 | 模板变量对应的实际值,**必须传 JSON 字符串**;参数个数应与模板内变量个数一致 | `{"name":"张三","number":"1390000****"}` |
| `SmsUpExtendCode` | string | 否 | 上行短信扩展码(上行短信按运营商普通短信资费收费) | `90999` |
| `OutId` | string | 否 | 外部流水扩展字段(回传用) | `abcdefgh` |

SDK 请求构造示例(存档中的 Java 版,其余语言见 OpenAPI 门户):

```java
SendSmsRequest sendSmsRequest = new SendSmsRequest()
            .setPhoneNumbers("1390000****")
            .setSignName("阿里云")
            .setTemplateCode("SMS_15305****")
            // TemplateParam 为序列化后的 JSON 字符串。其中\"表示转义后的双引号。
            .setTemplateParam("{\"name\":\"张三\",\"number\":\"1390000****\"}");

SendSmsResponse sendSmsResponse = client.sendSms(sendSmsRequest);
```

自签名(不走 SDK)时的关键请求头(V3 版 RPC 风格,存档实样):

```
POST /?PhoneNumbers=123****4567&SignName=阿里云短信测试&TemplateCode=SMS_154950909&TemplateParam={"code":"1234"} HTTP/1.1
Host: dysmsapi.aliyuncs.com
Authorization: ACS3-HMAC-SHA256 Credential=YourAccessKeyId,SignedHeaders=host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version,Signature=...
x-acs-action: SendSms
x-acs-version: 2017-05-25
x-acs-signature-nonce: <随机串>
x-acs-date: <ISO8601 UTC 时间>
x-acs-content-sha256: <请求体 SHA256>
```

## 4. ⚠ 三条注意事项(直接影响后端实现方式)

1. **超时与重试**:国内短信服务超时时间建议 ≥1s;发生超时失败时,**建议先查回执状态再判断是否重试**,
   不要盲目重试。
2. **不支持幂等**:国内/国际/多媒体短信均**不支持幂等**,调用方必须自己做幂等控制,
   防止多次重试导致重复发送(对接本系统时:同手机号+同验证码场景需在业务层加 Redis 去重键)。
3. **计费口径**:按运营商回执状态计费;`Code=OK` 只代表**提交成功**,最终是否送达以回执为准。

## 5. 返回参数(发送成功之后)

HTTP 提交成功后,响应体含 4 个字段:

| 字段 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- |
| `Code` | string | **请求状态码**。`OK` = 提交成功;非 `OK` 为各类失败码(全表在存档折叠部分,未捕获) | `OK` |
| `Message` | string | 状态码的描述 | `OK` |
| `BizId` | string | **发送回执 ID**。后续查发送结果(回执状态)的凭据 | `9006197469364984****` |
| `RequestId` | string | 请求 ID(排查问题用) | `F655A8D5-B967-440B-8683-DAD6FF8DE990` |

JSON 返回示例(存档原样):

```json
{
  "Code": "OK",
  "Message": "OK",
  "BizId": "9006197469364984****",
  "RequestId": "F655A8D5-B967-440B-8683-DAD6FF8DE990"
}
```

XML 格式同样支持(字段相同):`<SendSmsResponse><Message>OK</Message><RequestId>…</RequestId><BizId>336006646937050335^0</BizId><Code>OK</Code></SendSmsResponse>`
——注意 XML 样例里 BizId 出现过 `^0` 后缀的形态,解析时不要对 BizId 格式做强假设。

**成功判定与后续动作要点:**

- 判定"发送成果"看 `Code == "OK"`,不是看 HTTP 200(HTTP 200 时业务仍可能失败,失败码在 `Code`)。
- `BizId` 要落库:它是后续查询回执状态(如 `QuerySendDetails`)的关联 ID;配合 `OutId` 做业务侧流水对账。
- `Message` 可直接用于日志/错误透出。

## 6. 存档未捕获的信息(后续如需再查官方文档)

存档是网页 HTML,以下「展开详情」折叠区**未被展开**,本文不含其内容,实现前需回官方文档补齐:

- `PhoneNumbers` 的手机号码格式细则(国内 11 位、国际号段写法、群发分隔符等);
- `SignName` / `TemplateCode` / `TemplateParam` / `SmsUpExtendCode` / `OutId` 各自的完整约束(长度上限、字符集等);
- `Code` 失败状态码全表(如限流、模板变量不匹配等错误码语义);
- `BizId` 的完整规则说明;
- 超时机制(help.aliyun.com/document_detail/262079)与重试机制(/262080)文档正文;
- 公共请求头 V3 版完整定义(help.aliyun.com/document_detail/2593177)与签名机制示例。

## 7. 实测记录(2026-11-19,AK=LTAI5t6cJ…FBm5,自签名 V3 stdlib 脚本)

V3 自签名(ACS3-HMAC-SHA256,POST+query+空 body)一次通过,无 SDK 依赖,全链路仅标准库可跑通。

| # | 请求 | 结果 | 要点 |
| --- | --- | --- | --- |
| 1 | `SendSms` 不带 `TemplateParam` | HTTP 200,`Code=isv.SMS_TEMPLATE_ILLEGAL`,Message=「请检查模板内容与模板参数是否匹配」 | **模板含变量时缺 TemplateParam = 提交被拒**,但签名/鉴权/参数序列化(中文签名 UTF-8 百分号编码)全部正确;此失败不产生回执 |
| 2 | `QuerySmsTemplateList`(PageIndex/PageSize) | `Code=OK`,3 个模板全 `AUDIT_STATE_PASS` | 目标模板 `SMS_512523885`「密码重置」,内容=`您的动态码为：${code}…`,单变量 `${code}`,绑定签名=成都讨喜未来文化传媒 |
| 3 | `SendSms` 带 `{"code":"641869"}` | **`Code=OK`,`BizId=744611395060321845^0`**,RequestId=`01A1F1EE-CE09-…` | 实发成功(提交层);BizId 果然带 `^0` 后缀,与 §5 预判一致 |
| 4 | `QuerySendDetails`(号码+当天,±BizId) | `Code=OK` 但 `TotalCount=0`(发出后 8s/33s/12min 三查) | **该条发送没进可查询明细流水**;控制台却显示「发送失败」→ 失败发生在进入回执/明细之前 |
| 5 | MNS 回执队列 `Alicom-Queue-1903317001079316-SmsReport` | 自签名 403 `SignatureDoesNotMatch`(误导);**官方 SDK 实错=`ServiceNotEnabled`「OwnerId…has not enabled」** | 该阿里云账号**未开通消息服务 SMQ(原 MNS)**,短信服务自动建的回执队列不可 API 访问;签名实现已与官方 SDK 逐字符对齐验证,非签名问题 |
| 6 | `QuerySendStatistics` | 参数校验即拒:`IsGlobe=0` 报 not valid(=1 才放行)、`endDate` 格式不认(日期串与毫秒时间戳均试) | 该接口拿不到单条失败原因,放弃 |

**实测钉子:**

- 中文 SignName 走 RFC3986 percent-encoding(UTF-8)签名即可,无需特殊处理;`TemplateParam` 传 dict 时须先序列化为 JSON 字符串再入签名(嵌套引号转义易错,脚本内统一序列化最稳)。
- `QuerySmsTemplateList` 分页参数是 `PageIndex`/`PageSize`(不是 CurrentPage);`QuerySendStatistics` 是 `PageIndex` 且 `IsGlobe` 必填但 0 被拒——两接口文档与实现有出入,遇到逐参数试错即可。
- **MNS 403 `SignatureDoesNotMatch` 可能掩盖 `ServiceNotEnabled`**:签名比对失败与服务未开通都走 403,自签名调试时先用官方 SDK 交叉验证再怀疑算法。
- 待补:失败根因(等控制台失败行的错误码,或账号开通 SMQ 后读回执队列);手机端是否实际收到 641869 短信待确认。

## 8. 与本仓库的潜在衔接点(调研观察,未拍板)

- 后端为 FastAPI/Python,接入方式二选一:官方 Python SDK(`alibabacloud_dysmsapi20170525`,V2/V4 版)或
  按存档 §3 的 V3 签名头用 hand-rolled httpx(仓库已有先例:OIDC 即 hand-rolled httpx,依赖最小)。
- 服务实例接线应遵循 `app.state` 模式(CLAUDE.md:不在 module 顶层建 client)。
- 通知中心现通道为 SMTP(留空 = no-op);短信若作为第二通道,失败只 log 不影响主流程的既有约定可复用。
- `users` 表无手机号字段(只有飞书历史只读列),若用于用户级触达需先落手机号的存储与绑定流程。
