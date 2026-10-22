/// ThumbDiskStore — 缩略图位图磁盘缓存(app-polish-3 包 B1,可单测):
/// 按 assetId 落盘 `<getApplicationCacheDirectory()>/thumbs`,presigned URL
/// ~25min 轮换/冷启动/二次进入均本地秒出,不再整图重下(三段闪烁的根因级修复)。
///
/// 容量上限 150MB,按文件 mtime 升序 LRU 淘汰(init 与每次写后触发);
/// 登出/401 由 main.dart 经会话清空钩子整体 clear(缩略图含用户素材)。
/// **所有 IO 异常一律吞掉静默降级**:widget 测试环境 path_provider 无插件
/// 通道(MissingPluginException)时 read 回 null、写/清/初始化无操作,
/// 绝不向 UI 抛。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 容量上限 150MB(D3 定稿:覆盖数千格缩略图)。
const _kCapacityBytes = 150 * 1024 * 1024;

class ThumbDiskStore {
  ThumbDiskStore._();

  /// 全局单例(main.dart 挂会话清空钩子;ThumbnailImage 直接取用)。
  static final ThumbDiskStore I = ThumbDiskStore._();

  Directory? _dir;
  bool _initing = false;

  /// 幂等初始化:建目录 + 触发 LRU 清理;异常静默(测试环境无插件通道)。
  Future<void> init() async {
    if (_dir != null || _initing) return;
    _initing = true;
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/thumbs');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      await _evict();
    } catch (_) {
      _dir = null; // 降级:仅内存 URL 缓存 + 网络直取,行为同旧版
    } finally {
      _initing = false;
    }
  }

  /// 读位图;目录未就绪/文件缺失/任何 IO 异常回 null(走网络分支)。
  Future<Uint8List?> read(String assetId) async {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final f = File('${dir.path}/${_fileName(assetId)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 写位图:临时文件写入后 rename 原子替换(不产生半截文件);
  /// 写后异步触发 LRU 清理;异常静默(磁盘满等不阻断 UI)。
  Future<void> write(String assetId, Uint8List bytes) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final f = File('${dir.path}/${_fileName(assetId)}');
      final tmp =
          File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
      await _evict();
    } catch (_) {/* 静默 */}
  }

  /// 清空目录下所有文件(登出/401 会话清空钩子);异常静默。
  Future<void> clear() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {/* 单个删除失败不影响其余 */}
        }
      }
    } catch (_) {/* 静默 */}
  }

  /// 缓存总字节数(测试/诊断用;异常回 0)。
  Future<int> debugSizeBytes() async {
    final dir = _dir;
    if (dir == null) return 0;
    try {
      var total = 0;
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// LRU:总量超 [_kCapacityBytes] 时按 mtime 升序(最旧先删)逐出。
  Future<void> _evict() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final entries = <(File, DateTime, int)>[];
      var total = 0;
      for (final e in await dir.list(followLinks: false).toList()) {
        if (e is! File) continue;
        final st = await e.stat();
        entries.add((e, st.modified, st.size));
        total += st.size;
      }
      if (total <= _kCapacityBytes) return;
      entries.sort((a, b) => a.$2.compareTo(b.$2)); // 最旧在前
      for (final (f, _, size) in entries) {
        if (total <= _kCapacityBytes) break;
        try {
          await f.delete();
          total -= size;
        } catch (_) {/* 单个删除失败跳过 */}
      }
    } catch (_) {/* 列目录失败静默 */}
  }

  /// 文件名:assetId 仅保留 `[A-Za-z0-9_-]`,其余丢弃;清空后回退 hashCode
  /// 十六进制(保证非空可写)。内容即图片字节,扩展名固定 `.bin`。
  String _fileName(String assetId) {
    final name = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (name.isNotEmpty) return '$name.bin';
    return '${assetId.hashCode.toRadixString(16)}.bin';
  }

  /// 测试注入目录(生产走 [init];单测 LRU/落盘语义用临时目录)。
  @visibleForTesting
  void debugAttachDirectory(Directory dir) => _dir = dir;
}
