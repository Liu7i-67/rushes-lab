"""动态 Host 预签发 — 专职测试补充用例(边界/异常场景,qdev 测试周期 2026-10-12)。

与 test_dynamic_presign_host.py 的分工:正文件覆盖方案「测试功能点」1-5 + 两条
容器级主链路;本文件是全方位测试的边界/异常补充,复用正文件的替身与容器级
helpers(import 复用,不改正文件)。结论以 docstring 标注编号,对应测试报告:

  P1-1  Host/XFP 字符集合法但语义非法(裸 IPv6「::1」/ 多冒号「a:b:c」/ XFP=wss)
        → 曾让 _dynamic_signer 构造 boto3 client 抛异常 → 5xx,违反 D3。
        修复(2026-10-12):scheme 白名单 {http,https}(wss → None 回落)+
        _signer_for 构造失败捕获回落静态(不缓存不抛);test_ext_1(scheme)/
        test_ext_2 / 容器级 c6 已按新契约转正
  P2-1  _dynamic_signers 按 Host 头(客户端可控)缓存曾无上限 → 修复:常数上限
        MAX_DYNAMIC_SIGNERS=16,超限回落静态不新建(test_ext_3 按新契约断言)
  P2-2  缓存键曾未归一大小写(同入口两形态各建一份)→ 修复:request_base 与
        缓存键同步 lower() 归一,同入口共用同一 client(test_ext_3 按新契约断言)
  观察  XFP 多值/大写 → uvicorn ProxyHeadersMiddleware 只认 {http,https,ws,wss}
        精确值,其余一律不改 scheme → 安全回落 http(无崩溃无畸形 URL);
        下划线 host / 逗号 host → request_base_from 返 None 回落静态。

运行:docker exec feat-ms-api python -m pytest tests/test_dynamic_presign_host_ext.py -v
"""
from __future__ import annotations

import uuid as _uuid
from typing import Any

import boto3
import pytest
from httpx import AsyncClient
from starlette.requests import Request

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.services.presign import PresignService, request_base_from
from app.settings import get_settings
from tests.test_dynamic_presign_host import (
    HTTPS_HOST,
    PROJECT_EVENT,
    WAN_HOST,
    Boto3ClientSpy,
    _abort,
    _cleanup,
    _complete,
    _create_folder,
    _create_multipart,
    _entry_headers,
    _skip_if_no_dev_channel,
    _upload_part,
    mk_request,
    mk_settings,
)
from tests.test_dynamic_presign_host import (
    api_base as _dph_api_base,
)
from tests.test_dynamic_presign_host import (
    client as _dph_client,
)

# fixture 再导出:pytest 按本 module 命名空间按名解析 fixture(别名导入,
# 避开「测试函数形参 client 遮蔽导入名」的 F811)
api_base = _dph_api_base
client = _dph_client


# ══════════════════════════════════════════════════════════════════════════════
# 离线单元:helper 校验边界与缓存行为
# ══════════════════════════════════════════════════════════════════════════════
def test_ext_1_request_base_from_accepts_charset_legal_but_semantically_invalid_hosts() -> None:
    """P1-1 前置证据:裸 IPv6「::1」与多冒号「a:b:c」满足字符集 ^[A-Za-z0-9.\\-:\\[\\]]+$,
    request_base_from 放行(拼出「http://::1」这类 botocore 无法解析的 endpoint);
    尾点域名合法放行(浏览器/dns 语义等价,签名客户端会小写化,实测可用)。"""
    assert request_base_from(mk_request(host="::1")) == "http://::1"
    assert request_base_from(mk_request(host="a:b:c")) == "http://a:b:c"
    assert request_base_from(mk_request(host="bucket.taoxiplan.com.")) == (
        "http://bucket.taoxiplan.com."
    )


def test_ext_1_request_base_from_rejects_comma_and_underscore_hosts() -> None:
    """逗号 Host(header 注入拼接形态)与下划线 host(RFC 952 非法,虽内网常见)
    均不在字符集内 → None 回落静态(实测 API 侧返回静态 endpoint,见容器级 c4/c5)。"""
    assert request_base_from(mk_request(host="bucket.taoxiplan.com,evil.com")) is None
    assert request_base_from(mk_request(host="bucket_zone.example.com")) is None


def test_ext_1_request_base_from_scheme_whitelist_rejects_wss() -> None:
    """P1-1c 修复后契约:scheme 白名单 {http,https} —— XFP=wss 被 uvicorn 原样
    写进 scope 时 request_base_from 返 None 回落静态(修复前拼出「wss://host」进
    _dynamic_signer → botocore EndpointResolutionError → 5xx,容器级 c8 实锤)。"""
    req: dict[str, Any] = dict(mk_request(host="bucket.taoxiplan.com").scope)
    req["scheme"] = "wss"
    assert request_base_from(Request(req)) is None


def test_ext_2_dynamic_signer_invalid_endpoint_falls_back_to_static() -> None:
    """P1-1 修复后契约(D3,走真 boto3 —— 异常来自 botocore 真实 endpoint 校验,
    不能 monkeypatch):charset 合法但语义非法的 request_base 让 botocore 拒签 →
    _signer_for 捕获后 log.warning 回落静态 signer,不报错(URL 前缀=静态
    MINIO_ENDPOINT_PUBLIC);失败路径不污染缓存(dict 赋值在构造成功后)。
    两种实锤形态:「http://::1」client 构造期抛 ValueError、「http://a:b:c」
    构造成功但 generate_presigned_url 的 endpoint ruleset 解析抛
    EndpointResolutionError(canary 签名提前暴露)。容器级 c6 为同款契约端到端。"""
    settings = mk_settings()
    svc = PresignService(settings)
    for bad_base in ("http://::1", "http://a:b:c"):
        url = svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base=bad_base)
        assert url.startswith(settings.minio_endpoint_public + "/"), bad_base
    assert svc._dynamic_signers == {}  # 失败路径不在缓存留半成品


def test_ext_3_dynamic_signer_cache_capped_beyond_limit_falls_back(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """P2-1 修复后契约:缓存有常数上限(MAX_DYNAMIC_SIGNERS=16)—— 上限内逐
    host 正常建 client;超限不再新建,回落静态 endpoint 不报错(防已认证用户
    轮换客户端可控 Host 刷单进程内存;超限请求只是 URL host 不跟随入口)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    svc = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()
    urls = [
        svc.sign_get_url(
            "ms-proj", "f/a.mp4", 600,
            request_base=f"http://10.0.0.{i % 256}.host{i}.example",
        )
        for i in range(20)
    ]
    assert len(spy.created) == 16           # 上限内逐 host 新建,达上限后不再建
    assert len(svc._dynamic_signers) == 16
    for u in urls[16:]:
        assert u.startswith("http://localhost:9000/")  # 超限回落静态,不报错


def test_ext_3_cache_key_case_normalized_same_entry_single_client(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """P2-2 修复后契约:缓存键大小写归一 —— 同入口大小写两形态共用同一
    client(浏览器对 host 本就小写化、botocore 签名时亦小写化,归一不改
    签名语义,只消冗余;URL 回显同一 client_id)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    svc = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()
    u1 = svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base="https://BUCKET.TaoxiPlan.COM")
    u2 = svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base="https://bucket.taoxiplan.com")
    assert len(spy.created) == 1            # 归一后同键:仅一份 client
    assert len(svc._dynamic_signers) == 1
    assert u1 == u2


def test_ext_4_dynamic_and_static_signers_interleave_cleanly(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """同 service 实例上动态/静态/缩略图交错签名:静态调用零新建,动态按 base
    复用,动态失败路径(异常)不在缓存留半成品(dict 赋值在 client 构造成功后)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    svc = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()
    svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base="https://bucket.taoxiplan.com")
    svc.sign_get_url("ms-proj", "f/a.mp4", 600)  # 静态
    svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base="https://bucket.taoxiplan.com")
    assert len(spy.created) == 1
    assert len(svc._dynamic_signers) == 1
    u = svc.sign_get_url("ms-proj", "f/a.mp4", 600, request_base="https://bucket.taoxiplan.com")
    assert u.endswith("&client=1")  # 同 base 持续复用缓存(失败无污染的验证见 test_ext_2)
    svc.sign_thumbnail_url("thumbs/a.jpg", 1800, request_base="https://bucket.taoxiplan.com")
    assert len(svc._dynamic_signers) == 1  # 缩略图与原片动态共用同批 client(同 endpoint)


# ══════════════════════════════════════════════════════════════════════════════
# 容器级:feat-ms 隔离栈(API 直连模拟 nginx 转发头,打真 uvicorn socket)
# ══════════════════════════════════════════════════════════════════════════════
async def _mk_asset_with_tags(client: AsyncClient, uniq: str, **tags: str) -> tuple[dict, dict, str]:
    """建 folder + multipart + 传 1 个 part + complete,返回 (folder, upload, asset_id)。"""
    folder = await _create_folder(client, PROJECT_EVENT, f"zz_dphe_{uniq}")
    upload = await _create_multipart(client, folder, f"zz_dphe_{uniq}.txt")
    etag = _upload_part(upload["bucket"], upload["key"], upload["upload_id"])
    r = await _complete(
        client, upload["upload_id"], folder["id"],
        upload["bucket"], upload["key"], [{"partNumber": 1, "etag": etag}],
    )
    assert r.status_code == 200, r.text
    if tags:
        await _set_tags(r.json()["id"], **tags)
    return folder, upload, r.json()["id"]


async def _set_tags(asset_id: str, **kv: str) -> None:
    """直改 DB tags(与正文件 _set_thumbnail_key 同范式,多键一次写入)。"""
    async with get_sessionmaker()() as db:
        asset = await db.get(Asset, _uuid.UUID(asset_id))
        assert asset is not None
        asset.tags = {**(asset.tags or {}), **kv}
        await db.commit()


@pytest.mark.asyncio
async def test_ext_c1_part_url_dynamic_follows_entry_https_and_wan(client: AsyncClient) -> None:
    """sign_part(上传分片 URL,5 处接入点之一,正文件容器级未覆盖):https 域名入口
    → https://bucket.taoxiplan.com/ 前缀;外网 IP:端口入口(无 XFP)→ http://IP:端口/。"""
    await _skip_if_no_dev_channel(client)
    uniq = _uuid.uuid4().hex[:8]
    folder = await _create_folder(client, PROJECT_EVENT, f"zz_dphep_{uniq}")
    upload: dict = {}
    try:
        upload = await _create_multipart(client, folder, f"zz_dphep_{uniq}.txt")
        params = {"bucket": upload["bucket"], "key": upload["key"]}

        r = await client.get(
            f"/api/v1/assets/uploads/{upload['upload_id']}/parts/1",
            params=params, headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200, r.text
        assert r.json()["url"].startswith(f"https://{HTTPS_HOST}/"), r.json()["url"]

        r2 = await client.get(
            f"/api/v1/assets/uploads/{upload['upload_id']}/parts/1",
            params=params, headers=_entry_headers(WAN_HOST),
        )
        assert r2.status_code == 200, r2.text
        assert r2.json()["url"].startswith(f"http://{WAN_HOST}/"), r2.json()["url"]
    finally:
        if upload:
            await _abort(client, upload)
        await _cleanup(client, [], [folder["id"]])


@pytest.mark.asyncio
async def test_ext_c2_live_preview_url_dynamic_follows_entry(client: AsyncClient) -> None:
    """live-preview-url(5 处接入点之一,正文件容器级未覆盖):DB 直塞
    tags.live_video_key + https 域名入口 → URL 前缀 https://bucket.taoxiplan.com/ms-thumbs/
    (实况派生对象与缩略图同 bucket 同 vhost,明细 A.5)。"""
    await _skip_if_no_dev_channel(client)
    uniq = _uuid.uuid4().hex[:8]
    asset_id = ""
    folder: dict = {}
    try:
        folder, _upload, asset_id = await _mk_asset_with_tags(
            client, uniq, live_video_key=f"live/{uniq}.mp4",
        )
        r = await client.get(
            f"/api/v1/assets/{asset_id}/live-preview-url",
            headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200, r.text
        assert r.json()["url"].startswith(f"https://{HTTPS_HOST}/ms-thumbs/"), r.json()["url"]
        assert r.json()["expires_in"] == 1800
    finally:
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"] if folder else ""])


@pytest.mark.asyncio
async def test_ext_c3_download_link_attachment_semantics_with_dynamic_overlay(client: AsyncClient) -> None:
    """download-link 的 attachment 语义与动态叠加正交:?as_attachment=true + https 域名
    入口 → URL 前缀 https://HOST/ 且带 ResponseContentDisposition=attachment(RFC5987
    filename* 由 test_download_attachment 覆盖,此处只验「叠加不互斥」)。"""
    await _skip_if_no_dev_channel(client)
    uniq = _uuid.uuid4().hex[:8]
    asset_id = ""
    folder: dict = {}
    try:
        folder, _upload, asset_id = await _mk_asset_with_tags(client, uniq)
        r = await client.post(
            f"/api/v1/assets/{asset_id}/download-link",
            json={"as_attachment": True},   # DownloadLinkIn body 字段(非 query)
            headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200, r.text
        url = r.json()["url"]
        assert url.startswith(f"https://{HTTPS_HOST}/"), url
        # MinIO 侧 query 形态为小写连字符,response-content-disposition 按 RFC 6266
        # 编码;attachment 前缀必现(filename 部分中文会 RFC5987 编码,不在此断言)
        assert "response-content-disposition=attachment" in url.lower(), url
        assert r.json()["expires_in"] == 900
    finally:
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"] if folder else ""])


@pytest.mark.asyncio
async def test_ext_c4_illegal_host_falls_back_to_static_endpoint(client: AsyncClient) -> None:
    """Host 非法(逗号拼接 / 下划线)→ request_base_from 返 None → 回落静态
    MINIO_ENDPOINT_PUBLIC(feat-ms env 为 http://localhost:6100),200 不报错(D3 主形态)。"""
    await _skip_if_no_dev_channel(client)
    static_prefix = get_settings().minio_endpoint_public.rstrip("/") + "/"
    uniq = _uuid.uuid4().hex[:8]
    asset_id = ""
    folder: dict = {}
    try:
        folder, _upload, asset_id = await _mk_asset_with_tags(client, uniq)
        for host in ("bucket.taoxiplan.com,evil.com", "bucket_zone.example.com"):
            r = await client.post(
                f"/api/v1/assets/{asset_id}/download-link", headers=_entry_headers(host),
            )
            assert r.status_code == 200, f"{host}: {r.text}"
            assert r.json()["url"].startswith(static_prefix), f"{host}: {r.json()['url']}"
    finally:
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"] if folder else ""])


@pytest.mark.asyncio
async def test_ext_c5_xfp_invalid_values_downgrade_to_http_gracefully(client: AsyncClient) -> None:
    """XFP 非法值实测(uvicorn ProxyHeadersMiddleware 0.52.4 只认 {http,https,ws,wss}
    精确值,其余不改 scheme):
    - 「https, http」(多值)与「HTTPS」(大写)→ scheme 保持 http → URL http://HOST/
      (安全回落:无崩溃、无畸形 URL;代价是 https 页面场景退化为 http,见报告观察项);
    - XFP=http + Host=域名 → http://bucket.taoxiplan.com/(scheme 随 XFP、host 随 Host)。"""
    await _skip_if_no_dev_channel(client)
    uniq = _uuid.uuid4().hex[:8]
    asset_id = ""
    folder: dict = {}
    try:
        folder, _upload, asset_id = await _mk_asset_with_tags(client, uniq)
        for xfp in ("https, http", "HTTPS", "http"):
            r = await client.post(
                f"/api/v1/assets/{asset_id}/download-link",
                headers=_entry_headers(HTTPS_HOST, xfp=xfp),
            )
            assert r.status_code == 200, f"XFP={xfp!r}: {r.text}"
            assert r.json()["url"].startswith(f"http://{HTTPS_HOST}/"), f"XFP={xfp!r}: {r.json()['url']}"
    finally:
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"] if folder else ""])


@pytest.mark.asyncio
async def test_ext_c6_semantically_invalid_host_or_scheme_returns_gracefully(client: AsyncClient) -> None:
    """D3 契约(容器级):裸 IPv6 / 多冒号 Host、XFP=wss 应回落静态 200 而非 500;
    且非法请求不影响后续合法请求(无缓存污染)。P1-1 修复后转正(原 xfail 钉住
    「动态 signer 构造抛异常 → 500」的现状,scheme 白名单 + 构造失败回落静态
    后应直接通过)。"""
    await _skip_if_no_dev_channel(client)
    uniq = _uuid.uuid4().hex[:8]
    asset_id = ""
    folder: dict = {}
    try:
        folder, _upload, asset_id = await _mk_asset_with_tags(client, uniq)
        for headers in (
            _entry_headers("::1"),
            _entry_headers("a:b:c"),
            _entry_headers(HTTPS_HOST, xfp="wss"),
        ):
            r = await client.post(f"/api/v1/assets/{asset_id}/download-link", headers=headers)
            assert r.status_code == 200, f"{headers}: {r.status_code} {r.text[:120]}"
        r = await client.post(
            f"/api/v1/assets/{asset_id}/download-link",
            headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200  # 非法请求后合法链路无缓存污染
    finally:
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"] if folder else ""])


@pytest.mark.asyncio
async def test_ext_c7_unauthenticated_still_401_with_dynamic_headers(client: AsyncClient) -> None:
    """未登录(无 X-User-Id)+ 动态转发头 → 401 先于签名(签名不出 URL,无信息泄露);
    与动态签发正交,回归既有鉴权行为。"""
    for method, path in (
        ("GET", f"/api/v1/assets/{_uuid.uuid4()}/thumbnail-url"),
        ("GET", f"/api/v1/assets/{_uuid.uuid4()}/live-preview-url"),
        ("POST", f"/api/v1/assets/{_uuid.uuid4()}/download-link"),
        ("GET", "/api/v1/assets/uploads/x/parts/1?bucket=b&key=k"),
    ):
        r = await client.request(
            method, path,
            headers={"Host": HTTPS_HOST, "X-Forwarded-Proto": "https"},
        )
        assert r.status_code == 401, f"{method} {path}: {r.status_code}"
