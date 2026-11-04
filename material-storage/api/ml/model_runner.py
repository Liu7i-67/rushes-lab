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

_PROMPT_VERSION = "p5"
_MAX_NEW_TOKENS = 96
_TAG_CAP = 8  # 契约上限:tags_en 恒 ≤8(需求 §2.5)
_DESC_MAX_WORDS = 30  # prompt 约束 ≤30 words,出参侧兜底截断

_PROMPT = (
    "Answer in exactly this format:\n"
    "Tags: up to 8 short English tags separated by commas\n"
    "Description: one short sentence about the image"
)
# p4 起拆两轮单任务(256M 小模型对「双任务一格式」跟随差:dev 实测只回
# 描述句不回标签;单任务指令各自质量均验证可靠,2026-11-04):
#   轮 1 描述、轮 2 标签 —— 时长 ×2(~6-18s/图)换标签产出,回填口径见方案 §7.3
_PROMPT_DESC = "Describe this image in one short sentence."
_PROMPT_TAGS = (
    "List up to 8 short English keywords about this image, "
    "separated by commas. Answer with the keywords only."
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
    """lazy 加载 processor + 模型(仅 real 路径触达;阻塞,秒级)。

    翻译模型(opus-mt-en-zh,p5 起)独立 best-effort 加载:目录缺失/加载失败
    只禁用翻译(description_zh=None),不阻塞打标主链。
    """
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
    _load_translator()


def _load_translator() -> bool:
    """lazy 加载 en→zh 翻译模型(MarianMT;~300MB,CPU 单句亚秒)。

    环境变量 MS_ML_TRANSLATE_DIR(默认 /models/translate);目录不存在或
    加载异常 → 翻译禁用,打标主链不受影响(描述保留英文呈现)。
    """
    if _STATE.get("translator") is not None:
        return True
    directory = os.environ.get("MS_ML_TRANSLATE_DIR", "/models/translate")
    if not os.path.isdir(directory) or not any(os.scandir(directory)):
        _STATE["translate_failed"] = "no weights dir"
        return False
    try:
        import torch
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

        tok = AutoTokenizer.from_pretrained(directory, local_files_only=True)
        m = AutoModelForSeq2SeqLM.from_pretrained(directory, local_files_only=True)
        m.eval()
        _STATE["translate_tokenizer"] = tok
        _STATE["translator"] = m
        return True
    except Exception as e:  # noqa: BLE001 — best-effort:翻译不可用不拖垮主链
        _STATE["translate_failed"] = f"{type(e).__name__}"
        return False


def translate_en_zh(text: str) -> str | None:
    """英文短句 → 中文(阻塞,CPU 亚秒);翻译不可用返回 None。"""
    text = (text or "").strip()
    if not text:
        return None
    if _STATE.get("translator") is None and not _load_translator():
        return None
    import torch

    tok = _STATE["translate_tokenizer"]
    model = _STATE["translator"]
    with torch.no_grad():
        batch = tok([text], return_tensors="pt", truncation=True, max_length=256)
        out = model.generate(**batch, max_length=192, num_beams=1, do_sample=False)
    return tok.decode(out[0], skip_special_tokens=True).strip() or None


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


def _parse_freeform(text: str) -> dict[str, Any] | None:
    """自然语言输出解析(p3 主路径 + 自由格式回退)。

    p3 指令要求 "Tags: a, b" / "Description: ..." 前缀行——按前缀(大小写不敏感)
    提取;模型未按格式时回退:首行按逗号切开且片段 ≤8 个视为标签行,否则视为
    描述行。**tags 与 description 任一非空即成功**(256M 小模型常只完成其一,
    缺失项置空由上游降级,不判内容层失败)。
    """
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None
    desc = ""
    tags: list[str] = []

    def _split_tags(raw: str) -> list[str]:
        out: list[str] = []
        for part in raw.replace(";", ",").replace("、", ",").split(","):
            tag = part.strip(" .-*#-—\t")
            if tag and tag.lower() not in ("tags", "tag") and tag not in out:
                out.append(tag)
        return out

    for ln in lines:
        low = ln.lower()
        if low.startswith("tags:"):
            tags = _split_tags(ln[5:])
        elif low.startswith("tag:"):
            tags = _split_tags(ln[4:])
        elif low.startswith("description:"):
            desc = ln[12:].strip(" .-—\t")
    if not tags and not desc:
        # 自由格式回退:首行像标签串(逗号分段且段数 ≤8)当标签,否则当描述
        first = lines[0].rstrip(".,;")
        parts = _split_tags(first)
        if len(parts) > 1 and len(parts) <= _TAG_CAP:
            tags = parts
        else:
            desc = first
    return {"description": desc, "tags": tags}


def _generate(image: Any, prompt: str) -> str:
    """单轮推理,返回解码文本(阻塞;调用方持有 processor/model)。"""
    processor: Any = _STATE["processor"]
    model: Any = _STATE["model"]
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt},
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
    return processor.batch_decode(generated, skip_special_tokens=True)[0].strip()


def describe(image_bytes: bytes, max_tags: int = 8) -> dict[str, Any]:
    """单帧推理(p4 两轮单任务),阻塞返回 {"tags_en": [...], "description_en": str}。

    轮 1 描述(_PROMPT_DESC)、轮 2 标签(_PROMPT_TAGS);任一轮产出有效即
    降级保留,两轮皆空 → MlContentError(内容层失败分级,由 pipeline 重试)。
    """
    from PIL import Image  # lazy:最小依赖面

    if not _STATE["loaded"]:
        load_model()

    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    desc_text = _generate(image, _PROMPT_DESC)
    tags_text = _generate(image, _PROMPT_TAGS)

    description = " ".join(desc_text.split()[:_DESC_MAX_WORDS]).strip(" .-—\t")

    tags: list[str] = []
    for part in tags_text.replace(";", ",").replace("、", ",").split(","):
        tag = part.strip(" .-*#-—\t\n0123456789)")
        low = tag.lower()
        if (
            tag
            and low not in ("tags:", "tag:", "keywords:", "keywords", "tags", "tag",
                            "answer", "none", "n/a")
            and not tag.isdigit()
            and low not in tags  # 去重比较用归一小写(原始大小写交错时 tag not in tags 会漏)
        ):
            tags.append(low)
    limit = max(1, min(max_tags, _TAG_CAP))

    if not tags and not description:
        raise MlContentError("model produced neither description nor tags")

    # p5:描述补一轮 en→zh(opus-mt,best-effort——不可用时 None,上游呈现英文)
    description_zh = translate_en_zh(description) if description else None
    return {
        "tags_en": tags[:limit],
        "description_en": description,
        "description_zh": description_zh,
    }
