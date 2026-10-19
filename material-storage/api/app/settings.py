"""Pydantic Settings — env-driven config(12-factor)。"""
from typing import Any

from pydantic import Field, PostgresDsn, RedisDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


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
            "(配 0/负值会静默砖死创建与复活、恒 409 且无启动报错,见并发方案 §3.2)"
        )


# 单例(import 时 lazy 创建)
_settings: Settings | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()  # type: ignore[call-arg]
    return _settings
