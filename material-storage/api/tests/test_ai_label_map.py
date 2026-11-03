"""工作包 I 词表汉化层单测(表驱动;需求 §5-11:映射/词形归一/未命中保留/版本并入)。

纯函数零 IO,直接跑:cd material-storage/api && python -m pytest tests/test_ai_label_map.py -q
"""
from __future__ import annotations

import pytest

from app.services.ai_label_map import (
    _LABEL_MAP,
    map_version_suffix,
    translate_tags,
    unmapped_ratio,
)

# 表驱动用例:(用例名, 输入 tags_en, 期望输出)
# 覆盖:七组基础映射 / 复数 s·es·ies / -ing 直接去尾·双写·e 还原 / -ed /
# 大小写 / 未命中保留 / 去重保序 / 连字符 / 多词短语 / 空输入。
CASES: list[tuple[str, list[str], list[str]]] = [
    # ── 基础映射(每组抽 1)──
    ("基础-场景", ["stage"], ["舞台"]),
    ("基础-人物", ["woman"], ["女性"]),
    ("基础-物体", ["camera"], ["相机"]),
    ("基础-动作", ["jump"], ["跳跃"]),
    ("基础-风格光线", ["aerial"], ["航拍"]),
    ("基础-材质颜色", ["metallic"], ["金属"]),
    ("基础-医美高频", ["operating room"], ["手术室"]),
    # ── 复数归一 ──
    ("复数-s", ["plants"], ["植物"]),
    ("复数-es", ["boxes"], ["盒子"]),
    ("复数-es-ch结尾", ["watches"], ["手表"]),
    ("复数-ies", ["babies"], ["婴儿"]),
    ("复数-多词短语", ["group photos"], ["合影"]),
    ("不规则复数-显式收录", ["children", "women", "people"], ["儿童", "女性", "人物"]),
    # ── -ing / -ed 归一(仅去后命中词表才采纳)──
    ("ing-直接去尾", ["walking", "reading"], ["行走", "阅读"]),
    ("ing-双写辅音容错", ["running", "sitting", "swimming"], ["跑步", "坐", "游泳"]),
    ("ing-e还原", ["smiling", "dancing", "waving"], ["微笑", "舞蹈", "挥手"]),
    ("ed-直接去尾", ["jumped"], ["跳跃"]),
    ("ed-e还原", ["posed"], ["摆姿势"]),
    # ── 大小写与未命中 ──
    ("大小写归一", ["Stage", "PLANT"], ["舞台", "植物"]),
    ("未命中-保留英文", ["quantumflux"], ["quantumflux"]),
    ("未命中-保留小写化原样", ["GalaxyNote"], ["galaxynote"]),
    # ── 去重保序 ──
    ("去重-精确重复", ["stage", "plant", "stage"], ["舞台", "植物"]),
    ("去重-形态归一合并", ["plant", "plants"], ["植物"]),
    ("去重-大小写合并", ["Tree", "tree"], ["树"]),
    ("混合-命中与未命中保序", ["stage", "zzz", "camera"], ["舞台", "zzz", "相机"]),
    # ── 连字符与多词短语 ──
    ("连字符-展开匹配", ["close-up"], ["特写"]),
    ("多词短语", ["close up", "night view", "black and white"], ["特写", "夜景", "黑白"]),
    # ── 空与空白 ──
    ("空列表", [], []),
    ("空白项-跳过", ["", "   "], []),
]


@pytest.mark.parametrize(("name", "tags_en", "expected"), CASES, ids=[c[0] for c in CASES])
def test_translate_tags_table(name: str, tags_en: list[str], expected: list[str]) -> None:
    assert translate_tags(tags_en) == expected, name


def test_translate_tags_none_and_non_str() -> None:
    """None 输入与非字符串项容错(调用方传入畸形数据不炸)。"""
    assert translate_tags(None) == []
    assert translate_tags(["stage", 123, None, "camera"]) == ["舞台", "相机"]  # type: ignore[list-item]


def test_map_version_suffix_stable() -> None:
    """版本后缀稳定(词表 v1 = lm1),供 model_version 并入(正本 §6)。"""
    assert map_version_suffix() == "lm1"


@pytest.mark.parametrize(
    ("tags_en", "expected"),
    [
        (["stage", "camera"], 0.0),  # 全命中
        (["xx", "yy"], 1.0),  # 全未命中
        (["stage", "zz"], 0.5),  # 半命中
        ([], 0.0),  # 空
        (None, 0.0),  # None 容错
        (["", "stage"], 0.0),  # 空白项不计入统计
    ],
    ids=["全命中", "全未命中", "半命中", "空", "None", "空白项不计"],
)
def test_unmapped_ratio(tags_en: list[str] | None, expected: float) -> None:
    assert unmapped_ratio(tags_en) == expected


def test_vocab_sanity() -> None:
    """词表自检:规模 ≥200;键全小写无首尾空白;值非空中文。"""
    assert len(_LABEL_MAP) >= 200
    assert all(k == k.lower() == k.strip() for k in _LABEL_MAP)
    assert all(v and v.strip() for v in _LABEL_MAP.values())
