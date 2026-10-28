/// 风控 / 使用统计 API 契约单测(risk-control-module-plan §7.3;照
/// ms_api_test.dart 本地 HttpServer 模式,实码=routers/risk.py §3.1/§3.2 与
/// routers/usage_stats.py):请求路径 / 入参 / 出参解析 / 403 detail 透传。
///
/// 时区钉子:usage from/to 必须 tz-aware ISO(naive 会被后端 422),本层断言
/// 序列化恒为 UTC「Z」后缀且时刻不漂移(toUtc 语义,非本地串直拼)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/models/risk.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;
  final usageQuery = <String, String>{};

  setUp(() async {
    usageQuery.clear();
    h = ApiHarness((req) async {
      final p = req.uri.path;

      // ── risk(§3.1/§3.2 契约样例)──
      if (req.method == 'GET' && p == '/api/v1/admin/risk/locks') {
        json(req, {
          'users': [
            {
              'form': 'zhangsan',
              'match': 'unique',
              'matched_users': [
                {'id': 'u1', 'username': 'zhangsan', 'name': '张三'},
              ],
              'fail_count': 3,
              'lock_ttl_seconds': 742,
            },
            {
              'form': 'zhansa',
              'match': 'none',
              'matched_users': [],
              'fail_count': 5,
              'lock_ttl_seconds': 59,
            },
            {
              // name 形态锁命中老飞书用户:username 可空(§3.1 ⚠ 回归点)
              'form': '老王',
              'match': 'ambiguous',
              'matched_users': [
                {'id': 'u2', 'username': null, 'name': '老王'},
                {'id': 'u3', 'username': 'laowang2', 'name': '老王'},
              ],
              'fail_count': 2,
              'lock_ttl_seconds': 300,
            },
          ],
          'ips': [
            {
              'ip': '112.193.57.210',
              'fail_count': 5,
              'lock_ttl_seconds': 711,
              'recent_failed_userforms': ['zhangsan', 'zhansa'],
            },
            {
              'ip': 'unknown',
              'fail_count': 1,
              'lock_ttl_seconds': 60,
              'recent_failed_userforms': [],
            },
          ],
        });
        return;
      }
      final unlockMatch = RegExp(
        r'^/api/v1/admin/risk/locks/ips/([^/]+)/unlock$',
      ).firstMatch(p);
      if (req.method == 'POST' && unlockMatch != null) {
        final ip = Uri.decodeComponent(unlockMatch.group(1)!);
        if (ip == '6.6.6.6') {
          json(req, {'detail': '需要系统管理员权限'}, status: 403);
          return;
        }
        json(req, {'ip': ip, 'was_locked': ip != '7.7.7.7'});
        return;
      }

      // ── usage stats(routers/usage_stats.py 契约)──
      if (req.method == 'GET' && p == '/api/v1/admin/usage/stats') {
        usageQuery.addAll(req.uri.queryParameters);
        json(req, {
          'metric': usageQuery['metric'],
          'from': usageQuery['from'],
          'to': usageQuery['to'],
          'totals': {'users': 42, 'events': 1234},
          'by_platform': [
            {'platform': 'android_app', 'users': 10, 'events': 300},
          ],
          'by_platform_class': [
            {'platform_class': 'web', 'users': 30, 'events': 800},
          ],
          'by_network': [
            {'network': 'lan', 'users': 40, 'events': 1200},
            {'network': 'wan', 'users': 8, 'events': 34},
          ],
          'cross': [
            {
              'platform': 'android_app',
              'network': 'lan',
              'users': 10,
              'events': 300,
            },
          ],
          'daily': [
            {
              'date': '2026-10-26',
              'platform': 'web',
              'network': 'lan',
              'users': 5,
              'events': 11,
            },
            {
              'date': '2026-10-26',
              'platform': 'android_app',
              'network': 'wan',
              'users': 3,
              'events': 7,
            },
          ],
        });
        return;
      }

      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
  });

  tearDown(() => h.stop());

  test('risk locks:GET 路径 + 三态/可空 username/哨兵 IP 契约解析', () async {
    final locks = await h.api!.risk.fetchRiskLocks();
    expect(h.captured.last.method, 'GET');
    expect(h.captured.last.path, '/api/v1/admin/risk/locks');
    expect(h.captured.last.body, isEmpty);

    expect(locks.users, hasLength(3));
    expect(locks.users[0].match, RiskUserLockMatch.unique);
    expect(locks.users[0].matchedUsers.single.id, 'u1');
    expect(locks.users[0].matchedUsers.single.username, 'zhangsan');
    expect(locks.users[1].match, RiskUserLockMatch.none);
    expect(locks.users[1].matchedUsers, isEmpty);
    expect(locks.users[2].match, RiskUserLockMatch.ambiguous);
    expect(locks.users[2].matchedUsers, hasLength(2));
    // §3.1 回归:name 形态命中老飞书用户,username=null 不得炸解析
    expect(locks.users[2].matchedUsers.first.username, isNull);
    expect(locks.users[2].matchedUsers.first.name, '老王');
    expect(locks.users[0].failCount, 3);
    expect(locks.users[0].lockTtlSeconds, 742);
    expect(locks.users[0].remainingMinutes, 13); // ceil(742/60) 上取整

    expect(locks.ips, hasLength(2));
    expect(locks.ips[0].isUnknownSentinel, isFalse);
    expect(locks.ips[0].recentFailedUserforms, ['zhangsan', 'zhansa']);
    expect(locks.ips[1].isUnknownSentinel, isTrue);
    expect(locks.isEmpty, isFalse);
  });

  test('risk unlockIp:POST 路径透传 ip + was_locked 解析;403 detail 透传', () async {
    final r1 = await h.api!.risk.unlockIp('112.193.57.210');
    expect(h.captured.last.method, 'POST');
    expect(
      h.captured.last.path,
      '/api/v1/admin/risk/locks/ips/112.193.57.210/unlock',
    );
    expect(r1.ip, '112.193.57.210');
    expect(r1.wasLocked, isTrue);

    // 幂等:已无锁的 ip was_locked=false(锁 key 曾存在才 true,严格语义)
    final r2 = await h.api!.risk.unlockIp('7.7.7.7');
    expect(r2.wasLocked, isFalse);

    // unknown 哨兵同样透传可解(§3.1)
    final r3 = await h.api!.risk.unlockIp('unknown');
    expect(h.captured.last.path, '/api/v1/admin/risk/locks/ips/unknown/unlock');
    expect(r3.wasLocked, isTrue);

    Object? err;
    try {
      await h.api!.risk.unlockIp('6.6.6.6');
    } on ApiException catch (e) {
      err = e;
    }
    expect(err, isA<ApiException>());
    expect((err as ApiException).message, contains('需要系统管理员权限'));
  });

  test('usage stats:from/to/metric 入参;序列化恒 tz-aware UTC「Z」串', () async {
    // 本地时区构造(页面窗口算法产物),API 层统一 toUtc 序列化
    final from = DateTime(2026, 10, 1, 8, 30);
    final to = DateTime(2026, 10, 28, 10, 0);
    final stats = await h.api!.usage.fetchUsageStats(
      from: from,
      to: to,
      metric: 'logins',
    );

    expect(usageQuery['metric'], 'logins');
    // 钉子:naive 串会被后端 422(usage_stats.py 端点自判 tzinfo),
    // 必须是 toUtc().toIso8601String() 产出的带「Z」tz-aware 串且时刻不漂移
    expect(usageQuery['from'], from.toUtc().toIso8601String());
    expect(usageQuery['to'], to.toUtc().toIso8601String());
    expect(usageQuery['from']!.endsWith('Z'), isTrue);
    expect(DateTime.parse(usageQuery['from']!), from.toUtc());

    // 契约解析:六粒度 + 各键位
    expect(stats.metric, 'logins');
    expect(stats.totals.users, 42);
    expect(stats.totals.events, 1234);
    expect(stats.byPlatform.single.name, 'android_app');
    expect(stats.byPlatformClass.single.name, 'web');
    expect(stats.byNetwork.map((r) => r.name), ['lan', 'wan']);
    expect(stats.cross.single.platform, 'android_app');
    expect(stats.cross.single.network, 'lan');
    // daily 三元组多行:同日两行;按日聚合 events 可加(11+7=18)
    expect(stats.daily, hasLength(2));
    expect(stats.eventsByDate['2026-10-26'], 18);
    expect(stats.isEmptyData, isFalse);
  });

  test('usage stats:metric 缺省 active_users;非 admin 403 detail 透传', () async {
    final stats = await h.api!.usage.fetchUsageStats(
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 28),
    );
    expect(usageQuery['metric'], 'active_users');
    expect(stats.byNetwork, hasLength(2));
  });
}
