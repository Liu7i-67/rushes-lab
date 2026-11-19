/// PatToken / PatTokenCreated — /api/v1/auth/tokens 契约(api/app/models/__init__.py
/// TokenOut / TokenCreatedOut 实码 + routers/auth_tokens.py,2026-11-19 App 包A)。
///
/// - id 为 UUID → Dart String(吊销 DELETE /{id} 直接拼路径);
/// - 明文 token 只在 [PatTokenCreated](POST 响应,Cache-Control: no-store)
///   回显一次,列表 [PatToken] 永不含明文 / token_hash,仅 token_prefix 识别;
/// - `expired` 为后端响应期派生列:键在即**完全信任后端**(web
///   token-status.ts 同源——expired 为 boolean 时不再本地比对时钟,false 即
///   active);仅键缺失(旧响应,null)时才按 expires_at 与本地时钟派生兜底
///   (口径与后端活跃定义一致:revoked_at IS NULL AND expires_at > now)。
library;

/// 列表项(GET /api/v1/auth/tokens;永不含明文)。
class PatToken {
  PatToken({
    required this.id,
    required this.name,
    required this.tokenPrefix,
    required this.createdAt,
    required this.expiresAt,
    this.lastUsedAt,
    this.revokedAt,
    this.expired,
  });

  factory PatToken.fromJson(Map<String, dynamic> j) => PatToken(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        tokenPrefix: (j['token_prefix'] ?? '') as String,
        createdAt: (j['created_at'] ?? '') as String,
        expiresAt: (j['expires_at'] ?? '') as String,
        lastUsedAt: j['last_used_at'] as String?,
        revokedAt: j['revoked_at'] as String?,
        expired: j['expired'] as bool?,
      );

  final String id;
  final String name;

  /// 令牌前缀(列表识别用;完整明文仅创建时展示一次)。
  final String tokenPrefix;
  final String createdAt;

  /// null = 从未使用。
  final String? lastUsedAt;
  final String expiresAt;

  /// 非 null = 已吊销(吊销时间)。
  final String? revokedAt;

  /// 后端响应期派生列:键在即信任后端(false 即 active,不做本地时钟兜底);
  /// null = 键缺失(旧响应),仅此时按 [expiresAt] 本地兜底派生(web 同源)。
  final bool? expired;

  /// 展示三态:吊销优先;`expired` 键在即完全信任后端派生列;仅键缺失
  /// (null)时按 [expiresAt] 与本地时钟派生兜底(web patTokenStatus 同口径)。
  PatTokenStatus get status {
    if (revokedAt != null) return PatTokenStatus.revoked;
    final backend = expired;
    if (backend != null) {
      return backend ? PatTokenStatus.expired : PatTokenStatus.active;
    }
    final t = DateTime.tryParse(expiresAt);
    if (t != null && t.isBefore(DateTime.now())) return PatTokenStatus.expired;
    return PatTokenStatus.active;
  }

  bool get isActive => status == PatTokenStatus.active;

  /// 状态中文(web PAT_STATUS_LABEL 同映射)。
  String get statusLabel => switch (status) {
        PatTokenStatus.active => '有效',
        PatTokenStatus.revoked => '已吊销',
        PatTokenStatus.expired => '已过期',
      };
}

/// 令牌展示三态(有效/已吊销/已过期;徽标配色映射在页面侧,模型不依赖 UI)。
enum PatTokenStatus { active, revoked, expired }

/// 创建响应(POST /api/v1/auth/tokens 201)—— [token] 明文**只此一次**,
/// 调用方展示后即丢弃,不落任何持久化存储。
class PatTokenCreated {
  PatTokenCreated({
    required this.id,
    required this.name,
    required this.token,
    required this.tokenPrefix,
    required this.expiresAt,
  });

  factory PatTokenCreated.fromJson(Map<String, dynamic> j) => PatTokenCreated(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        token: (j['token'] ?? '') as String,
        tokenPrefix: (j['token_prefix'] ?? '') as String,
        expiresAt: (j['expires_at'] ?? '') as String,
      );

  final String id;
  final String name;

  /// 明文令牌(仅创建响应回显一次;服务端只存 SHA-256 哈希,无法找回)。
  final String token;
  final String tokenPrefix;
  final String expiresAt;
}
