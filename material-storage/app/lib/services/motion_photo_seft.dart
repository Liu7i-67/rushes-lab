/// Samsung SEFT trailer 解析(§3.1/§5.1:纯 SEFT 分支 P1 + XMP 轨尾部修正共用)。
///
/// trailer 字节布局(钉死口径;fixture 锁实现、真机未证,§8-D① 真机核对为硬前置):
/// ```
/// [video 字节][SEFH 块(L 字节)][size = L(4B 小端)]["SEFT"(4B)]
/// ```
/// - L = SEFH 块长,**不是** trailer 总长;totalTrailerLen = L + 8(size 与签名共 8 字节)。
/// - L 合法域 [24, 4088]:最小 SEFH 单 MotionPhoto_Data tag 形态 = 24 字节
///   (doodspav/motionphoto 口径),等效约束 totalTrailerLen = L+8 ∈ [32, 4096]。
/// - L 非法/推导位魔数不符 → 在尾窗内做 "SEFH" 魔数前向搜索兜底(「SEFH 直接解析
///   可能给出正确区间」;再失败才终局 null 降普通轨)。
/// - SEFH 块内定位 ASCII marker `MotionPhoto_Data`,其后 4 字节小端 int = 视频起始
///   绝对偏移;videoEnd = SEFH 块起点(L 合法时 = fileSize - (L+8),两口径一致)。
library;

/// L 合法域(§5.1 守卫 4)
const int seftLenMin = 24;
const int seftLenMax = 4088;

/// 纯 SEFT 分支解析产物:video = [videoStart, videoEnd)
class SeftSplit {
  final int videoStart;
  final int videoEnd;
  const SeftSplit(this.videoStart, this.videoEnd);
}

bool _asciiAt(List<int> b, int offset, String s) {
  if (offset < 0 || offset + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[offset + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOfAscii(List<int> b, String s, int from, int end) {
  final limit = end - s.length;
  for (var i = from; i <= limit; i++) {
    var hit = true;
    for (var j = 0; j < s.length; j++) {
      if (b[i + j] != s.codeUnitAt(j)) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

int _readUint32LE(List<int> b, int offset) =>
    b[offset] |
    (b[offset + 1] << 8) |
    (b[offset + 2] << 16) |
    (b[offset + 3] << 24);

/// 尾部 4 字节是否 `SEFT` 签名(三星 trailer 在场标志;签名恒在文件末尾,
/// 即调用方尾窗的末 4 字节)。
bool tailHasSeftSignature(List<int> tail) =>
    tail.length >= 4 && _asciiAt(tail, tail.length - 4, 'SEFT');

/// 读尾部 size 字段得 L:签名在场且 L ∈ [24,4088] 才返回,否则 null。
/// XMP 轨 trailer 修正专用口径:L 非法 → XMP 轨未命中,落 SEFT 兜底(§5.1 守卫 4)。
int? seftTrailerLen(List<int> tail) {
  if (tail.length < 8 || !tailHasSeftSignature(tail)) return null;
  final l = _readUint32LE(tail, tail.length - 8);
  if (l < seftLenMin || l > seftLenMax) return null;
  return l;
}

/// 纯 SEFT 分支解析(签名在场前提下):L 合法时优先按推导位取 SEFH(须有魔数),
/// 否则尾窗内 "SEFH" 魔数前向搜索兜底(最多 16 个候选,防极端字节串长尾)。
/// 返回 null = 解析失败,调用方终局降级普通轨。
SeftSplit? parseSeftTrailer(List<int> tail, int tailStart) {
  if (!tailHasSeftSignature(tail)) return null;
  final fileEnd = tailStart + tail.length;
  final candidates = <int>[];
  final l = seftTrailerLen(tail);
  if (l != null) {
    final derived = fileEnd - l - 8;
    if (derived >= tailStart) candidates.add(derived);
  }
  var from = 0;
  var found = 0;
  while (found < 16) {
    final idx = _indexOfAscii(tail, 'SEFH', from, tail.length - 8);
    if (idx < 0) break;
    candidates.add(tailStart + idx);
    from = idx + 1;
    found++;
  }
  for (final sefh in candidates) {
    final r = _parseSefh(tail, tailStart, sefh, fileEnd);
    if (r != null) return r;
  }
  return null;
}

SeftSplit? _parseSefh(List<int> tail, int tailStart, int sefhAbs, int fileEnd) {
  final local = sefhAbs - tailStart;
  if (local < 0 || !_asciiAt(tail, local, 'SEFH')) return null;
  final dataLimit = fileEnd - 8 - tailStart; // SEFH 数据止于 size 字段之前
  const marker = 'MotionPhoto_Data';
  final mIdx = _indexOfAscii(tail, marker, local + 4, dataLimit);
  if (mIdx < 0) return null;
  final offPos = mIdx + marker.length;
  if (offPos + 4 > dataLimit) return null;
  final videoStart = _readUint32LE(tail, offPos); // 偏移为文件内绝对位置
  final videoEnd = sefhAbs;
  if (videoStart < 2 || videoStart >= videoEnd) return null;
  return SeftSplit(videoStart, videoEnd);
}
