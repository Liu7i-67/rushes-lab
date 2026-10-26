/// ThumbDiskStore — 缩略图位图磁盘缓存(app-polish-3 包 B1;storm-fix W1 #7/#9
/// 增量代际与调试闸):按 assetId 落盘 `<getApplicationCacheDirectory()>/thumbs`,
/// presigned URL ~25min 轮换/冷启动/二次进入均本地秒出,不再整图重下。
///
/// 容量上限 150MB,按文件 mtime 升序 LRU 淘汰(init 与每次写后触发);
/// 登出/401 由 main.dart 经会话清空钩子整体 clear(缩略图含用户素材)。
/// **代际(W1 #9 写死)**:write/remove/clear 共用内部互斥串行;clear() 第一行
/// 同步自增代数再入队异步删除,删除期间 _clearing=true 使 read 一律回 null
/// (防读到旧代文件);write 在 rename 前校验代数,失配只放弃(删唯一 tmp,
/// 绝不删目标文件);remove 带代数防旧会话迟到 remove 误删新会话写入。
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

  /// 磁盘代数(clear 第一行同步自增;调用方在 read 前捕获、write/remove 透传)。
  int _generation = 0;
  int get generation => _generation;

  /// clear 异步删除期间置位:期间 read 一律回 null(防读到旧代文件)。
  bool _clearing = false;

  /// write/remove/clear 共用互斥链(串行化,消除写/清竞态)。
  Future<void> _mutex = Future<void>.value();

  /// T14 注入慢写窗口(置 null 清除;单例全局,用例间防挂起必须清)。
  Future<void> Function()? _writeGate;

  /// T13 注入慢读窗口(置 null 清除)。
  Future<void> Function()? _readGate;

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _mutex.then((_) => op());
    // 互斥链吞错续链:单个 op 失败不阻断后续 op
    _mutex = result.catchError((_) {});
    return result;
  }

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

  /// 读位图;清空期间/目录未就绪/文件缺失/任何 IO 异常回 null(走网络分支)。
  Future<Uint8List?> read(String assetId) async {
    if (_clearing) return null;
    final gate = _readGate;
    if (gate != null) await gate();
    final dir = _dir;
    if (dir == null || _clearing) return null;
    try {
      final f = File('${dir.path}/${_fileName(assetId)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 写位图:临时文件写入后 rename 原子替换(不产生半截文件);
  /// 互斥串行 + rename 前代数双校验(失配只删唯一 tmp 放弃,绝不删目标文件);
  /// 写后异步触发 LRU 清理;异常静默(磁盘满等不阻断 UI)。
  Future<void> write(
    String assetId,
    Uint8List bytes, {
    int? expectedGeneration,
  }) {
    return _enqueue(() async {
      final dir = _dir;
      if (dir == null) return;
      final genAtStart = _generation;
      final gate = _writeGate;
      if (gate != null) await gate(); // T14 慢写窗口(持有互斥,clear 排队其后)
      if (expectedGeneration != null && expectedGeneration != _generation) {
        return; // clear 已同步升代:本次写整体放弃(尚未产生 tmp)
      }
      try {
        final f = File('${dir.path}/${_fileName(assetId)}');
        final tmp = File(
          '${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await tmp.writeAsBytes(bytes, flush: true);
        if (genAtStart != _generation && expectedGeneration != null) {
          // rename 前校验代数,失配只放弃:删唯一 tmp,不 rename、绝不删目标
          try {
            await tmp.delete();
          } catch (_) {
            /* 静默 */
          }
          return;
        }
        await tmp.rename(f.path);
        await _evict();
      } catch (_) {
        /* 静默 */
      }
    });
  }

  /// 删除单文件(坏字节兜底 W1 #7/#25);纳入同一互斥 + 代数——防旧会话迟到
  /// remove 误删新会话写入;异常静默。
  Future<void> remove(String assetId, {int? expectedGeneration}) {
    return _enqueue(() async {
      final dir = _dir;
      if (dir == null) return;
      if (expectedGeneration != null && expectedGeneration != _generation) {
        return; // 跨代:不删(新会话可能已重写)
      }
      try {
        final f = File('${dir.path}/${_fileName(assetId)}');
        if (await f.exists()) await f.delete();
      } catch (_) {
        /* 静默 */
      }
    });
  }

  /// 清空目录下所有文件(登出/401 会话清空钩子);第一行同步自增代数 +
  /// 置 _clearing(期间 read 回 null),删除经互斥串行;异常静默。
  Future<void> clear() {
    _generation++;
    _clearing = true;
    return _enqueue(() async {
      try {
        final dir = _dir;
        if (dir != null) {
          await for (final e in dir.list(followLinks: false)) {
            if (e is File) {
              try {
                await e.delete();
              } catch (_) {
                /* 单个删除失败不影响其余 */
              }
            }
          }
        }
      } catch (_) {
        /* 静默 */
      } finally {
        _clearing = false;
      }
    });
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
        } catch (_) {
          /* 单个删除失败跳过 */
        }
      }
    } catch (_) {
      /* 列目录失败静默 */
    }
  }

  /// 文件名:assetId 仅保留 `[A-Za-z0-9_-]`,其余丢弃;清空后回退 hashCode
  /// 十六进制(保证非空可写)。内容即图片字节,扩展名固定 `.bin`。
  String _fileName(String assetId) {
    final name = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (name.isNotEmpty) return '$name.bin';
    return '${assetId.hashCode.toRadixString(16)}.bin';
  }

  /// 测试注入目录(生产走 [init];单测 LRU/落盘语义用临时目录;
  /// 传 null 恢复默认——T12 tearDown 重挂默认用,单例全局)。
  @visibleForTesting
  void debugAttachDirectory(Directory? dir) => _dir = dir;

  /// 测试注入慢写窗口(T14;传 null 清除,用例间防挂起)。
  @visibleForTesting
  void debugSetWriteGate(Future<void> Function()? gate) => _writeGate = gate;

  /// 测试注入慢读窗口(T13 read 在途 dispose 用例;传 null 清除)。
  @visibleForTesting
  void debugSetReadGate(Future<void> Function()? gate) => _readGate = gate;
}
