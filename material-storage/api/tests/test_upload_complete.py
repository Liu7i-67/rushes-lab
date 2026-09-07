"""complete endpoint 契约(显式 folder_id + key 前缀校验)— 容器内跑。

回归背景:此前 complete 按 key 目录前缀反查 folder(scalar_one_or_none),
生产库存在跨 project 的同名目录树(uq_folder_project_prefix 是
(project_id, prefix) 维度,跨 project 同前缀合法)→ 多行命中抛
MultipleResultsFound → 裸 500。契约改为显式 folder_id 主键解析后歧义天然
消除:主键唯一,同一把 key 只可能解析到「调用方指定的那个 folder」,前缀
校验再保证 key 确实落在它名下(见 test_complete_same_prefix_across_projects)。

预期前置(同 test_trash_and_purge):
  1. seed_demo_data.py 已跑过(PROJECT_EVENT / PROJECT_WEDDING 的 UUID 来自它)
  2. env=dev(允许 X-User-Id header 模拟身份)
  3. ms-api 容器可达 MinIO 内部端点:complete/abort 走 API 自带的
     s3_internal client;part 上传在测试里直连内部端点 PUT
     (公网签名 URL 是浏览器视角 host,容器内不通)
"""
from __future__ import annotations

import uuid

import boto3
import pytest
from botocore.client import Config
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.main import create_app
from app.settings import get_settings

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"          # 系统 admin(org admin)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"    # public
PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"  # private

PART_BODY = b"upload-complete-test" * 2


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


async def _create_folder(client: AsyncClient, project_id: str, name: str) -> dict:
    r = await client.post(
        "/api/v1/folders", json={"project_id": project_id, "name": name}, headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _create_multipart(client: AsyncClient, folder: dict, filename: str) -> dict:
    r = await client.post("/api/v1/assets/uploads", json={
        "folder_id": folder["id"],
        "filename": filename,
        "content_type": "text/plain",
        "size_bytes": len(PART_BODY),
    }, headers=_h())
    assert r.status_code == 200, r.text
    return r.json()  # {upload_id, key, bucket}


def _upload_part(bucket: str, key: str, upload_id: str) -> str:
    """直连 MinIO 内部端点传 1 个 part,返回 ETag(uppy 侧本应是浏览器 PUT)。"""
    s = get_settings()
    s3 = boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
        region_name="us-east-1",
    )
    resp = s3.upload_part(
        Bucket=bucket, Key=key, PartNumber=1, UploadId=upload_id, Body=PART_BODY,
    )
    return resp["ETag"]


async def _complete(
    client: AsyncClient, upload_id: str, folder_id: str,
    bucket: str, key: str, parts: list[dict],
):
    # parts 的 key 用 uppy 的驼峰形状(presign 清洗按 lower() 匹配 "partnumber")
    return await client.post(
        f"/api/v1/assets/uploads/{upload_id}/complete",
        json={
            "upload_id": upload_id,
            "folder_id": folder_id,
            "bucket": bucket,
            "key": key,
            "parts": parts,
        },
        headers=_h(),
    )


async def _abort(client: AsyncClient, upload: dict) -> None:
    r = await client.delete(
        f"/api/v1/assets/uploads/{upload['upload_id']}",
        params={"bucket": upload["bucket"], "key": upload["key"]}, headers=_h(),
    )
    assert r.status_code == 204, r.text


async def _get_asset(asset_id: str) -> Asset | None:
    async with get_sessionmaker()() as db:
        return await db.get(Asset, uuid.UUID(asset_id))


async def _cleanup(client: AsyncClient, asset_ids: list[str], folder_ids: list[str]) -> None:
    """软删 + 彻底删除测试资产,再删空 folder(删夹要求无活文件且回收站空)。"""
    for aid in asset_ids:
        r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
        assert r.status_code == 204, r.text
        r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
        assert r.status_code == 204, r.text
    for fid in folder_ids:
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        assert r.status_code == 204, r.text


@pytest.mark.asyncio
async def test_complete_missing_folder_id_is_422(client: AsyncClient) -> None:
    """缺 folder_id → FastAPI 入参校验 422(契约必填,请求体都到不了 handler)。"""
    uniq = uuid.uuid4().hex[:8]
    folder = await _create_folder(client, PROJECT_EVENT, f"zz_up422_{uniq}")
    upload: dict = {}
    try:
        upload = await _create_multipart(client, folder, f"zz_up422_{uniq}.txt")
        r = await client.post(
            f"/api/v1/assets/uploads/{upload['upload_id']}/complete",
            json={  # 故意不带 folder_id
                "upload_id": upload["upload_id"],
                "bucket": upload["bucket"],
                "key": upload["key"],
                "parts": [],
            },
            headers=_h(),
        )
        assert r.status_code == 422, r.text
    finally:
        if upload:
            await _abort(client, upload)  # 422 时 multipart 仍开着,清掉
        await _cleanup(client, [], [folder["id"]])


@pytest.mark.asyncio
async def test_complete_folder_key_mismatch_is_400(client: AsyncClient) -> None:
    """folder_id 与 key 前缀不一致(拿另一个 folder 的 id)→ 400,不落库。"""
    uniq = uuid.uuid4().hex[:8]
    f1 = await _create_folder(client, PROJECT_EVENT, f"zz_upm1_{uniq}")
    f2 = await _create_folder(client, PROJECT_EVENT, f"zz_upm2_{uniq}")
    upload: dict = {}
    try:
        upload = await _create_multipart(client, f1, f"zz_upm_{uniq}.txt")
        # create_upload 用 f"{minio_prefix.rstrip('/')}/{filename}" 拼 key
        assert upload["key"] == f"{f1['minio_prefix'].rstrip('/')}/zz_upm_{uniq}.txt"
        etag = _upload_part(upload["bucket"], upload["key"], upload["upload_id"])
        r = await _complete(
            client, upload["upload_id"], f2["id"],  # ← 别的 folder
            upload["bucket"], upload["key"], [{"partNumber": 1, "etag": etag}],
        )
        assert r.status_code == 400, r.text
        assert r.json()["detail"] == "key 与 folder 不匹配,请重新上传"
        # 400 发生在 MinIO complete 之前:key 名下的 f1 里没有入座行
        r = await client.get(
            f"/api/v1/assets?folder_id={f1['id']}", headers=_h(),
        )
        assert r.status_code == 200 and r.json()["total"] == 0
    finally:
        if upload:
            await _abort(client, upload)
        await _cleanup(client, [], [f1["id"], f2["id"]])


@pytest.mark.asyncio
async def test_complete_same_prefix_across_projects(client: AsyncClient) -> None:
    """原始故障场景回归:两个不同 project 的同名目录(minio_prefix 相同)各自
    complete 都成功且 folder_id 各归各夹 —— 此前按 key 前缀反查 folder 在此
    场景 scalar_one_or_none 多行命中 → 裸 500。

    主键解析消除歧义的原理:folder_id 由契约显式携带且是主键,反查的「多行
    命中」不可能再发生;前缀校验只对调用方指定的那一个 folder 做。两个上传用
    不同 filename,避免两 project 共用 bucket 时撞 uq_asset_minio_object_version
    (歧义的要害是 minio_prefix 相同,与 filename 无关)。
    """
    uniq = uuid.uuid4().hex[:8]
    name = f"zz_ambig_{uniq}"
    fe = await _create_folder(client, PROJECT_EVENT, name)
    fw = await _create_folder(client, PROJECT_WEDDING, name)
    # 前置成立:跨 project 的 minio_prefix 确实相同(uq 约束是 (project_id, prefix))
    assert fe["minio_prefix"] == fw["minio_prefix"] == f"{name}/"

    uploads: list[dict] = []
    completed: set[str] = set()  # 已 complete 成功的 upload 不能再 abort(严格 S3 报 NoSuchUpload)
    asset_ids: list[str] = []
    try:
        for folder, filename in ((fe, f"{name}_event.txt"), (fw, f"{name}_wedding.txt")):
            upload = await _create_multipart(client, folder, filename)
            uploads.append(upload)
            etag = _upload_part(upload["bucket"], upload["key"], upload["upload_id"])
            r = await _complete(
                client, upload["upload_id"], folder["id"],
                upload["bucket"], upload["key"], [{"partNumber": 1, "etag": etag}],
            )
            assert r.status_code == 200, r.text
            completed.add(upload["upload_id"])
            body = r.json()
            assert body["folder_id"] == folder["id"]
            assert body["filename"] == filename
            asset_ids.append(body["id"])

        # 入库行 folder_id 各归各夹(而不是反查到的某个「碰巧同名」的 folder)
        row_e = await _get_asset(asset_ids[0])
        row_w = await _get_asset(asset_ids[1])
        assert row_e is not None and str(row_e.folder_id) == fe["id"]
        assert row_w is not None and str(row_w.folder_id) == fw["id"]
    finally:
        for upload in uploads:
            if upload["upload_id"] not in completed:
                await _abort(client, upload)
        await _cleanup(client, asset_ids, [fe["id"], fw["id"]])
