"""OpenFGA subject 串 → 显示名称的批量解析 helper(批次一 B:组名显示)。

「用户组 {id[:12]}…」兜底原先分散在 4 个列表接口(project members / project grants
overview / folder members / folder grants),group 从未 join groups.name;收敛到这里
统一批量查 users + groups。主体类型(用户/群组/部门)由前端 KindTag 展示,
名称不再拼「用户组/部门」前缀。
"""
from __future__ import annotations

import uuid
from typing import TypedDict

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Group, User


class SubjectNameInfo(TypedDict):
    name: str
    found: bool  # True=users/groups 表命中;False=已删/存量非 UUID(走 id 兜底)


def _parse_uuids(ids: list[str] | set[str]) -> list[uuid.UUID]:
    """subject_id 字符串 → UUID,容错非法值(存量 open_id / grp_editors 等)直接跳过。"""
    out: list[uuid.UUID] = []
    for s in ids:
        try:
            out.append(uuid.UUID(s))
        except ValueError:
            continue
    return out


async def resolve_subject_names(
    db: AsyncSession, subjects: list[str],
) -> dict[str, SubjectNameInfo]:
    """OpenFGA subject 串 → {name, found}。批量查 users + groups;
    未命中(主体已删/存量非 UUID)name 回退 sid[:12]+"…"、found=False。

    subject 形如 user:<uuid> / group:<uuid>#member(部门存量按原样走 id 兜底)。
    返回 dict 必含传入的每个 subject,调用方无需二次兜底。
    """
    # 先按兜底预填(found=False),db 命中后回填覆盖
    out: dict[str, SubjectNameInfo] = {}
    kind_sids: dict[str, tuple[str, str]] = {}  # subject → (kind, sid)
    user_sids: list[str] = []
    group_sids: list[str] = []
    for subject in subjects:
        kind, _, rest = subject.partition(":")
        sid = rest.rsplit("#", 1)[0]
        kind_sids[subject] = (kind, sid)
        out[subject] = {"name": sid[:12] + "…", "found": False}
        if kind == "user":
            user_sids.append(sid)
        elif kind == "group":
            group_sids.append(sid)

    if user_uuids := _parse_uuids(user_sids):
        res = await db.execute(select(User.id, User.name).where(User.id.in_(user_uuids)))
        name_by_sid = {str(row[0]): row[1] for row in res.all()}
        for subject, (kind, sid) in kind_sids.items():
            if kind == "user" and sid in name_by_sid:
                out[subject] = {"name": name_by_sid[sid], "found": True}

    if group_uuids := _parse_uuids(group_sids):
        res = await db.execute(
            select(Group.id, Group.name).where(Group.id.in_(group_uuids))
        )
        name_by_sid = {str(row[0]): row[1] for row in res.all()}
        for subject, (kind, sid) in kind_sids.items():
            if kind == "group" and sid in name_by_sid:
                out[subject] = {"name": name_by_sid[sid], "found": True}

    return out
