"""folders router — Phase B-2 iter7。

endpoints:
  POST   /api/v1/folders                          — 创建 folder(+bootstrap_folder OpenFGA)
                                                    需 can_edit project
  GET    /api/v1/folders?project_id=...           — 列表 user 可见的 folder
                                                    (普通 folder by project member +
                                                     sensitive_folder by list_objects can_view)
  GET    /api/v1/folders/{id}                     — 单条(can_view)
  PATCH  /api/v1/folders/{id}                     — 改名 / 移动(W4/W5;普通夹 can_upload、
                                                    sensitive 夹 can_admin;reparent 额外
                                                    要求目标侧 can_upload;D1-B 子树 prefix
                                                    重算 + FGA parent tuple 原子交换)
  DELETE /api/v1/folders/{id}                     — 删除空 folder(硬删;无子夹、
                                                    无活跃文件、回收站已清空;
                                                    普通夹 can_upload 或 组级
                                                    file_deleter且can_view / sensitive 夹 can_admin)
  POST   /api/v1/folders/{id}/invite              — sensitive_folder 邀请(can_admin only)
  DELETE /api/v1/folders/{id}/invite/user/{uid}   — 撤销(can_admin only)
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from typing import Any, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import Asset, Folder, Project
from app.deps import (
    get_audit,
    CurrentUser,
    get_current_user,
    get_is_system_admin,
    get_permissions,
    get_request_context,
)
from app.models import FolderCreateIn, FolderInviteIn, FolderOut, FolderUpdateIn
from app.services.audit import AuditService
from app.services.folder_chain import (
    FolderChainError,
    check_prefix_budget,
    check_segment_name,
)
from app.services.notifications import run_notify_folder_invite_bg
from app.services.org import user_is_org_file_deleter
from app.services.permissions import PermissionsService, is_already_exists_error
from app.services.subject_names import resolve_subject_names

log = logging.getLogger(__name__)
router = APIRouter()


@router.post("", response_model=FolderOut, status_code=201)
async def create_folder(
    payload: FolderCreateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> FolderOut:
    user_id = user.id
    # 1) 权限:create folder 需 can_upload(model v4:uploader 隐含创建子目录)
    #    - 在 project 下建 root folder → check project.can_upload
    #    - 在 folder 下建 sub folder → check parent folder.can_upload
    #    系统 admin 直通
    if payload.parent_folder_id:
        parent_folder_for_check = await db.get(Folder, payload.parent_folder_id)
        if not parent_folder_for_check or parent_folder_for_check.project_id != payload.project_id:
            raise HTTPException(400, "parent_folder invalid for this project")
        # sensitive folder 限只能挂 project 一级,sub folder 必须挂普通 folder
        check_type = "sensitive_folder" if parent_folder_for_check.is_sensitive else "folder"
        check_id = str(parent_folder_for_check.id)
    else:
        check_type = "project"
        check_id = str(payload.project_id)

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_upload",
        object_type=check_type,
        object_id=check_id,
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=payload.project_id,
            details={"action": "create_folder", "reason": "openfga can_upload false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to create folder here(需 can_upload)")

    # 业务层 enforce:sensitive folder 只能直挂 project(限一级)
    if payload.is_sensitive and payload.parent_folder_id is not None:
        raise HTTPException(400, "sensitive folder 只能直挂 project 一级")

    # 2) 计算 minio_prefix
    minio_prefix = payload.minio_prefix
    if not minio_prefix:
        if payload.parent_folder_id:
            parent = await db.get(Folder, payload.parent_folder_id)
            assert parent is not None
            minio_prefix = f"{parent.minio_prefix.rstrip('/')}/{payload.name}/"
        else:
            minio_prefix = f"{payload.name}/"

    folder = Folder(
        id=uuid.uuid4(),
        project_id=payload.project_id,
        parent_folder_id=payload.parent_folder_id,
        name=payload.name,
        minio_prefix=minio_prefix,
        is_sensitive=payload.is_sensitive,
    )
    db.add(folder)
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        if "uq_folder_project_prefix" in str(e.orig):
            raise HTTPException(409, "该项目下已存在同名文件夹") from e
        raise HTTPException(400, "folder 创建失败,可能存在路径冲突") from e

    # 3) bootstrap OpenFGA parent tuple
    if payload.is_sensitive:
        # sensitive folder 必直挂 project(已 enforce)
        await permissions.bootstrap_sensitive_folder(
            folder_id=str(folder.id), project_id=str(payload.project_id),
        )
        # 自动给创建者永久 invited_downloader(隐含 can_view + can_download + can_upload)
        # — sensitive model 不让 admin 隐式 can_view,创建者若无显式 invite 会看不到自建 folder(#87)
        await permissions.invite_to_sensitive_folder(
            sensitive_folder_id=str(folder.id),
            subject=user.subject,
            level="downloader",
            duration_seconds=None,
        )
    else:
        # 普通 folder:可 nested,parent 是 project 或 folder
        if payload.parent_folder_id:
            parent_type: Literal["project", "folder"] = "folder"
            parent_id = str(payload.parent_folder_id)
        else:
            parent_type = "project"
            parent_id = str(payload.project_id)
        await permissions.bootstrap_folder(
            folder_id=str(folder.id),
            parent_type=parent_type,
            parent_id=parent_id,
        )

    await audit.write(
        event_type="folder_created",
        actor_user_id=user_id,
        target_project_id=payload.project_id,
        details={
            "folder_id": str(folder.id),
            "name": folder.name,
            "minio_prefix": folder.minio_prefix,
            "is_sensitive": folder.is_sensitive,
            "parent_folder_id": str(payload.parent_folder_id) if payload.parent_folder_id else None,
        },
        **ctx,
    )
    log.info("folder created id=%s name=%s sensitive=%s",
             folder.id, folder.name, folder.is_sensitive)

    await db.refresh(folder)
    return FolderOut.model_validate(folder)


@router.patch("/{folder_id}", response_model=FolderOut)
async def update_folder(
    folder_id: uuid.UUID,
    payload: FolderUpdateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    # dict[str, Any](非裸 dict):**ctx 解包进 audit.write 需值域为 Any,否则
    # mypy 严格模式按 keyword 逐参核对 str|None 会撞 arg-type
    ctx: dict[str, Any] = Depends(get_request_context),
) -> FolderOut:
    """改名 / 移动(重挂父级)— W4/W5(需求 §3.5,方案 §5)。

    权限:普通夹 can_upload(与创建对称,uploader 自主管理目录结构)、sensitive 夹
    can_admin(其 can_upload 实为 downloader 级,门槛太宽);系统 admin 直通;
    reparent 额外要求目标侧 can_upload(目标夹 / 移为一级时 project,与 create 对称)。

    校验(方案 §5.2 清单):段名(禁 / \\ . ..、≤255 字节)+ 拒首尾空白 422;同父同名
    409;子树新 prefix 逐夹过 check_prefix_budget 400;目标须同项目 400;防环 = 源+目标
    按 uuid 定序双行 FOR UPDATE 后显式栈迭代后代检测(禁递归);sensitive 三句式;
    带 explicit grant 的一级夹禁 reparent 409;重算终态与无结构关系的存量自拟 prefix
    相撞 409 预检。

    D1-B:整棵子树 minio_prefix 两段式重算(先挂临时前缀再落目标,防逐行更新途中
    瞬时撞 uq_folder_project_prefix),拓扑序自根向叶;不动物理对象、不动
    assets.minio_key(全部功能按 DB 行计算,方案 §5.1)。

    FGA:单次 WriteRequest(writes=[新 parent], deletes=[旧 parent]) 原子交换,DB
    commit 成功之后执行(删除先例同序),失败重试并记入 folder_moved 审计 details。
    """
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    # ── 0) 意图解析:「是否传了」以 model_fields_set 判定(缺省 ≠ 显式 null)────
    provided = payload.model_fields_set
    if "name" not in provided and "parent_folder_id" not in provided:
        raise HTTPException(400, "name 与 parent_folder_id 至少传一")
    if "name" in provided and payload.name is None:
        raise HTTPException(422, "name 不能为 null(不改名请省略该字段)")
    rename_requested = "name" in provided
    reparent_requested = "parent_folder_id" in provided
    # 显式 null 已在上方 422 拦下,此处 payload.name 收窄为 str
    if rename_requested and payload.name is not None:
        final_name: str = payload.name
    else:
        final_name = folder.name
    renamed = final_name != folder.name
    moved = reparent_requested and payload.parent_folder_id != folder.parent_folder_id

    # ── 1) 权限守门 ────────────────────────────────────────────────────────────
    obj_type = "sensitive_folder" if folder.is_sensitive else "folder"
    gate_relation = "can_admin" if folder.is_sensitive else "can_upload"
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation=gate_relation,
        object_type=obj_type, object_id=str(folder_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={"action": "update_folder", "folder_id": str(folder_id),
                     "reason": f"openfga {gate_relation} false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to update this folder")

    if not renamed and not moved:
        # 显式 no-op(name/parent 与现值一致):直接返回现状,不重算不写审计
        return FolderOut.model_validate(folder)

    # ── 2) 改名段名校验(对齐目录模板口径:拒绝而非静默 strip,admin.py 模板
    #      入库校验同款;「 foo 」这类模板建链永不允许的段名在此拦下)────────────
    if renamed:
        if final_name != final_name.strip():
            raise HTTPException(422, "名称首尾不能包含空白字符")
        try:
            check_segment_name(final_name)
        except FolderChainError as e:
            raise HTTPException(422, str(e)) from e

    # ── 3) reparent 校验:sensitive 三句式 + 目标存在且同项目 + 目标侧 can_upload ──
    target: Folder | None = None
    new_parent_id: uuid.UUID | None = None
    if moved:
        new_parent_id = payload.parent_folder_id
        # 三句式 ①:sensitive 夹必挂 project 一级(FGA parent: [project]),禁移动;
        # sensitive 夹改名(一级内,无结构变化)仍允许(上方 renamed 分支已放行)
        if folder.is_sensitive:
            raise HTTPException(400, "sensitive folder 只能直挂 project 一级,不支持移动")
        if new_parent_id is not None:
            if new_parent_id == folder.id:
                raise HTTPException(409, "不能将文件夹移动到其自身内")
            target = await db.get(Folder, new_parent_id)
            if target is None or target.project_id != folder.project_id:
                # 跨项目移动 MVP 不做(决策:目录移动限同项目)
                raise HTTPException(400, "target_folder invalid for this project")
            # 三句式 ②:目标为 sensitive 夹或其子树 → 禁(敏感父下的普通子夹是 FGA
            # 断链孤儿,除系统 admin 外恒不可见,移入 = 批量制造不可见资产);
            # 三句式 ③(普通夹移出敏感子树 → 允许,修复性操作)不设检查即放行
            if target.is_sensitive:
                raise HTTPException(400, "不支持移动到该目标文件夹内")
            cur_ancestor_id = target.parent_folder_id
            while cur_ancestor_id is not None:
                ancestor = await db.get(Folder, cur_ancestor_id)
                if ancestor is None:
                    break  # 防御:链上并发被删(sensitive 标记不可变,陈旧读无害)
                if ancestor.is_sensitive:
                    raise HTTPException(400, "不支持移动到该目标文件夹内")
                cur_ancestor_id = ancestor.parent_folder_id
        # 目标侧 can_upload(移为一级 → project:can_upload,与 create_folder 对称);
        # 系统 admin 直通。缺此门:仅对某子树有 can_upload 者可把子树嫁接到项目内
        # 任意位置,改变其他成员可见结构
        target_check_type = "project" if new_parent_id is None else "folder"
        target_check_id = str(folder.project_id) if new_parent_id is None else str(new_parent_id)
        target_allowed = is_system_admin or await permissions.check(
            user_subject=user.subject, relation="can_upload",
            object_type=target_check_type, object_id=target_check_id,
        )
        if not target_allowed:
            await audit.write(
                event_type="access_denied",
                actor_user_id=user_id,
                target_project_id=folder.project_id,
                details={"action": "update_folder", "folder_id": str(folder_id),
                         "reason": "openfga target can_upload false"},
                **ctx,
            )
            raise HTTPException(403, "no permission to move folder to this location")
        # 带 explicit grant 的一级夹禁 reparent(MVP,防 grant 管理能力语义漂移:
        # grants API 仅覆盖一级夹(_enforce_level1_folder),移深后授权失去管理入口;
        # 判据 = folder 对象上存在 explicit_* tuple,含审批临时 explicit_downloader)
        if folder.parent_folder_id is None:
            tuples = await permissions.read_all_tuples(
                object_type="folder", object_id=str(folder_id),
            )
            if any(rel.startswith("explicit_") for _, rel, _ in tuples):
                raise HTTPException(
                    409, "该文件夹带有关联授权,不支持移动;请先撤销相关授权后重试",
                )

    # ── 4) 行锁:reparent 时源+目标两行按 uuid 定序逐行 FOR UPDATE ────────────────
    # 对向并发 reparent(T1 移 A 入 B、T2 移 B 入 A)若各自只锁被移动夹,后代检测
    # 读到的是对方提交前快照,双双通过后成环(A.parent=B 且 B.parent=A;DB 层拦不住,
    # 前端 FolderTree defaultExpanded 上溯会挂死)。FGA 检查已在上面完成,不让锁跨
    # HTTP 调用(删除先例同序)
    lock_ids: list[uuid.UUID] = [folder_id]
    if moved and target is not None and new_parent_id is not None:
        lock_ids = sorted([folder_id, new_parent_id])
    for fid in lock_ids:
        locked = (
            await db.execute(select(Folder).where(Folder.id == fid).with_for_update())
        ).scalar_one_or_none()
        if locked is None:
            # 锁等待窗口内被并发删除
            raise HTTPException(404, "folder not found")
    await db.refresh(folder)   # 拿锁后取当前值(父链/前缀可能被并发 D1-B 改写)
    if target is not None:
        await db.refresh(target)

    # 旧值快照(供审计 / FGA 交换 / no-op 判定;expire_on_commit=False,提交后仍可读)
    old_parent_id = folder.parent_folder_id
    old_name = folder.name
    old_prefix = folder.minio_prefix
    effective_parent_id = new_parent_id if moved else old_parent_id

    # ── 5) 显式栈迭代:防环后代检测 + 子树收集(层序 = 自根向叶拓扑序)────────────
    # 禁递归:链深 >~960 即 RecursionError(API 无建夹深度限制,本仓有前科);
    # seen 兜底防结构性脏环(FK 自引用正常无环)
    subtree: list[Folder] = [folder]
    seen: set[uuid.UUID] = {folder.id}
    frontier: list[uuid.UUID] = [folder.id]
    while frontier:
        child_rows = (
            await db.execute(
                select(Folder).where(Folder.parent_folder_id.in_(frontier))
            )
        ).scalars().all()
        nxt: list[Folder] = []
        for r in child_rows:
            if r.id in seen:
                continue
            seen.add(r.id)
            nxt.append(r)
            subtree.append(r)
        if target is not None and target.id in seen:
            raise HTTPException(409, "不能将文件夹移动到其自身或其子文件夹内")
        frontier = [r.id for r in nxt]

    # ── 6) 同父同名 409(uq 语义,文案照 create_folder 撞 uq 分支)────────────────
    dup_id = await db.scalar(
        select(Folder.id).where(
            Folder.project_id == folder.project_id,
            Folder.name == final_name,
            Folder.id != folder.id,
            Folder.parent_folder_id.is_(None) if effective_parent_id is None
            else Folder.parent_folder_id == effective_parent_id,
        ).limit(1)
    )
    if dup_id is not None:
        raise HTTPException(409, "该项目下已存在同名文件夹")

    # ── 7) 计算子树新 prefix(跟随规则式重算:自拟形态视为历史遗留,重算后统一;
    #      层序保证父先于子)────────────────────────────────────────────────────
    if moved:
        if new_parent_id is None:
            new_source_prefix = f"{final_name}/"
        else:
            assert target is not None
            new_source_prefix = f"{target.minio_prefix.rstrip('/')}/{final_name}/"
    else:
        if old_parent_id is None:
            new_source_prefix = f"{final_name}/"
        else:
            parent_row = await db.get(Folder, old_parent_id)
            if parent_row is None:
                # 防御:父夹并发被删(有子夹时删除被 RESTRICT 挡住,理论不可达)
                raise HTTPException(404, "folder not found")
            await db.refresh(parent_row)  # 取当前 prefix(父链可能被并发 D1-B 改写)
            new_source_prefix = f"{parent_row.minio_prefix.rstrip('/')}/{final_name}/"
    new_prefix_by_id: dict[uuid.UUID, str] = {folder.id: new_source_prefix}
    for row in subtree[1:]:
        parent_key = row.parent_folder_id
        assert parent_key is not None  # 层序遍历:父必已入映射(结构性防御)
        parent_new = new_prefix_by_id[parent_key]
        new_prefix_by_id[row.id] = f"{parent_new.rstrip('/')}/{row.name}/"

    # 预算:逐夹 >1024 字符/字节 → 400(超 String(1024) 列宽直接落库是 PG DataError)
    for row in subtree:
        try:
            check_prefix_budget(new_prefix_by_id[row.id])
        except FolderChainError as e:
            raise HTTPException(400, str(e)) from e
    # 冲突预检:重算终态若与无结构关系的存量自拟 prefix 相撞,不是瞬时撞 uq 而是
    # 持久冲突 → 明确 409 文案(与 check_prefix_budget 同批做,方案 §5.2 D1-B ②)
    finals = [new_prefix_by_id[r.id] for r in subtree]
    if len(set(finals)) != len(finals):
        raise HTTPException(409, "子树内存在同名文件夹,重算后将产生重复存储路径,无法完成该操作")
    existed = (
        await db.execute(
            select(Folder.id, Folder.minio_prefix).where(
                Folder.project_id == folder.project_id,
                Folder.minio_prefix.in_(finals),
            )
        )
    ).all()
    for rid, pfx in existed:
        if rid not in new_prefix_by_id:
            raise HTTPException(
                409, f"目标路径与现有文件夹的存储前缀冲突:{pfx}"
                "(同项目下已存在使用该前缀的自定义路径文件夹)",
            )

    # ── 8) D1-B 两段式 UPDATE:先全子树改挂临时前缀再自根向叶落目标 ────────────────
    # uq_folder_project_prefix 逐行即时校验(非 DEFERRABLE),逐行更新途中新值与
    # 未更新行的旧值相撞即炸;先全部改挂随机 token 临时前缀(互异且不与存量行相撞),
    # flush 后终态互异(上方预检已保证)再落目标。不动物理对象、不动 assets.minio_key
    changed = [
        (row, new_prefix_by_id[row.id]) for row in subtree
        if new_prefix_by_id[row.id] != row.minio_prefix
    ]
    try:
        op_token = f"__d1b_{uuid.uuid4().hex[:8]}__"  # 16 字符;存量段名不可能形成该形态
        for row, _new in changed:
            if len(row.minio_prefix) + len(op_token) <= 1024:
                row.minio_prefix = op_token + row.minio_prefix
            # 超长行(>1008 字符)容不下 token:留待终态直改;极端自拟形态若仍撞
            # 唯一约束由下方 IntegrityError 兜底 409(常规冲突已被预检排除)
        await db.flush()
        for row, new_p in changed:  # changed 保持层序 = 自根向叶
            row.minio_prefix = new_p
        if renamed:
            folder.name = final_name
        if moved:
            folder.parent_folder_id = new_parent_id
        await db.flush()
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise HTTPException(
            409, "文件夹结构刚发生变化(可能新增了同名文件夹),请刷新后重试",
        ) from e

    # ── 9) FGA parent tuple 原子交换(DB commit 成功之后;删除先例同序)────────────
    fga_status: str = "not_needed"
    if moved:
        fga_status = await permissions.swap_folder_parent_tuple(
            folder_id=str(folder.id),
            project_id=str(folder.project_id),
            old_parent_folder_id=str(old_parent_id) if old_parent_id is not None else None,
            new_parent_folder_id=str(new_parent_id) if new_parent_id is not None else None,
        )

    # ── 10) 审计(audit.write 自带独立 commit)────────────────────────────────────
    common_details = {
        "folder_id": str(folder.id),
        "old_minio_prefix": old_prefix,
        "new_minio_prefix": new_source_prefix,
    }
    if renamed:
        await audit.write(
            event_type="folder_renamed",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={
                **common_details,
                "old_name": old_name,
                "new_name": final_name,
                "parent_folder_id": str(effective_parent_id) if effective_parent_id else None,
            },
            **ctx,
        )
    if moved:
        await audit.write(
            event_type="folder_moved",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={
                **common_details,
                "name": final_name,
                "old_parent_folder_id": str(old_parent_id) if old_parent_id else None,
                "new_parent_folder_id": str(new_parent_id) if new_parent_id else None,
                "fga_swap": fga_status,
            },
            **ctx,
        )
    log.info(
        "folder updated id=%s renamed=%s moved=%s prefix %s -> %s fga=%s",
        folder_id, renamed, moved, old_prefix, new_source_prefix, fga_status,
    )

    await db.refresh(folder)
    return FolderOut.model_validate(folder)


@router.get("", response_model=list[FolderOut])
async def list_folders(
    project_id: uuid.UUID = Query(...),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
) -> list[FolderOut]:
    # project 可见 check(public 直通,否则 can_view);系统 admin 直通
    project = await db.get(Project, project_id)
    if not project:
        raise HTTPException(404, "project not found")
    if not is_system_admin and project.visibility != "public":
        allowed = await permissions.check(
            user_subject=user.subject, relation="can_view",
            object_type="project", object_id=str(project_id),
        )
        if not allowed:
            raise HTTPException(403, "no permission")

    # 普通 folder:project member 都可见(用 SQL 拿全部)
    # sensitive folder:系统 admin 直接全部;否则 OpenFGA list_objects(can_view, sensitive_folder) intersect
    if is_system_admin:
        stmt = select(Folder).where(Folder.project_id == project_id).order_by(Folder.minio_prefix)
    else:
        sensitive_ids_str = await permissions.list_objects(
            user_subject=user.subject, relation="can_view", object_type="sensitive_folder"
        )
        sensitive_uuids = [uuid.UUID(s) for s in sensitive_ids_str]
        stmt = select(Folder).where(
            Folder.project_id == project_id,
            or_(
                Folder.is_sensitive.is_(False),                       # 普通 folder 全见
                Folder.id.in_(sensitive_uuids) if sensitive_uuids else False,  # sensitive 须 invited
            ),
        ).order_by(Folder.minio_prefix)
    res = await db.execute(stmt)
    folders = res.scalars().all()

    # ── 子树活跃文件计数(「子树含文件」标记,2026-10-15)────────────────────
    # 口径:沿 parent_folder_id 结构链回累,禁用 minio_prefix 前缀匹配
    # (prefix 可客户端自拟、name 未禁「/」,非结构真源;badge 方案 §2)。
    # 先一条 GROUP BY 聚合各夹直接活跃文件数(权限过滤之后的可见夹集合),
    # 再 Python 侧自真根两段式迭代回累(显式栈,不受链深限制;badge 方案 §3.2/§3.3)。
    direct: dict[uuid.UUID, int] = {}
    if folders:
        rows = await db.execute(
            select(Asset.folder_id, func.count())
            .where(
                Asset.folder_id.in_([f.id for f in folders]),
                Asset.deleted_at.is_(None),                    # 软删不计
            )
            .group_by(Asset.folder_id)
        )
        direct = {fid: cnt for fid, cnt in rows.all()}

    children: dict[uuid.UUID | None, list[Folder]] = {}
    for f in folders:
        children.setdefault(f.parent_folder_id, []).append(f)
    subtree: dict[uuid.UUID, int] = {}
    seen: set[uuid.UUID] = set()           # 防御环(FK 自引用正常无环,兜底即可)

    # 两段式显式栈迭代回累(P2-1:递归版链深 >~960 即 RecursionError → 500,
    # API 无建夹深度限制,用户可自造深链;迭代版无此上限,语义与递归严格一致):
    # ① 自真根 DFS 收集可达序(入栈即计 seen 防环;父必先于子出现在可达序);
    # ② 逆序自底向上累加 —— 任一节点计算时其全部后代已入 subtree。
    reachable: list[uuid.UUID] = []
    stack: list[uuid.UUID] = [f.id for f in children.get(None, [])]  # 真根起(普通根 + 可见 sensitive 根)
    while stack:
        fid = stack.pop()
        if fid in seen:
            continue
        seen.add(fid)
        reachable.append(fid)
        stack.extend(c.id for c in children.get(fid, []))
    for fid in reversed(reachable):        # 逆可达序 = 子先于父(递归后序的等价展开)
        subtree[fid] = direct.get(fid, 0) + sum(
            subtree.get(c.id, 0) for c in children.get(fid, [])
        )

    # 孤儿行(敏感父对当前用户不可见被过滤后的普通子夹及其后代,不在真根遍历
    # 可达集上)刻意不回填、按默认 0 输出 —— 受众信任边界口径(badge 方案
    # §3.3/§6.3/§6.4);缺键=刻意 0 非漏算,禁止改回 subtree[f.id]
    out: list[FolderOut] = []
    for r in folders:
        item = FolderOut.model_validate(r)
        item.subtree_file_count = subtree.get(r.id, 0)
        out.append(item)
    return out


@router.get("/{folder_id}", response_model=FolderOut)
async def get_folder(
    folder_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
) -> FolderOut:
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")
    obj_type = "sensitive_folder" if folder.is_sensitive else "folder"

    if is_system_admin:
        can_view = can_download = can_upload = can_admin = True
        # my_delete_grant 不含系统管理员直通(F8 口径):系统 admin 的删除入口由
        # my_can_admin 闸门表达,本字段只反映组级开关授权(两半都 False,不依赖
        # and 短路兜未定义变量)
        is_file_deleter = grant_can_view = False
    else:
        # public 项目非敏感 folder:组织内可浏览(「公开」语义,与 assets 列表 /
        # thumbnail-url 的"信任组织内可见性"一致);下载/上传/删除仍走各自权限
        public_browse = False
        if not folder.is_sensitive:
            project = await db.get(Project, folder.project_id)
            public_browse = project is not None and project.visibility == "public"

        async def _c(rel: str) -> bool:
            if rel == "can_view" and public_browse:
                return True
            return await permissions.check(
                user_subject=user.subject, relation=rel,
                object_type=obj_type, object_id=str(folder.id),
            )

        async def _delete_grant_parts() -> tuple[bool, bool]:
            """my_delete_grant 的两半(决策 #9):返回 (file_deleter, 裸 FGA can_view)。

            can_view 必须取**裸 FGA check**—— 与 assets(软删/hard/restore/trash)
            与 folders(删夹)四处删除守门的组开关分支完全同口径;上方 _c("can_view")
            的 public_browse 浏览直通只供 my_can_view 展示字段(FGA model 无 public
            传播,靠浏览直通拿到的 can_view 不代表删除守门会放行,亮灯必 403 口径
            分裂已由验收裁决封死,2026-10-16 决策 #9)。sensitive 夹恒 (False, False),
            零 FGA 调用;flag 为 false 的非组员同样跳过 can_view check(与守门短路序
            一致,不多打)。
            注意:本闭包是 gather 里唯一摸 AsyncSession 的任务(get_default_organization
            的 org 主键查),其余四个 check 纯 OpenFGA HTTP —— 单任务持有 session,
            不违反 AsyncSession「同一时刻仅一个协程使用」约束;若往 gather 里再加
            DB 触达分支,须先把 org 解析提到 gather 外
            """
            if folder.is_sensitive:
                return False, False
            is_file_deleter = await user_is_org_file_deleter(
                permissions, db, user_id=str(user.id),
            )
            if not is_file_deleter:
                return False, False
            raw_can_view = await permissions.check(
                user_subject=user.subject, relation="can_view",
                object_type=obj_type, object_id=str(folder.id),
            )
            return True, raw_can_view

        can_view, can_download, can_upload, can_admin, (is_file_deleter, grant_can_view) = (
            await asyncio.gather(
                _c("can_view"), _c("can_download"), _c("can_upload"),
                _c("can_admin"), _delete_grant_parts(),
            )
        )

    if not can_view:
        raise HTTPException(403, "no permission")
    out = FolderOut.model_validate(folder)
    out.my_can_view = can_view
    out.my_can_download = can_download
    out.my_can_upload = can_upload
    out.my_can_admin = can_admin
    # F8(2026-10-16 组删除授权):组级「删除文件/文件夹」开关生效态 =
    # 组开关 且 裸 FGA can_view(不含 public 浏览直通,决策 #9)且非 sensitive;
    # 不含系统管理员直通(见上)
    out.my_delete_grant = bool(is_file_deleter and grant_can_view)
    return out


@router.delete("/{folder_id}", status_code=204)
async def delete_folder(
    folder_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """删除文件夹 — 仅允许空文件夹(无活跃文件 **且回收站已清空**),硬删。

    不做软删的原因:空文件夹无对象可延迟清理、重建成本一次点击,软删无收益;
    且 uq_folder_project_prefix 是全量唯一约束,软删占位会让同名重建撞 409。
    非空拒绝而非级联:assets.folder_id 是 RESTRICT,且子树删除的产品语义未定。

    空 = 无子文件夹 且 无资产行(含软删)。软删文件须先在回收站里**显式**
    彻底清空(tester 定档:删除文件夹不做隐性连带清除,防"顺手删夹"把回收站
    里本可恢复的东西一并抹掉)。
    权限:普通 folder 用 can_upload(与创建对称,uploader 自主管理目录结构,
    model 里 uploader 隐含建子目录),2026-10-16 组删除授权再并一支组级
    file_deleter 且 can_view(F7;授权且可见);sensitive folder 维持 can_admin
    —— sensitive 的 can_upload 实为 downloader 级(model v4),拿它当删除门槛太宽,
    且邀请配置价值高,组织开关分支不穿透 sensitive。系统 admin 直通。

    并发安全(#177):判空后先 `SELECT … FOR UPDATE` 锁 folder 行再删,
    同窗口内并发的子夹 / 资产 INSERT 因 FK 取父行 key-share 锁会被阻塞到
    本事务提交,之后各自干净地撞 FK 报错(不会被我级联/500);delete+commit
    包 IntegrityError → 409 兜底。OpenFGA tuple 清理放在 **commit 成功之后**
    (与 directory 删组顺序相反:folder 有会失败的 RESTRICT 子引用,先清
    tuple 会在 DB 回滚时留下"活对象 + 空权限图"的断链且无自助修复入口;
    反过来,commit 成功后清理失败只留下已删对象上的孤儿 tuple —— UUID 不
    复用即天然失效,无害)。
    """
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    obj_type = "sensitive_folder" if folder.is_sensitive else "folder"
    del_relation = "can_admin" if folder.is_sensitive else "can_upload"
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation=del_relation,
        object_type=obj_type, object_id=str(folder_id),
    )
    # 组级「删除文件/文件夹」开关分支(F7,2026-10-16):普通夹 = 授权且可见
    # (can_view);短路在 can_upload 失败之后,常规路径不多打 org 解析与 check
    # (and 短路序同嵌套 if)。sensitive 夹不适用(上方 can_admin 单门,开关不穿透)
    if (
        not allowed
        and not folder.is_sensitive
        and await user_is_org_file_deleter(permissions, db, user_id=str(user_id))
    ):
        allowed = await permissions.check(
            user_subject=user.subject, relation="can_view",
            object_type="folder", object_id=str(folder_id),
        )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={"action": "delete_folder", "folder_id": str(folder_id),
                     "reason": f"openfga {del_relation} false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to delete this folder")

    # 锁住 folder 行:判空、删除、提交全程持有,并发写子引用被挡在门外
    # (OpenFGA 权限检查在上面完成,不让锁跨 HTTP 调用)
    locked = (
        await db.execute(
            select(Folder).where(Folder.id == folder_id).with_for_update()
        )
    ).scalar_one_or_none()
    if locked is None:
        raise HTTPException(404, "folder not found")

    child_id = await db.scalar(
        select(Folder.id).where(Folder.parent_folder_id == folder_id).limit(1)
    )
    if child_id is not None:
        raise HTTPException(409, "文件夹下还有子文件夹,请先删除子文件夹")

    # 判空 409 文案一律不带计数:删夹门槛(can_upload)低于回收站可见门槛
    # (can_admin),仅 uploader 者看不到回收站却会从报文拿到精确计数;sensitive
    # 夹再统一为不区分分支的模糊文案(防内容规模探测,F2)。数字对能看回收站
    # 的 admin 是冗余(角标/弹窗都有)
    _SENSITIVE_NONEMPTY_MSG = "文件夹不为空(或回收站未清空),请先彻底清空后再删除"
    live_id = await db.scalar(
        select(Asset.id)
        .where(Asset.folder_id == folder_id, Asset.deleted_at.is_(None))
        .limit(1)
    )
    if live_id is not None:
        if folder.is_sensitive:
            raise HTTPException(409, _SENSITIVE_NONEMPTY_MSG)
        raise HTTPException(409, "文件夹不为空,请先删除其中所有文件")
    trash_count = await db.scalar(
        select(func.count())
        .select_from(Asset)
        .where(Asset.folder_id == folder_id, Asset.deleted_at.is_not(None))
    )
    if trash_count:
        if folder.is_sensitive:
            raise HTTPException(409, _SENSITIVE_NONEMPTY_MSG)
        raise HTTPException(
            409, "回收站内还有已删除文件,请先在回收站中彻底清空后再删除文件夹",
        )

    name, prefix, is_sensitive, project_id = (
        folder.name, folder.minio_prefix, folder.is_sensitive, folder.project_id,
    )
    try:
        await db.delete(folder)
        await db.commit()
    except IntegrityError as e:
        # 理论上被上面的行锁挡住;兜底防御(如未来新增引用路径),不裸 500
        await db.rollback()
        raise HTTPException(
            409, "文件夹状态刚发生变化(可能新增了子文件夹或文件),请刷新后重试"
        ) from e

    # ── 以下都在 DB 删除成功之后:tuple 清理失败只留无害孤儿 ──────────────
    try:
        from openfga_sdk.client.models import ClientTuple, ClientWriteRequest
        from openfga_sdk.models import ReadRequestTupleKey
        resp = await permissions._client.read(  # type: ignore[attr-defined]
            ReadRequestTupleKey(object=f"{obj_type}:{folder_id}")
        )
        for t in resp.tuples:
            try:
                await permissions._client.write(  # type: ignore[attr-defined]
                    ClientWriteRequest(deletes=[ClientTuple(
                        user=t.key.user, relation=t.key.relation, object=t.key.object,
                    )])
                )
            except Exception:
                log.debug("folder tuple delete tolerate %s %s %s",
                          t.key.user, t.key.relation, t.key.object)
    except Exception as e:
        log.warning("delete folder tuple cleanup fail folder=%s err=%s", folder_id, e)

    # audit 落库失败不应让客户端误以为删除失败(删除已提交、不可逆,500 只会
    # 误导用户重试并吃 404)。仅此一处偏离「audit 失败即 500」的惯例:audit
    # 位于不可逆 commit 之后
    try:
        await audit.write(
            event_type="folder_deleted",
            actor_user_id=user_id,
            target_project_id=project_id,
            details={
                "folder_id": str(folder_id),
                "name": name,
                "minio_prefix": prefix,
                "is_sensitive": is_sensitive,
            },
            **ctx,
        )
    except Exception:
        log.warning("folder_deleted audit write fail folder=%s", folder_id, exc_info=True)
    log.info("folder deleted id=%s name=%s sensitive=%s by user=%s",
             folder_id, name, is_sensitive, user_id)


@router.post("/{folder_id}/invite", status_code=204)
async def invite(
    folder_id: uuid.UUID,
    payload: FolderInviteIn,
    background: BackgroundTasks,  # #153:应用内邀请通知用(#162 下线 IM 后原任务移除,参数重新引入)
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """邀请 user / group 进入 sensitive_folder(admin 操作)。

    审批驱动的邀请走 /api/v1/approvals。#154:department 轴写入已下线(ADR-0007)。"""
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")
    if not folder.is_sensitive:
        raise HTTPException(400, "only sensitive_folder needs invite")

    # subject 二选一(普通 OR 排除,只允许一个非 None)
    provided = [
        ("user", payload.user_id),
        ("group", payload.group_id),
    ]
    chosen = [(k, v) for k, v in provided if v]
    if len(chosen) != 1:
        raise HTTPException(400, "must specify exactly one of user_id / group_id")
    subject_kind, subject_id = chosen[0]

    # admin check;系统 admin 直通
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="sensitive_folder", object_id=str(folder_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={"action": "invite_sensitive_folder", "folder_id": str(folder_id),
                     "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no admin permission on this folder")

    from app.services.permissions import fmt_subject
    subject = fmt_subject(subject_kind, str(subject_id))  # type: ignore[arg-type]
    await permissions.invite_to_sensitive_folder(
        sensitive_folder_id=str(folder_id),
        subject=subject,
        level=payload.level,  # type: ignore[arg-type]
        duration_seconds=payload.duration_seconds,
    )

    await audit.write(
        event_type="sensitive_folder_invited",
        actor_user_id=user_id,
        target_project_id=folder.project_id,
        details={
            "folder_id": str(folder_id),
            "subject": subject,
            "level": payload.level,
            "permanent": payload.duration_seconds is None,
            "duration_seconds": payload.duration_seconds,
        },
        **ctx,
    )


    # #153:应用内"目录邀请"通知 — 仅 user 类型推送(group/department 无对应用户);
    # #162 已下线 IM 卡片,此为唯一通知渠道
    if subject_kind == "user":
        # #148:subject_id 已是 users.id UUID,直接主键查
        from app.db.tables import User as _User
        invitee = await db.get(_User, uuid.UUID(str(subject_id)))
        if invitee is not None:
            background.add_task(
                run_notify_folder_invite_bg,
                folder_id=folder_id,
                invitee_user_id=invitee.id,
                inviter_user_id=user_id,
                duration_seconds=payload.duration_seconds,
            )

@router.get("/{folder_id}/members")
async def list_members(
    folder_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
) -> list[dict]:
    """sensitive_folder 当前成员列表 — D iter3 前端 FolderInvitePanel 用。

    返:[{subject, kind, name, level, permanent, expires_at?}]
    subject 形如 "user:<users.id UUID>" / "group:<gid>#member" / "department:<did>#member"
    需 can_admin folder;系统 admin 直通。
    """
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")
    if not folder.is_sensitive:
        raise HTTPException(400, "not a sensitive_folder")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="sensitive_folder", object_id=str(folder_id),
    )
    if not allowed:
        raise HTTPException(403, "no admin permission")

    # OpenFGA read 所有 tuples for sensitive_folder:<id>
    from openfga_sdk.models import ReadRequestTupleKey

    resp = await permissions._client.read(  # type: ignore[attr-defined]
        ReadRequestTupleKey(object=f"sensitive_folder:{folder_id}")
    )

    members: list[dict] = []

    INVITE_RELATIONS = {
        "invited_viewer":            ("viewer", True),
        "invited_downloader":        ("downloader", True),
        "explicit_invited_viewer":   ("viewer", False),
        "explicit_invited_downloader": ("downloader", False),
    }
    for t in resp.tuples:
        rel = t.key.relation
        if rel not in INVITE_RELATIONS:
            continue
        level, permanent = INVITE_RELATIONS[rel]
        subject = t.key.user            # e.g. "user:ou_xxx" or "group:gid#member"
        kind, rest = subject.split(":", 1)
        sid = rest.rsplit("#", 1)[0]    # 去 #member 后缀

        expires_at = None
        cond = getattr(t.key, "condition", None)
        if cond and not permanent:
            try:
                ctx = cond.context or {}
                gt = ctx.get("grant_time")
                dur = ctx.get("grant_duration", "0s")
                if gt:
                    from datetime import datetime, timedelta
                    seconds = int(dur.rstrip("s"))
                    expires_at = (
                        datetime.fromisoformat(gt.replace("Z", "+00:00"))
                        + timedelta(seconds=seconds)
                    ).isoformat()
            except (ValueError, AttributeError):
                pass

        record = {
            "subject": subject,
            "kind": kind,            # user / group / department
            "subject_id": sid,
            "name": None,            # 后面批量解析
            "level": level,
            "permanent": permanent,
            "expires_at": expires_at,
        }
        members.append(record)

    # 批量解析主体名称(user → users.name,group → groups.name;未命中走 id 兜底)
    names = await resolve_subject_names(db, [str(m["subject"]) for m in members])
    for m in members:
        m["name"] = names[m["subject"]]["name"]

    # 排序:user 在前,group/department 在后;name 字典序
    members.sort(key=lambda m: (0 if m["kind"] == "user" else 1, m["name"] or ""))
    return members


@router.delete("/{folder_id}/invite", status_code=204)
async def revoke_invite(
    folder_id: uuid.UUID,
    subject: str = Query(..., description="完整 subject 字符串,例:user:<users.id UUID> / group:<gid>#member / department:<did>#member"),
    level: str = Query("viewer", pattern=r"^(viewer|downloader)$"),
    permanent: bool = Query(True, description="True=删 invited(永久);False=删 explicit_invited(临时)"),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")
    if not folder.is_sensitive:
        raise HTTPException(400, "not a sensitive_folder")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="sensitive_folder", object_id=str(folder_id),
    )
    if not allowed:
        raise HTTPException(403, "no admin permission")

    await permissions.revoke_sensitive_folder_invite(
        sensitive_folder_id=str(folder_id),
        subject=subject,
        level=level,  # type: ignore[arg-type]
        permanent=permanent,
    )

    await audit.write(
        event_type="sensitive_folder_revoked",
        actor_user_id=user_id,
        target_project_id=folder.project_id,
        details={
            "folder_id": str(folder_id),
            "subject": subject,
            "level": level,
            "permanent": permanent,
        },
        **ctx,
    )


# ─── 普通 folder explicit grant(仅一级 folder)─────────────────────────────
FOLDER_GRANT_KINDS = ("viewer", "downloader", "uploader")


def _enforce_level1_folder(folder: Folder) -> None:
    if folder.parent_folder_id is not None:
        raise HTTPException(
            400,
            "explicit grant 仅支持一级 folder(直接挂在 project 下);"
            "深层 folder 想要不同权限,请在 project 下新建一级 folder",
        )


@router.get("/{folder_id}/grants")
async def list_folder_grants(
    folder_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
) -> list[dict]:
    """列普通 folder 的 explicit_* grants。

    返:[{subject, kind, subject_id, name, role: explicit_viewer|downloader|uploader}]
    需 can_admin folder + folder 为一级;系统 admin 直通。
    """
    folder = await db.get(Folder, folder_id)
    if folder is None:
        raise HTTPException(404, "folder not found")
    if folder.is_sensitive:
        raise HTTPException(400, "sensitive folder 用 /members endpoint")
    _enforce_level1_folder(folder)

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="folder", object_id=str(folder_id),
    )
    if not allowed:
        raise HTTPException(403, "no admin permission on this folder")

    from openfga_sdk.models import ReadRequestTupleKey

    resp = await permissions._client.read(  # type: ignore[attr-defined]
        ReadRequestTupleKey(object=f"folder:{folder_id}")
    )

    grants: list[dict] = []
    GRANT_RELATIONS = {f"explicit_{k}" for k in FOLDER_GRANT_KINDS}
    for t in resp.tuples:
        rel = t.key.relation
        if rel not in GRANT_RELATIONS:
            continue
        kind = rel.removeprefix("explicit_")  # viewer / downloader / uploader
        subject = t.key.user
        sk, rest = subject.split(":", 1)
        sid = rest.rsplit("#", 1)[0]
        grants.append({
            "subject": subject, "kind": sk, "subject_id": sid,
            "name": None, "level": kind,
        })

    # 批量解析主体名称(user → users.name,group → groups.name;未命中走 id 兜底)
    names = await resolve_subject_names(db, [str(g["subject"]) for g in grants])
    for g in grants:
        g["name"] = names[g["subject"]]["name"]

    grants.sort(key=lambda g: (0 if g["kind"] == "user" else 1, g["name"] or ""))
    return grants


@router.post("/{folder_id}/grants", status_code=204)
async def add_folder_grant(
    folder_id: uuid.UUID,
    payload: dict,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """body:{user_id|group_id, level?: viewer|downloader|uploader, levels?: [...]}
    levels 一次授多 level;旧单 level 字段继续兼容
    (user_id = users.id UUID,#148 起;#154:department 轴写入下线)"""
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if folder is None:
        raise HTTPException(404, "folder not found")
    if folder.is_sensitive:
        raise HTTPException(400, "sensitive folder 用 /invite endpoint")
    _enforce_level1_folder(folder)

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="folder", object_id=str(folder_id),
    )
    if not allowed:
        raise HTTPException(403, "no admin permission on this folder")

    # P2-1:levels 类型先校验(客户端误传字符串时按字符迭代,报错费解)
    raw_levels = payload.get("levels")
    if raw_levels is not None and not isinstance(raw_levels, list):
        raise HTTPException(400, "levels 必须是数组")
    legacy_level = payload.get("level")
    raw_levels = raw_levels or ([legacy_level] if legacy_level else [])
    bad = [l for l in raw_levels if not isinstance(l, str) or l not in FOLDER_GRANT_KINDS]
    if bad:
        raise HTTPException(400, f"level must be one of {FOLDER_GRANT_KINDS}: got {bad}")
    if not raw_levels:
        raise HTTPException(400, "level(或 levels)必填")
    levels = [l for l in FOLDER_GRANT_KINDS if l in set(raw_levels)]  # 去重 + 固定序

    provided = [
        ("user", payload.get("user_id")),
        ("group", payload.get("group_id")),
    ]
    chosen = [(k, v) for k, v in provided if v]
    if len(chosen) != 1:
        raise HTTPException(
            400, "must specify exactly one of user_id / group_id"
        )
    subject_kind, subject_id = chosen[0]

    from app.services.permissions import fmt_subject
    subject = fmt_subject(subject_kind, str(subject_id))  # type: ignore[arg-type]
    # 部分成功语义:重复(已存在)按幂等跳过;真错误中止 —— 此前 level 已生效并
    # 留有 audit,客户端重试可幂等补齐(P2-2)。注意 folder grant 由服务层内部
    # 先删后写刷新到期时间(grant_folder_explicit_subject),不会走到这里。
    for level in levels:
        try:
            await permissions.grant_folder_explicit_subject(
                folder_id=str(folder_id), subject=subject,
                kind=f"explicit_{level}",  # type: ignore[arg-type]
            )
        except Exception as e:
            # OpenFGA 重复 tuple —— 重复 grant / 多 level 部分重叠按幂等成功跳过;
            # 真错误继续抛
            if not is_already_exists_error(e):
                raise
            continue
        await audit.write(
            event_type="folder_grant_added",
            actor_user_id=user_id, target_project_id=folder.project_id,
            details={"folder_id": str(folder_id), "subject": subject, "level": level},
            **ctx,
        )


@router.delete("/{folder_id}/grants", status_code=204)
async def remove_folder_grant(
    folder_id: uuid.UUID,
    subject: str = Query(..., description="完整 OpenFGA subject"),
    level: str = Query(..., pattern=r"^(viewer|downloader|uploader)$"),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if folder is None:
        raise HTTPException(404, "folder not found")
    if folder.is_sensitive:
        raise HTTPException(400, "sensitive folder 用 /invite endpoint")
    _enforce_level1_folder(folder)

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="folder", object_id=str(folder_id),
    )
    if not allowed:
        raise HTTPException(403, "no admin permission on this folder")

    await permissions.revoke_folder_explicit_subject(
        folder_id=str(folder_id), subject=subject,
        kind=f"explicit_{level}",  # type: ignore[arg-type]
    )
    await audit.write(
        event_type="folder_grant_removed",
        actor_user_id=user_id, target_project_id=folder.project_id,
        details={"folder_id": str(folder_id), "subject": subject, "level": level},
        **ctx,
    )
