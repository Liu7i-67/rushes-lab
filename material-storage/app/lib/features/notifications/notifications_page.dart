/// NotificationsPage — 通知中心(B7 §8.7;B9 遗留清偿分页):时间倒序列表
/// (未读橙点)+ 服务端分页「加载更多」(offset 递增,B7 期固定 limit=100
/// 的截断收口)+ **「全部已读」按钮恒显**(all=true 服务端全量已读,不依赖
/// 当前已拉到的前 100 条);点击按 **kind 白名单** 跳转(approval_*→审批中心,
/// folder_invite→对应项目文件夹;未知 kind 显通用详情,不崩溃、不把任意 URL
/// 交导航器),未读行点击即标已读并即时同步全局红点(功能点 5)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/polling_controller.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'notification_row.dart';

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

  /// 加载更多(B9 分页清偿):offset=已拉条数,追加;失败静默留按钮重试。
  Future<void> _loadMore() async {
    final data = _data;
    if (data == null || _loadingMore || data.items.length >= data.total) return;
    setState(() => _loadingMore = true);
    try {
      final r = await session.api!
          .notifications.list(limit: _kPageSize, offset: data.items.length);
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
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _markAll() async {
    setState(() => _markingAll = true);
    try {
      await session.api!.notifications.markRead(all: true);
      _poller.unreadCount = 0; // 红点即时更新(功能点 5)
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
        // P2-1:原地替换该行 readAt —— 行内未读样式即时消除,不等下轮重拉
        // (web 同哲学;列表自身 unread 同步减一,驱动「全部已读」入口消失)。
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
            items: items, total: data.total, unreadCount: unread);
      }
      _poller.unreadCount =
          (_poller.unreadCount - 1).clamp(0, 1 << 30); // 红点即时减一
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// kind 白名单路由(§8.7 钉子:未知 kind 不崩溃、不导航)。
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
      NotificationItem n) async {
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

  /// 通用详情(白名单外/无可跳转字段):只展示标题+正文,不导航。
  void _showDetail(NotificationItem n) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n.title),
        content: Text(n.body ?? '(无正文)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        // 全部已读恒显(B9 分页清偿:all=true 服务端全量已读,不依赖当前
        // 已拉到的条目;无未读时仍可点,幂等无害)
        actions: [
          TextButton(
            onPressed: _markingAll ? null : _markAll,
            child: const Text('全部已读'),
          ),
        ],
      ),
      body: _buildBody(data),
    );
  }

  Widget _buildBody(NotificationsList? data) {
    if (_error != null && data == null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data.items.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 80),
        EmptyState(icon: Icons.notifications_none_outlined, message: '暂无通知'),
      ]);
    }
    final hasMore = data.items.length < data.total;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: data.items.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          if (i >= data.items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: OutlinedButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? '加载中…' : '加载更多'),
              ),
            );
          }
          return NotificationRow(
            item: data.items[i],
            onTap: () => _open(data.items[i]),
          );
        },
      ),
    );
  }
}
