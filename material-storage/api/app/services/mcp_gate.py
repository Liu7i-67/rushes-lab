"""MCP 第六步:两级并发闸 + PAT 排除清单 + 上传归属 + batch-move 上限 + 启动自检。

需求:`docs/qdev/2026-10-30-mcp-service.md`(C.6「两级并发闸」/ D9 归属绑定 /
工作包 4)。本模块是 **router 级 yield 依赖**,靠
``include_router(..., dependencies=[Depends(mcp_gate)])`` 挂载:

- ``auth_method != "pat"``(session/dev)→ 立即 ``yield``(无害 no-op,零开销);
- PAT → 两级 ZSET 闸占位 → ``yield`` → ``finally`` 两闸各 ``ZREM req_id``
  (**try/except 只 log**:Redis 抖动不能让已成功的响应变错误;成员靠租约自愈);
- **严禁挂 app 级**(会锁死 ``/healthz``、``/auth/local/login``、
  ``/maintenance/banner``,与「MCP 出问题不影响真人」相反);严禁逐端点挂
  (破坏「业务端点零改动」);勿写进 ``get_current_user``。

PAT 排除七项(D1 的显式安全收窄 —— 租约 600s 只覆盖 11 个工具映射端点,下列
慢端点要么排除、要么封顶)。判定键 **``(method, route 模板)`` 二元组**:
method 不可省(``GET/PATCH/DELETE /folders/{folder_id}`` 共用同一模板)。

    1 POST /api/v1/assets/batch-prefix                    (mass-scale 1000 项)
    2 DELETE /api/v1/assets/{asset_id}?hard=<真值>        (同步删对象,可能数分钟)
    3 GET  /api/v1/admin/audit/export.csv                 (5 万行流式)
    4 POST /api/v1/admin/grant-templates/apply-default     (满批串行 FGA)
    5 POST /api/v1/admin/directory/users/{user_id}/disable (逐对象 revoke)
    6 GET  /api/v1/admin/usage/stats                      (366 天 GROUPING SETS)
    7 DELETE /api/v1/folders/{folder_id}                  (无上界逐 tuple FGA write)

``hard`` 用 ``request.query_params.getlist`` + ``pydantic.TypeAdapter(bool)``
**与端点同源**解析(自行白名单会漏 ``t/y/TRUE/ON`` 被绕过执行 purge);多值
(``?hard=false&hard=true``)→ 400;解析失败(``?hard=maybe``)→ 放行给端点 422。
**禁止在 gate 签名里声明 body 模型** —— 那会把 body 参数塞进该 router 全部端点。

**启动自检** ``validate_gate_routes(app)``:路由改名会让排除清单静默失效 →
启动时遍历 ``app.routes`` 校验 7 个模板存在;失败**只 log.error** 并把模块标志
置为不通过(PAT 一律 403 ``channel_unavailable``),**绝不让 ms-api 启动失败**
(否则一次路由改名会让全站崩溃循环)。
"""
from __future__ import annotations

import json
import logging
import os
import uuid
from collections.abc import AsyncIterator, Iterable, Iterator
from typing import Any, NoReturn

from fastapi import Depends, HTTPException, Request
from pydantic import TypeAdapter, ValidationError

from app.deps import CurrentUser, get_current_user
from app.services.mcp_limiter import acquire_concurrency, release_concurrency
from app.services.mcp_settings import McpSettings, McpSettingsUnavailable

log = logging.getLogger(__name__)

# 租约(秒):只决定崩溃回收上限;正常请求靠 finally ZREM 即时释放
# 可注入(MCP_CONC_LEASE_SECONDS)以秒级验证 ZSET 自愈(方案「测试钩子」)
LEASE_ENV_VAR = "MCP_CONC_LEASE_SECONDS"
DEFAULT_LEASE_SECONDS = 600

# batch-move 单次上限(控租约;batch-prefix 已被排除)
BATCH_MOVE_MAX_ASSET_IDS = 200

# 上传归属键(写键在 create_upload 端点内 —— gate 在端点前进入,拿不到 upload_id)
UPLOAD_OWNER_KEY_TEMPLATE = "mcp:upload:{upload_id}"
UPLOAD_OWNER_TTL_SECONDS = 86400

# ─── 端点模板(启动自检逐个核对;勿手抄,见 validate_gate_routes)──────────────
DELETE_ASSET_TEMPLATE = "/api/v1/assets/{asset_id}"
BATCH_MOVE_TEMPLATE = "/api/v1/assets/batch-move"

PAT_FORBIDDEN_ROUTES: frozenset[tuple[str, str]] = frozenset(
    {
        ("POST", "/api/v1/assets/batch-prefix"),
        ("GET", "/api/v1/admin/audit/export.csv"),
        ("POST", "/api/v1/admin/grant-templates/apply-default"),
        ("POST", "/api/v1/admin/directory/users/{user_id}/disable"),
        ("GET", "/api/v1/admin/usage/stats"),
        ("DELETE", "/api/v1/folders/{folder_id}"),
    }
)

# 上传归属三端点(D9:owner 校验统一在此,勿在端点重复查)
UPLOAD_OWNED_ROUTES: frozenset[tuple[str, str]] = frozenset(
    {
        ("GET", "/api/v1/assets/uploads/{upload_id}/parts/{part_number}"),
        ("POST", "/api/v1/assets/uploads/{upload_id}/complete"),
        ("DELETE", "/api/v1/assets/uploads/{upload_id}"),
    }
)

# 启动自检清单 = 排除七项(含 DELETE /assets/{asset_id} 的 hard 分支)
REQUIRED_ROUTE_TEMPLATES: frozenset[tuple[str, str]] = PAT_FORBIDDEN_ROUTES | {
    ("DELETE", DELETE_ASSET_TEMPLATE),
}

# 文案(测试按此断言)
PAT_FORBIDDEN_DETAIL = "令牌不支持该操作(批量改名/彻底删除/审计导出/admin 批量)"
PAT_UPLOAD_FORBIDDEN_DETAIL = "无权操作该上传会话(可能不是本令牌创建)"
PAT_BATCH_MOVE_DETAIL = f"令牌单次批量移动最多 {BATCH_MOVE_MAX_ASSET_IDS} 个文件"
MCP_GATE_UNAVAILABLE_DETAIL = "MCP 通道配置不可用,请稍后重试"
MCP_CONCURRENCY_DETAIL = "MCP 通道并发已满,请稍后重试"
MCP_REDIS_DOWN_DETAIL = "认证服务暂时不可用,请稍后重试"

# 启动自检结果(默认通过;只在 validate_gate_routes 明确失败时置 False)
_gate_routes_ok = True


def gate_routes_ok() -> bool:
    """启动自检是否通过(False ⇒ PAT 一律 403 channel_unavailable)。"""
    return _gate_routes_ok


def set_gate_routes_ok(ok: bool) -> None:
    """测试钩子(生产只由 ``validate_gate_routes`` 写)。"""
    global _gate_routes_ok
    _gate_routes_ok = ok


def lease_seconds() -> int:
    """租约秒数(env ``MCP_CONC_LEASE_SECONDS``,默认 600;非法值回落默认)。"""
    raw = os.environ.get(LEASE_ENV_VAR)
    if not raw:
        return DEFAULT_LEASE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        log.warning("mcp gate: %s=%r 非整数,回落 %d", LEASE_ENV_VAR, raw, DEFAULT_LEASE_SECONDS)
        return DEFAULT_LEASE_SECONDS
    return value if value >= 1 else DEFAULT_LEASE_SECONDS


def upload_owner_key(upload_id: str) -> str:
    return UPLOAD_OWNER_KEY_TEMPLATE.format(upload_id=upload_id)


# ─── 路由模板解析(FastAPI 0.162 起 app.routes 是惰性 _IncludedRouter)──────────
def route_template(request: Request) -> str:
    """当前请求命中的 **完整路由模板**(含 router prefix)。

    FastAPI 0.162 的 ``scope["route"].path`` 是**未加 prefix** 的原始路径
    (实测 ``/uploads/{upload_id}/complete``),完整模板在
    ``scope["fastapi"]["effective_route_context"].path``;旧版本(扁平化路由)
    直接用 ``route.path``。两层都取,前缀缺失即回落。
    """
    fastapi_scope = request.scope.get("fastapi")
    if isinstance(fastapi_scope, dict):
        context = fastapi_scope.get("effective_route_context")
        path = getattr(context, "path", None)
        if isinstance(path, str) and path:
            return path
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) else ""


def _iter_route_templates(routes: Iterable[Any]) -> Iterator[tuple[str, frozenset[str]]]:
    """遍历 ``app.routes`` → ``(模板, methods)``;兼容惰性 ``_IncludedRouter``。"""
    for route in routes:
        expand = getattr(route, "effective_route_contexts", None)
        if callable(expand):
            for context in expand():
                path = getattr(context, "path", None)
                methods = getattr(context, "methods", None) or ()
                if isinstance(path, str) and path:
                    yield path, frozenset(str(m).upper() for m in methods)
            continue
        path = getattr(route, "path", None)
        methods = getattr(route, "methods", None) or ()
        if isinstance(path, str) and path:
            yield path, frozenset(str(m).upper() for m in methods)


def route_keys(app: Any) -> set[tuple[str, str]]:
    """``(METHOD, 模板)`` 全集(启动自检 / 测试用)。"""
    keys: set[tuple[str, str]] = set()
    for path, methods in _iter_route_templates(app.routes):
        for method in methods:
            keys.add((method, path))
    return keys


async def validate_gate_routes(app: Any) -> bool:
    """启动自检:排除清单的 7 个模板必须存在;**失败只 log.error,不阻塞启动**。

    形态按方案钉死为 ``async def``(lifespan 内 ``await``);实现本身不 IO。
    """
    global _gate_routes_ok
    keys = route_keys(app)
    missing = sorted(REQUIRED_ROUTE_TEMPLATES - keys)
    if missing:
        _gate_routes_ok = False
        log.error(
            "mcp gate: 启动自检失败 —— 以下 PAT 排除路由模板不存在(路由被改名/删除?): %s;"
            "PAT 通道将一律 403(channel_unavailable)",
            missing,
        )
        return False
    _gate_routes_ok = True
    return True


# ─── hard 真值 / 排除清单 ────────────────────────────────────────────────────
def _reject(request: Request, status_code: int, detail: str, reason: str) -> NoReturn:
    request.state.mcp_reject_reason = reason
    raise HTTPException(status_code, detail)


def parse_hard_flag(request: Request) -> bool | None:
    """与端点同源解析 ``?hard``:多值 → 400;解析失败 → None(放行给端点 422)。"""
    values = request.query_params.getlist("hard")
    if len(values) > 1:
        raise HTTPException(400, "hard 参数重复")
    if not values:
        return False
    try:
        return TypeAdapter(bool).validate_python(values[0])
    except ValidationError:
        return None


def is_excluded_route(request: Request) -> bool:
    """命中 PAT 排除清单(DELETE /assets/{id} 仅 ``hard`` 真值时)。"""
    key = (request.method.upper(), route_template(request))
    if key in PAT_FORBIDDEN_ROUTES:
        return True
    if key == ("DELETE", DELETE_ASSET_TEMPLATE):
        return parse_hard_flag(request) is True
    return False


# ─── 上传归属(D9)─────────────────────────────────────────────────────────────
async def _check_upload_ownership(request: Request, user: CurrentUser) -> None:
    """PAT 上传三步:Redis ``mcp:upload:{upload_id}`` 必须等于当前 user。

    键缺失/不符 → 403(键缺失一律 403);Redis 异常 → 503 redis_down。
    """
    if (request.method.upper(), route_template(request)) not in UPLOAD_OWNED_ROUTES:
        return
    upload_id = request.path_params.get("upload_id")
    if not upload_id:
        _reject(request, 403, PAT_UPLOAD_FORBIDDEN_DETAIL, "pat_forbidden")
    redis = getattr(request.app.state, "redis", None)
    if redis is None:
        _reject(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    try:
        owner = await redis.get(upload_owner_key(str(upload_id)))
    except Exception as e:  # Redis 故障 fail-closed
        log.warning("mcp gate: 上传归属查询失败(fail-closed): %s", e)
        _reject(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    if owner != str(user.id):
        _reject(request, 403, PAT_UPLOAD_FORBIDDEN_DETAIL, "pat_forbidden")


# ─── batch-move 上限(asset_ids > 200 → 403)─────────────────────────────────
async def _check_batch_move_cap(request: Request) -> None:
    """仅当路由命中 batch-move 时读 body 数 ``asset_ids``;解析失败放行给端点。

    ``request.body()`` 有缓存,与后续端点解析不冲突;解析失败(非 JSON / 非
    dict / 非 list)→ 放行,由端点返回 422。
    """
    if (request.method.upper(), route_template(request)) != ("POST", BATCH_MOVE_TEMPLATE):
        return
    body = await request.body()
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return
    if not isinstance(payload, dict):
        return
    asset_ids = payload.get("asset_ids")
    if isinstance(asset_ids, list) and len(asset_ids) > BATCH_MOVE_MAX_ASSET_IDS:
        _reject(request, 403, PAT_BATCH_MOVE_DETAIL, "quota_batch")


# ─── 并发闸读取配置 ──────────────────────────────────────────────────────────
async def _resolve_flag(request: Request) -> McpSettings:
    """优先复用 ``get_current_user`` 写入的 ``request.state.mcp_flag``。"""
    flag = getattr(request.state, "mcp_flag", None)
    if isinstance(flag, McpSettings):
        return flag
    service = getattr(request.app.state, "mcp_settings", None)
    if service is None:
        _reject(request, 403, MCP_GATE_UNAVAILABLE_DETAIL, "channel_unavailable")
    try:
        settings: McpSettings = await service.read()
        return settings
    except McpSettingsUnavailable as e:
        log.warning("mcp gate: 通道配置不可用(fail-closed): %s", e)
        _reject(request, 403, MCP_GATE_UNAVAILABLE_DETAIL, "channel_unavailable")


# ─── 依赖本体 ────────────────────────────────────────────────────────────────
async def mcp_gate(
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  FastAPI DI,repo 全量同款
) -> AsyncIterator[None]:
    """第六步两级并发闸 + PAT 策略收窄(session 请求 no-op)。"""
    if getattr(request.state, "auth_method", None) != "pat":
        yield
        return

    if not _gate_routes_ok:
        # 启动自检失败:排除清单不可信 → PAT 一律 403(不影响 session/网页)
        _reject(request, 403, MCP_GATE_UNAVAILABLE_DETAIL, "channel_unavailable")

    # 1) PAT 排除清单(慢端点/mass-scale 一律 session-only;hard 真值同源解析)
    if is_excluded_route(request):
        _reject(request, 403, PAT_FORBIDDEN_DETAIL, "pat_forbidden")

    # 2) 上传归属(owner 校验全在 gate;端点只做 path/body 一致性断言)
    await _check_upload_ownership(request, user)

    # 3) batch-move 单次上限
    await _check_batch_move_cap(request)

    # 4) 两级 ZSET 并发闸(全局 8 / 每令牌 4;单 Lua 原子)
    flag = await _resolve_flag(request)
    redis = getattr(request.app.state, "redis", None)
    if redis is None:
        _reject(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    token_id = getattr(request.state, "auth_token_id", None)
    if not isinstance(token_id, uuid.UUID):
        _reject(request, 403, MCP_GATE_UNAVAILABLE_DETAIL, "channel_unavailable")

    req_id = uuid.uuid4().hex
    try:
        acquired = await acquire_concurrency(
            redis,
            token_id=token_id,
            req_id=req_id,
            lease_seconds=lease_seconds(),
            max_token=flag.per_token_concurrency,
            max_global=flag.max_concurrency,
        )
    except Exception as e:  # Redis 故障 fail-closed(绝不 fail-open)
        log.warning("mcp gate: 并发闸 Redis 失败(fail-closed): %s", e)
        _reject(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    if not acquired:
        request.state.mcp_reject_reason = "quota_conc"
        raise HTTPException(429, MCP_CONCURRENCY_DETAIL, headers={"Retry-After": "1"})

    try:
        yield
    finally:
        # 释放:两闸各 ZREM(幂等);Redis 抖动不能让已成功的响应变错误
        try:
            await release_concurrency(redis, token_id=token_id, req_id=req_id)
        except Exception as e:
            log.warning("mcp gate: 并发闸释放失败(靠租约 %ds 自愈): %s", lease_seconds(), e)
