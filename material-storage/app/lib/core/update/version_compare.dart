/// 版本比较纯函数(F2-3):先比 version(按 `.` 切段、逐段整数、段数不齐补 0、
/// 非数字段按 0),version 相同再比 build;远端 > 本地才提示更新。
/// 全部无 IO / 无平台依赖,便于单测(T2)。
library;

/// 单段解析:非数字/负数按 0("v1" 里的修饰段、脏数据兜底)。
int _parseSegment(String part) {
  final n = int.tryParse(part.trim());
  return n == null || n < 0 ? 0 : n;
}

/// "1.2.3" → [1, 2, 3];"1.a.2" → [1, 0, 2];"" → [0]
/// (空串 split 后是 [''],tryParse 为 null → 落 0,无需特判)。
List<int> parseVersionSegments(String v) =>
    [for (final part in v.split('.')) _parseSegment(part)];

/// 逐段比较:a < b → -1,相等 → 0,a > b → 1;段数不齐短侧补 0(1.0 ≡ 1.0.0)。
int compareVersionStrings(String a, String b) {
  final sa = parseVersionSegments(a);
  final sb = parseVersionSegments(b);
  final len = sa.length > sb.length ? sa.length : sb.length;
  for (var i = 0; i < len; i++) {
    final x = i < sa.length ? sa[i] : 0;
    final y = i < sb.length ? sb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// 远端是否有可用更新(F2-3 口径):version 不同按段比较决胜;version 相同
/// 再比 build;均相同或远端更低 → false(不提示)。
bool isNewerVersion({
  required String remoteVersion,
  required int remoteBuild,
  required String localVersion,
  required int localBuild,
}) {
  final c = compareVersionStrings(remoteVersion, localVersion);
  if (c != 0) return c > 0;
  return remoteBuild > localBuild;
}
