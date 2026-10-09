"""worker 侧 aioboto3 异步对象存储封装 — 方案 §6(批次 3)。

PresignService 是同步 boto3(其 list_parts/create/complete/abort 均为同步实现),
**同步版禁止在 async 路径直调**(会阻塞事件循环);worker 的下载流与 multipart
操作与本仓 httpx 异步下载同栈,统一走本封装(aioboto3 已是依赖):

- create_multipart_upload / upload_part(直传 bytes)/ complete_multipart_upload
- list_parts(paginator 分页取全;本仓 MinIO 单页至多 10000 parts,AWS 端点兼容)
- abort_multipart_upload(NoSuchUpload 透传给调用方甄别 —— 死会话自愈路径依赖)
- head_object(404 → None,head 快捷路径)/ put_object(零字节直传)/ delete_object

parts 严格按序号串行上传由调用方保证(断点偏移 = 已完成 parts 总字节的前提是
已列 parts 恒为连续前缀;并行化会让偏移算法静默失真)。
"""
from __future__ import annotations

import logging
from typing import Any

import aioboto3  # type: ignore[import-untyped]
from botocore.client import Config  # type: ignore[import-untyped]
from botocore.exceptions import ClientError  # type: ignore[import-untyped]

from app.settings import Settings

log = logging.getLogger(__name__)

_OBJECT_GONE_CODES = frozenset({"404", "NoSuchKey", "NotFound"})
_NO_SUCH_UPLOAD = "NoSuchUpload"


def is_no_such_upload_error(e: BaseException) -> bool:
    """list_parts/abort 撞已失效会话(complete 之后 upload_id 即死,§6)。"""
    return isinstance(e, ClientError) and str(
        (e.response or {}).get("Error", {}).get("Code", "")
    ) == _NO_SUCH_UPLOAD


class AsyncObjectStore:
    """aioboto3 S3 异步客户端生命周期封装(async with 进入/退出,单 job 一实例)。"""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._session = aioboto3.Session(
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            region_name="us-east-1",
        )
        self._client: Any = None

    async def __aenter__(self) -> AsyncObjectStore:
        self._client = await self._session.client(
            "s3",
            endpoint_url=self._settings.minio_endpoint_internal,
            config=Config(signature_version="s3v4", region_name="us-east-1"),
        ).__aenter__()
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        if self._client is not None:
            await self._client.__aexit__(*exc_info)
            self._client = None

    @property
    def client(self) -> Any:
        if self._client is None:
            raise RuntimeError("AsyncObjectStore 必须以 async with 进入后使用")
        return self._client

    async def create_multipart_upload(
        self, bucket: str, key: str, content_type: str = "application/octet-stream",
    ) -> str:
        resp = await self.client.create_multipart_upload(
            Bucket=bucket, Key=key, ContentType=content_type,
        )
        return str(resp["UploadId"])

    async def upload_part(
        self, bucket: str, key: str, upload_id: str, part_number: int, body: bytes,
    ) -> str:
        """直传分片,返回 ETag(调用方按序串行;每片成功后调用方落 bytes_done)。"""
        resp = await self.client.upload_part(
            Bucket=bucket, Key=key, UploadId=upload_id, PartNumber=part_number, Body=body,
        )
        return str(resp.get("ETag", ""))

    async def list_parts(self, bucket: str, key: str, upload_id: str) -> list[dict[str, Any]]:
        """list_parts 分页取全(paginator;NoSuchUpload 由调用方甄别为死会话)。"""
        parts: list[dict[str, Any]] = []
        paginator = self.client.get_paginator("list_parts")
        async for page in paginator.paginate(Bucket=bucket, Key=key, UploadId=upload_id):
            for p in page.get("Parts", []) or []:
                parts.append({
                    "PartNumber": int(p["PartNumber"]),
                    "Size": int(p.get("Size", 0)),
                    "ETag": str(p.get("ETag", "")),
                })
        parts.sort(key=lambda p: p["PartNumber"])
        return parts

    async def complete_multipart_upload(
        self, bucket: str, key: str, upload_id: str, parts: list[dict[str, Any]],
    ) -> dict[str, Any]:
        ordered = sorted(parts, key=lambda p: int(p["PartNumber"]))
        resp = await self.client.complete_multipart_upload(
            Bucket=bucket, Key=key, UploadId=upload_id,
            MultipartUpload={"Parts": [
                {"PartNumber": int(p["PartNumber"]), "ETag": str(p["ETag"])} for p in ordered
            ]},
        )
        return {
            "location": resp.get("Location"),
            "etag": resp.get("ETag"),
            "version_id": resp.get("VersionId"),
        }

    async def abort_multipart_upload(self, bucket: str, key: str, upload_id: str) -> None:
        await self.client.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)

    async def head_object(self, bucket: str, key: str) -> dict[str, Any] | None:
        """对象元信息;404/NoSuchKey → None(head 快捷路径的「对象已存在」判定)。"""
        try:
            resp = await self.client.head_object(Bucket=bucket, Key=key)
        except ClientError as e:
            code = str((e.response or {}).get("Error", {}).get("Code", ""))
            if code in _OBJECT_GONE_CODES:
                return None
            raise
        return {
            "size_bytes": int(resp.get("ContentLength", 0)),
            "content_type": resp.get("ContentType"),
            "etag": (str(resp.get("ETag", "")).strip('"') or None),
            "version_id": resp.get("VersionId"),
        }

    async def put_object(
        self, bucket: str, key: str, body: bytes, content_type: str = "application/octet-stream",
    ) -> str:
        """零字节/小对象直传(multipart 无法 complete 0 parts,§6);返回 ETag。"""
        resp = await self.client.put_object(
            Bucket=bucket, Key=key, Body=body, ContentType=content_type,
        )
        return str(resp.get("ETag", ""))

    async def delete_object(self, bucket: str, key: str) -> None:
        await self.client.delete_object(Bucket=bucket, Key=key)
