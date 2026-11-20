"""FakeSms — 替换 ``app.state.sms`` 的假实现(手机绑定/短信找回密码方案 §10.1)。

d1(test_phone_bind_api)/ d2(test_phone_reset_api)两个容器级测试文件共用,
接口由方案钉死:记录调用参数、可编排下一次 send 抛出的异常。零真实发送、
零真实凭证 —— 测试容器内绝不打阿里云。
"""
from __future__ import annotations


class FakeSms:
    """替换 app.state.sms 的假实现:记录调用,可编排失败。

    calls:每次 send 一条 {"phone","template_code","code","kind"};
      成功 kind="ok",失败 kind="error"(失败调用也记录)。
    fail_next:预置下一次 send 抛出的异常(SmsSendError / SmsTransportError
      实例,由测试从 app.services.aliyun_sms 构造);抛出一次后自动清回 None。
    """

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.fail_next: Exception | None = None

    async def send(self, phone: str, template_code: str, code: str) -> str:
        if self.fail_next is not None:
            exc, self.fail_next = self.fail_next, None
            self.calls.append(
                {"phone": phone, "template_code": template_code, "code": code, "kind": "error"}
            )
            raise exc
        self.calls.append(
            {"phone": phone, "template_code": template_code, "code": code, "kind": "ok"}
        )
        return "0170123456789^0"  # 模拟带 ^0 后缀的 BizId(接口钉子,§5.6)
