/// NotificationsPage — 通知中心(§6 F13):PageHeader(返回 + 未读副标题 +
/// 全部已读) + SectionCard 行卡列表;滚动到底自动加载;点击按 **kind 白名单**
/// 跳转(approval_*→审批中心,folder_invite→对应项目文件夹;未知 kind 显通用
/// 详情卡,不崩溃、不把任意 URL 交导航器),未读行点击即标已读并即时同步全局
/// 红点。列表/空态/加载体拆在 notifications_body.dart。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/polling_controller.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'notifications_body.dart';

/// 单页条目(与 web NOTIFICATIONS_PAGE_SIZE 对齐的轻量口径)。
const _kPageSize = 100;

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, this.poller});

  /// 测试注入;默认全局单例(红点/对账同源 §8.7)。
  final UnreadPoller? poller;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  NotificationsList? _data;
  String? _error;
  bool _markingAll = false;
  bool _loadingMore = false;

  UnreadPoller get _poller => widget.poller ?? unreadPoller;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 拉第一页并落态(下拉刷新/重试同路);返回真 future 供 RefreshIndicator。
  Future<void> _reload() async {
    try {
      final r = await session.api!.notifications.list(limit: _kPageSize);
      if (!mounted) return;
      setState(() {
        _data = r;
        _error = null;
      });
      _poller.unreadCount = r.unreadCount; // 与全局 badge 对账
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorMessage(e, '通知加载失败'));
    }
  }

  /// 自动加载:offset=已拉条数,追加;失败 toast 提示(再次滚动重试)。
  Future<void> _loadMore() async {
    final data = _data;
    if (data == null || _loadingMore || data.items.length >= data.total) return;
    setState(() => _loadingMore = true);
    try {
      final r = await session.api!.notifications.list(
        limit: _kPageSize,
        offset: data.items.length,
      );
      if (!mounted) return;
      final known = data.items.map((n) => n.id).toSet();
      setState(() {
        _data = NotificationsList(
          items: [
            ...data.items,
            ...r.items.where((n) => !known.contains(n.id)), // 翻页间隙新读防重
          ],
          total: r.total,
          unreadCount: r.unreadCount,
        );
        _loadingMore = false;
      });
      _poller.unreadCount = r.unreadCount;
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMore = false);
        // 静默失败改可见反馈;再次滚动到底即可重试
        toast(
          context,
          errorMessage(e, '加载更多失败,可再次下拉重试'),
          tone: ToastTone.error,
        );
      }
    }
  }

  Future<void> _markAll() async {
    setState(() => _markingAll = true);
    try {
      await session.api!.notifications.markRead(all: true);
      _poller.unreadCount = 0; // 红点即时更新
      await _reload();
    } catch (_) {} // 失败保静默:列表仍在,红点由下轮轮询纠正
    if (mounted) setState(() => _markingAll = false);
  }

  void _open(NotificationItem n) {
    _route(n); // 先跳转(白名单内),失败/白名单外落通用详情
    if (n.isUnread) _markRead(n);
  }

  Future<void> _markRead(NotificationItem n) async {
    try {
      await session.api!.notifications.markRead(ids: [n.id]);
      final data = _data;
      if (data != null) {
        // 原地替换该行 readAt:行内未读样式即时消除,不等下轮重拉
        var unread = data.unreadCount;
        final items = <NotificationItem>[];
        for (final x in data.items) {
          if (x.id == n.id && x.isUnread) {
            items.add(x.markedRead());
            unread = (unread - 1).clamp(0, 1 << 30);
          } else {
            items.add(x);
          }
        }
        _data = NotificationsList(
          items: items,
          total: data.total,
          unreadCount: unread,
        );
      }
      _poller.unreadCount = (_poller.unreadCount - 1).clamp(
        0,
        1 << 30,
      ); // 红点即时减一
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// kind 白名单路由(未知 kind 不崩溃、不导航)。
  Future<void> _route(NotificationItem n) async {
    switch (n.kind) {
      case 'approval_pending':
      case 'approval_decided':
        await Navigator.of(context).pushNamed('/approvals');
      case 'folder_invite':
        final target = await _inviteTarget(n);
        if (target != null && mounted) {
          await Navigator.of(context).pushNamed('/folders', arguments: target);
        } else {
          _showDetail(n);
        }
      default:
        _showDetail(n);
    }
  }

  /// folder_invite → FoldersPage 入参 (projectId, projectName, myRoles):
  /// 解析通知 link 段(实码=web_url(projects/{pid}/folders/{fid});web
  /// base 带 /ms-static/web basename,故按段扫描匹配,不固定下标),
  /// 项目名/角色经 /projects 反查;任一环节拿不到 → null 落通用详情。
  Future<(String, String, List<String>)?> _inviteTarget(
    NotificationItem n,
  ) async {
    final link = n.link;
    if (link == null) return null;
    final seg = Uri.tryParse(link)?.pathSegments ?? const [];
    // 段扫描匹配 .../projects/{pid}/folders/{fid}(i+3 为 fid,须在界内)
    String? pid;
    for (var i = 0; i + 3 < seg.length && pid == null; i++) {
      if (seg[i] == 'projects' && seg[i + 2] == 'folders') {
        pid = seg[i + 1];
      }
    }
    if (pid == null) return null;
    try {
      final projects = await session.api!.projects.list();
      for (final p in projects) {
        if (p.id == pid) return (pid, p.name, p.myRoles);
      }
    } catch (_) {}
    return null;
  }

  /// 通用详情(白名单外/无可跳转字段):统一单钮收束,只展示标题+正文,不导航。
  void _showDetail(NotificationItem n) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n.title),
        content: Text((n.body == null || n.body!.isEmpty) ? '(无正文)' : n.body!),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final unread = data?.unreadCount ?? 0;
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '通知',
            subtitle: unread > 0 ? '$unread 条未读' : '全部已读',
            actions: [
              TextButton(
                // 无未读时禁用(幂等但按钮给出不可用语义)
                onPressed: (_markingAll || unread == 0) ? null : _markAll,
                child: const Text('全部已读'),
              ),
            ],
          ),
          Expanded(
            child: NotificationsBody(
              data: data,
              error: _error,
              loadingMore: _loadingMore,
              onRefresh: _reload,
              onLoadMore: _loadMore,
              onOpen: _open,
            ),
          ),
        ],
      ),
    );
  }
}
