"""ms-ml real 推理:SmolVLM2-256M CPU(工作包 F,ai-tagging-slicing 方案 §7)。

**模块级零 torch 依赖(硬验收)**:torch / transformers / PIL 全部在
load_model()/describe() 内 lazy import —— CI 不装 torch 时 `import model_runner`
与 `import app` 都不炸;stub 模式永不触达本文件的 import 重路径。

要点(方案 §7.1/§7.2):
- torch.set_num_threads(16) 默认(8 推理进程 x 16 = 128 线程预算);env
  MS_ML_NUM_THREADS 可覆盖。
- 不传 flash_attention_2(CUDA 参数);CPU 上 bf16 权重自动落 fp32,
  from_pretrained 不传 dtype。
- prompt 版本化在代码内(_PROMPT_VERSION);要求严格 JSON 输出,
  解析失败做一次宽松正则抽取(§7.2「一次修复重试」;do_sample=False 下
  重新 generate 结果逐字节相同,重试无增益,故重试只做解析修复),
  仍失败抛 MlContentError → app 层 502,调用方按内容层失败分级。
- 权重 local_files_only:权重走宿主卷一次性导入(方案 §13),运行期不触网。

uvicorn --workers 8 下本模块每 worker 进程一份(进程级单例状态)。
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
from typing import Any

# ---- 常量与配置(env 读取全部延迟到调用时,便于测试 monkeypatch)----

_PROMPT_VERSION = "p1"
_MAX_NEW_TOKENS = 96
_TAG_CAP = 8  # 契约上限:tags_en 恒 ≤8(需求 §2.5)
_DESC_MAX_WORDS = 30  # prompt 约束 ≤30 words,出参侧兜底截断

_PROMPT = (
    "You are tagging an image for a media asset library. "
    "Look at the image and answer with STRICT JSON only (no markdown fence, "
    "no commentary, no trailing text) in exactly this shape: "
    '{"description": "<=30 words English description of the image", '
    '"tags": ["<=8 short lowercase English tags"]}'
)


class MlContentError(RuntimeError):
    """模型输出无法解析为契约 JSON(内容层失败;app 层映射 502)。"""


def _model_dir() -> str:
    return os.environ.get("MS_ML_MODEL_DIR", "/models/smolvlm2-256m")


def _num_threads() -> int:
    return int(os.environ.get("MS_ML_NUM_THREADS", "16"))


# 进程级单例状态(lazy 填充;非线程安全 —— 推理端点内联阻塞,进程内天然串行)
_STATE: dict[str, Any] = {"processor": None, "model": None, "loaded": False}


def model_version() -> str:
    """权重目录名 + 权重指纹 hash8 + prompt 版本,如 `smolvlm2-256m@1a2b3c4d+p1`。

    指纹 = 权重目录顶层文件 (name,size) 列表的 sha256(不读文件内容,
    开销亚秒;区分同名目录下的不同权重修订)。任一时刻可调用,不触 torch。
    """
    directory = _model_dir()
    base = os.path.basename(os.path.normpath(directory)) or "model"
    digest = hashlib.sha256()
    try:
        entries = sorted(
            (entry.name, entry.stat().st_size)
            for entry in os.scandir(directory)
            if entry.is_file()
        )
    except OSError:
        entries = []
    for name, size in entries:
        digest.update(f"{name}:{size}\n".encode("utf-8", "replace"))
    return f"{base}@{digest.hexdigest()[:8]}+{_PROMPT_VERSION}"


def is_loaded() -> bool:
    return bool(_STATE["loaded"])


def load_model() -> None:
    """lazy 加载 processor + 模型(仅 real 路径触达;阻塞,秒级)。"""
    if _STATE["loaded"]:
        return

    import torch  # lazy:模块级零 torch 依赖(硬验收)
    from transformers import (
        AutoModelForImageTextToText,
        AutoProcessor,
    )

    torch.set_num_threads(_num_threads())
    directory = _model_dir()
    # CPU:bf16 权重自动落 fp32 → 不传 dtype;不传 flash_attention_2(CUDA 参数)
    processor = AutoProcessor.from_pretrained(directory, local_files_only=True)
    model = AutoModelForImageTextToText.from_pretrained(directory, local_files_only=True)
    model.eval()
    _STATE["processor"] = processor
    _STATE["model"] = model
    _STATE["loaded"] = True


def _extract_json(text: str) -> dict[str, Any] | None:
    """严格 json.loads 优先;失败则一次宽松修复(fence 段 / 首尾 {} 段正则)。"""
    candidates = [text.strip()]
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fenced:
        candidates.append(fenced.group(1))
    loose = re.search(r"\{.*\}", text, re.DOTALL)  # 贪婪:首 { 到尾 }
    if loose:
        candidates.append(loose.group(0))
    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(obj, dict):
            return obj
    return None


def describe(image_bytes: bytes, max_tags: int = 8) -> dict[str, Any]:
    """单帧推理,阻塞返回 {"tags_en": [...≤min(max_tags,8)], "description_en": str}。

    输出无法解析为契约 JSON → MlContentError(内容层失败分级)。
    """
    from PIL import Image  # lazy:最小依赖面

    if not _STATE["loaded"]:
        load_model()
    processor: Any = _STATE["processor"]
    model: Any = _STATE["model"]

    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    # SmolVLM2 模型卡形态:apply_chat_template(tokenize=True, return_dict=True);
    # image 直接传 PIL 对象(最小依赖,免 data URI 往返),processor 自带缩放
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": _PROMPT},
            ],
        }
    ]
    inputs = processor.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
    )
    output = model.generate(**inputs, max_new_tokens=_MAX_NEW_TOKENS, do_sample=False)
    generated = output[:, inputs["input_ids"].shape[1] :]
    text = processor.batch_decode(generated, skip_special_tokens=True)[0].strip()

    parsed = _extract_json(text)
    if parsed is None:
        raise MlContentError("model output is not parseable as contract JSON")

    raw_description = parsed.get("description")
    raw_tags = parsed.get("tags")
    if (
        not isinstance(raw_description, str)
        or not raw_description.strip()
        or not isinstance(raw_tags, list)
    ):
        raise MlContentError("model JSON missing description/tags fields")

    tags: list[str] = []
    for tag in raw_tags:
        normalized = str(tag).strip()
        if normalized and normalized not in tags:
            tags.append(normalized)
    limit = max(1, min(max_tags, _TAG_CAP))
    words = raw_description.split()[:_DESC_MAX_WORDS]
    return {"tags_en": tags[:limit], "description_en": " ".join(words)}
