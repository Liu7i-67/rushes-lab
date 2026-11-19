"""用户级偏好 — GET/PUT /api/v1/me/preferences(2026-11-19 设置页收拢包)。

需求:`docs/qdev/2026-11-19-settings-mcp-collapse-folders.md`(§6 接口定义,
F10/F11)。Web/App 双端读写同一份服务端偏好;鉴权与 ``/auth/me`` 同源
(``deps.get_current_user``:cookie session → PAT → dev ``X-User-Id``),
401/422 同既有语义;纯 UI 偏好**不写审计事件**(D6)。

存储:``user_prefs`` 每 user 恰一行,prefs JSONB 存已知键全集(缺键由
``_effective`` 按 ``DEFAULT_PREFS`` 补默认)。写侧行级 upsert:
SELECT ... FOR UPDATE → 无则 INSERT、有则合并 UPDATE
(同一用户并发首写理论上可撞 PK —— 单用户双击窗口,纯偏好可接受)。

加新偏好键三处同步:本模块 ``DEFAULT_PREFS`` 补默认 + models 里
``PreferenceUpdateIn`` / ``PreferencesOut`` 各补一个字段;端点与合并逻辑零改动。
"""
from __future__ import annotations

import logging
import uuid
from typing import Any

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import UserPref
from app.deps import CurrentUser, get_current_user
from app.models import PreferenceUpdateIn, PreferencesOut

log = logging.getLogger(__name__)
router = APIRouter()

# 已知偏好键与默认值全集(唯一扩键点;GET 缺键补默认,PUT 仅合并已知键)
DEFAULT_PREFS: dict[str, bool] = {"folder_tree_default_collapsed": False}


def _effective(prefs: dict[str, Any] | None) -> dict[str, bool]:
    """DB 行 prefs(可能缺键 / 行不存在传 None)→ 已知键全集(缺省补默认)。"""
    stored: dict[str, Any] = prefs or {}
    return {key: bool(stored.get(key, default)) for key, default in DEFAULT_PREFS.items()}


async def _load_prefs(db: AsyncSession, user_id: uuid.UUID) -> dict[str, bool]:
    """读本人偏好行 → 补齐默认值后的全集;无行 = 全默认(F11:存量用户零迁移)。"""
    row = (
        await db.execute(select(UserPref).where(UserPref.user_id == user_id))
    ).scalar_one_or_none()
    return _effective(row.prefs if row is not None else None)


@router.get("", response_model=PreferencesOut)
async def get_my_preferences(
    cur: CurrentUser = Depends(get_current_user),  # noqa: B008  repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008
) -> PreferencesOut:
    """本人偏好全集(200;无偏好行用户返回全默认 false)。"""
    return PreferencesOut(**await _load_prefs(db, cur.id))


@router.put("", response_model=PreferencesOut)
async def update_my_preferences(
    body: PreferenceUpdateIn,
    cur: CurrentUser = Depends(get_current_user),  # noqa: B008
    db: AsyncSession = Depends(get_db),  # noqa: B008
) -> PreferencesOut:
    """部分更新本人偏好(None 字段跳过,未知键忽略)→ 200 返回合并后全集。

    行级 upsert:SELECT ... FOR UPDATE 锁行 → 无则 INSERT、有则合并 UPDATE
    (updated_at 经 ORM onupdate 刷新);commit 由端点负责(routers 惯例,
    见 auth_tokens.py)。422 只来自 body 非法(pydantic,同既有语义)。
    """
    changes = {
        key: value
        for key, value in body.model_dump().items()
        if value is not None and key in DEFAULT_PREFS
    }
    locked = (
        await db.execute(
            select(UserPref).where(UserPref.user_id == cur.id).with_for_update()
        )
    ).scalar_one_or_none()
    merged = {**_effective(locked.prefs if locked is not None else None), **changes}
    if locked is None:
        db.add(UserPref(user_id=cur.id, prefs=merged))
    else:
        locked.prefs = merged  # 整体重赋值(JSONB 原地改不进 UPDATE,勿改 in-place)
    await db.commit()
    if changes:
        log.info("user preferences updated user_id=%s keys=%s", cur.id, sorted(changes))
    return PreferencesOut(**merged)
