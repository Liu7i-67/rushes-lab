"""Upload stats service — 文件上传数量统计聚合(2026-11-06 stats-panel-upload-stats §4.2-§4.4)。

依托 assets 单表(无类型列,分类由 content_type + filename/minio_key 推导)做只读
聚合,不新建表、不写埋点;回答「窗口内每项目四分类各上传多少 + 全选汇总」。

约定(需求 docs/qdev/2026-11-06-stats-panel-upload-stats.md):
- 分类规则只在 SQL 实现(单点,无 Python 双实现,方案 D4):CASE 规则序
  livp > 口播视频 > 生活视频 > 图片,单条 sa.case 每条资产恰好落一桶,
  四桶 count(*) FILTER 复用同一表达式 → total = 四桶之和 ≡ count(*);
  扩展名清单由 thumb_exts.VIDEO_EXTS/IMAGE_EXTS 生成(单一事实来源,勿手抄)
- 软删不计数(D6,deleted_at IS NULL);归档/软删项目不进任何口径(D3,admin
  分支同样适用,不因直通而放宽)
- 数据权限 = 盲搜同款 folder 级零泄露(D3;系统 admin true() 直通):
  list_objects(can_view, folder) ∪ list_objects(can_view, sensitive_folder)
  ∪ public 项目非敏感 folder —— public 分支同加项目活性条件(刻意收紧,
  偏离盲搜先例 assets.py:679-687 的只过滤 visibility+is_sensitive,方案 §4.4 明示)
- rows = 项目宇宙(GET /projects 同口径,零填充)∪ 计数面补充(仅 folder 级
  grant、项目不可见但有数即现,不零填充);project_ids 显式给出时对两者一律
  取交集,不可见/归档/软删 id 静默丢弃(不 403 防探测,与盲搜一致)
- asset 级单文件授权(explicit_downloader)不在计数面:盲搜对它本就「宁漏勿泄」
  不纳入(assets.py:648-649),本端点沿同一保守口径,持单文件授权者可下载该
  资产但其不计入统计 —— 防后来者当 bug「修」
- 时间归一固定 +08:00 偏移而非 ZoneInfo("Asia/Shanghai"):不依赖运行环境
  tzdata 的完备性与版本漂移(zoneinfo 全仓零先例);Asia/Shanghai 自 1991 年起
  无夏令时,固定偏移语义等价、零新依赖。与 usage_stats daily 的 SQL 内
  AT TIME ZONE 'Asia/Shanghai' 同偏移口径(机制不同:那边吃 PG 时区库)
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from fastapi import HTTPException
from sqlalchemy import ColumnElement, case, func, or_, select, true
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Asset, Folder, Project
from app.services.permissions import PermissionsService
from app.services.thumb_exts import IMAGE_EXTS, VIDEO_EXTS

# ─── 时间归一常量(§4.2)───────────────────────────────────────────────────────
# 固定 +08:00 偏移(勿改 ZoneInfo,理由见模块 docstring)。
CN_TZ = timezone(timedelta(hours=8))
# date_to - date_from > 365 天 → 422(纯 date 减法不会溢出);窗口最长 366 自然日,
# **较 usage 紧一天**(usage 是 to - from > 366 才 422,差异明示勿「对齐」,§4.2)。
_MAX_WINDOW_DAYS = 365
_MAX_PROJECT_IDS = 200

# ─── 分类表达式常量(§4.3;D4,与 thumb_exts 单一事实来源)─────────────────────
# ~* = PG 大小写不敏感正则;扩展名清单由 thumb_exts 常量生成(改常量即两侧同步)。
VIDEO_EXT_RE = r"\.(" + "|".join(sorted(e.lstrip(".") for e in VIDEO_EXTS)) + r")$"
IMAGE_EXT_RE = r"\.(" + "|".join(sorted(e.lstrip(".") for e in IMAGE_EXTS)) + r")$"
# 口播关键词单点常量:「口播视频」只作用于视频(非视频文件名含关键词仍按自身
# 类别归类,CASE 规则序保证);ILIKE 对 CJK 无大小写问题。
VOICE_OVER_VIDEO_KEYWORD = "口播视频"

# 视频判定与 is_video_asset 同构(mime 前缀 OR filename 扩展名;.ts 刻意不在
# VIDEO_EXTS —— mime 是 video/* 时仍按 mime 落「生活视频」,非 video/* mime 落「其他」)。
_VIDEO_EXPR = Asset.content_type.like("video/%") | Asset.filename.op("~*")(VIDEO_EXT_RE)
# 图片判定与 is_image_asset 同构(image/* 且非 svg OR 扩展名;.svg 同上边界口径)。
_IMAGE_EXPR = (Asset.content_type.like("image/%") & (Asset.content_type != "image/svg+xml")) | (
    Asset.filename.op("~*")(IMAGE_EXT_RE)
)
# livp:.livp 后缀(livp 不属于 image,thumb_exts.is_livp_asset 同口径)。
_LIVP_EXPR = Asset.filename.op("~*")(r"\.livp$")
# 口播关键词:filename / minio_key 任一命中即算。minio_key = folder.minio_prefix +
# '/' + filename(assets.py:197),filename 分支天然被 minio_key 分支覆盖;保留
# 双分支作防御性冗余(两字段理论上独立演进),勿删 —— 后读者勿误以为必须两字段
# 同时含关键词(方案 §4.3 明示)。
_VOICE_KW_EXPR = Asset.filename.ilike(f"%{VOICE_OVER_VIDEO_KEYWORD}%") | Asset.minio_key.ilike(
    f"%{VOICE_OVER_VIDEO_KEYWORD}%",
)

# 桶互斥:单条 CASE 按优先级落桶。不用四条独立布尔 FILTER —— content_type 是
# 客户端可控值(上传直传),content_type=image/png + .mp4 文件名的资产会同时命中
# 图片桶与视频桶,致 total ≠ count(*);CASE 恰好落一桶,恒相等。livp 分支置于
# video 之前:与上传派发优先级 livp > image > video 同构(assets.py:353-369),
# .livp 恒落生活图文(需求:livp 算生活图文),即便客户端给了 video/* mime 也不抢跑。
_CATEGORY_CASE = case(
    (_LIVP_EXPR, "life_images"),  # livp 最先
    (_VIDEO_EXPR & _VOICE_KW_EXPR, "voice_videos"),  # 口播视频次之
    (_VIDEO_EXPR, "life_videos"),
    (_IMAGE_EXPR, "life_images"),  # 普通图片
    else_="other",
)

_ZERO_BUCKETS: dict[str, int] = {
    "life_images": 0,
    "voice_videos": 0,
    "life_videos": 0,
    "others": 0,
    "total": 0,
}


def _buckets(total: int, life_images: int, voice_videos: int, life_videos: int, others: int) -> dict[str, int]:
    return {
        "life_images": life_images,
        "voice_videos": voice_videos,
        "life_videos": life_videos,
        "others": others,
        "total": total,
    }


def normalize_window(date_from: date, date_to: date) -> tuple[datetime, datetime]:
    """日粒度入参 → Asia/Shanghai 归一半开区间 [起始日 00:00, 结束日次日 00:00)(§4.2)。

    等价于「起始日 00:00:00 ~ 结束日 23:59:59」;服务端归一避免客户端时区/格式
    漂移,天然规避 usage_stats 的 naive-422 一族问题。

    校验顺序写死(§4.2):
      1. date_from > date_to → 422;
      2. date_to - date_from > 365 天 → 422(纯 date 减法,不会溢出);
      3. combine 包 try/except OverflowError → 422 —— 前两步拦不住
         date_from=9999-01-01 & date_to=9999-12-31(差 363 ≤ 365 通过校验,但
         date_to + timedelta(days=1) 越过 date.max 抛 OverflowError,不兜则 500)。
         守卫只用 try/except 主方案,勿写「date_to >= date.max - 1 天先行 422」
         之类替代表述(会误伤 9999-12-30 这一可正常处理的日期,off-by-one)。
    """
    if date_from > date_to:
        raise HTTPException(422, "date_from 必须早于或等于 date_to")
    if date_to - date_from > timedelta(days=_MAX_WINDOW_DAYS):
        raise HTTPException(
            422,
            f"日期窗口过长:date_from 与 date_to 相差不能超过 {_MAX_WINDOW_DAYS} 天",
        )
    try:
        from_dt = datetime.combine(date_from, time.min, tzinfo=CN_TZ)
        to_dt = datetime.combine(date_to + timedelta(days=1), time.min, tzinfo=CN_TZ)
    except OverflowError:
        raise HTTPException(422, "date_to 超出可表示日期范围") from None
    return from_dt, to_dt


def parse_project_ids(raw: str | None) -> list[uuid.UUID] | None:
    """project_ids 单参数逗号串 → UUID 列表(§4.1 契约;None = 全部 in-scope)。

    - **单参数 str + 手工 split(',')**(勿声明 List[UUID] = Query(None) —— 那是
      重复参数形态 ?a&b,逗号串会直接 422 与契约不符;重复参数形态在 str Query
      下 starlette 静默取末值,非正式契约、行为不保证);
    - 空串(strip 后为空)视同缺省 = None(全部,防第三方调用踩 422);
    - 非法 UUID → 422(格式错误属参数校验,不属权限静默);
    - 上限 200 个,超限 422(恰 200 放行)。
    """
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    ids: list[uuid.UUID] = []
    for part in raw.split(","):
        try:
            ids.append(uuid.UUID(part))
        except ValueError:
            raise HTTPException(422, f"project_ids 含非法 UUID:{part!r}") from None
    if len(ids) > _MAX_PROJECT_IDS:
        raise HTTPException(422, f"project_ids 最多 {_MAX_PROJECT_IDS} 个")
    return ids


class UploadStatsService:
    """文件上传数量统计(只读,无写入副作用);对外仅 stats() 一个入口。"""

    def __init__(self, session: AsyncSession):
        self._session = session

    async def stats(
        self,
        *,
        from_dt: datetime,
        to_dt: datetime,
        project_ids: list[uuid.UUID] | None,
        user_subject: str,
        is_admin: bool,
        permissions: PermissionsService,
    ) -> dict[str, Any]:
        """聚合统计(§4.1 响应契约;排序与 summary 均在此单点实现)。

        project_ids:None = 全部 in-scope;显式给出时对宇宙与补充项目一律取交集,
        不可见/归档/软删 id 静默丢弃(D7/§4.4)。
        """
        folder_filter, zero_reachable = await self._folder_filter(
            user_subject=user_subject, is_admin=is_admin, permissions=permissions,
        )

        # ── 行集合第一层:项目宇宙(零填充基准,GET /projects 同口径)──────────
        # admin = 全部活性项目;非 admin = list_objects(can_view, project) ∪ public,
        # 同口径过滤归档/软删(routers/projects.py:650-677 逐字同款)。
        universe_stmt = select(Project.id, Project.code, Project.name).where(
            Project.is_archived.is_(False),
            Project.deleted_at.is_(None),
        )
        if not is_admin:
            member_ids = await permissions.list_objects(
                user_subject=user_subject, relation="can_view", object_type="project",
            )
            member_uuids = [uuid.UUID(s) for s in member_ids]
            universe_stmt = universe_stmt.where(
                or_(
                    Project.id.in_(member_uuids) if member_uuids else False,
                    Project.visibility == "public",
                ),
            )
        if project_ids is not None:
            # 交集静默丢弃:不可见/归档/软删 id 从宇宙里自然消失(不 403 防探测)
            universe_stmt = universe_stmt.where(Project.id.in_(project_ids))
        universe_rows = (await self._session.execute(universe_stmt)).all()

        # ── 行集合第二层:计数面(folder 级 grant 补充 + 窗口分类计数)─────────
        counts_by_pid: dict[uuid.UUID, dict[str, Any]] = {}
        if not zero_reachable:
            # 零可达 folder → 跳过计数 SQL,rows 仍按宇宙零填充(rows 恒返回数组,
            # 宇宙为空时为 [],勿造 sentinel,§4.4)
            count_stmt = (
                select(
                    Folder.project_id,
                    Project.code,
                    Project.name,
                    # 四桶 count(*) FILTER 复用同一 _CATEGORY_CASE(桶互斥:
                    # 恰好落一桶 → total = 四桶之和 ≡ count(*))
                    func.count().filter(_CATEGORY_CASE == "life_images").label("life_images"),
                    func.count().filter(_CATEGORY_CASE == "voice_videos").label("voice_videos"),
                    func.count().filter(_CATEGORY_CASE == "life_videos").label("life_videos"),
                    func.count().filter(_CATEGORY_CASE == "other").label("others"),
                )
                .join(Folder, Asset.folder_id == Folder.id)
                .join(Project, Folder.project_id == Project.id)
                .where(
                    Asset.deleted_at.is_(None),  # 软删不计数(D6;彻底删已无行)
                    Project.is_archived.is_(False),  # 归档/软删项目不计(D3;admin
                    Project.deleted_at.is_(None),  #   分支同样适用,不因直通而放宽)
                    Asset.created_at >= from_dt,  # 半开区间 [from_dt, to_dt)
                    Asset.created_at < to_dt,
                    folder_filter,
                )
                .group_by(Folder.project_id, Project.code, Project.name)
                # GROUP BY 须带 p.code/p.name —— PG 函数依赖推断只在 GROUP BY 表
                # 自身主键时生效,只按 f.project_id 分组直接 SELECT p.* 会 42803;
                # code/name 与 project_id 1:1,加入分组不改语义(§4.4)
            )
            if project_ids is not None:
                count_stmt = count_stmt.where(Folder.project_id.in_(project_ids))
            count_rows = (await self._session.execute(count_stmt)).all()
            for row in count_rows:
                pid, code, name, li, vv, lv, ot = row
                counts_by_pid[pid] = {
                    "code": code,
                    "name": name,
                    "buckets": _buckets(
                        total=li + vv + lv + ot, life_images=li, voice_videos=vv,
                        life_videos=lv, others=ot,
                    ),
                }

        # ── rows 拼装:宇宙零填充 ∪ 计数面补充(有数即现,不零填充)────────────
        rows: list[dict[str, Any]] = []
        universe_ids: set[uuid.UUID] = set()
        for pid, code, name in universe_rows:
            universe_ids.add(pid)
            buckets = counts_by_pid[pid]["buckets"] if pid in counts_by_pid else _ZERO_BUCKETS
            rows.append({
                "project_id": pid, "project_code": code, "project_name": name, **buckets,
            })
        # 补充行:folder 级 explicit grant 独立于项目级 can_view(store.fga.yaml:112-114)
        # —— 存在「项目不可见但 folder 可见」的用户,其资产已进 folder_filter 计数;
        # 若 rows 严格按项目宇宙会漏出 rows 与 summary,违反 D3「计数面=浏览面」
        # 不变量(盲搜对这些资产本就回显项目名,无新增泄露面)。显式传入这类补充
        # 项目 id 同样合法(按 folder 可达口径计数);计数为 0 时不产生行。
        for pid, meta in counts_by_pid.items():
            if pid in universe_ids:
                continue
            rows.append({
                "project_id": pid, "project_code": meta["code"],
                "project_name": meta["name"], **meta["buckets"],
            })

        # 排序单点实现(§4.1 定死):total desc → project_name asc
        rows.sort(key=lambda r: (-int(r["total"]), str(r["project_name"])))

        # summary = rows 逐列求和(后端为准,前端 Table Summary 同显)
        summary = {
            key: sum(int(r[key]) for r in rows)
            for key in ("life_images", "voice_videos", "life_videos", "others", "total")
        }
        return {"rows": rows, "summary": summary}

    async def _folder_filter(
        self,
        *,
        user_subject: str,
        is_admin: bool,
        permissions: PermissionsService,
    ) -> tuple[ColumnElement[bool], bool]:
        """folder 级数据权限过滤(§4.4,与盲搜 assets.py:667-691 同款 + 活性收紧)。

        返回 (folder_filter, zero_reachable):
        - 系统 admin:true() 直通(活性过滤由计数 SQL 的 JOIN projects 承担);
        - 非 admin:folder_id IN(list_objects(can_view, folder) ∪
          list_objects(can_view, sensitive_folder) ∪ public 项目非敏感 folder);
          public 分支**同加项目活性条件**(is_archived=false 且 deleted_at IS NULL,
          偏离盲搜先例的只过滤 visibility+is_sensitive,§4.4 明示的收紧点);
        - sensitive 口径分主语:未受邀的 sensitive folder 资产不计入(不进 public
          分支、list_objects 不返回未受邀对象,对未受邀者零泄露);受邀的照常计入
          (与盲搜浏览面同口径)。
        - 零可达 folder:zero_reachable=True,调用方跳过计数 SQL(rows 仍按宇宙
          零填充,不返回空集 sentinel)。
        """
        if is_admin:
            return true(), False

        folder_ids: list[uuid.UUID] = []
        for obj_type in ("folder", "sensitive_folder"):
            ids_str = await permissions.list_objects(
                user_subject=user_subject, relation="can_view", object_type=obj_type,
            )
            folder_ids.extend(uuid.UUID(s) for s in ids_str)
        # public 项目非敏感 folder 对组织内可浏览(与 GET /assets、GET /folders/{id}
        # 同语义,盲搜 PR #176 review P1-2);sensitive folder 不在此列 —— 仍只走
        # list_objects(can_view),零泄露语义不变。
        public_rows = await self._session.execute(
            select(Folder.id)
            .join(Project, Folder.project_id == Project.id)
            .where(
                Project.visibility == "public",
                Folder.is_sensitive.is_(False),
                # 本端点刻意收紧(偏离盲搜先例,§4.4 明示):public 分支同加项目
                # 活性 —— 归档/软删项目不进任何口径
                Project.is_archived.is_(False),
                Project.deleted_at.is_(None),
            )
        )
        folder_ids.extend(public_rows.scalars().all())
        folder_ids = list({*folder_ids})  # 去重
        if not folder_ids:
            return true(), True  # 无可达 folder → 结果必为空,不跑计数 SQL
        return Asset.folder_id.in_(folder_ids), False
