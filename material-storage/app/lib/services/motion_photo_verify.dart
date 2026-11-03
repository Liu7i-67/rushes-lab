/// Motion Photo 下载侧定点读自校验 + 字节级定点读内核(安卓实况图适配,
/// 方案 §5.4 步骤 4b 拆件——motion_photo_save.dart 超 300 行硬顶,按
/// 编排/自校验 拆件,§5.4 步骤号即拆分边界)。
///
/// flm 合成产物入相册前的**输出自校验**(flm §3.2 缺陷 1:对整张主图搜首个
/// `ftyp`,高熵 JPEG 数据随机命中会静默产出截断损坏文件且不抛异常)的唯一
/// 兜底。三段定点读校验(**禁全量回读产物**,主 isolate 零大对象,见
/// [verifyMotionPhotoProduct]):
/// ① XMP 命中——复用包 A motion_photo.dart 的 `extractMotionXmp` 同一内核
///    (marker 搜索+元素域提取+双标记互验一致取 gcontainer,口径零漂移);
/// ② `video 长度 == 输入 mp4 长度` 且 `首 8 字节 == 输入 mp4 首 8 字节`
///    (ftyp box;残留 XMP 长度失配形态由此拦下);
/// ③ **image 半段完整性 = 确定性尾段比对:`输出 image 段尾 32B == 输入主图
///    尾 32B`**——ftyp 误命中场景损坏只体现在 image 半段(video 尾与 XMP
///    长度对该场景恒自洽,只查 video 侧零判别力);弃 EOI 容忍窗口径,防
///    厂商 padding(Item:Padding/扇区对齐)系统性误拒。
/// 任一不过 = 合成产物可疑 → 调用方不落盘、走 D1。
library;

import 'dart:io';

import 'motion_photo.dart' show extractMotionXmp, minVideoBytes, xmpHeadWindow;

/// 三段定点读自校验(纯判定,不落盘;[imageTail]/[videoHead] 为**输入侧**
/// 主图尾段/视频头段,由编排层在合成前定点读出;[videoLength] 为输入 mp4
/// 长度;产物无 trailer,videoEnd=文件尾)。任何 IO/解析异常 → false
/// (fail-safe,走 D1)。
Future<bool> verifyMotionPhotoProduct(
  File product, {
  required List<int> imageTail,
  required List<int> videoHead,
  required int videoLength,
}) async {
  try {
    final size = await product.length();
    if (size <= 0) return false;
    // ① 头 256KB XMP 段(产物 XMP 必在头部;包 A 同一解析内核)
    final windowEnd = size < xmpHeadWindow ? size : xmpHeadWindow;
    final xmp = extractMotionXmp(await readFileRange(product, 0, windowEnd));
    if (xmp == null) return false;
    final n = xmp.videoBytes;
    if (n < minVideoBytes) return false; // 守卫:防 XMP 残留小值误判
    final videoStart = size - n;
    if (videoStart <= xmp.xmpEnd || videoStart >= size) return false; // 区间
    // ② video 长度与 ftyp 头比对
    if (videoLength != n) return false;
    final vHead = await readFileRange(product, videoStart, videoStart + 8);
    if (!bytesEqual(vHead, videoHead)) return false;
    // ③ image 段尾确定性比对(误命中截断点在图中间 → 输出尾段≠输入尾段)
    final iTail = await readFileRange(
      product,
      videoStart - imageTail.length,
      videoStart,
    );
    return bytesEqual(iTail, imageTail);
  } catch (_) {
    return false;
  }
}

// ── 字节级定点读内核(编排层输入侧快路径门同用,全链禁全量回读)────────

/// 定点读 [start, end)(越界夹取;空区间返回空表)。
Future<List<int>> readFileRange(File f, int start, int end) async {
  final len = await f.length();
  final s = start < 0 ? 0 : (start > len ? len : start);
  final e = end < s ? s : (end > len ? len : end);
  if (e <= s) return const <int>[];
  final raf = await f.open();
  try {
    await raf.setPosition(s);
    return await raf.read(e - s);
  } finally {
    await raf.close();
  }
}

/// 文件头 n 字节。
Future<List<int>> fileHeadBytes(File f, int n) => readFileRange(f, 0, n);

/// 文件尾 n 字节(不足 n 全返)。
Future<List<int>> fileTailBytes(File f, int n) async {
  final len = await f.length();
  return readFileRange(f, len - n, len);
}

/// JPEG SOI 快路径门(外部异构 livp 的改名 HEIC 条目防):头 2 字节 FF D8。
Future<bool> hasJpegSoi(File f) async {
  final h = await fileHeadBytes(f, 2);
  return h.length == 2 && h[0] == 0xFF && h[1] == 0xD8;
}

/// MP4 ftyp box 头强特征(§5.1 守卫 5 同口径):头 8 字节的 [4..8)=='ftyp'
/// (微信/截图剥视频残留 XMP、假 mp4 条目由此挡住)。
Future<bool> hasMp4FtypHeader(File f) async {
  final h = await fileHeadBytes(f, 8);
  return h.length == 8 &&
      h[4] == 0x66 &&
      h[5] == 0x74 &&
      h[6] == 0x79 &&
      h[7] == 0x70;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 幂等静默删除(下载链产物均在 app cache/系统临时目录,失败无害——系统可
/// 回收;D1 收尾/成功清理/取消补删共用)。
Future<void> deleteQuietly(FileSystemEntity e) async {
  try {
    if (await e.exists()) await e.delete(recursive: true);
  } catch (_) {}
}
