"""ai_scene 纯函数表驱动单测(方案 §8.4-3/§8.4-5/§17-5;验收清单 #4)。

覆盖四组:showinfo pts_time 解析(科学计数法/缺字段/多切点)、切点聚合(<5s 合并/
均匀锚点/超上限最短段合并)、interval 分段(段数上限钳制)、帧位规划(自适应 3/2/1
+ ai_max_frames 封顶降级)。
"""
from __future__ import annotations

import itertools
import math

import pytest

from app.workers.ai_scene import (
    aggregate_cut_points,
    parse_showinfo_pts_times,
    plan_frame_positions,
    plan_interval_segments,
    segment_boundaries,
)

# showinfo 行稳定格式(§17-5):stderr 一行一切点
_SHOWINFO_LINE = "[Parsed_showinfo_1 @ 0x55d1c2] n: {n} pts: {pts} pts_time:{t} pos: 248832"


def _showinfo_lines(times: list[float]) -> str:
    out = []
    for i, t in enumerate(times):
        out.append(_SHOWINFO_LINE.format(n=i, pts=int(t * 1024), t=repr(t)))
    return "\n".join(out)


# ─── showinfo pts_time 解析(验收 #4:科学计数法/缺帧/多切点)─────────────────


class TestParseShowinfo:
    @pytest.mark.parametrize(
        ("text", "expected"),
        [
            pytest.param(
                _showinfo_lines([4.25, 12.5, 97.75]),
                [4.25, 12.5, 97.75],
                id="multi_cuts_decimal",
            ),
            pytest.param(
                "n: 0 pts: 1024 pts_time:1.04167e+02 pos:1\n"
                "n: 1 pts: 2048 pts_time:2.05e+02 pos:2",
                [104.167, 205.0],
                id="scientific_notation",
            ),
            pytest.param(
                "n: 0 pts: 1024 pts_time:5.0 pos:1\n"
                "[Parsed_showinfo_1 @ 0x] n: 1 pts: 2048 pos:2\n"  # 缺 pts_time → 跳过
                "frame:0 pts:99\n"
                "n: 2 pts: 4096 pts_time:11.5 pos:3",
                [5.0, 11.5],
                id="missing_pts_time_lines_skipped",
            ),
            pytest.param("", [], id="empty_stderr"),
            pytest.param("no showinfo output at all\n", [], id="no_showinfo_lines"),
            pytest.param(
                "n: 0 pts: 0 pts_time:0.0\nn: 1 pts: 1 pts_time:-3.0\n"
                "n: 2 pts: 2 pts_time:nan\nn: 3 pts: 3 pts_time:8.0",
                [0.0, 8.0],
                id="negative_and_nan_filtered",
            ),
            pytest.param(
                "n: 0 pts: 4 pts_time:9.0\nn: 1 pts: 2 pts_time:3.0",
                [3.0, 9.0],
                id="output_sorted_even_if_stderr_unordered",
            ),
        ],
    )
    def test_parse_table(self, text: str, expected: list[float]) -> None:
        assert parse_showinfo_pts_times(text) == expected

    def test_scientific_pts_matches_decimal_semantics(self) -> None:
        """1.04167e+03 ≈ 1041.67(整数秒的科学计数法形态,浮点容差比较)。"""
        cuts = parse_showinfo_pts_times("n: 0 pts: 1 pts_time:1.04167e+03 pos:1")
        assert len(cuts) == 1 and math.isclose(cuts[0], 1041.67, rel_tol=1e-4)


# ─── interval 分段(§8.4-3:段数恒 ≤ max_segments;末段截到 duration)──────────


class TestPlanIntervalSegments:
    @pytest.mark.parametrize(
        ("duration", "interval", "max_segments", "expected"),
        [
            pytest.param(3600.0, 60.0, 60, 60, id="hour_at_60s_equals_cap"),
            pytest.param(100.0, 30.0, 60, 4, id="ceil_rounding"),
            pytest.param(5.0, 60.0, 60, 1, id="shorter_than_interval"),
            pytest.param(0.0, 60.0, 60, 0, id="zero_duration_empty"),
            pytest.param(-3.0, 60.0, 60, 0, id="negative_duration_empty"),
            pytest.param(6000.0, 60.0, 50, 50, id="max_segments_clamp"),
        ],
    )
    def test_plan_table(self, duration: float, interval: float, max_segments: int,
                        expected: int) -> None:
        segs = plan_interval_segments(duration, interval, max_segments)
        assert len(segs) == expected
        assert all(e > s for s, e in segs)
        if segs:
            assert segs[0][0] == 0.0
            assert math.isclose(segs[-1][1], duration, rel_tol=1e-9, abs_tol=1e-3)

    def test_even_split_when_clamped(self) -> None:
        """钳制后均匀切分(6000/50 = 120s),等价于 interval=dur/n。"""
        segs = plan_interval_segments(6000.0, 60.0, 50)
        assert len(segs) == 50
        assert all(math.isclose(e - s, 120.0, abs_tol=1e-3) for s, e in segs)


# ─── 切点聚合(§8.4-4:<5s 合并 / 均匀锚点 / 超上限最短段合并)──────────────────


class TestAggregateCutPoints:
    def test_close_cuts_merged_below_min_gap(self) -> None:
        """相邻切点 <5s 合并(10/12 → 10),其余保留。"""
        segs = aggregate_cut_points([10.0, 12.0, 40.0, 41.5], 120.0, max_segments=60)
        assert segs == [(0.0, 10.0), (10.0, 40.0), (40.0, 120.0)]

    def test_no_cuts_short_video_single_segment(self) -> None:
        """<5min 无切点 → 整条 1 段(不触发锚点)。"""
        segs = aggregate_cut_points([], 120.0, max_segments=60)
        assert segs == [(0.0, 120.0)]

    def test_long_single_shot_gets_uniform_anchors(self) -> None:
        """时长 >5min 且切点 <3(无人机缓慢运镜)→ 按 max(60, dur/30) 强制补切。"""
        dur = 720.0  # 12min;锚点间隔 = max(60, 24) = 60s
        segs = aggregate_cut_points([100.0], dur, max_segments=60)
        assert len(segs) > 2
        # 锚点与 100.0 落段并存,段并集覆盖全时长且单调
        assert segs[0][0] == 0.0 and math.isclose(segs[-1][1], dur)
        for a, b in itertools.pairwise(segs):
            assert math.isclose(a[1], b[0], abs_tol=1e-6)

    def test_segment_cap_merges_shortest_pairs(self) -> None:
        """段数超上限 → 反复合并时长最短的相邻段对直到达标(确定性降级)。"""
        dur = 100.0
        cuts = [10.0 * i for i in range(1, 10)]  # 10 段各 10s
        segs = aggregate_cut_points(cuts, dur, max_segments=3)
        assert len(segs) == 3
        assert segs[0][0] == 0.0 and math.isclose(segs[-1][1], dur)
        # 合并保序:边界来自原切点集合
        bounds = {b for s in segs for b in s}
        assert bounds <= {0.0, 100.0, *cuts}

    def test_out_of_range_cuts_dropped(self) -> None:
        """切点钳制:0/duration 外的切点丢弃,不产碎屑段。"""
        segs = aggregate_cut_points([0.0, 50.0, 100.0], 100.0, max_segments=60)
        assert segs == [(0.0, 50.0), (50.0, 100.0)]

    def test_segment_boundaries_drops_slivers(self) -> None:
        """碎屑段(<0.5s)丢弃(切点贴边场景)。"""
        assert segment_boundaries([0.05, 40.0], 100.0) == [(0.05, 40.0), (40.0, 100.0)]


# ─── 帧位规划(§8.4-5:自适应 3/2/1 + ai_max_frames 封顶)──────────────────────


def _uniform_segments(n: int, length: float = 10.0) -> list[tuple[float, float]]:
    return [(i * length, (i + 1) * length) for i in range(n)]


class TestPlanFramePositions:
    @pytest.mark.parametrize(
        ("n_segments", "per_segment"),
        [(10, 3), (20, 3), (21, 2), (40, 2), (41, 1), (60, 1)],
        ids=["10seg_3f", "20seg_3f", "21seg_2f", "40seg_2f", "41seg_1f", "60seg_1f"],
    )
    def test_adaptive_frames_per_segment(self, n_segments: int, per_segment: int) -> None:
        positions = plan_frame_positions(_uniform_segments(n_segments), max_frames=10**6)
        assert all(len(p) == per_segment for p in positions)

    def test_frame_positions_inside_segment(self) -> None:
        segs = _uniform_segments(4, 20.0)
        positions = plan_frame_positions(segs, max_frames=10**6)
        for (start, end), times in zip(segs, positions, strict=True):
            assert all(start <= t <= end for t in times)
            assert times[0] == start          # 段首
            assert times[-1] < end            # 段尾近端(0.95,不吞下段首帧)

    def test_single_segment_gets_three_positions(self) -> None:
        """1 段(≤20 段档)→ 3 帧:段首/中/尾近端。"""
        positions = plan_frame_positions([(0.0, 60.0)], max_frames=10**6)
        assert positions == [[0.0, 30.0, 57.0]]

    def test_one_frame_per_segment_is_midpoint(self) -> None:
        """>40 段档每段 1 帧 = 段中点。"""
        positions = plan_frame_positions(_uniform_segments(41, 60.0), max_frames=10**6)
        assert all(len(p) == 1 for p in positions)
        assert positions[0] == [30.0]
        assert positions[5] == [330.0]

    def test_cap_downgrades_from_tail_to_one_frame(self) -> None:
        """10 段 x3 帧 = 30,cap=12 → 末段起逐段降 1 帧:3x4 + 1x? 达标即停。"""
        positions = plan_frame_positions(_uniform_segments(10), max_frames=12)
        counts = [len(p) for p in positions]
        assert sum(counts) <= 12
        assert counts[0] == 3                    # 头部段保持 3 帧
        assert all(c == 1 for c in counts[4:]), counts  # 尾部段已降为 1

    def test_cap_extreme_zeroes_tail_segments(self) -> None:
        """病态配置(max_frames < 段数):全部降 1 仍超 → 从末段起清零。"""
        positions = plan_frame_positions(_uniform_segments(10), max_frames=8)
        counts = [len(p) for p in positions]
        assert sum(counts) == 8
        assert counts == [1, 1, 1, 1, 1, 1, 1, 1, 0, 0]

    def test_empty_segments_and_zero_cap(self) -> None:
        assert plan_frame_positions([], 60) == []
        assert plan_frame_positions(_uniform_segments(3), max_frames=0) == [[], [], []]
