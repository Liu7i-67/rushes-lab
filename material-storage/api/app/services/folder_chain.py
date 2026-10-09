"""目录链创建服务 ensure_folder_chain — 方案 §5.1(批次 2 抽取)。

参照 routers/folders.py:49 create_folder 的 minio_prefix 计算,与
services/permissions.py:206 bootstrap_folder 的 OpenFGA parent tuple 写入。

约束(方案 §5.1 约束①-⑤,全部在本模块收敛):
  ① 同名子目录已存在则复用,且复用分支同样幂等 ensure parent tuple(直接 write、
     is_already_exists_error 幂等跳过,先例 permissions.py:79-89);调用方按轮
     memoize(folder_id+prefix),防 20k 文件 x 多层链的 OpenFGA 写放大;并发同名
     建夹竞态用 IntegrityError 兜底(仿 folders.py:115-119 捕获后改查复用);
     tuple 写失败(非 already_exists)→ folder_tuple_error(可重试)
  ② 不截断:目录名单段超 Folder.name(255) 字符或 255 UTF-8 字节 → name_too_long;
     链上 minio_prefix 累计超 1024 字符/字节 → key_too_long(截断会让"预计导入
     路径"与实际落位不一致)
  ③ 总长校验:prefix + 文件名(leaf)超出 key 护栏(字符/字节双口径)→ key_too_long,
     不截断(截断会破坏 key = minio_prefix + '/' + filename 全局不变量)
  ④ 防御断言:链上任何节点(含根)不得为 sensitive folder → target_sensitive_chain
     (non_retryable)
  ⑤ 路径穿越断言:段名 ∈ {., ..} 或含 / 或 \\ → invalid_name(non_retryable)

同时提供枚举期静态护栏纯函数(§4:长度护栏枚举时静态校验,不进下载流程)。
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import Literal

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Folder
from app.services.permissions import PermissionsService, is_already_exists_error

log = logging.getLogger(__name__)

# ─── 长度/结构护栏常量(方案 §4;字符/字节双口径)────────────────────────────
SOURCE_DIR_MAX_CHARS = 600        # source_dir 创建期护栏(网盘绝对路径)
REL_PATH_MAX_CHARS = 600          # rel_path 护栏(唯一键 (task_id, rel_path) 的可定位性)
FILENAME_MAX_CHARS = 512          # Asset.filename String(512) 列限
FILENAME_MAX_BYTES = 255          # MinIO 每个 '/' 分隔段上限 255B(本仓 POSIX 后端硬限)
KEY_MAX_CHARS = 1024              # assets.minio_key / task_files.minio_key 列限
KEY_MAX_BYTES = 1024              # S3/MinIO 对象 key 硬限(UTF-8 字节)

# 失败码(行级 last_error / 结构性失败码域,方案 §4/§5.1)
GuardCode = Literal[
    "path_too_long", "name_too_long", "key_too_long",
    "target_sensitive_chain", "invalid_name", "file_too_large",
    "folder_tuple_error", "target_deleted",
]


class FolderChainError(Exception):
    """目录链护栏违规;non_retryable=True 的结构性失败重试不可能自愈(方案 §4)。"""

    def __init__(self, code: GuardCode, message: str, *, non_retryable: bool) -> None:
        super().__init__(message)
        self.code = code
        self.non_retryable = non_retryable


# ─── 纯函数护栏(枚举期静态校验 + ensure_folder_chain 内部复用)────────────────


def _utf8_len(text: str) -> int:
    return len(text.encode("utf-8"))


def check_segment_name(name: str) -> None:
    """§5.1 约束⑤+② 的段名断言:路径穿越 + 段长(字符/字节)。违规抛 FolderChainError。"""
    if name in (".", "..") or "/" in name or "\\" in name or not name:
        raise FolderChainError(
            "invalid_name", f"目录/文件名段非法(路径穿越或空段):{name!r}", non_retryable=True,
        )
    if len(name) > 255 or _utf8_len(name) > 255:
        raise FolderChainError(
            "name_too_long", f"目录/文件名超长(>255 字符或 255 字节):{name!r}", non_retryable=True,
        )


def check_prefix_budget(prefix: str) -> None:
    """minio_prefix 累计护栏(§5.1 约束②;字符/字节双口径,均对齐 1024 列限)。"""
    if len(prefix) > KEY_MAX_CHARS or _utf8_len(prefix) > KEY_MAX_BYTES:
        raise FolderChainError(
            "key_too_long", f"目录前缀超长(>1024 字符或 1024 字节):{prefix!r}", non_retryable=True,
        )


def guard_rel_path(target_prefix: str, rel_path: str) -> GuardCode | None:
    """枚举期静态护栏(§4):对 (目标 prefix, rel_path) 返结构性失败码或 None。

    口径:
    - rel_path > 600 字符 → path_too_long
    - 任一段(目录或文件名)路径穿越/空段 → invalid_name
    - 文件名(末段)> 512 字符或 > 255 UTF-8 字节 → name_too_long
    - key = prefix + '/' + rel_path 超 1024 字符或字节 → key_too_long
    """
    if len(rel_path) > REL_PATH_MAX_CHARS:
        return "path_too_long"
    segments = rel_path.split("/")
    for seg in segments:
        if seg in (".", "..") or "/" in seg or "\\" in seg or not seg:
            return "invalid_name"
    leaf = segments[-1]
    if len(leaf) > FILENAME_MAX_CHARS or _utf8_len(leaf) > FILENAME_MAX_BYTES:
        return "name_too_long"
    key = f"{target_prefix.rstrip('/')}/{rel_path}"
    if len(key) > KEY_MAX_CHARS or _utf8_len(key) > KEY_MAX_BYTES:
        return "key_too_long"
    return None


def guard_file_size(source_size: int, part_size_bytes: int) -> GuardCode | None:
    """单文件大小护栏(§6):multipart 10,000 parts 上限,超限 file_too_large。"""
    if source_size > 10_000 * part_size_bytes:
        return "file_too_large"
    return None


# ─── ensure_folder_chain ──────────────────────────────────────────────────────

# 轮内 memoize 值:(folder_id, minio_prefix) — prefix 供下层继续累计,免重复查库
ChainMemo = dict[tuple[uuid.UUID, str], tuple[uuid.UUID, str]]


@dataclass(frozen=True)
class ChainNode:
    folder_id: uuid.UUID
    prefix: str


async def _bootstrap_folder_tuple(
    permissions: PermissionsService, *, folder_id: uuid.UUID,
    parent_type: Literal["project", "folder"], parent_id: uuid.UUID,
) -> None:
    """幂等写 parent tuple:already_exists 幂等跳过(复用分支"tuple 就位"语义,§5.1①);
    其他异常 → folder_tuple_error(可重试,重试必须重走 tuple ensure)。"""
    try:
        await permissions.bootstrap_folder(
            folder_id=str(folder_id), parent_type=parent_type, parent_id=str(parent_id),
        )
    except Exception as e:
        if is_already_exists_error(e):
            return
        raise FolderChainError(
            "folder_tuple_error",
            f"OpenFGA parent tuple 写入失败 folder={folder_id}:{e}",
            non_retryable=False,
        ) from e


async def _get_folder(db: AsyncSession, folder_id: uuid.UUID) -> Folder:
    folder = await db.get(Folder, folder_id)
    if folder is None:
        # 目标根夹在任务生命周期内被删(正常路径 task.target_folder_id 已被 SET NULL,
        # 该分支防御并发窗口:行级引用还挂着但夹已没);可重试(下一轮重查)
        raise FolderChainError(
            "target_deleted", f"目标目录不存在 folder={folder_id}", non_retryable=False,
        )
    return folder


async def _assert_not_sensitive(folder: Folder, *, root: bool) -> None:
    if folder.is_sensitive:
        raise FolderChainError(
            "target_sensitive_chain",
            f"目录链命中 sensitive folder(根={root}):{folder.name}",
            non_retryable=True,
        )


async def _find_child(
    db: AsyncSession, *, project_id: uuid.UUID, parent_id: uuid.UUID | None, name: str,
) -> Folder | None:
    from sqlalchemy import select
    stmt = select(Folder).where(
        Folder.project_id == project_id,
        Folder.name == name,
        Folder.parent_folder_id.is_(None) if parent_id is None else Folder.parent_folder_id == parent_id,
    ).limit(1)
    return (await db.execute(stmt)).scalar_one_or_none()


async def _create_child(
    db: AsyncSession, *, project_id: uuid.UUID, parent_id: uuid.UUID | None,
    name: str, prefix: str,
) -> Folder:
    """创建子目录;并发同名建夹撞 uq_folder_project_prefix → IntegrityError 兜底
    (folders.py:115-119 同款:调用方 rollback 后改查复用)。"""
    folder = Folder(
        id=uuid.uuid4(),
        project_id=project_id,
        parent_folder_id=parent_id,
        name=name,
        minio_prefix=prefix,
        is_sensitive=False,  # 导入目标链永远非 sensitive(④ 由断言保证)
    )
    db.add(folder)
    await db.commit()
    return folder


async def ensure_folder_chain(
    db: AsyncSession,
    permissions: PermissionsService,
    *,
    project_id: uuid.UUID,
    root_folder_id: uuid.UUID,
    rel_dir_parts: list[str],
    leaf_name: str | None = None,
    memo: ChainMemo | None = None,
) -> ChainNode:
    """建出 rel_dir_parts 目录链(逐层复用/创建),返回末层节点。

    - root_folder_id:任务目标根承接目录(已解析;本函数同时断言其非 sensitive)
    - leaf_name 传文件名时做 ③ 总长校验(prefix + '/' + leaf 的字符/字节双口径)
    - memo:runner 进程内按轮 memoize(键 (parent_folder_id, name)),重试=新轮
      memo 失效自愈;memo 命中视为"行存在且 tuple 就位"(写入方已保证)
    """
    root = await _get_folder(db, root_folder_id)
    await _assert_not_sensitive(root, root=True)
    current = ChainNode(folder_id=root.id, prefix=root.minio_prefix)
    parent_for_tuple: tuple[Literal["project", "folder"], uuid.UUID] | None = None

    for name in rel_dir_parts:
        check_segment_name(name)
        child_prefix = f"{current.prefix.rstrip('/')}/{name}/"
        check_prefix_budget(child_prefix)

        memo_key = (current.folder_id, name)
        if memo is not None and memo_key in memo:
            fid, pref = memo[memo_key]
            current = ChainNode(folder_id=fid, prefix=pref)
            parent_for_tuple = None  # memo 命中:tuple 已由写入方保证
            continue

        existing = await _find_child(db, project_id=project_id, parent_id=current.folder_id, name=name)
        if existing is not None:
            await _assert_not_sensitive(existing, root=False)
            # 复用分支同样幂等 ensure parent tuple(§5.1①:"复用"语义 = 行存在且 tuple 就位)
            await _bootstrap_folder_tuple(
                permissions, folder_id=existing.id, parent_type="folder", parent_id=current.folder_id,
            )
            node = ChainNode(folder_id=existing.id, prefix=existing.minio_prefix)
        else:
            try:
                created = await _create_child(
                    db, project_id=project_id, parent_id=current.folder_id, name=name,
                    prefix=child_prefix,
                )
                parent_for_tuple = ("folder", current.folder_id)
            except IntegrityError:
                # 并发同名建夹竞态:回滚改查复用(folders.py:115-119 同款);
                # 改查仍无(父夹被并发删除等)→ folder_tuple_error 可重试
                await db.rollback()
                reused = await _find_child(db, project_id=project_id, parent_id=current.folder_id, name=name)
                if reused is None:
                    raise FolderChainError(
                        "folder_tuple_error",
                        f"目录创建竞态且复用查询为空 name={name!r}", non_retryable=False,
                    ) from None
                await _assert_not_sensitive(reused, root=False)
                await _bootstrap_folder_tuple(
                    permissions, folder_id=reused.id, parent_type="folder", parent_id=current.folder_id,
                )
                node = ChainNode(folder_id=reused.id, prefix=reused.minio_prefix)
            else:
                node = ChainNode(folder_id=created.id, prefix=created.minio_prefix)

        if memo is not None:
            memo[memo_key] = (node.folder_id, node.prefix)
        # 新建夹的 tuple 在 commit 后补写(与 folders.py create_folder 同序:DB 行先落)
        if parent_for_tuple is not None:
            ptype, pid = parent_for_tuple
            await _bootstrap_folder_tuple(
                permissions, folder_id=node.folder_id, parent_type=ptype, parent_id=pid,
            )
            parent_for_tuple = None
        current = node

    if leaf_name is not None:
        check_segment_name(leaf_name)
        key = f"{current.prefix.rstrip('/')}/{leaf_name}"
        if len(key) > KEY_MAX_CHARS or _utf8_len(key) > KEY_MAX_BYTES:
            raise FolderChainError(
                "key_too_long", f"对象 key 超长(>1024 字符或字节):{key!r}", non_retryable=True,
            )
    return current


async def ensure_root_folder_at_project(
    db: AsyncSession,
    permissions: PermissionsService,
    *,
    project_id: uuid.UUID,
    name: str,
) -> ChainNode:
    """项目根下确保承接夹存在(同名单一语义,复用/创建),返回节点。

    供两处复用:创建任务时的自动承接夹解析(§5.2),与 worker 步骤 1 的
    target_auto_created 在途重建(§6:target_folder_id 被置 NULL 后按名重建写回)。
    调用方负责 sensitive 同名夹的前置校验/断言(本函数专注行+tuple)。
    """
    check_segment_name(name)
    prefix = f"{name}/"
    check_prefix_budget(prefix)
    existing = await _find_child(db, project_id=project_id, parent_id=None, name=name)
    if existing is not None:
        await _assert_not_sensitive(existing, root=True)
        await _bootstrap_folder_tuple(
            permissions, folder_id=existing.id, parent_type="project", parent_id=project_id,
        )
        return ChainNode(folder_id=existing.id, prefix=existing.minio_prefix)
    try:
        created = await _create_child(db, project_id=project_id, parent_id=None, name=name, prefix=prefix)
    except IntegrityError:
        await db.rollback()
        reused = await _find_child(db, project_id=project_id, parent_id=None, name=name)
        if reused is None:
            raise FolderChainError(
                "folder_tuple_error", f"承接夹创建竞态且复用查询为空 name={name!r}", non_retryable=False,
            ) from None
        await _assert_not_sensitive(reused, root=True)
        await _bootstrap_folder_tuple(
            permissions, folder_id=reused.id, parent_type="project", parent_id=project_id,
        )
        return ChainNode(folder_id=reused.id, prefix=reused.minio_prefix)
    await _bootstrap_folder_tuple(
        permissions, folder_id=created.id, parent_type="project", parent_id=project_id,
    )
    log.info("folder_chain root folder created project=%s name=%s id=%s", project_id, name, created.id)
    return ChainNode(folder_id=created.id, prefix=created.minio_prefix)
