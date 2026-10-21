/// TransferStore — 传输队列快照持久化(mobile-ux-polish-2 R4c)。
///
/// 口径(需求文档 R4c / 决策 #2 #8):
/// - 快照=应用支持目录 `transfers.json`,字段精简(kind/filename/where/status/
///   error/进度/时间戳);**worker 闭包不入快照**——相册 AssetEntity 句柄、iOS
///   livp 小包临时轨、百度/文件选择器的临时路径等源信息不可序列化(会过期/跨
///   进程失效),恢复记录的「重试」降级为提示重新发起(见 TransferQueue.retry),
///   不做断点续传。
/// - 写入时机=入队/状态变化(队列侧去抖合并,高频进度回调不写盘,进度字段
///   只在状态变化点落当时值,收尾即终值)。
/// - 启动恢复=终态(done/failed/canceled)原样还原;非终态(queued/running)
///   标 failed(error=[kInterruptedError])——上次运行被杀,任务实际已中断。
/// - 坏 JSON 容错:解析失败返回 null,调用方按「空快照重来」处理,不崩溃。
/// - 存储打开失败(测试环境无插件通道等)整体静默降级为仅内存(与 AppLog/
///   Notifier 同款降级哲学)。
library;

import 'dart:async' show FutureOr;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../../services/app_log.dart';
import 'transfer_task.dart';

/// 快照文件名(应用支持目录下)。
const kTransfersSnapshotName = 'transfers.json';

/// 恢复时非终态任务的失败原因(需求文档口径「进程中断」)。
const kInterruptedError = '进程中断';

/// 快照任务数上限(防御:内存列表随用户使用只增不减,落盘截取最新 200 条;
/// 展示序=列表序 index 0 最新,截尾即丢最旧)。
const kMaxSnapshotTasks = 200;

/// 去抖窗口:状态高频翻转时合并为一次写盘(进度回调不写盘,不进此路径)。
const kPersistDebounce = Duration(milliseconds: 500);

/// 任务列表 → 快照 JSON(纯函数,单测钉字段)。列表序=展示序(index 0 最新),
/// 超 [kMaxSnapshotTasks] 截尾(丢最旧)。
String encodeTasks(List<TransferTask> tasks) {
  final rows = tasks.take(kMaxSnapshotTasks).map((t) => <String, Object?>{
        'id': t.id,
        'kind': t.kind.name,
        'filename': t.filename,
        'where': t.where,
        'totalBytes': t.totalBytes,
        'doneBytes': t.doneBytes,
        'status': t.status.name,
        if (t.error != null) 'error': t.error,
        'startedAt': t.startedAt.toIso8601String(),
      }).toList();
  return jsonEncode(rows);
}

/// 快照 JSON → 恢复任务列表(纯函数):终态原样还原;非终态标 failed
/// 「进程中断」;坏 JSON/条目残缺 → null(调用方按空快照重来,不崩溃)。
List<TransferTask>? decodeTasks(String raw) {
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    final restored = <TransferTask>[];
    for (final item in list) {
      final map = item as Map<String, dynamic>;
      final status = TransferStatus.values.byName(map['status'] as String);
      final task = TransferTask(
        id: map['id'] as String,
        kind: TransferKind.values.byName(map['kind'] as String),
        filename: map['filename'] as String,
        where: map['where'] as String? ?? '',
        totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
        doneBytes: (map['doneBytes'] as num?)?.toInt() ?? 0,
        status: status,
        error: map['error'] as String?,
        startedAt:
            DateTime.tryParse(map['startedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );
      if (!status.isTerminal) {
        task
          ..status = TransferStatus.failed
          ..error = kInterruptedError;
      }
      restored.add(task);
    }
    return restored;
  } catch (e) {
    AppLog.error('transfer', '传输快照解析失败,按空快照恢复', e);
    return null;
  }
}

/// 快照存储:[read]/[write] 可注入(单测零真实 IO;write 收 FutureOr——同步
/// 闭包如 `list.add` 亦可作捕获桩);缺省走真实文件系统。
class TransferStore {
  /// 测试注入:文本读写件(null=真实文件系统,应用支持目录 transfers.json)。
  @visibleForTesting
  TransferStore(
      {Future<String?> Function()? read, FutureOr<void> Function(String)? write}) {
    _read = read;
    _write = write;
  }

  Future<String?> Function()? _read;
  FutureOr<void> Function(String)? _write;

  /// 真实存储(应用支持目录);打开失败(无插件通道等)返回 null → 队列整体
  /// 降级仅内存,不留半可用实例。
  static Future<TransferStore?> openDefault() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$kTransfersSnapshotName');
      return TransferStore(
        read: () async => await file.exists() ? await file.readAsString() : null,
        write: (content) async => file.writeAsString(content, flush: true),
      );
    } catch (e) {
      AppLog.error('transfer', '传输快照存储打开失败,降级仅内存', e);
      return null;
    }
  }

  /// 读快照原文;文件不存在 → null(首次启动,非错误)。
  Future<String?> read() async {
    final r = _read;
    if (r != null) return r();
    return null; // 未注入读写件的真实实例不会出现(openDefault 恒注入)
  }

  /// 写快照;失败由调用方记日志(写盘失败不阻断队列状态机)。
  Future<void> write(String content) async {
    final w = _write;
    if (w != null) await w(content);
  }
}
