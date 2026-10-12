"""MinIO presigned URL signer + STS — Phase B-2。

双 boto3 client(P-10):
  - s3_internal:容器内访问 MinIO,admin API(create_multipart / complete / abort / list)
  - s3_signer:签 presigned URL 用浏览器视角 host(MINIO_ENDPOINT_PUBLIC)

缩略图分层(ADR-0008 P1):
  - s3_thumb_signer:签缩略图 presigned URL,host = MINIO_THUMBNAIL_ENDPOINT_PUBLIC
    (留空回落 MINIO_ENDPOINT_PUBLIC);bucket = MINIO_THUMBNAIL_BUCKET(SSD)

封装:
  - sign_get_url / sign_put_url
  - 5-endpoint multipart(uppy)
  - issue_sts_for_prefix(7-bis.1 桌面客户端临时凭据)
  - get_object_streaming(敏感目录 FastAPI stream proxy)

动态签发(dynamic presign host,2026-10-12):
  多入口部署(https 域名跳板机 / 内网 IP / 外网 IP:端口)下,静态
  MINIO_ENDPOINT_PUBLIC 只能签出固定 host,https 入口的页面拿到
  http://47.108.196.211:18080/... 会被浏览器按混合内容(mixed content)
  拦截,预览/上传全挂(prod 已实锤)。4 个签名方法因此新增可选
  request_base(由 request_base_from 从请求上下文取 scheme://host[:port]):
  传入时用按入口缓存的 signer client 签名,URL 的 scheme/host 跟随浏览器
  实际访问入口;不传回落静态 endpoint(零行为变化)。内部 client
  (create/complete/head/list/delete/copy/sts)不受影响,始终走容器内 endpoint。
  防刷与回落(D3 可用性优先):Host 头是客户端可控输入 —— request_base_from
  只放行 scheme∈{http,https}(XFP 透传的 wss 等一律回落)+ 字符集校验 +
  host 小写归一(浏览器对 host 本就小写化,签名语义不变);即便如此仍可能有
  字符集合法但语义非法的 base(如裸 IPv6「::1」)让 botocore 拒绝建 client,
  构造失败即 log.warning 回落静态 signer,不缓存不报错;动态缓存另有常数上限
  MAX_DYNAMIC_SIGNERS,超限回落静态,防已认证用户轮换 Host 刷单进程内存。
"""
from __future__ import annotations

import logging
import re
from typing import Any

import boto3
from botocore.client import Config
from fastapi import Request

from app.settings import Settings

log = logging.getLogger(__name__)

# Host 头合法字符集:裸域名 / IPv4 / IPv4:port / [IPv6]:port 都在此内。
# 超出视作伪造或异常请求 → 回落静态 endpoint(可用性优先,D3:防伪造只影响
# 自身拿到的 URL 形态,对象访问仍要过权限 + MinIO 签名校验,无提权面)
_HOST_PATTERN = re.compile(r"^[A-Za-z0-9.\-:\[\]]+$")

# scheme 白名单:X-Forwarded-Proto 客户端可控且 uvicorn 原样透传(如 wss 直接
# 写进 scope["scheme"]),拼进 endpoint botocore 无法解析 → 非 http/https 一律
# 返 None 回落静态(D3 不报错)
_VALID_SCHEMES = frozenset({"http", "https"})

# 动态 signer 缓存上限:Host 头客户端可控,已认证用户轮换合法 Host 即可逐个
# 建 boto3 client 刷单进程内存 —— 常数上限封顶,超限不再新建、回落静态
# endpoint(签名仍可用,只是 host 不跟随入口;真实部署入口数远小于该值)
MAX_DYNAMIC_SIGNERS = 16


def request_base_from(request: Request) -> str | None:
    """从请求上下文取预签名 URL 的 base(f"{scheme}://{host}")。

    host 取 Host 头(含端口 —— S3v4 签名把 host:port 算进 canonical
    request,与 nginx 侧 $http_host 同源;$host 会剥端口);scheme 取
    request.url.scheme(uvicorn 开 --proxy-headers,nginx 透传
    X-Forwarded-Proto 后 https 入口即 https)。Host 缺失 / 超长(>253)/
    非法字符、scheme 不在 {http,https} 白名单(XFP 客户端可控,uvicorn
    原样透传 wss 等)返回 None,调用方回落静态 endpoint。host 一律
    lower() 归一:浏览器对 host 本就小写化(DNS 大小写不敏感,botocore
    签名时亦小写化),归一不改签名语义,且让动态缓存同键不建冗余 client。
    """
    host = request.headers.get("host") or ""
    if not host or len(host) > 253 or not _HOST_PATTERN.match(host):
        return None
    scheme = request.url.scheme
    if scheme not in _VALID_SCHEMES:
        return None
    return f"{scheme}://{host.lower()}"


class PresignService:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._s3_internal = boto3.client(
            "s3",
            endpoint_url=settings.minio_endpoint_internal,
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            config=Config(signature_version="s3v4", region_name="us-east-1"),
        )
        self._s3_signer = boto3.client(
            "s3",
            endpoint_url=settings.minio_endpoint_public,
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            config=Config(signature_version="s3v4", region_name="us-east-1"),
        )
        # ADR-0008 P1:缩略图走独立 MinIO(SSD)。endpoint 留空 → 回落主 MinIO(降级)
        self._s3_thumb_signer = boto3.client(
            "s3",
            endpoint_url=settings.minio_thumbnail_endpoint_public or settings.minio_endpoint_public,
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            config=Config(signature_version="s3v4", region_name="us-east-1"),
        )
        # 内部视角的缩略图 client(删除派生对象用)—— 与 worker 的 _thumb_s3_client
        # 同构:指独立 SSD 实例,留空回落主 MinIO。不能复用 _s3_internal:分层部署
        # 下主/缩略图是两个实例,用主实例删 ms-thumbs 会打错地方(NoSuchBucket 被吞)
        self._s3_thumb_internal = boto3.client(
            "s3",
            endpoint_url=settings.minio_thumbnail_endpoint_internal or settings.minio_endpoint_internal,
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            config=Config(signature_version="s3v4", region_name="us-east-1"),
        )
        self._sts = boto3.client(
            "sts",
            endpoint_url=settings.minio_endpoint_internal,
            aws_access_key_id=settings.minio_access_key,
            aws_secret_access_key=settings.minio_secret_key,
            region_name="us-east-1",
            config=Config(signature_version="s3v4"),
        )
        # 动态签发:按请求入口 base(scheme://host[:port])缓存的 signer client,
        # 首见创建。Host 头客户端可控 —— 缓存键做大小写归一 + 常数上限
        # (MAX_DYNAMIC_SIGNERS,见 _signer_for),超限回落静态防刷内存。
        # 原片与缩略图动态模式共用同一批 client:两者 host 同源(nginx 按
        # /ms-thumbs/ 路径分流),client 只关心 endpoint,bucket 由签名时的
        # Params 决定
        self._dynamic_signers: dict[str, Any] = {}
        self._dynamic_cap_warned = False  # 达上限 log.warning 只报一次,不刷日志

    def _signer_for(self, request_base: str | None, fallback: Any) -> Any:
        """按 request_base 取签名 client:None 回落 fallback(静态 signer),
        否则取/建缓存的动态 client(缓存策略见 __init__ 与 MAX_DYNAMIC_SIGNERS)。

        与 _s3_signer 同构,仅 endpoint 换成 request_base:S3v4 签名把
        host(:port) 算进 canonical request,换 endpoint 即换签出 URL 的
        scheme://host,凭据与签名算法不变,MinIO 侧按 URL host 校验通过。
        防御(D3 可用性优先,2026-10-12 修复):
          - request_base 先 lower() 归一(与 request_base_from 同步,直调方
            传大写也同键)—— host 语义本就大小写不敏感,签名不变;
          - botocore 拒绝语义非法 endpoint 时(「http://::1」构造期抛
            ValueError、「http://a:b:c」签名期抛 EndpointResolutionError)
            捕获、log.warning 并回落 fallback,不缓存半成品不抛错;
          - 缓存达 MAX_DYNAMIC_SIGNERS 不再新建,回落 fallback(防客户端
            轮换 Host 刷单进程内存)。
        """
        if not request_base:
            return fallback
        base = request_base.lower()
        client = self._dynamic_signers.get(base)
        if client is not None:
            return client
        if len(self._dynamic_signers) >= MAX_DYNAMIC_SIGNERS:
            if not self._dynamic_cap_warned:
                log.warning(
                    "动态 signer 缓存达上限 %s,后续未知入口回落静态 endpoint"
                    "(防客户端轮换 Host 刷内存)", MAX_DYNAMIC_SIGNERS,
                )
                self._dynamic_cap_warned = True
            return fallback
        try:
            client = boto3.client(
                "s3",
                endpoint_url=base,
                aws_access_key_id=self._settings.minio_access_key,
                aws_secret_access_key=self._settings.minio_secret_key,
                config=Config(signature_version="s3v4", region_name="us-east-1"),
            )
            # 构造成功 ≠ 可签名:部分语义非法 endpoint 逃过构造期校验(如
            # 「http://::1」构造期抛 ValueError,而「http://a:b:c」要到
            # generate_presigned_url 的 endpoint ruleset 解析才抛
            # EndpointResolutionError)。做一次本地 canary 签名(纯计算不触网)
            # 提前暴露:坏 client 不进缓存、整体回落静态(D3)。
            client.generate_presigned_url(
                "get_object", Params={"Bucket": "canary", "Key": "canary"}, ExpiresIn=1,
            )
        except Exception as e:
            # botocore 的 endpoint 校验(ValueError:Invalid endpoint)与
            # EndpointResolutionError 等:语义非法 base 不值得让 5 个接入点
            # 全体 500,回落静态(D3)
            log.warning(
                "动态 signer 构造失败(request_base=%r:%s: %s),回落静态 endpoint",
                base, type(e).__name__, e,
            )
            return fallback
        self._dynamic_signers[base] = client
        return client

    def sign_get_url(
        self,
        bucket: str,
        key: str,
        expires_seconds: int,
        response_content_disposition: str | None = None,
        request_base: str | None = None,
    ) -> str:
        """签 GET presigned URL。

        response_content_disposition 非 None 时并入 Params(移动端下载直连的
        attachment 语义,方案 §3.5);None 时 Params 与旧版完全一致(预览路径
        inline 语义零变化)。
        request_base 传入时 URL 的 scheme://host 跟随请求入口(动态签发,见
        模块 docstring);None 时走静态 MINIO_ENDPOINT_PUBLIC(零行为变化)。
        """
        params: dict[str, Any] = {"Bucket": bucket, "Key": key}
        if response_content_disposition is not None:
            params["ResponseContentDisposition"] = response_content_disposition
        signer = self._signer_for(request_base, self._s3_signer)
        return signer.generate_presigned_url(
            "get_object",
            Params=params,
            ExpiresIn=expires_seconds,
        )

    def delete_object(self, bucket: str, key: str) -> None:
        """删除主存储对象(purge 用;软删本身不删对象)。"""
        self._s3_internal.delete_object(Bucket=bucket, Key=key)

    def copy_object(self, bucket: str, source_key: str, dest_key: str) -> dict[str, Any]:
        """同 bucket 服务端复制对象(batch-prefix key 迁移用,§F3)。

        走 s3_internal(admin client,与 create/complete multipart 同通道);
        返回新对象的 etag / version_id(无版本化 bucket 两者常为 None),
        供 DB 行 UPDATE 时沿用「copy 有新值则用新值,否则保留原值」语义。
        """
        resp = self._s3_internal.copy_object(
            Bucket=bucket,
            Key=dest_key,
            CopySource={"Bucket": bucket, "Key": source_key},
        )
        return {
            "etag": (resp.get("CopyObjectResult", {}).get("ETag") or "").strip('"') or None,
            "version_id": resp.get("VersionId"),
        }

    def delete_thumbnail_object(self, key: str) -> None:
        """删除缩略图 MinIO(SSD,ADR-0008 P1 独立实例)上的派生对象。"""
        self._s3_thumb_internal.delete_object(
            Bucket=self._settings.minio_thumbnail_bucket, Key=key,
        )

    @property
    def thumbnail_bucket(self) -> str:
        """缩略图 MinIO 的 bucket 名(ADR-0008 P1;清理派生对象用)。"""
        return self._settings.minio_thumbnail_bucket

    def sign_put_url(
        self, bucket: str, key: str, expires_seconds: int, request_base: str | None = None
    ) -> str:
        """签 PUT presigned URL(现无调用方;4 个签名方法参数保持一致 — D2)。"""
        signer = self._signer_for(request_base, self._s3_signer)
        return signer.generate_presigned_url(
            "put_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=expires_seconds,
        )

    def sign_thumbnail_url(
        self, key: str, expires_seconds: int, request_base: str | None = None
    ) -> str:
        """缩略图 presigned URL(ADR-0008 P1)。

        走缩略图 MinIO(SSD)的公开 endpoint + 独立 bucket;不走 OpenFGA enforce
        (既有决策:1024px 模糊化)。host 绑定:P-10 坑 — endpoint 必须等于
        浏览器实际访问缩略图的 host(nginx 按 /ms-thumbs/ 路由)。
        request_base 传入时 endpoint 整体替换为该 host(缩略图与原片同 vhost,
        nginx 按 /ms-thumbs/ 路径分流,host 同源);MINIO_THUMBNAIL_ENDPOINT_PUBLIC
        仅作无请求上下文的回落。
        """
        signer = self._signer_for(request_base, self._s3_thumb_signer)
        return signer.generate_presigned_url(  # type: ignore[no-any-return]
            "get_object",
            Params={
                "Bucket": self._settings.minio_thumbnail_bucket,
                "Key": key,
            },
            ExpiresIn=expires_seconds,
        )

    def create_multipart_upload(
        self, bucket: str, key: str, content_type: str = "application/octet-stream"
    ) -> str:
        resp = self._s3_internal.create_multipart_upload(
            Bucket=bucket, Key=key, ContentType=content_type
        )
        return resp["UploadId"]

    def sign_part_url(
        self,
        bucket: str,
        key: str,
        upload_id: str,
        part_number: int,
        expires_seconds: int,
        request_base: str | None = None,
    ) -> str:
        signer = self._signer_for(request_base, self._s3_signer)
        return signer.generate_presigned_url(
            "upload_part",
            Params={
                "Bucket": bucket,
                "Key": key,
                "UploadId": upload_id,
                "PartNumber": part_number,
            },
            ExpiresIn=expires_seconds,
        )

    def complete_multipart_upload(
        self,
        bucket: str,
        key: str,
        upload_id: str,
        parts: list[dict[str, Any]],
    ) -> dict[str, Any]:
        # 清洗 parts:uppy v4 client 把 PUT response 整组 headers 都塞进 part dict,
        # boto3 严格只接 PartNumber / ETag / Checksum*,其他字段会触发
        # 'Unknown parameter' 校验失败 → 5xx。这里 case-insensitive 提取 + key 大小写归一。
        ALLOWED = {
            "etag", "partnumber",
            "checksumcrc32", "checksumcrc32c", "checksumcrc64nvme",
            "checksumsha1", "checksumsha256",
        }
        # 大小写归一:PartNumber / ETag / ChecksumXxx 是 boto3 期望的 Pascal/camel
        BOTO_KEY = {
            "etag": "ETag", "partnumber": "PartNumber",
            "checksumcrc32": "ChecksumCRC32", "checksumcrc32c": "ChecksumCRC32C",
            "checksumcrc64nvme": "ChecksumCRC64NVME",
            "checksumsha1": "ChecksumSHA1", "checksumsha256": "ChecksumSHA256",
        }

        cleaned: list[dict[str, Any]] = []
        for p in parts:
            row: dict[str, Any] = {}
            for k, v in p.items():
                lk = k.lower()
                if lk in ALLOWED:
                    # ETag 去引号(uppy 不一定 strip)
                    if lk == "etag" and isinstance(v, str):
                        v = v.strip().strip('"')
                    row[BOTO_KEY[lk]] = v
            if "PartNumber" in row and "ETag" in row:
                cleaned.append(row)

        cleaned.sort(key=lambda r: int(r["PartNumber"]))

        resp = self._s3_internal.complete_multipart_upload(
            Bucket=bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={"Parts": cleaned},
        )
        return {
            "location": resp.get("Location"),
            "etag": resp.get("ETag"),
            "version_id": resp.get("VersionId"),
        }

    def abort_multipart_upload(self, bucket: str, key: str, upload_id: str) -> None:
        self._s3_internal.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)

    def head_object(self, bucket: str, key: str) -> dict[str, Any]:
        """拿 object 元信息(size / content-type / etag),complete 后 enrich Asset 用。"""
        resp = self._s3_internal.head_object(Bucket=bucket, Key=key)
        return {
            "size_bytes": int(resp.get("ContentLength", 0)),
            "content_type": resp.get("ContentType"),
            "etag": (resp.get("ETag") or "").strip('"') or None,
            "version_id": resp.get("VersionId"),
            "last_modified": resp.get("LastModified"),
        }

    def list_parts(self, bucket: str, key: str, upload_id: str) -> list[dict[str, Any]]:
        resp = self._s3_internal.list_parts(Bucket=bucket, Key=key, UploadId=upload_id)
        return [
            {"PartNumber": p["PartNumber"], "Size": p["Size"], "ETag": p["ETag"]}
            for p in resp.get("Parts", [])
        ]

    def issue_sts_for_prefix(
        self,
        user_id: str,
        bucket: str,
        prefix: str,
        duration_seconds: int = 3600,
        readonly: bool = True,
    ) -> dict[str, str]:
        """7-bis.1:给桌面客户端签 时间 + 资源 双限制 的临时凭据。"""
        actions = ['"s3:GetObject"', '"s3:ListBucket"', '"s3:GetBucketLocation"']
        if not readonly:
            actions += ['"s3:PutObject"', '"s3:AbortMultipartUpload"', '"s3:ListBucketMultipartUploads"']

        policy = f'''{{
            "Version": "2012-10-17",
            "Statement": [
                {{
                    "Effect": "Allow",
                    "Action": [{",".join(actions)}],
                    "Resource": [
                        "arn:aws:s3:::{bucket}",
                        "arn:aws:s3:::{bucket}/{prefix}*"
                    ],
                    "Condition": {{
                        "StringLike": {{"s3:prefix": ["{prefix}*"]}}
                    }}
                }}
            ]
        }}'''
        resp = self._sts.assume_role(
            RoleArn=f"arn:minio:sts::{user_id}",
            RoleSessionName=f"material-storage-{user_id}",
            DurationSeconds=duration_seconds,
            Policy=policy,
        )
        creds = resp["Credentials"]
        return {
            "access_key": creds["AccessKeyId"],
            "secret_key": creds["SecretAccessKey"],
            "session_token": creds["SessionToken"],
            "expiration": creds["Expiration"].isoformat(),
        }

    def get_object_streaming(self, bucket: str, key: str):  # type: ignore[no-untyped-def]
        """敏感目录代理 stream 用;返回 StreamingBody,可 iter_chunks()。"""
        resp = self._s3_internal.get_object(Bucket=bucket, Key=key)
        return resp["Body"]
