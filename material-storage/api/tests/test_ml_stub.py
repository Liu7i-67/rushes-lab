"""ms-ml stub 契约单测(工作包 F,需求文档 §2.5 / §5-14)。

覆盖:
- healthz 响应形状(stub / stub-fault);
- describe 确定性输出 + max_tags 截断 + b64/max_tags 校验 422;
- stub-fault 奇偶故障注入(每 app 实例序号独立);
- 无 torch 环境 `import app`(及 model_runner)不炸 —— 子进程 + meta_path
  拦截器模拟 CI 无 torch(硬验收;本机装有 torch 也能确定性复验 lazy 结构);
- model_runner:JSON 宽松解析表驱动 + model_version 派生(权重指纹/prompt 版本);
- real 模式:无权重环境 healthz loaded=false / describe 503(lifespan 不执行);
  有权重+transformers 的环境才跑启动冒烟,无权重 skip(需求 §5-14)。

不依赖 torch/transformers/权重文件;全部同步(TestClient),纯离线。
"""

from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

ML_DIR = Path(__file__).resolve().parent.parent / "ml"
APP_PY = ML_DIR / "app.py"
RUNNER_PY = ML_DIR / "model_runner.py"

# 任意合法 b64(stub 不真的解码图片;端点仅校验 b64 形状)
_B64_PAYLOAD = base64.b64encode(b"fake-image-bytes-not-really-a-png").decode()


def _load_module(name: str, path: Path) -> Any:
    """以独立模块名加载 ml/ 下模块(避免与 api/app 包重名冲突,不污染 sys.path)。"""
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


APP_MOD = _load_module("ms_ml_app_under_test", APP_PY)
RUNNER_MOD = _load_module("ms_ml_model_runner_under_test", RUNNER_PY)

_STUB_BODY = {"tags_en": ["demo", "stub"], "description_en": "stub description",
               "description_zh": "存根描述(p5 翻译演示)"}


def _describe(client: TestClient, **overrides: Any) -> Any:
    payload: dict[str, Any] = {"image_b64": _B64_PAYLOAD}
    payload.update(overrides)
    return client.post("/v1/describe", json=payload)


# ---------------------------------------------------------------- healthz


def test_healthz_stub_shape() -> None:
    client = TestClient(APP_MOD.create_app("stub"))
    resp = client.get("/healthz")
    assert resp.status_code == 200
    # 整体形状钉死:恰好这四个键;stub 模式 loaded 恒 true
    assert resp.json() == {
        "status": "ok",
        "mode": "stub",
        "model_version": "stub@p0",
        "loaded": True,
    }


def test_healthz_stub_fault_mode() -> None:
    client = TestClient(APP_MOD.create_app("stub-fault"))
    body = client.get("/healthz").json()
    assert body["status"] == "ok"
    assert body["mode"] == "stub-fault"
    assert body["loaded"] is True


# ---------------------------------------------------------------- describe:stub


def test_describe_stub_deterministic() -> None:
    client = TestClient(APP_MOD.create_app("stub"))
    r1 = _describe(client)
    r2 = _describe(client)
    r3 = _describe(client)
    # 确定性:同入参逐字节同出参
    assert r1.status_code == r2.status_code == r3.status_code == 200
    assert r1.json() == r2.json() == r3.json() == _STUB_BODY


def test_describe_stub_max_tags_truncates() -> None:
    client = TestClient(APP_MOD.create_app("stub"))
    # max_tags 缺省=8 → 两个 stub 标签原样
    assert _describe(client, max_tags=8).json() == _STUB_BODY
    # max_tags=5 ≥ len(tags) → 原样
    assert _describe(client, max_tags=5).json()["tags_en"] == ["demo", "stub"]
    # max_tags=1 → 截到 1 个
    assert _describe(client, max_tags=1).json()["tags_en"] == ["demo"]


def test_describe_validation_422() -> None:
    client = TestClient(APP_MOD.create_app("stub"))
    # b64 非法字符
    resp = client.post("/v1/describe", json={"image_b64": "not-base64!!!"})
    assert resp.status_code == 422
    # b64 合法但解出空载荷
    resp = client.post("/v1/describe", json={"image_b64": ""})
    assert resp.status_code == 422
    # 缺字段
    resp = client.post("/v1/describe", json={"max_tags": 8})
    assert resp.status_code == 422
    # max_tags 越界(ge=1, le=32)
    assert client.post("/v1/describe", json={"image_b64": _B64_PAYLOAD, "max_tags": 0}).status_code == 422
    assert client.post("/v1/describe", json={"image_b64": _B64_PAYLOAD, "max_tags": 33}).status_code == 422


# ---------------------------------------------------------------- describe:stub-fault


def test_stub_fault_parity_injection() -> None:
    """奇数次 → 200 + 非法 JSON 文本体;偶数次 → 正常 stub 结果(故障注入,验收 #4)。"""
    client = TestClient(APP_MOD.create_app("stub-fault"))
    r1 = _describe(client)
    assert r1.status_code == 200
    assert r1.text  # 非空非法体
    with pytest.raises(json.JSONDecodeError):
        r1.json()

    r2 = _describe(client)
    assert r2.status_code == 200
    assert r2.json() == _STUB_BODY

    r3 = _describe(client)
    with pytest.raises(json.JSONDecodeError):
        r3.json()

    r4 = _describe(client)
    assert r4.json() == _STUB_BODY


def test_stub_fault_counter_resets_per_app_instance() -> None:
    """计数器语义 = 每 app 实例(uvicorn 每 worker 进程一个),新实例从奇数次开始。"""
    fresh = TestClient(APP_MOD.create_app("stub-fault"))
    with pytest.raises(json.JSONDecodeError):
        _describe(fresh).json()


# ---------------------------------------------------------------- lazy 结构硬验收


def test_describe_is_async_inline_no_threadpool() -> None:
    """推理端点 async def 内联阻塞(禁 to_thread/线程池);healthz 是同步 def。"""
    source = APP_PY.read_text(encoding="utf-8")
    assert "to_thread" not in source, "ms-ml 推理禁 to_thread(一进程一请求形态)"
    assert "run_in_executor" not in source, "ms-ml 推理禁线程池"
    assert re.search(r"async def describe\(", source), "describe 必须 async def"
    assert re.search(r"(?<!async )def healthz\(", source), "healthz 必须同步 def"


def test_import_app_without_torch_subprocess() -> None:
    """CI 不装 torch 时 `import app` / `import model_runner` 不炸(硬验收)。

    子进程插 meta_path 拦截器:任何 torch/transformers import 即抛 ImportError,
    证明模块级零 torch 依赖(不依赖本机是否恰好装有 torch)。
    """
    code = textwrap.dedent(
        """
        import sys

        class _NoTorchFinder:
            def find_spec(self, fullname, path=None, target=None):
                if fullname == "torch" or fullname.startswith("torch.") or fullname == "transformers":
                    raise ImportError("blocked: " + fullname)
                return None

        sys.meta_path.insert(0, _NoTorchFinder())
        sys.path.insert(0, {ml_dir!r})
        import app
        import model_runner
        assert "torch" not in sys.modules, "torch got imported"
        assert "transformers" not in sys.modules, "transformers got imported"

        from fastapi.testclient import TestClient
        with TestClient(app.create_app("stub")) as client:
            resp = client.get("/healthz")
        assert resp.status_code == 200
        body = resp.json()
        assert body["mode"] == "stub" and body["loaded"] is True
        print("HEALTHZ", resp.status_code, body["mode"], body["loaded"])
        print("NO_TORCH_IMPORT_OK")
        """
    ).format(ml_dir=str(ML_DIR))
    env = {**os.environ, "MS_ML_MODE": "stub"}
    proc = subprocess.run(
        [sys.executable, "-I", "-c", code],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert proc.returncode == 0, f"subprocess failed:\n{proc.stdout}\n{proc.stderr}"
    assert "NO_TORCH_IMPORT_OK" in proc.stdout
    assert "HEALTHZ 200 stub True" in proc.stdout


# ---------------------------------------------------------------- model_runner(torch-free 部分)


def test_model_runner_json_extraction() -> None:
    """严格解析优先,失败一次宽松修复(fence 段/首尾 {} 段);彻底失败 None。"""
    cases: list[tuple[str, dict[str, Any] | None]] = [
        ('{"description": "a b", "tags": ["x"]}', {"description": "a b", "tags": ["x"]}),
        (
            '```json\n{"description": "d", "tags": ["t"]}\n```',
            {"description": "d", "tags": ["t"]},
        ),
        (
            'Sure: {"description": "d", "tags": ["t"]} hope this helps',
            {"description": "d", "tags": ["t"]},
        ),
        ("no json here at all", None),
        ('{"description": "trunca', None),
    ]
    for text, expected in cases:
        assert RUNNER_MOD._extract_json(text) == expected, f"case: {text!r}"


def test_model_runner_version_derivation(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """model_version = 目录名@权重指纹8+p3;权重内容变 → 指纹变;目录缺失可派生。"""
    model_dir = tmp_path / "smolvlm2-256m"
    model_dir.mkdir()
    (model_dir / "config.json").write_text("{}", encoding="utf-8")
    (model_dir / "model.safetensors").write_bytes(b"x" * 10)
    monkeypatch.setenv("MS_ML_MODEL_DIR", str(model_dir))

    version = RUNNER_MOD.model_version()
    assert version.startswith("smolvlm2-256m@")
    assert version.endswith("+p5")
    hash8 = version.split("@")[1].split("+")[0]
    assert len(hash8) == 8
    assert all(c in "0123456789abcdef" for c in hash8)

    # 权重内容变化 → 指纹变化(指纹=文件名+字节数列表;同名字节数不同的修订可区分)
    (model_dir / "model.safetensors").write_bytes(b"y" * 12)
    assert RUNNER_MOD.model_version() != version

    # 目录不存在 → 仍返回派生串,healthz 可应答(不炸)
    monkeypatch.setenv("MS_ML_MODEL_DIR", str(tmp_path / "missing"))
    missing_version = RUNNER_MOD.model_version()
    assert missing_version.startswith("missing@")
    assert missing_version.endswith("+p5")


# ---------------------------------------------------------------- real 模式


def _real_ready() -> bool:
    """real 冒烟前置:权重目录在 + transformers 可 import(本机/CI 无权重 → skip)。"""
    model_dir = Path(os.environ.get("MS_ML_MODEL_DIR", "/models/smolvlm2-256m"))
    return model_dir.is_dir() and importlib.util.find_spec("transformers") is not None


def test_real_mode_not_loaded_without_lifespan(monkeypatch: pytest.MonkeyPatch) -> None:
    """无权重环境 real 模式:lifespan 未执行 → healthz loaded=false,describe 503。"""
    monkeypatch.syspath_prepend(str(ML_DIR))  # 兄弟 import model_runner(torch-free)
    app = APP_MOD.create_app("real")
    client = TestClient(app)  # 不进 with:lifespan(权重加载)不执行
    body = client.get("/healthz").json()
    assert body["status"] == "ok"
    assert body["mode"] == "real"
    assert body["loaded"] is False
    assert isinstance(body["model_version"], str)

    resp = client.post("/v1/describe", json={"image_b64": _B64_PAYLOAD})
    assert resp.status_code == 503


@pytest.mark.skipif(
    not _real_ready(),
    reason="real 权重/transformers 不在本机(ms_ml 无权重时 skip,需求 §5-14)",
)
def test_real_mode_startup_smoke_when_weights_present(monkeypatch: pytest.MonkeyPatch) -> None:
    """有权重环境才执行:startup 阻塞加载 → healthz loaded=true → 单帧 describe 契约。"""
    monkeypatch.syspath_prepend(str(ML_DIR))
    with TestClient(APP_MOD.create_app("real")) as client:
        body = client.get("/healthz").json()
        assert body["status"] == "ok"
        assert body["loaded"] is True
        assert body["model_version"].endswith("+p5")

        from PIL import Image

        buf = io.BytesIO()
        Image.new("RGB", (8, 8), "red").save(buf, format="JPEG")
        resp = client.post(
            "/v1/describe",
            json={"image_b64": base64.b64encode(buf.getvalue()).decode()},
        )
        assert resp.status_code == 200
        described = resp.json()
        assert set(described) == {"tags_en", "description_en"}
        assert 1 <= len(described["tags_en"]) <= 8
        assert isinstance(described["description_en"], str)
