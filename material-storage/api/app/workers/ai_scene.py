"""视频场景检测纯函数模块(方案 §8.4-3/§8.4-5;无 IO,表驱动单测可跑)。

ffmpeg 侧的全部纯计算收敛于此(showinfo 解析 / 切点聚合 / interval 分段 / 帧位
规划),ai_pipeline 只负责 subprocess 与 MinIO/HTTP IO。判定规则与正本逐条对应:

- showinfo pts_time 解析(§17-5):科学计数法容错、缺字段行跳过、多切点保序;
- interval 分段(§8.4-3):``<10s 或 >30min`` 兜底路径,段数恒 ≤ max_segments;
- 切点聚合(§8.4-4):相邻切点 <5s 合并;时长 >5min 且切点 <3 的单镜头长视频叠加
  均匀锚点 ``max(60s, duration/30)``;段数 > ai_max_segments 时反复合并「时长最短的
  相邻段对」直到达标(showinfo 不输出 scene 分数,最短段合并是确定性降级);
- 帧位规划(§8.4-5):段数 ≤20:3 帧 / ≤40:2 帧 / >40:1 帧,总帧数硬封顶
  ai_max_frames,超出从末段起逐段降为 1 帧直到达标(仍超则从末段起清零)。
"""
from __future__ import annotations

import itertools
import math
import re

# ─── 常量(与 §8.4 文本一致;ai_pipeline 传参可覆盖)──────────────────────────
CUT_MIN_GAP_S = 5.0        # 相邻切点 <5s 合并
ANCHOR_TRIGGER_DUR_S = 300.0   # 时长 >5min 才补均匀锚点
ANCHOR_TRIGGER_MIN_CUTS = 3    # 且切点 <3(单镜头长视频)
MIN_SEG_S = 0.5            # 段最短有效时长(碎屑段丢弃)
FRAME_FRACTIONS = {1: (0.5,), 2: (0.0, 0.5), 3: (0.0, 0.5, 0.95)}
ADAPT_SHORT_SEGMENTS = 20      # 段数 ≤20 → 每段 3 帧
ADAPT_MID_SEGMENTS = 40        # 段数 ≤40 → 每段 2 帧,否则 1 帧

# showinfo 行形如:
#   [Parsed_showinfo_0 @ 0x...] n:   0 pts:    102 pts_time:4.25 pos:  ... 248832
# pts_time 支持十进制/科学计数法(§17-5);缺 pts_time 的行(帧头乱序/截断)跳过
_PTS_TIME_RE = re.compile(r"pts_time:\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)")


def parse_showinfo_pts_times(stderr_text: str) -> list[float]:
    """从 ffmpeg ``-vf select,showinfo`` stderr 提取全部切点(pts_time,秒)。

    容错(§17-5):非 showinfo 行忽略;pts_time 缺失/不可解析的行跳过;科学计数法
    (``1.04167e+03``)正常解析;输出按时间升序(ffmpeg 输出本身有序,排序只是防御)。
    """
    cuts: list[float] = []
    for match in _PTS_TIME_RE.finditer(stderr_text or ""):
        try:
            value = float(match.group(1))
        except ValueError:      # 正则已约束数字形态,防御式保留
            continue
        if math.isfinite(value) and value >= 0:
            cuts.append(value)
    return sorted(cuts)


def plan_interval_segments(duration_s: float, interval_s: float,
                           max_segments: int) -> list[tuple[float, float]]:
    """固定间隔分段(§8.4-3 兜底):返回 [(start, end)] 秒。

    段数恒 ≤ max_segments(超限改均匀切分,等价于 interval=dur/n);末段截到
    duration;零长尾段丢弃。
    """
    if duration_s <= 0:
        return []
    interval = max(float(interval_s), MIN_SEG_S)
    count = min(math.ceil(duration_s / interval), int(max_segments))
    if count <= 0:
        count = 1
    step = duration_s / count
    return [(round(i * step, 3), round((i + 1) * step, 3)) for i in range(count)]


def segment_boundaries(cuts: list[float], duration_s: float,
                       *, min_seg_s: float = MIN_SEG_S) -> list[tuple[float, float]]:
    """切点 → 相邻段 [(start,end)]:切点钳到 (0,dur) 内、碎屑段(<min_seg_s)丢弃。"""
    pts = sorted({c for c in cuts if 0 < c < duration_s})
    bounds = [0.0, *pts, float(duration_s)]
    segments: list[tuple[float, float]] = []
    for start, end in itertools.pairwise(bounds):
        if end - start >= min_seg_s:
            segments.append((start, end))
    return segments


def merge_until_within_cap(segments: list[tuple[float, float]],
                           max_segments: int) -> list[tuple[float, float]]:
    """段数超上限时反复合并「时长最短的相邻段对」直到达标(§8.4-4 确定性降级)。

    最短段并入右邻(末段并入左邻);同长取最左(排序稳定)。段数 ≤ 上限原样返回。
    """
    segs = list(segments)
    while len(segs) > max_segments > 0:
        idx = min(range(len(segs)), key=lambda i: (segs[i][1] - segs[i][0], i))
        if idx + 1 < len(segs):
            merged = (segs[idx][0], segs[idx + 1][1])
            segs[idx:idx + 2] = [merged]
        else:
            segs[idx - 1:idx + 1] = [(segs[idx - 1][0], segs[idx][1])]
    return segs


def aggregate_cut_points(cuts: list[float], duration_s: float, *,
                         max_segments: int,
                         min_gap_s: float = CUT_MIN_GAP_S) -> list[tuple[float, float]]:
    """切点聚合(§8.4-4 全链):<5s 合并 → 单镜头长视频补均匀锚点 → 段数封顶合并。

    - 相邻切点 <min_gap 合并(保首个,其后不足间距的顺次丢弃);
    - duration >5min 且切点 <3:按 ``max(60s, duration/30)`` 强制补切(无人机缓慢
      运镜常态,防场景路径产出整条 1 段、描述粒度过粗);
    - 段数 > max_segments:合并时长最短的相邻段对直到达标。
    """
    pts = sorted({c for c in cuts if 0 < c < duration_s})
    kept: list[float] = []
    for c in pts:
        if not kept or c - kept[-1] >= min_gap_s:
            kept.append(c)
    if duration_s > ANCHOR_TRIGGER_DUR_S and len(kept) < ANCHOR_TRIGGER_MIN_CUTS:
        anchor_interval = max(60.0, duration_s / 30.0)
        anchors = _arange(anchor_interval, duration_s)
        kept = sorted({*kept, *anchors})
        # 锚点并入后重新按间距合并(锚点与原切点可能 <5s 相邻)
        deduped: list[float] = []
        for c in kept:
            if not deduped or c - deduped[-1] >= min_gap_s:
                deduped.append(c)
        kept = deduped
    return merge_until_within_cap(segment_boundaries(kept, duration_s), max_segments)


def _arange(step: float, stop: float) -> list[float]:
    """step, 2*step, ... < stop(不含端点;浮点步进防漂移用乘法)。"""
    if step <= 0:
        return []
    out: list[float] = []
    k = 1
    while k * step < stop:
        out.append(round(k * step, 3))
        k += 1
    return out


def plan_frame_positions(segments: list[tuple[float, float]],
                         max_frames: int) -> list[list[float]]:
    """每段帧位规划(§8.4-5):自适应 3/2/1 帧 + 总帧数硬封顶。

    自适应按段数:≤20 → 3 帧/段,≤40 → 2 帧/段,否则 1 帧/段。封顶从末段起逐段
    降为 1 帧直到达标;全部为 1 仍超(病态配置 max_frames < 段数)则从末段起清零
    (清零段由调用方按无帧段降级处理)。帧位 = 段首/中(3 帧含段尾近端 0.95,
    避免抽到下段首帧),返回各段绝对秒时刻。
    """
    n = len(segments)
    if n == 0 or max_frames <= 0:
        return [[] for _ in segments]
    if n <= ADAPT_SHORT_SEGMENTS:
        per = 3
    elif n <= ADAPT_MID_SEGMENTS:
        per = 2
    else:
        per = 1
    counts = [per] * n
    total = per * n
    # 封顶 pass 1:从末段起逐段降为 1 帧(§8.4-5)
    for i in range(n - 1, -1, -1):
        if total <= max_frames:
            break
        if counts[i] > 1:
            total -= counts[i] - 1
            counts[i] = 1
    # 封顶 pass 2(病态配置):从末段起逐段清零
    for i in range(n - 1, -1, -1):
        if total <= max_frames:
            break
        if counts[i] == 1:
            counts[i] = 0
            total -= 1
    out: list[list[float]] = []
    for (start, end), count in zip(segments, counts, strict=True):
        fractions = FRAME_FRACTIONS.get(count, ())
        out.append([round(start + f * (end - start), 3) for f in fractions])
    return out
