/// ThumbDiskStore — 缩略图位图磁盘缓存(app-polish-3 包 B1;storm-fix W1 #7/#9
/// 增量代际与调试闸;thumb-variant 批 A1 加 variant 维度):按 assetId+变体
/// 落盘 `<getApplicationCacheDirectory()>/thumbs_v2/<净化id>.<diskTag>.bin`
/// (lg=1024 large / s=240 small;v2 与旧 `thumbs/` 同级,禁止嵌套)。
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

import 'thumb_variant.dart';

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

  /// clear 删除期间置位:期间 read 一律回 null(防读到旧代文件)。
  bool _clearing = false;

  /// T14 注入慢写窗口(置 null 清除;单例全局,用例间防挂起必须清)。
  Future<void> Function()? _writeGate;

  /// T13 注入慢读窗口(置 null 清除)。
  Future<void> Function()? _readGate;

  /// 幂等初始化:建 v2 目录 + 文件级清空旧 `thumbs/` 内 *.bin(一次性迁移,
  /// 非递归、不删旧目录本身)+ 触发 LRU 清理;异常静默(测试环境无插件通道)。
  Future<void> init() async {
    if (_dir != null || _initing) return;
    _initing = true;
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/thumbs_v2');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      await _clearLegacyThumbs(base);
      await _evict();
    } catch (_) {
      _dir = null; // 降级:仅内存 URL 缓存 + 网络直取,行为同旧版
    } finally {
      _initing = false;
    }
  }

  /// 一次性迁移(v2 上线):文件级删除旧 `thumbs/` 目录内的 `*.bin`
  /// (沿用 [clear] 的 listSync 逐文件删除模式,非递归、不删目录本身);
  /// 独立 try/catch:清旧失败不影响 v2 正常初始化。旧目录清空后后续 init
  /// 仅剩一次 exists() 探测,成本可忽略。
  Future<void> _clearLegacyThumbs(Directory base) async {
    try {
      final legacy = Directory('${base.path}/thumbs');
      if (!await legacy.exists()) return;
      final files = legacy.listSync(followLinks: false).whereType<File>();
      for (final f in files) {
        if (!f.path.endsWith('.bin')) continue;
        try {
          f.deleteSync();
        } catch (_) {
          /* 单个删除失败不影响其余 */
        }
      }
    } catch (_) {
      /* 旧目录遍历失败静默 */
    }
  }

  /// 读位图([variant] 维度:large/small 各自独立文件);清空期间/目录未就绪/
  /// 文件缺失/任何 IO 异常回 null(走网络分支)。
  /// 同步 IO(existsSync/readAsBytesSync):缩略图为百 KB 级小文件,同步读
  /// 亚毫秒;真实异步 IO 的 completion 在 widget 测试的 fakeAsync zone 内
  /// 永不派发(宫格/预览的磁盘优先路径会整体挂死),同步化同时根治可测性。
  Future<Uint8List?> read(
    String assetId, {
    ThumbVariant variant = ThumbVariant.large,
  }) async {
    if (_clearing) return null;
    final gate = _readGate;
    if (gate != null) await gate();
    final dir = _dir;
    if (dir == null || _clearing) return null;
    try {
      final f = File('${dir.path}/${_fileName(assetId, variant)}');
      if (!f.existsSync()) return null;
      return f.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  /// 写位图:临时文件写入后 rename 原子替换(不产生半截文件);
  /// rename 前代数双校验(失配只删唯一 tmp 放弃,绝不删目标文件);
  /// 写后异步触发 LRU 清理;异常静默(磁盘满等不阻断 UI)。
  /// IO 全同步(read 同因:异步 IO 在 widget 测试 fakeAsync zone 挂死;
  /// 缩略图百 KB 级同步亚毫秒);**不经 _enqueue 微任务链**——fire-and-forget
  /// 的 then 链在 fakeAsync 嵌套 zone 下不被 pump flush,同步段在 UI isolate
  /// 天然串行,跨代由代数校验兜住;[debugSetWriteGate] 仅测试注入慢写窗口。
  Future<void> write(
    String assetId,
    Uint8List bytes, {
    int? expectedGeneration,
    ThumbVariant variant = ThumbVariant.large,
  }) async {
    final dir = _dir;
    if (dir == null) return;
    final genAtStart = _generation;
    final gate = _writeGate;
    if (gate != null) await gate(); // T14 慢写窗口(仅测试注入)
    if (expectedGeneration != null && expectedGeneration != _generation) {
      return; // clear 已同步升代:本次写整体放弃(尚未产生 tmp)
    }
    try {
      final f = File('${dir.path}/${_fileName(assetId, variant)}');
      final tmp = File(
        '${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      tmp.writeAsBytesSync(bytes, flush: true);
      if (genAtStart != _generation && expectedGeneration != null) {
        // rename 前校验代数,失配只放弃:删唯一 tmp,不 rename、绝不删目标
        try {
          tmp.deleteSync();
        } catch (_) {
          /* 静默 */
        }
        return;
      }
      tmp.renameSync(f.path);
      // LRU 清理不阻塞写路径:真机异步执行;其异步 IO 在 fakeAsync 下挂起
      // 无人等待、无害(容量清理的回归验证由 thumb_disk_store_test 承担)
      _evict().ignore();
    } catch (_) {
      /* 静默 */
    }
  }

  /// 删除单文件(坏字节兜底 W1 #7/#25);纳入同一互斥 + 代数——防旧会话迟到
  /// remove 误删新会话写入;异常静默。
  Future<void> remove(
    String assetId, {
    int? expectedGeneration,
    ThumbVariant variant = ThumbVariant.large,
  }) async {
    final dir = _dir;
    if (dir == null) return;
    if (expectedGeneration != null && expectedGeneration != _generation) {
      return; // 跨代:不删(新会话可能已重写)
    }
    try {
      final f = File('${dir.path}/${_fileName(assetId, variant)}');
      // 同步 IO(与 read/write 同因:fakeAsync 下异步 IO 挂死;
      // 同 remove 不经 _enqueue——见 write 注释)
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      /* 静默 */
    }
  }

  /// 清空目录下所有文件(登出/401 会话清空钩子);第一行同步自增代数 +
  /// 置 _clearing(期间 read 回 null);目录遍历删除为真实异步 IO(fakeAsync
  /// 下挂起无人等待、无害;真机正常),异常静默。
  Future<void> clear() async {
    _generation++;
    _clearing = true;
    try {
      final dir = _dir;
      if (dir != null) {
        final files = dir.listSync(followLinks: false).whereType<File>();
        for (final f in files) {
          try {
            f.deleteSync();
          } catch (_) {
            /* 单个删除失败不影响其余 */
          }
        }
      }
    } catch (_) {
      /* 静默 */
    } finally {
      _clearing = false;
    }
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
  /// 十六进制(保证非空可写)。内容即图片字节,按 variant 加磁盘标签后固定
  /// `.bin`:`<name>.lg.bin`(large)/ `<name>.s.bin`(small)。
  String _fileName(String assetId, ThumbVariant variant) {
    final name = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final tag = variant.diskTag;
    if (name.isNotEmpty) return '$name.$tag.bin';
    return '${assetId.hashCode.toRadixString(16)}.$tag.bin';
  }

  /// 测试注入目录(生产走 [init];单测 LRU/落盘语义用临时目录;
  /// 传 null 恢复默认——T12 tearDown 重挂默认用,单例全局)。
  @visibleForTesting
  void debugAttachDirectory(Directory? dir) => _dir = dir;

  /// 测试专用同步探测:该 assetId+variant 的缓存文件是否已落盘(fire-and-forget
  /// 写链在 fakeAsync 下只能靠 tester.pump 推进,runAsync 真实时间推不动微任务)。
  @visibleForTesting
  bool debugHas(String assetId, {ThumbVariant variant = ThumbVariant.large}) {
    final dir = _dir;
    if (dir == null) return false;
    return File('${dir.path}/${_fileName(assetId, variant)}').existsSync();
  }

  /// 测试注入慢写窗口(T14;传 null 清除,用例间防挂起)。
  @visibleForTesting
  void debugSetWriteGate(Future<void> Function()? gate) => _writeGate = gate;

  /// 测试注入慢读窗口(T13 read 在途 dispose 用例;传 null 清除)。
  @visibleForTesting
  void debugSetReadGate(Future<void> Function()? gate) => _readGate = gate;
}
