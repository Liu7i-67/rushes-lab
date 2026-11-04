"""ms-ml HTTP 客户端(httpx AsyncClient 封装;方案 §7.2/§8.3-4/§8.3-5)。

契约(派发文档 §2.2 对应面):
- ``check_health(base_url, timeout_s=16) -> (ok, model_version | None)``:单次探测;
  「连续 2 次失败才判死」的组合逻辑由调用方(ai_pipeline 健康闸)承担 —— 满载时
  推理阻塞 ms-ml 事件循环,healthz 应答可达 2-8s,1s 超时必误判(§7.2),故默认
  超时 16s ≈ 2x 最坏单请求阻塞。
- ``describe_image(base_url, image_bytes, timeout_s, max_tags) -> (tags_en, description_en)``:
  **传输层异常(ConnectError/ConnectTimeout/ReadTimeout 等 httpx.TransportError 族)
  原样上抛**(调用方二级分级:annotate x2 重试 / slice 连续≥2 帧判 job failed);
  **内容层(非 200 / 非 JSON / 字段缺失)抛 ``MlContentError``**。
- 日志卫生:不落图片内容与返回文本全文(tags/description 不进日志),本模块仅记
  状态码级 warning。
"""
from __future__ import annotations

import base64
import logging
from typing import Any

import httpx

log = logging.getLogger(__name__)

# ms-ml 契约(§2.5):POST /v1/describe 出参形状
_MAX_TAGS_CAP = 8


class MlContentError(Exception):
    """内容层失败:HTTP 非 2xx / 响应非 JSON / 出参字段缺失或形状不对。

    与传输层异常(网络/超时)刻意区分:内容层走帧级容错或一次修复重试,
    传输层走 job 级失败分级(§8.4-6)。
    """


def _client(base_url: str, timeout_s: float,
            shared: httpx.AsyncClient | None) -> httpx.AsyncClient:
    """shared 客户端优先(管线内逐帧复用,省 TLS/连接建立);否则单次建。"""
    if shared is not None:
        return shared
    return httpx.AsyncClient(timeout=httpx.Timeout(timeout_s), base_url=base_url)


async def check_health(base_url: str, timeout_s: float = 16,
                       shared: httpx.AsyncClient | None = None) -> tuple[bool, str | None]:
    """单次 GET /healthz → (ok, model_version | None)。

    任何异常(含超时)一律 (False, None) —— 失败计数由调用方跨两次探测累计;
    model_version 供调用方断言与 settings.ai_model_version 一致(§8.3-3 血缘闸)。
    """
    own = shared is None
    client = _client(base_url, timeout_s, shared)
    try:
        resp = await client.get("/healthz", timeout=timeout_s)
        if resp.status_code != 200:
            log.warning("ml healthz http %s", resp.status_code)
            return (False, None)
        data: Any = resp.json()
        ok = isinstance(data, dict) and data.get("status") == "ok"
        version = data.get("model_version") if isinstance(data, dict) else None
        return (bool(ok), str(version) if version else None)
    except Exception:  # 单次探测失败即 ok=False,不区分原因
        return (False, None)
    finally:
        if own:
            await client.aclose()


async def describe_image(base_url: str, image_bytes: bytes, timeout_s: float,
                         *, max_tags: int = _MAX_TAGS_CAP) -> tuple[list[str], str, str | None]:
    """POST /v1/describe → (tags_en, description_en, description_zh|None)。
    description_zh:ms-ml 侧 en→zh 机器翻译(p5 起,best-effort 不可用为 None)。

    - 传输层(httpx.TransportError 族,含 ConnectError/ConnectTimeout/ReadTimeout):
      **原类型上抛**,由调用方二级分级(§8.3-5 annotate x2 / §8.4-6 slice 帧级);
    - 内容层(非 2xx / 非 JSON / tags_en 非 str 列表 / description_en 缺失):
      MlContentError;
    - 日志卫生:不落 image 内容、tags/description 文本与 presigned URL。

    每次调用自建一次性 client(用毕关闭);无 shared 复用参数(P2-7 删死参:
    全仓库无调用方传参,check_health 的 shared 不受影响)。
    """
    payload = {
        "image_b64": base64.b64encode(image_bytes).decode("ascii"),
        "max_tags": max_tags,
    }
    client = _client(base_url, timeout_s, None)
    try:
        # httpx.TransportError(含三类命名异常)不捕获 —— 原类型上抛(契约)
        resp = await client.post("/v1/describe", json=payload, timeout=timeout_s)
    finally:
        await client.aclose()
    if resp.status_code // 100 != 2:
        # 状态码进日志无内容泄露风险(路径/鉴权头不含素材信息)
        log.warning("ml describe http %s", resp.status_code)
        raise MlContentError(f"ml describe http {resp.status_code}")
    try:
        data: Any = resp.json()
    except ValueError as e:
        raise MlContentError("ml describe non-json body") from e
    if not isinstance(data, dict):
        raise MlContentError("ml describe bad schema")
    tags = data.get("tags_en")
    desc = data.get("description_en")
    if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
        raise MlContentError("ml describe tags_en missing")
    if not isinstance(desc, str):
        raise MlContentError("ml describe description_en missing")
    desc_zh = data.get("description_zh")
    if not isinstance(desc_zh, str):
        desc_zh = None
    return tags[:max_tags], desc, desc_zh or None
