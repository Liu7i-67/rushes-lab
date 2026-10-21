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
