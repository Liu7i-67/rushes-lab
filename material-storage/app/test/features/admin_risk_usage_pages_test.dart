/// 风控 / 使用统计页面 widget 测试(risk-control-module-plan §5/§7.3,
/// 2026-10-28 自 admin_pages_test.dart 拆出):非 admin 页面级闸显隐、
/// 磁贴入口直推风控页、三态账号行 / unknown IP 标注、unique 账号解锁与
/// IP 解除(记录式断言)、统计窗口 / metric 切换与空数据态。
///
/// 桩族本文件自持、两文件可独立运行:FakeRiskApi / FakeUsageApi 随用例整体
/// 拆入;目录解锁断言只需 unlockUser 最小面,不跨文件复用既有 FakeDirectoryApi
/// (留在 admin_pages_test.dart 服务用户/组用例)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/directory_api.dart'
    show DirectoryApi, UnlockResult;
import 'package:ms_app/core/api/risk_api.dart' show RiskApi;
import 'package:ms_app/core/api/usage_api.dart'
    show UsageApi, kUsageMetricActiveUsers;
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/admin_home.dart';
import 'package:ms_app/features/admin/admin_risk_page.dart';
import 'package:ms_app/features/admin/admin_usage_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/models/risk.dart';
import 'package:ms_app/models/usage.dart';
import 'package:ms_app/widgets/badge.dart' as w;

import '../helpers/api_harness.dart' show FakeMsApi;

// ── 假 API 族(记录式;目录解锁 / 风控 / 使用统计三域)──────────────────────

/// 目录域最小桩(仅解锁):记录调用并按 FakeDirectoryApi 同款缺省返回。
class FakeDirectoryUnlockApi extends DirectoryApi {
  FakeDirectoryUnlockApi(super.api);

  final unlockCalls = <String>[];

  @override
  Future<UnlockResult> unlockUser(String userId) async {
    unlockCalls.add(userId);
    return UnlockResult(
      clearedUserForms: const ['zs'],
      clearedIps: const [],
      wasLocked: true,
    );
  }
}

/// 风控域桩(risk-control-module §7.3):锁定快照可编排,unlockIp 记录断言。
class FakeRiskApi extends RiskApi {
  FakeRiskApi(super.api);

  Object? locksStaged;
  var fetchCalls = 0;
  final unlockIpCalls = <String>[];

  @override
  Future<RiskLocks> fetchRiskLocks() async {
    fetchCalls++;
    final staged = locksStaged;
    if (staged is Exception) throw staged;
    return staged as RiskLocks? ?? RiskLocks(users: const [], ips: const []);
  }

  @override
  Future<RiskIpUnlockResult> unlockIp(String ip) async {
    unlockIpCalls.add(ip);
    return RiskIpUnlockResult(ip: ip, wasLocked: true);
  }
}

/// 使用统计域桩:入参记录(窗口/metric 切换断言)+ 桩数据。
class FakeUsageApi extends UsageApi {
  FakeUsageApi(super.api);

  Object? statsStaged;
  final calls = <({String metric, DateTime from, DateTime to})>[];

  @override
  Future<UsageStats> fetchUsageStats({
    required DateTime from,
    required DateTime to,
    String metric = kUsageMetricActiveUsers,
  }) async {
    calls.add((metric: metric, from: from, to: to));
    final staged = statsStaged;
    if (staged is Exception) throw staged;
    return staged as UsageStats? ??
        UsageStats(
          metric: metric,
          from: from.toIso8601String(),
          to: to.toIso8601String(),
          totals: UsageTotals(users: 0, events: 0),
          byPlatform: const [],
          byPlatformClass: const [],
          byNetwork: const [],
          cross: const [],
          daily: const [],
        );
  }
}

class FakeRiskUsageMsApi extends FakeMsApi {
  late final _directory = FakeDirectoryUnlockApi(this);
  late final _risk = FakeRiskApi(this);
  late final _usage = FakeUsageApi(this);

  @override
  FakeDirectoryUnlockApi get directory => _directory;
  @override
  FakeRiskApi get risk => _risk;
  @override
  FakeUsageApi get usage => _usage;
}

FakeRiskUsageMsApi _install() {
  final api = FakeRiskUsageMsApi();
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

void main() {
  // ── 风控 / 使用统计(risk-control-module-plan §5/§7.3,2026-10-28)────────

  testWidgets('风控/使用统计:非 admin 深链直接锁定 EmptyState(页面级闸刻意加严)', (tester) async {
    _install();
    session.me = Me.fromJson({
      'id': 'u1',
      'name': '普通',
      'is_system_admin': false,
    });
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();
    expect(find.text('只有系统管理员可以进入登录风控'), findsOneWidget);
    expect(find.text('当前无任何登录锁定'), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();
    expect(find.text('只有系统管理员可以查看使用统计'), findsOneWidget);
  });

  testWidgets('管理后台:风控/使用统计磁贴渲染,_open 直推风控页', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = RiskLocks(users: const [], ips: const []);
    await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
    await tester.pumpAndSettle();
    expect(find.text('风控'), findsOneWidget);
    expect(find.text('使用统计'), findsOneWidget);

    // 既有范式:磁贴 _open(context, const XxxPage()) 直推,不走 pushNamed
    await tester.tap(find.text('风控'));
    await tester.pumpAndSettle();
    expect(find.text('登录风控'), findsOneWidget);
    expect(find.text('当前无任何登录锁定'), findsOneWidget);
  });

  testWidgets('风控页:三态账号行 + unknown IP 标注;none/ambiguous 无解锁入口', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = _riskLocks();
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();

    // unique 主标题 = 账号名(name(username));none / ambiguous = form 原文 + 徽标
    expect(find.text('张三(zhangsan)'), findsOneWidget);
    expect(find.text('zhansa'), findsOneWidget);
    expect(find.text('laowang'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '未匹配账号'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '重名歧义'), findsOneWidget);
    // unknown 哨兵:如实展示 + 「未知 IP」标注(§3.1,不静默过滤)
    expect(find.text('unknown'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '未知 IP'), findsOneWidget);
    expect(find.textContaining('链路异常(IP 缺失)'), findsOneWidget);
    // 剩余约 N 分钟:742s 上取整 = 13 分钟;失败次数 = 当前窗口计数
    expect(find.textContaining('剩余约 13 分钟'), findsOneWidget);
    expect(find.textContaining('当前窗口失败 3 次'), findsOneWidget);
    expect(find.textContaining('近 24h:zhangsan, zhansa'), findsOneWidget);

    // none 行无动作:点行不出弹层(D4)
    await tester.tap(find.text('zhansa'));
    await tester.pumpAndSettle();
    expect(find.text('解锁'), findsNothing);
  });

  testWidgets('风控页:unique 行解锁 + unknown IP 解除(记录式断言)', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = _riskLocks();
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();
    final fetchesAfterLoad = api.risk.fetchCalls;

    // 账号解锁:行 → 底部弹层 → showAppConfirm → directory.unlockUser → 刷新
    await tester.tap(find.text('张三(zhangsan)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连带清近 24h 失败 IP 的锁'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.directory.unlockCalls, ['u1']);
    expect(api.risk.fetchCalls, greaterThan(fetchesAfterLoad)); // 解锁后刷新

    // IP 解除(unknown 哨兵可解):弹层 → 确认 → risk.unlockIp 记录
    await tester.tap(find.text('unknown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除锁定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请确认非暴力破解来源'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.risk.unlockIpCalls, ['unknown']);
  });

  testWidgets('使用统计页:默认 30 天活跃用户渲染;切近 7 天 / 登录次数重取数', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.usage.statsStaged = _usageStats();
    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();

    // 默认窗口 = 本地时区「今日 -(N-1) 天零点 → now」(web defaultRange 同口径)
    final todayStart = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    expect(api.usage.calls.first.metric, kUsageMetricActiveUsers);
    expect(
      api.usage.calls.first.from,
      todayStart.subtract(const Duration(days: 29)),
    );

    // StatRow totals + 各分组行(AppRow)+ cross + daily(按日聚合 events,倒序)
    expect(find.text('42'), findsOneWidget);
    expect(find.text('1234'), findsOneWidget);
    expect(find.text('网页(三端合并)'), findsOneWidget);
    expect(find.text('网页 · 桌面'), findsOneWidget);
    expect(find.text('Android App'), findsNWidgets(2)); // class + platform 各一行

    // 列表懒构建:滚到页脚,让下半部(内外网/交叉/按日/页脚)进入构建范围
    await tester.dragUntilVisible(
      find.textContaining('跨组数字不可加总'),
      find.byType(ListView).last,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    expect(find.text('内网'), findsOneWidget);
    expect(find.text('Android App · 内网'), findsOneWidget);
    // daily:2026-10-26 两条三元组 events 11+7=18;最近日期在前
    expect(find.text('2026-10-27'), findsOneWidget);
    expect(find.text('30 条事件'), findsOneWidget);
    expect(find.text('2026-10-26'), findsOneWidget);
    expect(find.text('18 条事件'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('2026-10-27')).dy,
      lessThan(tester.getTopLeft(find.text('2026-10-26')).dy),
    );
    expect(find.textContaining('跨组数字不可加总'), findsOneWidget);

    // 切窗口 → 重取数(days=7)
    await tester.tap(find.text('近 7 天'));
    await tester.pumpAndSettle();
    expect(
      api.usage.calls.last.from,
      todayStart.subtract(const Duration(days: 6)),
    );
    // 切 metric → logins
    await tester.tap(find.text('登录次数'));
    await tester.pumpAndSettle();
    expect(api.usage.calls.last.metric, 'logins');
  });

  testWidgets('使用统计页:totals 双零 → 空数据态', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.usage.statsStaged = UsageStats(
      metric: 'active_users',
      from: '2026-09-29T00:00:00.000Z',
      to: '2026-10-28T10:00:00.000Z',
      totals: UsageTotals(users: 0, events: 0),
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();
    expect(find.text('所选时间范围内暂无可用数据'), findsOneWidget);
  });
}

/// 风控桩数据(§3.1 契约):unique / none / ambiguous 三态 + 普通与 unknown IP。
RiskLocks _riskLocks() => RiskLocks(
  users: [
    RiskUserLock(
      form: 'zhangsan',
      match: RiskUserLockMatch.unique,
      matchedUsers: [
        RiskMatchedUser(id: 'u1', username: 'zhangsan', name: '张三'),
      ],
      failCount: 3,
      lockTtlSeconds: 742,
    ),
    RiskUserLock(
      form: 'zhansa',
      match: RiskUserLockMatch.none,
      matchedUsers: const [],
      failCount: 5,
      lockTtlSeconds: 59,
    ),
    RiskUserLock(
      form: 'laowang',
      match: RiskUserLockMatch.ambiguous,
      matchedUsers: [
        RiskMatchedUser(id: 'u2', username: null, name: '老王'),
        RiskMatchedUser(id: 'u3', username: 'laowang2', name: '老王'),
      ],
      failCount: 2,
      lockTtlSeconds: 300,
    ),
  ],
  ips: [
    RiskIpLock(
      ip: '112.193.57.210',
      failCount: 5,
      lockTtlSeconds: 711,
      recentFailedUserforms: const ['zhangsan', 'zhansa'],
    ),
    RiskIpLock(
      ip: 'unknown',
      failCount: 1,
      lockTtlSeconds: 60,
      recentFailedUserforms: const [],
    ),
  ],
);

/// 使用统计桩数据:三端 / 明细 / 内外网 / 交叉 / daily(两日多条三元组)。
UsageStats _usageStats() => UsageStats(
  metric: 'active_users',
  from: '2026-09-29T00:00:00.000Z',
  to: '2026-10-28T10:00:00.000Z',
  totals: UsageTotals(users: 42, events: 1234),
  byPlatformClass: [
    UsageGroupRow(name: 'web', users: 30, events: 800),
    UsageGroupRow(name: 'android_app', users: 10, events: 300),
    UsageGroupRow(name: 'ios_app', users: 2, events: 134),
  ],
  byPlatform: [
    UsageGroupRow(name: 'web_desktop', users: 18, events: 500),
    UsageGroupRow(name: 'web_mobile', users: 12, events: 300),
    UsageGroupRow(name: 'android_app', users: 10, events: 300),
  ],
  byNetwork: [
    UsageGroupRow(name: 'lan', users: 40, events: 1200),
    UsageGroupRow(name: 'wan', users: 8, events: 34),
  ],
  cross: [
    UsageCrossRow(
      platform: 'android_app',
      network: 'lan',
      users: 10,
      events: 300,
    ),
  ],
  daily: [
    UsageDailyRow(
      date: '2026-10-26',
      platform: 'web',
      network: 'lan',
      users: 5,
      events: 11,
    ),
    UsageDailyRow(
      date: '2026-10-26',
      platform: 'android_app',
      network: 'wan',
      users: 3,
      events: 7,
    ),
    UsageDailyRow(
      date: '2026-10-27',
      platform: 'web',
      network: 'lan',
      users: 6,
      events: 30,
    ),
  ],
);

Me _adminMe() =>
    Me.fromJson({'id': 'u9', 'name': '管理员', 'is_system_admin': true});
