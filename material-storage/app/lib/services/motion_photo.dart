/// Motion Photo 探测内核(§5.1,纯 Dart,PC 可单测)。
///
/// 三族:GContainer(GCamera:MotionPhoto + Container:Item:Length=N)/
/// GCamera MicroVideo(MicroVideoOffset=N,offset=「距文件尾的长度」——假说+真机校准)/
/// Samsung SEFT trailer(P1 兜底,见 motion_photo_seft.dart)。
/// 六守卫:① JPEG SOI;② XMP marker(头 256KB 经验窗口,漏检 fail-safe null);
/// ③ 元素域提取(不假定属性顺序,容单双引号,Container:Directory 内
/// Semantic="MotionPhoto" 条目数必须==1,双标记并存两族区间互验:不一致 null、
/// 一致取 gcontainer);④ videoEnd 与 totalTrailerLen(尾 4 字节 SEFT 签名时
/// videoEnd=fileSize-(L+8),L∈[24,4088],L 非法→XMP 轨未命中落 SEFT 兜底);
/// ⑤ N>=1024 + videoStart>xmpEnd + videoStart<videoEnd;⑥ video[4..8]=='ftyp'。
/// 两级探测钉死(XMP 轨优先):① XMP 命中→尾部 SEFT 修正;② XMP 未命中且尾
/// 64KB 有签名→纯 SEFT 兜底;③ 都未命中→null 降普通轨。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ms_app/services/motion_photo_seft.dart';

/// XMP 经验窗口:单 APP1 段 ≤64KB 但 Adobe Extended XMP 可跨段,256KB 是经验值
const int xmpHeadWindow = 256 * 1024;

/// 尾窗(纯 SEFT 分支入口判定 + trailer 修正读数)
const int seftTailWindow = 64 * 1024;

/// 视频最小字节数(防 XMP 残留小值误判)
const int minVideoBytes = 1024;

/// 全量字节版拆分产物(测试与下载侧自校验共用内核)。
/// image=[0, videoStart) 主图原字节;video=[videoStart, videoEnd);
/// format ∈ 'gcontainer' | 'microvideo' | 'seft'。
class MotionPhotoSplit {
  final List<int> image;
  final List<int> video;
  final String format;
  MotionPhotoSplit(this.image, this.video, this.format);
}

/// 三读预筛的轻量结果(不含字节;命中后全量读+拆分+pack 收进 compute isolate)。
/// videoEnd:无 trailer=fileSize;三星混合形态=fileSize-(L+8)。
class MotionPhotoPlan {
  final String format;
  final int videoStart;
  final int videoEnd;
  final int fileSize;
  MotionPhotoPlan(this.format, this.videoStart, this.videoEnd, this.fileSize);
}

/// 头窗 XMP 提取产物(公开:下载侧定点读自校验复用同一解析,§5.4 步骤 4b)。
class MotionXmp {
  final String format; // 'gcontainer' | 'microvideo'
  final int videoBytes; // N(视频字节数)
  final int xmpEnd; // </x:xmpmeta> 结束后的绝对偏移(= 窗口偏移 + 窗内偏移)
  MotionXmp(this.format, this.videoBytes, this.xmpEnd);
}

/// 头窗字节内的 XMP marker 搜索 + motion 元素域提取(不引 XML 解析器,marker
/// 搜索与 flm extractOriginalXmp 同口径)。[windowOffset] = window 在原文件中的
/// 绝对偏移(定点读版复用入口)。未命中/字段不全/双标记不一致 → null(fail-safe)。
MotionXmp? extractMotionXmp(List<int> window, {int windowOffset = 0}) {
  final s = utf8.decode(window, allowMalformed: true);
  const open = '<x:xmpmeta';
  const close = '</x:xmpmeta>';
  final start = s.indexOf(open);
  if (start < 0) return null;
  final endIdx = s.indexOf(close, start);
  if (endIdx < 0) return null;
  final xmpEnd = windowOffset + endIdx + close.length; // endIdx 已是绝对索引
  final xmp = s.substring(start, endIdx + close.length);

  final isG = _attrIs(xmp, 'GCamera:MotionPhoto', '1');
  final isMv = _attrIs(xmp, 'GCamera:MicroVideo', '1');
  final nG = isG ? _motionItemLength(xmp) : null;
  final nM = isMv ? _intAttr(xmp, 'GCamera:MicroVideoOffset') : null;
  if (isG && isMv) {
    // 双标记并存(flm 默认模板即此形态):两族区间互验,不一致 null,一致取 gcontainer
    if (nG == null || nM == null || nG != nM) return null;
    return MotionXmp('gcontainer', nG, xmpEnd);
  }
  if (isG && nG != null) return MotionXmp('gcontainer', nG, xmpEnd);
  if (isMv && nM != null) return MotionXmp('microvideo', nM, xmpEnd);
  return null;
}

class _Attr {
  final String value;
  final int nameStart;
  final int valueEnd;
  _Attr(this.value, this.nameStart, this.valueEnd);
}

const _namePunct = {0x3A, 0x5F, 0x2D, 0x2E}; // : - _ .

bool _isNameChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A) ||
    _namePunct.contains(c);

int _skipSp(String s, int j) {
  while (j < s.length && (s.codeUnitAt(j) == 0x20 || s.codeUnitAt(j) == 0x09)) {
    j++;
  }
  return j;
}

/// 定位属性:名称边界检查(防 `X{name}` 子串误命中)+ 容空白 + 单/双引号值。
_Attr? _findAttrFrom(String s, String name, int from) {
  var i = from;
  while (true) {
    final at = s.indexOf(name, i);
    if (at < 0) return null;
    i = at + name.length;
    if (at > 0 && _isNameChar(s.codeUnitAt(at - 1))) continue; // 名称边界
    final eq = _skipSp(s, i);
    if (eq >= s.length || s.codeUnitAt(eq) != 0x3D) continue; // '='
    final q0 = _skipSp(s, eq + 1);
    if (q0 >= s.length) continue;
    final q = s.codeUnitAt(q0);
    if (q != 0x22 && q != 0x27) continue; // " 或 '
    final vEnd = s.indexOf(String.fromCharCode(q), q0 + 1);
    if (vEnd < 0) continue;
    return _Attr(s.substring(q0 + 1, vEnd), at, vEnd + 1);
  }
}

String? _attrValue(String s, String name) => _findAttrFrom(s, name, 0)?.value;

bool _attrIs(String s, String name, String expected) =>
    _attrValue(s, name) == expected;

int? _intAttr(String s, String name) {
  final v = _attrValue(s, name);
  if (v == null) return null;
  final n = int.tryParse(v.trim());
  return (n == null || n < 0) ? null : n;
}

/// 元素域提取:先定位 Item:Semantic="MotionPhoto" 的 Container:Item 元素边界
/// (向前最近 '<' / 向后最近 '>'),再在元素内取 Item:Length——Length 写在
/// Semantic 之前的厂商变体由此覆盖。Directory 内 MotionPhoto 条目数必须==1
/// (多 motion item = GContainer v2 多段,D5 不解析 → null)。
int? _motionItemLength(String xmp) {
  var scopeStart = 0;
  var scopeEnd = xmp.length;
  final dirAt = xmp.indexOf('<Container:Directory');
  if (dirAt >= 0) {
    scopeStart = dirAt;
    final dirClose = xmp.indexOf('</Container:Directory>', dirAt);
    if (dirClose >= 0) scopeEnd = dirClose;
  }
  var count = 0;
  _Attr? first;
  var from = scopeStart;
  while (from < scopeEnd) {
    final a = _findAttrFrom(xmp, 'Item:Semantic', from);
    if (a == null || a.nameStart >= scopeEnd) break;
    if (a.value == 'MotionPhoto') {
      count++;
      first ??= a;
    }
    from = a.valueEnd;
  }
  if (count != 1 || first == null) return null;
  final lt = xmp.lastIndexOf('<', first.nameStart);
  if (lt < scopeStart) return null;
  final gt = xmp.indexOf('>', first.nameStart);
  if (gt < 0 || gt >= scopeEnd) return null;
  final raw = _attrValue(xmp.substring(lt, gt + 1), 'Item:Length') ?? '';
  final n = int.tryParse(raw);
  return (n == null || n < 0) ? null : n;
}

class _Resolved {
  final String format;
  final int videoStart;
  final int videoEnd;
  _Resolved(this.format, this.videoStart, this.videoEnd);
}

/// XMP 轨守卫 4/5(区间部分;ftyp 守卫由调用方按全量/定点读两形态各自执行)
_Resolved? _xmpTrackRange(List<int> tail, MotionXmp xmp, int fileSize) {
  int videoEnd;
  if (tailHasSeftSignature(tail)) {
    final l = seftTrailerLen(tail);
    if (l == null) return null; // L 非法 → XMP 轨未命中,落 SEFT 兜底(两级探测②)
    videoEnd = fileSize - (l + 8); // totalTrailerLen = L+8(钉死口径,勿搞错 8 字节)
  } else {
    videoEnd = fileSize;
  }
  final n = xmp.videoBytes;
  if (n < minVideoBytes) return null;
  final videoStart = videoEnd - n;
  if (videoStart <= xmp.xmpEnd) return null; // 视频必须在 XMP 之后
  if (videoStart >= videoEnd) return null;
  return _Resolved(xmp.format, videoStart, videoEnd);
}

/// 纯 SEFT 兜底(P1,无 XMP 老三星):尾 64KB 窗签名 → SEFH → MotionPhoto_Data 偏移
_Resolved? _seftTrackRange(List<int> bytes) {
  final tailStart = max(0, bytes.length - seftTailWindow);
  final t = parseSeftTrailer(bytes.sublist(tailStart), tailStart);
  if (t == null) return null;
  if (t.videoEnd - t.videoStart < minVideoBytes) return null;
  return _Resolved('seft', t.videoStart, t.videoEnd);
}

bool _ftypAt(List<int> b, int pos) {
  if (pos < 0 || pos + 8 > b.length) return false;
  const ftyp = [0x66, 0x74, 0x79, 0x70]; // 'ftyp'(ISO-BMFF box 头,video[4..8))
  for (var i = 0; i < 4; i++) {
    if (b[pos + 4 + i] != ftyp[i]) return false;
  }
  return true;
}

MotionPhotoPlan _plan(_Resolved r, int fileSize) =>
    MotionPhotoPlan(r.format, r.videoStart, r.videoEnd, fileSize);

/// 全量字节版内核(单测用;下载侧自校验须用定点读版,禁全量回读产物,§5.1)
MotionPhotoSplit? probeMotionPhoto(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  final head = bytes.sublist(0, min(bytes.length, xmpHeadWindow));
  final xmp = extractMotionXmp(head);
  _Resolved? hit;
  if (xmp != null) {
    final tail = bytes.sublist(max(0, bytes.length - seftTailWindow));
    final r = _xmpTrackRange(tail, xmp, bytes.length);
    if (r != null && _ftypAt(bytes, r.videoStart)) hit = r; // 守卫⑥
  }
  if (hit == null) {
    // 两级探测②:XMP 未命中(无 XMP/守卫败)才进纯 SEFT 兜底
    final r = _seftTrackRange(bytes);
    if (r != null && _ftypAt(bytes, r.videoStart)) hit = r; // 守卫⑥(D9 强特征)
  }
  if (hit == null) return null;
  return MotionPhotoSplit(
    bytes.sublist(0, hit.videoStart),
    bytes.sublist(hit.videoStart, hit.videoEnd),
    hit.format,
  );
}

/// 文件版(生产入口):三读预筛(头 256KB + 尾 64KB + videoStart 定点 8 字节),
/// 自身零全量读;「readAsBytes 全量读+守卫重验+拆分」属 worker/compute isolate 职责。
Future<MotionPhotoPlan?> probeMotionPhotoFile(String path) async {
  final file = File(path);
  final fileSize = await file.length();
  if (fileSize < 4) return null;
  final raf = await file.open();
  try {
    final head = await raf.read(min(fileSize, xmpHeadWindow));
    if (head.length < 4 || head[0] != 0xFF || head[1] != 0xD8) return null;
    final tailLen = min(fileSize, seftTailWindow);
    final tailStart = fileSize - tailLen;
    final List<int> tail;
    if (fileSize <= head.length) {
      tail = head.sublist(head.length - tailLen); // 头读已覆盖整个文件:零二次读
    } else {
      await raf.setPosition(tailStart);
      tail = await raf.read(tailLen);
    }
    // 两级探测①:XMP 轨(命中即按尾部 trailer 修正)
    final xmp = extractMotionXmp(head);
    if (xmp != null) {
      final r = _xmpTrackRange(tail, xmp, fileSize);
      if (r != null && await _ftypAtRaf(raf, r.videoStart)) {
        return _plan(r, fileSize);
      }
    }
    // 两级探测②:XMP 未命中(无 XMP/守卫败)且尾窗有签名 → 纯 SEFT 分支(P1)
    final t = parseSeftTrailer(tail, tailStart);
    if (t != null &&
        t.videoEnd - t.videoStart >= minVideoBytes &&
        await _ftypAtRaf(raf, t.videoStart)) {
      return _plan(_Resolved('seft', t.videoStart, t.videoEnd), fileSize);
    }
    return null; // 两级探测③:都未命中 → null 普通轨
  } finally {
    await raf.close();
  }
}

Future<bool> _ftypAtRaf(RandomAccessFile raf, int pos) async {
  await raf.setPosition(pos);
  return _ftypAt(await raf.read(8), 0);
}

/// 生产入口:任何 IO/解析异常 → null 落普通轨(§5.3)
Future<MotionPhotoPlan?> probeMotionPhotoFileGuarded(String path) async {
  try {
    return await probeMotionPhotoFile(path);
  } catch (_) {
    // 降级普通轨:probe 失败不能阻塞上传/下载主链路
    return null;
  }
}
