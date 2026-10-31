"""结构化字段白名单与文件夹组树(只做响应裁剪,不含 IO)。

不透 minio_key / minio_bucket / tags / open_id / email / organization_id。
唯一例外由调用方处理:upload 三元组 upload_id/key/bucket 是 complete 的入参,
必须回传(见 toolimpl.create_upload)。
"""

from __future__ import annotations

from typing import Any

ASSET_FIELDS = (
    "id", "folder_id", "filename", "size_bytes", "content_type",
    "created_at", "user_labels", "notes",
)
PROJECT_FIELDS = (
    "id", "code", "name", "description", "visibility", "is_archived",
    "created_at", "my_roles", "is_pinned",
)
FOLDER_FIELDS = (
    "id", "project_id", "parent_folder_id", "name", "created_at",
    "direct_file_count", "subtree_file_count",
    "my_can_view", "my_can_download", "my_can_upload", "my_can_admin",
)


def _pick(obj: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
    return {key: obj.get(key) for key in fields}


def project_summary(project: dict[str, Any]) -> dict[str, Any]:
    data = _pick(project, PROJECT_FIELDS)
    admins = project.get("admins") or []
    data["admins"] = [
        {"user_id": a.get("user_id"), "name": a.get("name")}
        for a in admins if isinstance(a, dict)
    ]
    return data


def folder_summary(folder: dict[str, Any]) -> dict[str, Any]:
    return _pick(folder, FOLDER_FIELDS)


def asset_summary(asset: dict[str, Any]) -> dict[str, Any]:
    return _pick(asset, ASSET_FIELDS)


def search_summary(asset: dict[str, Any]) -> dict[str, Any]:
    data = asset_summary(asset)
    data.update(
        folder_name=asset.get("folder_name"),
        project_id=asset.get("project_id"),
        project_name=asset.get("project_name"),
    )
    return data


def build_folder_tree(folders: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """按 parent_folder_id 组树;父不可见/父 id 不存在的节点按根输出(不丢数据)。"""
    nodes: dict[str, dict[str, Any]] = {}
    for folder in folders:
        node = folder_summary(folder)
        node["children"] = []
        nodes[str(folder.get("id"))] = node
    roots: list[dict[str, Any]] = []
    for folder in folders:
        fid = str(folder.get("id"))
        parent_id = folder.get("parent_folder_id")
        parent = nodes.get(str(parent_id)) if parent_id else None
        if parent is None or parent is nodes[fid]:
            roots.append(nodes[fid])
        else:
            parent["children"].append(nodes[fid])
    return roots
