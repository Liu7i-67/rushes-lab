"""ffmpeg/ffprobe 同步执行段(ai_pipeline 拆出;方案 §8.4-2~5/§17-5/§17-16)。

只含 ffmpeg 命令构建 + subprocess 同步执行,**全部由调用方经 asyncio.to_thread 调用**
(§17-16:同步阻塞体冻结事件循环 → 心跳饿死 → sweeper 误接管双跑)。纯计算部分
(showinfo 解析 / 切点聚合 / interval 分段 / 帧位规划)在 app/workers/ai_scene.py,
本模块把解析器的产生侧(命令)与消费侧(解析)分离存放,便于各自单测。

⚠ 日志卫生(§8.4-2,先例 workers/main.py:949-952):异常串(cmd / TimeoutExpired.cmd /
stderr 回显)可能含 presigned URL —— 本模块一律吞异常返回哨兵值,URL 载体不落日志。
"""
from __future__ import annotations

import pathlib
import subprocess

FFMPEG_THREADS = 4               # 2 并发 x4 + ms-ml 8x16 = 136 < 256(§16-R3)
SCENE_DETECT_TIMEOUT_S = 600     # 场景检测 subprocess 硬上限(超时降级 interval)
FRAME_TIMEOUT_S = 60             # 单帧抽取 / ffprobe 硬上限(沿 main.py URL 路径口径)
FRAME_SCALE_PX = 512             # 关键帧分辨率(§12:低分辨率中间档依据)


def ffprobe_duration(url: str) -> float | None:
    """`-show_entries format=duration` 取秒;缺字段/解析失败 None(§17-5 容错)。"""
    cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration",
           "-of", "default=noprint_wrappers=1:nokey=1", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=FRAME_TIMEOUT_S)
        return float(proc.stdout.decode().strip())
    except Exception:  # 含 TimeoutExpired;URL 异常串不落日志
        return None


def scene_detect(url: str, threshold: float) -> list[float] | None:
    """select+showinfo 场景检测一遍(§8.4-4);超时/失败返回 None(调用方降级 interval)。

    切点解析委托 ai_scene.parse_showinfo_pts_times(表驱动单测覆盖)。
    """
    from app.workers import ai_scene
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-threads", str(FFMPEG_THREADS),
           "-i", url, "-vf", f"select='gt(scene,{threshold})',showinfo",
           "-an", "-f", "null", "-"]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=SCENE_DETECT_TIMEOUT_S)
    except Exception:  # TimeoutExpired;不落 e(URL 泄露向量)
        return None
    return ai_scene.parse_showinfo_pts_times(proc.stderr.decode(errors="replace"))


def extract_frame(url: str, at_s: float, out_path: pathlib.Path) -> bytes | None:
    """-ss 精确 seek(input seek)抽单帧 + scale 512 JPEG;失败 None(§8.4-5)。"""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-threads", str(FFMPEG_THREADS), "-ss", f"{at_s:.3f}", "-i", url,
           "-frames:v", "1", "-vf", f"scale={FRAME_SCALE_PX}:-2",
           "-q:v", "3", "-f", "image2", str(out_path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=FRAME_TIMEOUT_S)
    except Exception:
        return None
    if proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
        return out_path.read_bytes()
    return None
