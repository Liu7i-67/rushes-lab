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

## 7. 与本仓库的潜在衔接点(调研观察,未拍板)

- 后端为 FastAPI/Python,接入方式二选一:官方 Python SDK(`alibabacloud_dysmsapi20170525`,V2/V4 版)或
  按存档 §3 的 V3 签名头用 hand-rolled httpx(仓库已有先例:OIDC 即 hand-rolled httpx,依赖最小)。
- 服务实例接线应遵循 `app.state` 模式(CLAUDE.md:不在 module 顶层建 client)。
- 通知中心现通道为 SMTP(留空 = no-op);短信若作为第二通道,失败只 log 不影响主流程的既有约定可复用。
- `users` 表无手机号字段(只有飞书历史只读列),若用于用户级触达需先落手机号的存储与绑定流程。
