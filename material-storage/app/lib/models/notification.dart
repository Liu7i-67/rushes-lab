/// NotificationItem — /api/v1/notifications 契约(B7;notifications.py
/// NotificationOut 实码)。link 为 web 站内 URL(web_app_base_url 拼接),
/// App 侧只做 kind 白名单跳转、**不把任意 URL 交导航器**(§8.7 钉子)。
library;

/// 通知列表 → {items, total, unread_count}(unread_count=badge 轮询同源)。
class NotificationsList {
  NotificationsList({
    required this.items,
    required this.total,
    required this.unreadCount,
  });

  factory NotificationsList.fromJson(Map<String, dynamic> j) =>
      NotificationsList(
        items: ((j['items'] ?? const []) as List)
            .map((e) =>
                NotificationItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
        unreadCount: (j['unread_count'] ?? 0) as int,
      );

  final List<NotificationItem> items;
  final int total;
  final int unreadCount;
}

class NotificationItem {
  NotificationItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.body,
    this.link,
    this.readAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) =>
      NotificationItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: (j['title'] ?? '') as String,
        body: j['body'] as String?,
        link: j['link'] as String?,
        readAt: j['read_at'] as String?,
        createdAt: (j['created_at'] ?? '') as String,
      );

  final String id;
  final String kind;
  final String title;
  final String? body;
  final String? link; // web 站内 URL;仅 folder_invite 类携带项目/夹路径
  final String? readAt; // null=未读(橙点)
  final String createdAt;

  bool get isUnread => readAt == null;

  /// 已读副本(mark-read 成功后原地替换列表项,行内未读样式即时消除,
  /// 不等下轮重拉;时间戳仅占位,契约真实值以下次 list 对账为准)。
  NotificationItem markedRead() => NotificationItem(
        id: id,
        kind: kind,
        title: title,
        body: body,
        link: link,
        readAt: readAt ?? DateTime.now().toUtc().toIso8601String(),
        createdAt: createdAt,
      );

  /// kind 中文(web NOTIFICATION_KIND_LABEL 实况);未知 kind 回 raw token
  /// (白名单外仍可展示,跳转走通用详情不崩溃)。
  String get kindLabel => kNotificationKindLabel[kind] ?? kind;
}

/// kind → 中文 chip(web NOTIFICATION_KIND_LABEL 同映射;白名单跳转另见
/// features/notifications 侧 kind 路由)。
const kNotificationKindLabel = <String, String>{
  'approval_pending': '审批待办',
  'approval_decided': '审批结果',
  'folder_invite': '目录邀请',
  'share': '资源分享',
};
