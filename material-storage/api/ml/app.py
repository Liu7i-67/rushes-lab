"""ms-ml:素材打标推理服务(工作包 F,ai-tagging-slicing 方案 §7 / 需求文档 §2.5)。

- FastAPI + uvicorn --workers 8:推理端点为 async def 且**内联阻塞执行推理**
  (禁线程池/executor 类手段)—— 事件循环被单次推理冻结 = 天然一进程一请求,
  并发上限就是 uvicorn 进程数(§7.1 内存/线程预算依赖此形态,勿改)。
- /healthz 例外用同步 def(handler 自身不占事件循环;满载误判的主防线
  是调用方 16s 探测超时 + 连续 2 次失败判死,方案 §7.2)。
- 模式开关 env MS_ML_MODE=stub|stub-fault|real(默认 stub):
  - stub:确定性假结果,不 import torch —— CI/单测不装 torch 也能起(硬验收);
  - stub-fault:进程内请求计数器,奇数次返回非法 JSON 文本体(内容层故障注入),
    偶数次正常 stub 结果;
  - real:调 model_runner(torch/transformers 仅在 real 分支触达;
    model_runner 与本文件模块级均零 torch 依赖)。
- 日志卫生:不落图片内容与描述文本(只记模式/序号/标签数,方案 §7.2)。

uvicorn 启动(CMD,workdir=/app/ml):uvicorn app:app --host 0.0.0.0 --port 8000 --workers 8
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field, field_validator

logger = logging.getLogger("ms_ml")
logging.basicConfig(level=logging.INFO)

VALID_MODES = ("stub", "stub-fault", "real")
_STUB_TAGS = ["demo", "stub"]
_STUB_DESCRIPTION = "stub description"

# 环境变量(与 compose 包 G 对齐):
#   MS_ML_MODE           stub|stub-fault|real(默认 stub)
#   MS_ML_MODEL_VERSION  健康闸版本号覆盖(须与 api 侧 settings.ai_model_version 一致);
#                        不设则 stub 恒 "stub@p0",real 由 model_runner.model_version() 派生
MODE_ENV = "MS_ML_MODE"
MODEL_VERSION_ENV = "MS_ML_MODEL_VERSION"


class DescribeRequest(BaseModel):
    """POST /v1/describe 入参(需求 §2.5 定死契约)。

    image_b64 由 pydantic validator 显式解码校验:非法 base64 / 空载荷 →
    ValueError → FastAPI 422(满足「b64 解码失败 422」;
    注:pydantic v2 的 bytes 字段在 lax JSON 模式对非法 b64 是原样放行的,
    不能靠注解实现该语义,须显式解码)。
    """

    image_b64: str
    max_tags: int = Field(default=8, ge=1, le=32)

    @field_validator("image_b64")
    @classmethod
    def _b64_must_decode(cls, value: str) -> str:
        try:
            data = base64.b64decode(value, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError("image_b64 is not valid base64") from exc
        if not data:
            raise ValueError("image_b64 decodes to an empty payload")
        return value  # 校验通过原样返回;解码产物在 handler 内取(validator 保证可解码)


class DescribeResponse(BaseModel):
    """POST /v1/describe 出参:tags_en ≤ max_tags(且恒 ≤8);description_en 英文
    原文 + description_zh 机器翻译(p5 起,opus-mt best-effort,不可用时 None)。"""

    tags_en: list[str]
    description_en: str
    description_zh: str | None = None


def _env_mode() -> str:
    raw = os.environ.get(MODE_ENV, "stub").strip().lower()
    if raw not in VALID_MODES:
        logger.warning("unknown MS_ML_MODE=%s, falling back to stub", raw)
        return "stub"
    return raw


def _resolve_model_version(mode: str) -> str:
    """healthz 的 model_version:env 覆盖优先;real 由权重目录+prompt 版本派生。

    model_runner 模块级零 torch 依赖,仅 real 分支才 import。
    """
    env_version = os.environ.get(MODEL_VERSION_ENV)
    if env_version:
        return env_version
    if mode == "real":
        try:
            import model_runner  # type: ignore[import-not-found]

            return model_runner.model_version()
        except Exception:  # 权重目录不可读等,healthz 仍须可应答
            logger.exception("model_runner.model_version() failed")
            return "unknown"
    return "stub@p0"


def _stub_result(max_tags: int) -> DescribeResponse:
    return DescribeResponse(
        tags_en=_STUB_TAGS[:max_tags],
        description_en=_STUB_DESCRIPTION,
        description_zh="存根描述(p5 翻译演示)",
    )


def _get_runner() -> Any:
    """real 分支专用:延迟 import 兄弟模块(stub 路径永不触达)。"""
    import model_runner  # type: ignore[import-not-found]

    return model_runner


@asynccontextmanager
async def _real_lifespan(app: FastAPI) -> AsyncIterator[None]:
    """real 模式 lifespan:startup 阻塞加载权重(uvicorn 每 worker 进程各一次)。"""
    runner = _get_runner()
    try:
        # 阻塞 startup 加载权重(256M ~秒级);失败不拒起,loaded 保持 false
        # → healthz 如实上报,describe 返回 503
        runner.load_model()
        app.state.loaded = True
        logger.info("model weights loaded version=%s", app.state.model_version)
    except Exception:
        logger.exception("model weights load failed (loaded stays false)")
    yield


def create_app(mode: str | None = None) -> FastAPI:
    """构建 FastAPI 应用;mode 显式传参供测试,缺省读 env(生产入口)。"""
    resolved = (mode or _env_mode()).strip().lower()
    if resolved not in VALID_MODES:
        resolved = "stub"
    is_real = resolved == "real"

    app = FastAPI(
        title="ms-ml",
        version="1.0.0",
        # 仅内网容器网可达(不 publish 端口),关掉 openapi/docs 减暴露面
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=_real_lifespan if is_real else None,
    )
    app.state.mode = resolved
    # stub 族无权重概念,loaded 恒 true;real 待 startup 加载权重后翻 true
    app.state.loaded = not is_real
    # 进程内请求计数器(stub-fault 奇偶注入;uvicorn 每 worker 进程一个实例,
    # 与「进程内计数」语义一致)
    app.state.describe_seq = 0
    app.state.model_version = _resolve_model_version(resolved)

    @app.get("/healthz")
    def healthz() -> dict[str, Any]:
        """同步 def:handler 自身不阻塞事件循环(FastAPI 调度到线程池)。"""
        return {
            "status": "ok",
            "mode": app.state.mode,
            "model_version": app.state.model_version,
            "loaded": bool(app.state.loaded),
        }

    @app.post("/v1/describe", response_model=DescribeResponse)
    async def describe(req: DescribeRequest) -> Any:
        app.state.describe_seq += 1
        seq = app.state.describe_seq

        if app.state.mode == "stub-fault":
            if seq % 2 == 1:
                # 奇数次:200 + 非法 JSON 文本体(内容层失败注入,验收 #4)
                logger.info("describe fault-injected seq=%d", seq)
                return PlainTextResponse(
                    "stub-fault: this body is intentionally not valid json",
                    status_code=200,
                    media_type="text/plain; charset=utf-8",
                )
            return _stub_result(req.max_tags)

        if app.state.mode == "stub":
            return _stub_result(req.max_tags)

        # ---- real:内联阻塞推理(禁线程池 —— 事件循环冻结即单进程并发闸)----
        if not app.state.loaded:
            raise HTTPException(status_code=503, detail="model weights not loaded")
        runner = _get_runner()
        try:
            result = runner.describe(
                base64.b64decode(req.image_b64, validate=True),
                max_tags=req.max_tags,
            )
        except runner.MlContentError:
            # 内容层失败(输出无法解析为契约 JSON)→ 502,调用方按内容层分级
            logger.warning("describe content-failed seq=%d", seq)
            raise HTTPException(status_code=502, detail="ml content error") from None
        logger.info("describe ok seq=%d n_tags=%d", seq, len(result["tags_en"]))
        return result

    return app


app = create_app()
