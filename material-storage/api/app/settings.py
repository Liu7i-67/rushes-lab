"""Pydantic Settings — env-driven config(12-factor)。"""
import ipaddress
import logging
from typing import Any, Literal, overload
from urllib.parse import urlsplit

from pydantic import Field, PostgresDsn, RedisDsn
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.services.email_utils import is_header_safe_addr

log = logging.getLogger(__name__)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # ─── app ──────────────────────────────────────────────────────────────────
    env: str = "dev"
    log_level: str = "INFO"
    log_format: str = "json"          # "json" | "console"

    # ─── postgres ─────────────────────────────────────────────────────────────
    db_url: PostgresDsn = Field(..., description="postgresql+asyncpg://...")

    # ─── redis(cache + arq broker)────────────────────────────────────────────
    redis_url: RedisDsn = Field(..., description="redis://...")

    # ─── MinIO / S3 ───────────────────────────────────────────────────────────
    minio_endpoint_internal: str = Field(..., description="容器内访问 MinIO 用,e.g. http://poc-pigsty-minio:9000")
    minio_endpoint_public: str = Field(..., description="浏览器访问 MinIO 用(签 presigned URL host),e.g. https://rusheslab.taoxiplan.com")
    minio_access_key: str
    minio_secret_key: str
    minio_default_bucket: str = "incoming"

    # ─── 缩略图分层(ADR-0008 P1:SSD 第二个 MinIO 专放缩略图)───────────────
    # 生产 LAN:内部端点指 poc-minio-thumbs(SSD 卷),公开端点与主 MinIO 同 host
    # (nginx 按 bucket 名 /ms-thumbs/ 路由到缩略图实例);留空 = 回落主 MinIO
    # (降级开关:配合 MINIO_THUMBNAIL_BUCKET 指回原片 bucket 即回滚,无需数据迁移)
    minio_thumbnail_endpoint_internal: str | None = Field(
        None, description="缩略图 MinIO 容器内 endpoint;None = 回落 minio_endpoint_internal(降级)"
    )
    minio_thumbnail_endpoint_public: str | None = Field(
        None, description="浏览器访问缩略图的 endpoint;None = 回落 minio_endpoint_public;"
                          "签名 host 必须与浏览器实际访问一致(P-10 类坑,见 poc/minio docker-compose 注释)"
    )
    minio_thumbnail_bucket: str = Field(
        "ms-thumbs", description="缩略图 bucket(SSD);降级 = 指回原片 bucket(如 ms-dev)"
    )

    # ─── OpenFGA ──────────────────────────────────────────────────────────────
    openfga_api_url: str = Field(..., description="e.g. http://poc-openfga:8080")
    openfga_store_id: str = Field(..., description="启动时通过 list stores + name=material-storage-poc 找;或固化")
    openfga_model_id: str | None = Field(None, description="可选;None = 用 store latest model")

    # ─── OIDC provider 留口(ADR-0007:#154 起飞书 OIDC 抽象为通用配置)─────
    # 默认空 dict = 纯本地登录。配置一个 provider 时走标准 authorization_code
    # + userinfo 流程(services/auth.py OIDCService)。
    # 形状:{"authorize_endpoint", "token_endpoint", "userinfo_endpoint",
    #        "client_id", "client_secret", "redirect_uri",
    #        "scope"(可选), "claims"(可选,{"sub","name","email"} claim 名映射)}
    # env 注入:OIDC_PROVIDER='{"authorize_endpoint": "...", ...}'(JSON 字符串)
    oidc_provider: dict[str, Any] = Field(
        default_factory=dict,
        description="可选 OIDC provider 配置;默认空 = 纯本地账号密码登录",
    )

    # web 前端 base URL — 分享短链 / 前端回跳等用
    web_app_base_url: str = Field(
        ...,
        description="e.g. https://rusheslab.taoxiplan.com/ms-static/web/ — 末尾带斜杠",
    )

    # CORS — 默认从 web_app_base_url derive(同源场景够用);需要额外 origin 时
    # 设 env CORS_ALLOW_ORIGINS=https://a.com,https://b.com(逗号分隔)
    cors_allow_origins: str | None = Field(
        None,
        description="逗号分隔的 origin allow list;留空 = 自动从 web_app_base_url derive",
    )

    # ─── session JWT ─────────────────────────────────────────────────────────
    session_jwt_secret: str = Field(..., description="HS256 签名密钥,至少 32 字节随机")
    session_jwt_alg: str = "HS256"
    # #149:本地认证主路径下会话期默认 7 天(局域网使用,降低频繁登录摩擦)
    session_jwt_ttl_seconds: int = 7 * 24 * 3600
    session_cookie_name: str = "ms_session"
    session_cookie_secure: bool = True
    session_cookie_samesite: str = "lax"     # H5 webview 同站访问,lax 足够

    # ─── 本地账号密码登录(#149)─────────────────────────────────────────────
    # 登录限流:同一 username / 同一 IP 连续失败 auth_max_failures 次,
    # 锁定 auth_lock_seconds 秒(Redis 计数,per IP + per username 双维度)
    auth_max_failures: int = 5
    auth_lock_seconds: int = 15 * 60
    # 密码策略:最小长度;且必须同时含字母和数字(validate_password_policy 判定)
    auth_password_min_length: int = 8

    # ─── presigned URL TTL ────────────────────────────────────────────────────
    presigned_normal_ttl_seconds: int = 900       # 15 min,普通文件
    presigned_sensitive_ttl_seconds: int = 600    # 10 min,敏感文件(配合 OpenFGA grant duration)

    # ─── audit 留存 ───────────────────────────────────────────────────────────
    audit_retention_days: int = 365

    # ─── 默认组织 ─────────────────────────────────────────────────────────────
    # PoC 单 org 场景:新 OIDC 登录的 user 自动绑入该 org;
    # create_project 时未指定 organization_id 也用此值
    default_organization_id: str | None = Field(
        None, description="UUID;留空则 user.organization_id 必须显式设置")

    # ─── SMTP(可选邮件通知 — #153;host/from 留空 = 关闭,no-op 零报错)────────
    # 企业邮箱就绪后填上即可启用:通知投递时同步发一封邮件到收件人 email
    smtp_host: str | None = Field(
        None, description="SMTP 服务器地址;留空 = 邮件通知关闭(仅应用内通知)")
    smtp_port: int = Field(587, description="SMTP 端口;465 隐式 SSL 用 smtp_use_ssl=true")
    smtp_username: str | None = Field(None, description="SMTP 登录用户名(可选)")
    smtp_password: str | None = Field(None, description="SMTP 登录密码(可选;仅存 .env,不进 git)")
    smtp_from_email: str | None = Field(
        None, description="发件人地址;与 smtp_host 同时非空才启用邮件通知")
    smtp_use_tls: bool = Field(True, description="587 端口 starttls(默认)")
    smtp_use_ssl: bool = Field(False, description="465 端口隐式 SSL;与 smtp_use_tls 互斥")

    @property
    def smtp_enabled(self) -> bool:
        """host + from_email 齐备才算启用;其余字段缺省不影响发送(匿名中继场景)。"""
        return bool(self.smtp_host and self.smtp_from_email)

    # ─── 邮箱绑定/找回密码(方案 email-account-and-password-reset-plan.md §5.10)──
    # 代码默认整体关闭(EMAIL_AUTH_ENABLED=false);部署/启用须等 §9.1 硬前置确认。
    # 功能总开关:只影响邮箱绑定/找回;**不影响**站内通知邮件(那个看 NOTIFY_EMAIL_ENABLED)
    email_auth_enabled: bool = Field(
        False, description="邮箱绑定/找回密码总开关;false 时 mail_ready=false、入口隐藏",
    )
    # 站内通知邮件(审批/邀请)独立开关:填 SMTP 不会自动打开它 —— 否则审批/邀请
    # 会立刻发给管理员手填的(可能未验证/录错的)地址(方案 §5.1/§8.6)
    notify_email_enabled: bool = Field(
        False, description="站内通知邮件开关;需与 SMTP 同时开启才发(默认 false)",
    )
    email_link_base_url: str | None = Field(
        None,
        description="邮件链接公网 SPA 基址(含 /ms-static/web/);功能开启时必填,"
                    "不回落 WEB_APP_BASE_URL(生产 WEB_APP_BASE_URL 是内网地址)",
    )
    email_link_base_url_lan: str | None = Field(
        None,
        description="可选内网 SPA 基址;配置后邮件正文同时给内网链接(允许私网 host)",
    )
    smtp_from_name: str | None = Field(
        None, description="发件人显示名(可选;不得含 CR/LF,启动校验检查)",
    )
    smtp_timeout_seconds: int = Field(15, description="单次 socket 操作超时(与既有行为一致)")
    smtp_total_timeout_seconds: int = Field(
        20, description="交互式发信总预算(asyncio.wait_for;< 前端 30s)",
    )
    # ── 验证码(B2 域,配置一并收口)──
    email_code_ttl_seconds: int = 600          # 验证码有效期
    email_code_max_attempts: int = 5           # 单码最多错误次数
    email_code_resend_seconds: int = 60        # 重发冷却
    email_code_daily_per_user: int = 10        # 每用户每日验证码上限
    email_code_hourly_per_ip: int = 200        # 每 IP 每小时验证码(共享 NAT 余量)
    email_code_request_per_user: int = 30      # 每用户每小时请求预算(含 409 占用尝试)
    email_change_max_password_failures: int = 5    # 邮箱操作密码错误上限
    email_change_password_lock_seconds: int = 900  # 密码错误锁时长
    # ── 找回密码(B3 域,配置一并收口)──
    password_reset_token_ttl_seconds: int = 1800   # 重置链接有效期
    password_reset_max_failures: int = 5           # R8:IP 失败上限
    password_reset_lock_seconds: int = 900         # R8:IP 封控时长(可调 3600)
    password_reset_cooldown_seconds: int = 60      # 重置邮件冷却
    password_reset_hourly_per_user: int = 5        # 每账号每小时重置邮件
    password_reset_hourly_per_ip: int = 60         # 每 IP 每小时重置邮件(共享 NAT 余量)
    password_reset_hourly_confirm_per_ip: int = 150    # 每 IP 每小时 verify/confirm(>=2x 发信)
    password_reset_hourly_request_per_ip: int = 120    # 每 IP 每小时格式合法的重置申请预算

    # ─── 百度网盘备份导入(方案 rushes-spec/material-storage/baidu-netdisk-backup-plan.md)──
    # 功能总开关(方案 §5.2):默认 false,未启用时 /api/v1/baidu/* 统一 404,
    # 前端菜单显隐读 /auth/me 的 baidu_backup_enabled;回滚急停也走此开关
    baidu_backup_enabled: bool = False
    # 百度开放平台应用凭证(方案 §8:hh2 .env 注入,不入库不入仓)
    baidu_app_key: str | None = Field(None, description="百度开放平台 AppKey")
    baidu_app_secret: str | None = Field(None, description="百度开放平台 SecretKey")
    # 绑定 token 的 Fernet 加密密钥材料(方案 §5.1);留空 = 由 sha256(session_jwt_secret)
    # 派生(启动打 warning:跨用途复用 JWT 密钥应被运维感知,生产建议显式配置)
    baidu_token_enc_key: str | None = Field(None, description="Fernet 密钥材料;留空回退派生")
    # ── 时延常量(方案 §10 批次 3 收进 Settings;生产默认,集成测试注入秒级值)──
    baidu_relay_after_s: int = 3300       # 55min 接力检查点(约束:RELAY+300 ≤ 3600 arq timeout)
    baidu_round_timeout_s: int = 172800   # 48h 单轮活跃时间上限(轮起点判停)
    baidu_lease_s: int = 60               # runner 租约(心跳)时长;≥ 2x 检查点周期
    baidu_sweep_throttle_s: int = 600     # sweeper 接管节流(dispatched_at 超此时长才可派发)
    baidu_part_size_bytes: int = 16 * 1024 * 1024  # multipart 分片(下限 5MiB,见校验)
    # ── 下载传输层容错(方案 baidu-import-transport-retry-plan.md §3.4;生产默认,
    # 单测/集成注入秒级值,勿吃真退避档)──
    baidu_stream_retry_max: int = 3       # 单次文件级尝试内传输中断+Range 被忽略共享的重试上限
    baidu_stream_retry_backoff_s: str = "2,5,15"  # 重试退避档(逗号分隔正整数;档位不足以末档延续)
    baidu_max_row_attempts: int = 10      # 行级 attempts 熔断阈值(bytes_done==0 零进展才熔断,§3.3)
    # ── API 端点(默认生产端点;集成测试/调试可注入本地 mock 桩,如 kill -9/SIGTERM
    # 故障注入把 openapi/pan 指向本地服务器;下载 CDN 白名单 *.pcs.baidu.com/
    # *.baidupcs.com 不受此影响,仍按宿主后缀硬校验)
    baidu_openapi_base_url: str = "https://openapi.baidu.com"  # OAuth authorize/token
    baidu_pan_base_url: str = "https://pan.baidu.com"          # xpan file/multimedia/nas
    # ── 并发与排队参数(方案 baidu-backup-multi-task-concurrency-plan.md §3.2;
    # env 可调不发版。⚠ 调 .env 后 docker compose restart 不重读 env_file,须按
    # 消费方分别 up -d --force-recreate:前三个消费方是 ms-worker,软上限消费在
    # ms-api,见方案 §3.2)──
    baidu_admission_limit: int = Field(
        4, description="全局准入并发槽总数(VIP 分道:会员恒有 ≥2 槽可用,方案 §3.1)",
    )
    baidu_nonvip_admission_limit: int = Field(
        2, description="非会员道并发上限(非会员 = vip_type 0/NULL,§3.1)",
    )
    worker_max_jobs: int = Field(
        8, description="arq WorkerSettings.max_jobs 全池并发(§3.3:4 百度槽 + "
                       "≥4 缩略图/cron 槽;并发升 4 不动它会挤饿缩略图)",
    )
    baidu_max_active_tasks_per_binding: int = Field(
        5, description="同绑定活动任务软上限(§2.5 防滥用;check-then-insert 无 DB 兜底)",
    )

    def baidu_stream_backoff_steps(self) -> list[int]:
        """解析 BAIDU_STREAM_RETRY_BACKOFF_S 逗号串为 0 基退避档位列表(秒)。

        调用方索引一律钳位末档:steps[min(n, len(steps)) - 1](首次重试取档 0,
        档位不足时以最后一档延续);逐项为正整数由 validate_baidu_settings 断言。
        """
        return [
            int(part.strip())
            for part in self.baidu_stream_retry_backoff_s.split(",")
            if part.strip()
        ]

    def validate_baidu_settings(self) -> None:
        """百度备份配置的启动断言(方案 §6)——配置关系错误宁可启动失败,不带病运行。

        - RELAY_AFTER_S + 300 ≤ 3600:接力必须能在 arq job timeout(3600s)内触发;
          违反则接力永不触发、任务每小时被硬断退化到 sweeper 接管,噪音无告警
        - PART_SIZE_BYTES ≥ 5MiB:S3/MinIO complete 强制除末片外每片 ≥5MiB(EntityTooSmall)
        - STREAM_RETRY_BACKOFF_S:非空逗号分隔正整数串(流内重试退避档,§3.4);
          STREAM_RETRY_MAX / MAX_ROW_ATTEMPTS ≥ 1(并入下方正数校验组)
        - 并发红线(§3.2):1 ≤ NONVIP ≤ ADMISSION-2 —— 上限守住「会员恒有 ≥2 槽」
          承诺(只校验 ≤ 总数则运维配 2/2 会把 VIP 保证静默清零),下限 ≥1 防 2/0
          把非会员道清零饿死(排队无超时,round 为 NULL 不受 48h 判停);隐含
          ADMISSION ≥ 3。软上限 ≥1(配 0/负值会静默砖死创建与复活、恒 409 无启动报错)
        """
        assert self.baidu_relay_after_s + 300 <= 3600, (
            f"BAIDU_RELAY_AFTER_S={self.baidu_relay_after_s} 必须满足 +300 ≤ 3600"
            "(接力须在 arq job timeout 内触发,见方案 §6)"
        )
        assert self.baidu_part_size_bytes >= 5 * 1024 * 1024, (
            f"BAIDU_PART_SIZE_BYTES={self.baidu_part_size_bytes} 必须 ≥ 5MiB"
            "(S3/MinIO complete 除末片外每片 ≥5MiB,见方案 §6)"
        )
        assert min(
            self.baidu_round_timeout_s, self.baidu_lease_s, self.baidu_sweep_throttle_s,
            self.baidu_stream_retry_max, self.baidu_max_row_attempts,
        ) > 0, "百度备份时延常量(ROUND_TIMEOUT/LEASE/SWEEP_THROTTLE/STREAM_RETRY_MAX/MAX_ROW_ATTEMPTS)必须为正数"
        raw_backoff = self.baidu_stream_retry_backoff_s.strip()
        assert raw_backoff, (
            "BAIDU_STREAM_RETRY_BACKOFF_S 不能为空"
            "(流内重试退避档,逗号分隔正整数串,如 2,5,15;见方案 §3.4)"
        )
        items = [part.strip() for part in raw_backoff.split(",")]
        assert all(part.isdigit() and int(part) > 0 for part in items), (
            f"BAIDU_STREAM_RETRY_BACKOFF_S={raw_backoff!r} 必须为逗号分隔的"
            "正整数串(如 2,5,15;逐项 >0,见方案 §3.4)"
        )
        assert (
            1 <= self.baidu_nonvip_admission_limit
            <= self.baidu_admission_limit - 2
        ), (
            f"BAIDU_NONVIP_ADMISSION_LIMIT={self.baidu_nonvip_admission_limit} 必须满足 "
            f"1 ≤ nonvip ≤ BAIDU_ADMISSION_LIMIT-2(当前 ADMISSION="
            f"{self.baidu_admission_limit};上限守住「会员恒有 ≥2 槽」、下限防非会员道"
            "清零饿死,见并发方案 §3.2)"
        )
        assert self.baidu_max_active_tasks_per_binding >= 1, (
            f"BAIDU_MAX_ACTIVE_TASKS_PER_BINDING="
            f"{self.baidu_max_active_tasks_per_binding} 必须 ≥ 1"
            "(配 0/负值会静默砖死创建与复活,恒 409 且无启动报错,见并发方案 §3.2)"
        )

    # ─── 邮箱绑定/找回密码:启动校验与降级(方案 §5.10)────────────────────────
    @overload
    def resolve_mail_ready(self, *, detail: Literal[True]) -> tuple[bool, str]: ...

    @overload
    def resolve_mail_ready(self, *, detail: Literal[False] = ...) -> bool: ...

    def resolve_mail_ready(
        self, *, detail: bool = False,
    ) -> bool | tuple[bool, str]:
        """计算邮箱功能有效开关 mail_ready(方案 §5.2 D11 / §5.10)。

        - EMAIL_AUTH_ENABLED=false → 直接 false,跳过全部校验(默认态,不打 ERROR)。
        - 开启时校验 SMTP 全套 + EMAIL_LINK_BASE_URL(生产拒私网/环回/非 https);
          **不合法不抛异常、不拖垮登录**:log.error("email auth disabled: invalid
          config: <原因>") + 返回 false —— 邮箱找回是非核心功能,一个链接基址
          拼写错误不应该让全站进入容器重启循环。
        - lifespan 启动时调一次挂 app.state.mail_ready(不要每请求重算,非法配置
          会每请求刷 ERROR);``detail=True`` 返回 (bool, 原因) 供 runbook 预检
          (§9.3 第 6 步)打印原因。
        """
        ok, reason = self._check_mail_ready()
        if not ok and self.email_auth_enabled:
            log.error("email auth disabled: invalid config: %s", reason)
        if detail:
            return ok, reason
        return ok

    def _check_mail_ready(self) -> tuple[bool, str]:
        """纯校验(不打日志);返回 (ok, 原因),ok=True 时 reason 为 "ok"。"""
        if not self.email_auth_enabled:
            return False, "EMAIL_AUTH_ENABLED=false"
        if not self.smtp_enabled:
            return False, "SMTP 未配置齐(SMTP_HOST 与 SMTP_FROM_EMAIL 需同时非空)"
        if bool(self.smtp_username) != bool(self.smtp_password):
            return False, "SMTP_USERNAME 与 SMTP_PASSWORD 必须同时有或同时无"
        if self.smtp_use_ssl and self.smtp_use_tls:
            return False, "SMTP_USE_SSL 与 SMTP_USE_TLS 互斥"
        if self.smtp_port == 465 and not (self.smtp_use_ssl and not self.smtp_use_tls):
            return False, "SMTP_PORT=465 必须 SMTP_USE_SSL=true 且 SMTP_USE_TLS=false"
        if self.smtp_port == 587 and not (self.smtp_use_tls and not self.smtp_use_ssl):
            return False, "SMTP_PORT=587 必须 SMTP_USE_TLS=true 且 SMTP_USE_SSL=false"
        if not is_header_safe_addr(self.smtp_from_email):
            return False, "SMTP_FROM_EMAIL 含头部危险字符(, ; < > \" 空白/控制字符)或为空"
        if self.smtp_from_name and ("\r" in self.smtp_from_name or "\n" in self.smtp_from_name):
            return False, "SMTP_FROM_NAME 不得含 CR/LF"
        reason = _check_spa_base_url(self.email_link_base_url, "EMAIL_LINK_BASE_URL",
                                     prod_strict=self.env == "production")
        if reason is not None:
            return False, reason
        if self.email_link_base_url_lan:
            # LAN 可选:合法 http(s) SPA 基址即可(允许私网 host / http;公网要求
            # 不适用 —— 它只是双入口兜底,不能单独让 mail_ready 变 true,§5.6.2)
            reason = _check_spa_base_url(self.email_link_base_url_lan,
                                         "EMAIL_LINK_BASE_URL_LAN", prod_strict=False)
            if reason is not None:
                return False, reason
        return True, "ok"


def _check_spa_base_url(url: str | None, name: str, *, prod_strict: bool) -> str | None:
    """校验邮件链接 SPA 基址;通过返回 None,否则返回失败原因(方案 §5.10/D15)。

    - 非空、http(s):// 开头、路径以 /ms-static/web/ 结尾(容忍无尾斜杠);
    - urlsplit 后 username/password/query/fragment 必须为空
      (防把凭据/查询串写进邮件正文);
    - prod_strict=True(生产的 EMAIL_LINK_BASE_URL):必须 https、host 含 ``.``
      且不以 ``.local`` 结尾;可解析为 IP(含 IPv6)时拒绝
      is_private/is_loopback/is_link_local/is_unspecified(覆盖 169.254.*、
      0.0.0.0、::1、IPv6 ULA);同时拒绝字面 localhost / 10.* / 192.168.* /
      172.16-31.*(非 IP 字面量时按前缀判,见分支)。
    """
    if not url or not url.strip():
        return f"{name} 未配置(邮箱功能开启时必填,不回落 WEB_APP_BASE_URL)"
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https"):
        return f"{name} 必须以 http(s):// 开头"
    if parts.username or parts.password or parts.query or parts.fragment:
        return f"{name} 不得包含凭据/查询串/fragment"
    if not parts.path.rstrip("/").endswith("/ms-static/web"):
        return f"{name} 路径必须以 /ms-static/web/ 结尾"
    host = parts.hostname
    if not host:
        return f"{name} 缺少 host"
    if not prod_strict:
        return None
    # ── 生产专属:公网 https 入口(D15)──
    if parts.scheme != "https":
        return f"{name} 生产环境必须 https"
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None
    if ip is not None:
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified:
            return f"{name} 生产环境不得指向私网/环回/链路本地地址"
        return None
    # 非字面 IP 的 host:字面 localhost / *.local / 无点单标签(内部主机名)
    # 都不可用作公网入口;10.*/192.168.*/172.16-31.* 这类字面 IP 已在上面
    # 被 ipaddress 分支按 is_private 拒绝
    if host == "localhost" or host.endswith(".local") or "." not in host:
        return f"{name} 生产环境必须是公网域名(非 localhost/.local/内部主机名)"
    return None



# 单例(import 时 lazy 创建)
_settings: Settings | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()  # type: ignore[call-arg]
    return _settings
