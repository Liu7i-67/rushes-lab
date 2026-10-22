/// fmt — 展示格式化纯函数(可单测):字节大小 / ISO 日期。
library;

/// 字节人性化:B / KB / MB / GB(与 web 端口吻一致,一位小数)。
String fmtBytes(num n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// ISO 时间戳 → 日期段(YYYY-MM-DD);不足 10 位原样返回。
String fmtDate(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;

/// ISO → 'MM-DD HH:mm'(B6 邀请/授权到期展示;解析失败原样截断)。
String fmtIsoShort(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) {
    return iso.length >= 16 ? iso.substring(0, 16) : iso;
  }
  return '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 相对时间(app-polish E6):通知等列表行的人类化时间。
/// 规则:刚刚(<1 分钟)/ N 分钟前(<1 小时)/ N 小时前(今日)/
/// 昨天 HH:mm / 前天 HH:mm / N 天前(3~7 天)/ MM-DD(同年)/
/// YYYY-MM-DD(跨年);[now] 注入供单测;解析失败原样返回(不崩溃)。
String fmtRelativeTime(String iso, {DateTime? now}) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  final n = (now ?? DateTime.now()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final diff = n.difference(t);
  if (diff < const Duration(minutes: 1)) return '刚刚';
  if (diff < const Duration(hours: 1)) return '${diff.inMinutes} 分钟前';
  final today = DateTime(n.year, n.month, n.day);
  final that = DateTime(t.year, t.month, t.day);
  final days = today.difference(that).inDays;
  if (days <= 0) return '${diff.inHours} 小时前';
  if (days == 1) return '昨天 $hm';
  if (days == 2) return '前天 $hm';
  if (days <= 7) return '$days 天前';
  if (t.year == n.year) return '${two(t.month)}-${two(t.day)}';
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// ETA 人类可读(web fmtEta 同口径;B9 P2-6 收敛为单一实现——网盘备份任务
/// 详情页与列表卡共用,勿再各自内联)。
String fmtEtaShort(int seconds) {
  if (seconds < 60) return '不足 1 分钟';
  final m = (seconds / 60).round();
  if (m < 60) return '约 $m 分钟';
  final h = m ~/ 60;
  final rm = m % 60;
  return rm == 0 ? '约 $h 小时' : '约 $h 小时 $rm 分';
}
