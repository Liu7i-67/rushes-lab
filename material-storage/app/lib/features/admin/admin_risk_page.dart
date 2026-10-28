/// AdminRiskPage — 登录风控(risk-control-module-plan §5.2):被锁账号 /
/// 被锁 IP 双 SectionCard 拉取快照(不轮询、不做倒计时,D1/D2)。
///
/// 账号解锁复用既有 directory unlock 端点(连带清近 24h 失败 IP 的行为保留),
/// none / ambiguous 行无解锁入口(D4);IP 锁单独解除走 risk.unlockIp。
/// 交互范式照抄 admin_user_row.dart:行 → 底部 actions 弹层 → showAppConfirm
/// → 端点 → toast → 刷新;403/429 detail 透传(GET 错误态 / 写操作 toast)。
///
/// 页面级 EmptyState 闸(照 admin_home.dart:34-48 同款)属刻意加严(§5.1):
/// 既有六个 admin 子页无页面级闸、靠后端 403 兜底,风控/统计页数据敏感,
/// 深链直达时直接给锁定态体验更好。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/risk.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/section_label.dart';
import '../../widgets/toast.dart';

class AdminRiskPage extends StatefulWidget {
  const AdminRiskPage({super.key});

  @override
  State<AdminRiskPage> createState() => _AdminRiskPageState();
}

class _AdminRiskPageState extends State<AdminRiskPage> {
  RiskLocks? _data;
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = _data == null);
    try {
      final locks = await session.api!.risk.fetchRiskLocks();
      if (!mounted) return;
      setState(() {
        _data = locks;
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

  // ── 账号解锁(照 admin_user_row.dart 'unlock' 先例 :117-137)──────────────

  Future<void> _openUserActions(RiskUserLock lock) async {
    final user = lock.matchedUsers.first;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.lock_open_outlined),
              title: const Text('解锁'),
              subtitle: const Text('清登录锁定与失败计数,连带清近 24h 失败 IP'),
              onTap: () => Navigator.of(context).pop('unlock'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _unlockUser(user);
  }

  Future<void> _unlockUser(RiskMatchedUser user) async {
    final name = _displayName(user);
    if (!await _confirm(
          context,
          '解锁 $name 的登录锁定?',
          '清除用户名维度锁定与失败计数,并连带清近 24h 失败 IP 的锁;'
              '完成后即可重新登录。',
        ) ||
        !mounted) {
      return;
    }
    try {
      final r = await session.api!.directory.unlockUser(user.id);
      if (!mounted) return;
      toast(
        context,
        r.wasLocked
            ? '已解锁 $name(清 ${r.clearedUserForms.length} 个登录名形态 / '
                  '${r.clearedIps.length} 个 IP 锁)'
            : '$name 当前无登录锁,已顺手清理失败计数',
        tone: ToastTone.success,
      );
      _load(); // 连带清 IP:两列表都要刷新
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 409/429 detail 透传
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '操作失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  // ── 单 IP 解锁(§3.2)────────────────────────────────────────────────────

  Future<void> _openIpActions(RiskIpLock lock) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.wifi_lock_outlined),
              title: const Text('解除锁定'),
              subtitle: Text('清除 ${lock.ip} 的登录锁与失败计数'),
              onTap: () => Navigator.of(context).pop('unlock'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (!await _confirm(
          context,
          '解除 ${lock.ip} 的登录锁定?',
          '该 IP 的锁定与失败计数将立即清除,窗口内重新可登录;请确认非暴力破解来源。',
        ) ||
        !mounted) {
      return;
    }
    try {
      final r = await session.api!.risk.unlockIp(lock.ip);
      if (!mounted) return;
      toast(
        context,
        r.wasLocked ? '已解除 ${lock.ip} 的登录锁定' : '${lock.ip} 当前无登录锁',
        tone: ToastTone.success,
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error);
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '操作失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 页面级闸(刻意加严,§5.1):非 system admin 深链直接锁定态
    if (!(session.me?.isSystemAdmin ?? false)) {
      return Scaffold(
        body: Column(
          children: [
            const PageHeader(back: true, title: '登录风控'),
            Expanded(
              child: EmptyState(
                icon: Icons.lock_outline,
                message: '只有系统管理员可以进入登录风控',
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '登录风控',
            subtitle: '登录失败触发的锁定快照 · 15 分钟自动过期',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
              ),
            ],
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
    final locks = _data!;
    final tk = context.tk;
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: const EdgeInsets.only(top: Tk.spaceMd, bottom: Tk.space2xl),
          children: locks.isEmpty
              ? [
                  SizedBox(
                    height: constraints.maxHeight,
                    child: const EmptyState(
                      icon: Icons.lock_open_outlined,
                      message: '当前无任何登录锁定',
                      description: '列表为拉取快照,可用右上角刷新。',
                    ),
                  ),
                ]
              : [
                  SectionLabel(
                    title: '被锁账号',
                    hint: '${locks.users.length} 个登录名形态',
                  ),
                  SectionCard(
                    margin: const EdgeInsets.symmetric(
                      horizontal: Tk.spacePage,
                    ),
                    children: [for (final u in locks.users) _userRow(u)],
                  ),
                  SectionLabel(title: '被锁 IP', hint: '${locks.ips.length} 个'),
                  SectionCard(
                    margin: const EdgeInsets.symmetric(
                      horizontal: Tk.spacePage,
                    ),
                    children: [for (final ip in locks.ips) _ipRow(ip)],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Tk.spacePage,
                      Tk.spaceSm,
                      Tk.spacePage,
                      0,
                    ),
                    child: Text(
                      '失败次数为当前窗口计数(滚动窗口,非累计);'
                      '「未匹配账号 / 重名歧义」无解锁入口,可解除相关 IP 锁。',
                      style: TextStyle(
                        fontSize: Tk.fzMd,
                        height: 1.6,
                        color: tk.ink3,
                      ),
                    ),
                  ),
                ],
        ),
      ),
    );
  }

  /// 被锁账号行:unique 主标题 = 账号名(username 为 null 的老用户只显示
  /// name);none / ambiguous 主标题 = form 原文 + 副标注徽标,无动作(D4)。
  Widget _userRow(RiskUserLock lock) {
    final meta =
        '${lock.form} · 当前窗口失败 ${lock.failCount} 次 · 剩余约 ${lock.remainingMinutes} 分钟';
    final (title, badge, onTap) = switch (lock.match) {
      RiskUserLockMatch.unique => (
        _displayName(lock.matchedUsers.first),
        null,
        () => _openUserActions(lock),
      ),
      RiskUserLockMatch.none => (
        lock.form,
        const Badge(label: '未匹配账号', tone: BadgeTone.outline),
        null,
      ),
      RiskUserLockMatch.ambiguous => (
        lock.form,
        const Badge(label: '重名歧义', tone: BadgeTone.warn),
        null,
      ),
    };
    return AppRow(
      leading: const Icon(Icons.person_outline),
      title: title,
      subtitle: meta,
      trailing: badge,
      onTap: onTap,
      showChevron: onTap != null,
    );
  }

  /// 被锁 IP 行:'unknown' 哨兵如实展示 + 「未知 IP」标注(§3.1,可解锁)。
  Widget _ipRow(RiskIpLock lock) {
    final forms = lock.recentFailedUserforms;
    final sentinel = lock.isUnknownSentinel ? '链路异常(IP 缺失) · ' : '';
    final formsPart = forms.isEmpty ? '' : ' · 近 24h:${forms.join(', ')}';
    final meta =
        '$sentinel'
        '当前窗口失败 ${lock.failCount} 次 · 剩余约 ${lock.remainingMinutes} 分钟'
        '$formsPart';
    return AppRow(
      leading: const Icon(Icons.lan_outlined),
      title: lock.ip,
      subtitle: meta,
      trailing: lock.isUnknownSentinel
          ? const Badge(label: '未知 IP', tone: BadgeTone.warn)
          : null,
      onTap: () => _openIpActions(lock),
    );
  }
}

/// unique 账号名:name + username;username 为 null 只显示 name(老飞书用户)。
String _displayName(RiskMatchedUser user) {
  final un = user.username;
  return (un == null || un.isEmpty) ? user.name : '${user.name}($un)';
}

/// 操作确认(照 admin_user_row.dart 收口:取消 / 遮罩关闭均 = false)。
Future<bool> _confirm(BuildContext context, String title, String content) =>
    showAppConfirm(
      context,
      title: title,
      content: content,
    ).then((ok) => ok ?? false);
