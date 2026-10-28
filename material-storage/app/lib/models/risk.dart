/// 风控域出参契约(risk-control-module-plan §3.1/§3.2;api routers/risk.py 实码):
/// RiskLocks(被锁账号 / 被锁 IP 双列表快照)与 IP 解锁结果。fromJson 容错
/// 风格照 me.dart:缺字段回落空值,不因后端增列崩解析。
library;

/// 登录名形态匹配态(§3.1):unique=唯一命中可解锁;none=查无此人(typo /
/// 探测);ambiguous=name 重名歧义。后两者无 user_id 锚点,不提供解锁(D4)。
enum RiskUserLockMatch {
  unique,
  none,
  ambiguous;

  /// 未知值保守按 none 处理(不渲染解锁入口,宁可少一个入口不误伤)。
  static RiskUserLockMatch fromName(Object? v) => switch (v) {
    'unique' => unique,
    'ambiguous' => ambiguous,
    _ => none,
  };
}

/// 命中的账号(§3.1 ⚠:username 可空——老飞书用户无本地登录名,tables.py
/// username 列 nullable;Dart 声明必须 String?,否则 name 形态锁命中老用户时
/// 整单解析崩)。
class RiskMatchedUser {
  RiskMatchedUser({required this.id, this.username, required this.name});

  factory RiskMatchedUser.fromJson(Map<String, dynamic> j) => RiskMatchedUser(
    id: j['id'] as String,
    username: j['username'] as String?,
    name: (j['name'] ?? '') as String,
  );

  final String id;

  /// 可空(老飞书用户);展示只落 name。
  final String? username;
  final String name;
}

/// 被锁账号行(锁 key 的一个登录名形态)。
class RiskUserLock {
  RiskUserLock({
    required this.form,
    required this.match,
    required this.matchedUsers,
    required this.failCount,
    required this.lockTtlSeconds,
  });

  factory RiskUserLock.fromJson(Map<String, dynamic> j) => RiskUserLock(
    form: (j['form'] ?? '') as String,
    match: RiskUserLockMatch.fromName(j['match']),
    matchedUsers: ((j['matched_users'] ?? const []) as List)
        .map((e) => RiskMatchedUser.fromJson(e as Map<String, dynamic>))
        .toList(),
    failCount: (j['fail_count'] ?? 0) as int,
    lockTtlSeconds: (j['lock_ttl_seconds'] ?? 0) as int,
  );

  /// 锁 key 的登录名形态(小写原文)。
  final String form;
  final RiskUserLockMatch match;

  /// unique=1 条;ambiguous=全部命中;none=[]。
  final List<RiskMatchedUser> matchedUsers;

  /// 当前窗口失败计数(滚动窗口,非累计——展示文案钉子)。
  final int failCount;

  /// 锁剩余秒数(PTTL ceil 换算)。
  final int lockTtlSeconds;

  /// 剩余「约 N 分钟」(上取整,静态快照不倒计时,D2)。
  int get remainingMinutes => (lockTtlSeconds / 60).ceil();
}

/// 被锁 IP 行(含近 24h 失败用户名富化)。
class RiskIpLock {
  RiskIpLock({
    required this.ip,
    required this.failCount,
    required this.lockTtlSeconds,
    required this.recentFailedUserforms,
  });

  factory RiskIpLock.fromJson(Map<String, dynamic> j) => RiskIpLock(
    ip: (j['ip'] ?? '') as String,
    failCount: (j['fail_count'] ?? 0) as int,
    lockTtlSeconds: (j['lock_ttl_seconds'] ?? 0) as int,
    recentFailedUserforms: ((j['recent_failed_userforms'] ?? const []) as List)
        .map((e) => e as String)
        .toList(),
  );

  final String ip;

  /// 哨兵 IP(登录链路 request_ip 缺失回落 'unknown'):如实展示但标注
  /// 「未知 IP(链路异常,IP 缺失)」,允许解锁,勿静默过滤(§3.1)。
  bool get isUnknownSentinel => ip == 'unknown';

  final int failCount;
  final int lockTtlSeconds;

  /// 近 24h 该 IP 失败用户名去重(小写)。
  final List<String> recentFailedUserforms;

  int get remainingMinutes => (lockTtlSeconds / 60).ceil();
}

/// GET /api/v1/admin/risk/locks 响应:两列表为空 = 当前无任何锁。
class RiskLocks {
  RiskLocks({required this.users, required this.ips});

  factory RiskLocks.fromJson(Map<String, dynamic> j) => RiskLocks(
    users: ((j['users'] ?? const []) as List)
        .map((e) => RiskUserLock.fromJson(e as Map<String, dynamic>))
        .toList(),
    ips: ((j['ips'] ?? const []) as List)
        .map((e) => RiskIpLock.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// 按 lock_ttl_seconds 降序(新触发的在前,后端排好,原样承接)。
  final List<RiskUserLock> users;
  final List<RiskIpLock> ips;

  bool get isEmpty => users.isEmpty && ips.isEmpty;
}

/// POST /locks/ips/{ip}/unlock 响应(was_locked 严格语义 = 锁 key 曾存在;
/// false = 本就未锁,DEL 幂等 no-op)。
class RiskIpUnlockResult {
  RiskIpUnlockResult({required this.ip, required this.wasLocked});

  factory RiskIpUnlockResult.fromJson(Map<String, dynamic> j) =>
      RiskIpUnlockResult(
        ip: (j['ip'] ?? '') as String,
        wasLocked: (j['was_locked'] ?? false) as bool,
      );

  final String ip;
  final bool wasLocked;
}
