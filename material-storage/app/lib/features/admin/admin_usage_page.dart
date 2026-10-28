/// AdminUsagePage — 客户端使用统计(risk-control-module-plan §5.3;消费既有
/// GET /api/v1/admin/usage/stats,纯新增展示,后端零改动):
/// 窗口 chips(近 7 / 近 30 天,默认 30)+ metric 切换(活跃用户 / 登录次数)
/// + StatRow totals + by_platform_class / by_platform / by_network / cross
/// 分组行 + daily 按日聚合 events(最近 14 个有数据日期倒序,缺日不补零,D7)。
///
/// 窗口算法照抄 Web AdminUsageStatsPage.tsx(defaultRange):本地时区
/// 「今日 -(N-1) 天零点 → now」锚定(非 UTC 滚动窗),两端默认窗口一致、
/// 数字可直接对读;序列化的 tz-aware 钉子收口在 usage_api.dart。
/// 各分组独立去重、跨组不可加:页脚固定说明文案同 Web 口径注释。
/// 不引图表库(D7)。页面级 EmptyState 闸照 admin_risk_page 同款(§5.1)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/api/usage_api.dart';
import '../../core/session.dart';
import '../../models/usage.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_row.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/section_label.dart';
import '../../widgets/stat_row.dart';

class AdminUsagePage extends StatefulWidget {
  const AdminUsagePage({super.key});

  @override
  State<AdminUsagePage> createState() => _AdminUsagePageState();
}

class _AdminUsagePageState extends State<AdminUsagePage> {
  var _days = 30;
  var _metric = kUsageMetricActiveUsers;
  UsageStats? _data;
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 窗口锚定(web defaultRange 同口径):本地时区「今日 -(N-1) 天零点 → now」。
  (DateTime, DateTime) _window() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    return (todayStart.subtract(Duration(days: _days - 1)), now);
  }

  Future<void> _load() async {
    setState(() => _loading = _data == null);
    final (from, to) = _window();
    try {
      final stats = await session.api!.usage.fetchUsageStats(
        from: from,
        to: to,
        metric: _metric,
      );
      if (!mounted) return;
      setState(() {
        _data = stats;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      _fail(e.message); // 403/429 detail 透传(非 admin 深链兜底)
    } catch (e) {
      _fail(errorMessage(e, '加载失败,请稍后重试'));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  void _retune() {
    setState(() {});
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // 页面级闸(刻意加严,§5.1):非 system admin 深链直接锁定态
    if (!(session.me?.isSystemAdmin ?? false)) {
      return Scaffold(
        body: Column(
          children: [
            const PageHeader(back: true, title: '使用统计'),
            Expanded(
              child: EmptyState(
                icon: Icons.lock_outline,
                message: '只有系统管理员可以查看使用统计',
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(
            back: true,
            title: '使用统计',
            subtitle: '客户端三端占比 / 内外网访问占比',
          ),
          // 参数区:窗口 chip 轨(默认 30 天)+ metric 切换(§5.3)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                Tk.spaceSm,
                Tk.spacePage,
                0,
              ),
              children: [
                for (final (label, days) in const [
                  ('近 7 天', 7),
                  ('近 30 天', 30),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: Tk.spaceSm),
                    child: AppChip(
                      label: label,
                      selected: _days == days,
                      onTap: () {
                        if (_days == days) return;
                        _days = days;
                        _retune();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              0,
            ),
            child: AppSegmented<String>(
              segments: const [
                Segment(value: kUsageMetricActiveUsers, label: '活跃用户'),
                Segment(value: kUsageMetricLogins, label: '登录次数'),
              ],
              value: _metric,
              onChanged: (v) {
                if (_metric == v) return;
                _metric = v;
                _retune();
              },
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    final stats = _data!;
    final tk = context.tk;
    if (stats.isEmptyData) {
      return const EmptyState(
        icon: Icons.query_stats,
        message: '所选时间范围内暂无可用数据',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: Tk.spaceMd, bottom: Tk.space2xl),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          child: StatRow(
            items: [
              StatItem(value: '${stats.totals.users}', label: '去重用户数'),
              StatItem(value: '${stats.totals.events}', label: '事件总数'),
            ],
          ),
        ),
        const SectionLabel(title: '三端占比'),
        _groupCard([for (final r in stats.byPlatformClass) _groupRow(r)]),
        const SectionLabel(title: '客户端明细'),
        _groupCard([for (final r in stats.byPlatform) _groupRow(r)]),
        const SectionLabel(title: '内外网占比'),
        _groupCard([for (final r in stats.byNetwork) _groupRow(r)]),
        const SectionLabel(title: '端 × 网络交叉'),
        _groupCard([
          for (final r in stats.cross)
            _groupRow(
              UsageGroupRow(
                name:
                    '${_platformLabel(r.platform)} · ${_networkLabel(r.network)}',
                users: r.users,
                events: r.events,
              ),
            ),
        ]),
        _dailySection(stats),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            Tk.spaceSm,
            Tk.spacePage,
            0,
          ),
          child: Text(
            '各分组用户独立去重,跨组数字不可加总;同一用户多端 / 多网络会重复计数。'
            '按日仅计事件数(用户数跨三元组不可加,不求和)。',
            style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink3),
          ),
        ),
      ],
    );
  }

  Widget _groupCard(List<Widget> rows) => rows.isEmpty
      ? const SizedBox.shrink()
      : SectionCard(
          margin: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          children: rows,
        );

  /// 分组行:名称 + users/events(AppRow 单行,不引图表,不二次解析口径)。
  Widget _groupRow(UsageGroupRow row) => AppRow(
    title: _label(row.name),
    subtitle: '去重 ${row.users} 人 · ${row.events} 条事件',
    showChevron: false,
  );

  /// daily:按日聚合 events 取最近 14 个「有数据的日期」倒序(后端 ASC 需
  /// 反转;缺日不补零)。逐日 users 不展示(跨三元组不可加,D7)。
  Widget _dailySection(UsageStats stats) {
    final byDate = stats.eventsByDate;
    if (byDate.isEmpty) return const SizedBox.shrink();
    final dates = byDate.keys.toList()..sort();
    final recent = dates.length > 14 ? dates.sublist(dates.length - 14) : dates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel(title: '按日事件数', hint: '最近 14 个有数据日期'),
        _groupCard([
          for (final d in recent.reversed)
            AppRow(title: d, subtitle: '${byDate[d]} 条事件', showChevron: false),
        ]),
      ],
    );
  }
}

// ── 展示映射(键名中文 label;缺省回落原文,后端新增枚举不炸)──────────────

const _platformLabels = <String, String>{
  'web': '网页(三端合并)',
  'web_desktop': '网页 · 桌面',
  'web_mobile': '网页 · 移动',
  'android_app': 'Android App',
  'ios_app': 'iOS App',
  'app_legacy': '旧版 App',
  'unknown': '未知',
};

const _networkLabels = <String, String>{
  'lan': '内网',
  'wan': '外网',
  'unknown': '未知',
};

String _platformLabel(String key) => _platformLabels[key] ?? key;
String _networkLabel(String key) => _networkLabels[key] ?? key;

String _label(String key) => _platformLabels[key] ?? _networkLabels[key] ?? key;
