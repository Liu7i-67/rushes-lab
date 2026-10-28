/// 使用统计域出参契约(GET /api/v1/admin/usage/stats;api models UsageStatsOut
/// 实码,routers/usage_stats.py):totals / by_platform / by_platform_class /
/// by_network / cross / daily 六粒度。核心不变量:各分组 count(DISTINCT)
/// 独立去重,跨组不可加(页脚固定说明文案同口径);daily 为 (date, platform,
/// network) 三元组多行且 date 升序,users 跨行不可加、events 可加。
/// fromJson 容错风格照 me.dart。
library;

/// 全窗口总计(GROUPING SETS () 分组集独立产出)。
class UsageTotals {
  UsageTotals({required this.users, required this.events});

  factory UsageTotals.fromJson(Map<String, dynamic> j) => UsageTotals(
    users: (j['users'] ?? 0) as int,
    events: (j['events'] ?? 0) as int,
  );

  final int users;
  final int events;
}

/// 单分组行(by_platform / by_platform_class / by_network 共用;键名不同,
/// 由 API 层按各自 keyField 解析后归一为 [name])。
class UsageGroupRow {
  UsageGroupRow({
    required this.name,
    required this.users,
    required this.events,
  });

  factory UsageGroupRow.fromJson(Map<String, dynamic> j, String keyField) =>
      UsageGroupRow(
        name: (j[keyField] ?? '') as String,
        users: (j['users'] ?? 0) as int,
        events: (j['events'] ?? 0) as int,
      );

  /// 分组键原文(web/android_app/lan/…;展示层再映射中文,缺省回落原文)。
  final String name;
  final int users;
  final int events;
}

/// (platform, network) 交叉行;users 为该组合内去重,与单维行不可互推。
class UsageCrossRow {
  UsageCrossRow({
    required this.platform,
    required this.network,
    required this.users,
    required this.events,
  });

  factory UsageCrossRow.fromJson(Map<String, dynamic> j) => UsageCrossRow(
    platform: (j['platform'] ?? '') as String,
    network: (j['network'] ?? '') as String,
    users: (j['users'] ?? 0) as int,
    events: (j['events'] ?? 0) as int,
  );

  final String platform;
  final String network;
  final int users;
  final int events;
}

/// (date, platform, network) 完整三元组日行(date=Asia/Shanghai 日界,
/// 后端仅产出有事件的日期、date 升序;App 端按日聚合 events 取最近 14 个
/// 有数据日期倒序展示,users 不展示——跨三元组求和会虚高,D7)。
class UsageDailyRow {
  UsageDailyRow({
    required this.date,
    required this.platform,
    required this.network,
    required this.users,
    required this.events,
  });

  factory UsageDailyRow.fromJson(Map<String, dynamic> j) => UsageDailyRow(
    date: (j['date'] ?? '') as String,
    platform: (j['platform'] ?? '') as String,
    network: (j['network'] ?? '') as String,
    users: (j['users'] ?? 0) as int,
    events: (j['events'] ?? 0) as int,
  );

  final String date;
  final String platform;
  final String network;
  final int users;
  final int events;
}

/// GET /stats 响应整体(服务端回显 from/to 为 tz-aware ISO 原文)。
class UsageStats {
  UsageStats({
    required this.metric,
    required this.from,
    required this.to,
    required this.totals,
    this.byPlatform = const [],
    this.byPlatformClass = const [],
    this.byNetwork = const [],
    this.cross = const [],
    this.daily = const [],
  });

  factory UsageStats.fromJson(Map<String, dynamic> j) => UsageStats(
    metric: (j['metric'] ?? 'active_users') as String,
    from: (j['from'] ?? '') as String,
    to: (j['to'] ?? '') as String,
    totals: UsageTotals.fromJson(
      (j['totals'] ?? const {}) as Map<String, dynamic>,
    ),
    byPlatform: _rows(j['by_platform'], 'platform'),
    byPlatformClass: _rows(j['by_platform_class'], 'platform_class'),
    byNetwork: _rows(j['by_network'], 'network'),
    cross: ((j['cross'] ?? const []) as List)
        .map((e) => UsageCrossRow.fromJson(e as Map<String, dynamic>))
        .toList(),
    daily: ((j['daily'] ?? const []) as List)
        .map((e) => UsageDailyRow.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  static List<UsageGroupRow> _rows(Object? raw, String keyField) =>
      ((raw ?? const []) as List)
          .map(
            (e) => UsageGroupRow.fromJson(e as Map<String, dynamic>, keyField),
          )
          .toList();

  /// 口径:'active_users'(默认)/ 'logins',原样回显。
  final String metric;
  final String from;
  final String to;
  final UsageTotals totals;
  final List<UsageGroupRow> byPlatform;
  final List<UsageGroupRow> byPlatformClass;
  final List<UsageGroupRow> byNetwork;
  final List<UsageCrossRow> cross;
  final List<UsageDailyRow> daily;

  /// 空数据(照 Web 使用统计页:totals 双零 = 所选窗口无可用数据)。
  bool get isEmptyData => totals.users == 0 && totals.events == 0;

  /// 按日聚合 events(跨三元组可加口径,D7):date → events 合计,
  /// 升序(daily 本就 ASC,此处幂等)。
  Map<String, int> get eventsByDate {
    final byDate = <String, int>{};
    for (final row in daily) {
      byDate.update(
        row.date,
        (v) => v + row.events,
        ifAbsent: () => row.events,
      );
    }
    return byDate;
  }
}
