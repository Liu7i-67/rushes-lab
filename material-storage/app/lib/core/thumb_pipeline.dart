/// ThumbPipeline — 缩略图字节任务全局并发闸(app-thumbnail-storm-fix W1;
/// thumb-variant 批 A1 去重键加 variant 维度):
/// 进程级单实例 [thumbPipeline],上限 6、FIFO;同 assetId+variant 订阅去重
/// (键 `'$assetId:${variant.diskTag}'`;排队态与运行态均共享同一次执行,任务
/// 任一终态立即出表);订阅句柄式取消(最后订阅者离开即终止任务:排队撤销/
/// 运行按 D7 分阶段 abort+短路);任务硬超时 20s(自开始执行起算,排队不计时);
/// 管线级 swallow(终态后 job 迟到异常一律吞掉,防未处理异步异常弹报错页架空
/// D2);代际 clear(先终止运行任务再清表)。
///
/// Timer 纪律:唯一 Timer 是 deadline watchdog,任务任一终态在调用栈内同步
/// 取消(禁事件队列延迟);调度/短路全走 Future/microtask。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/app_log.dart';
import 'thumb_variant.dart';

/// 任务被取消/超时后 job 短路用的标记异常(管线保证吞掉,不向 UI 传播)。
class ThumbCancelled implements Exception {
  ThumbCancelled(this.message);

  final String message;

  @override
  String toString() => 'ThumbCancelled: $message';
}

/// 任务上下文:job 在每个 await 后、发起下一个请求前查 [isCancelled] 短路;
/// [registerAbort] 多次注册按序保留(响应头前 `req.abort()`;`resp.listen` 后
/// `subscription.cancel()` 等),任务已终态后才注册的立即触发。
class ThumbTaskContext {
  bool _cancelled = false;
  final _aborts = <void Function()>[];

  bool get isCancelled => _cancelled;

  void registerAbort(void Function() abort) {
    if (_cancelled) {
      // 晚注册立即触发(D7:getUrl 返回后才发现已取消 → 立即 abort 防占池连接)
      _runAbort(abort);
      return;
    }
    _aborts.add(abort);
  }

  void _markCancelled() => _cancelled = true;

  void _abortAll() {
    for (final a in List.of(_aborts)) {
      _runAbort(a);
    }
    _aborts.clear();
  }

  static void _runAbort(void Function() abort) {
    try {
      abort();
    } catch (e) {
      // abort 回调自身异常必须吞掉(D2)
      AppLog.error('thumb-pipeline', 'abort 回调异常(已吞)', e);
    }
  }
}

/// 订阅句柄:[future] 超时/异常向上抛(调用方 catch 置降级),cancel/终止以
/// null 完成;[cancel] 幂等,最后一个订阅者离开 → 终止任务。
class ThumbHandle {
  ThumbHandle._(this._cancelSub, this._future);

  final void Function() _cancelSub;
  final Future<Uint8List?> _future;

  Future<Uint8List?> get future => _future;

  void cancel() => _cancelSub();
}

class _Sub {
  final completer = Completer<Uint8List?>();
  bool done = false;
}

class _Task {
  _Task(this.pipeline, this.assetId, this.variant, this.job, this.generation);

  final ThumbPipeline pipeline;
  final String assetId;

  /// 规格变体(去重维度之一:同 assetId 的 large/small 是两个独立任务)。
  final ThumbVariant variant;

  /// 去重表键:`'$assetId:${variant.diskTag}'`(日志仍用纯 [assetId] 便于定位)。
  String get key => '$assetId:${variant.diskTag}';

  final Future<Uint8List?> Function(ThumbTaskContext ctx) job;
  final int generation;

  final ctx = ThumbTaskContext();
  final subs = <_Sub>{};
  Timer? watchdog;
  bool terminal = false;
  bool slotHeld = false;
}

/// 全局管线实例(并发 6 / 任务硬超时 20s,W1 定稿)。
final thumbPipeline = ThumbPipeline(
  concurrency: 6,
  taskDeadline: Duration(seconds: 20),
);

class ThumbPipeline {
  ThumbPipeline({
    this.concurrency = 6,
    this.taskDeadline = const Duration(seconds: 20),
  });

  final int concurrency;
  final Duration taskDeadline;

  final _queue = <_Task>[];
  final _running = <_Task>{};
  final _dedup = <String, _Task>{};
  int _active = 0;
  int _generation = 0;

  /// 运行中任务数(占并发名额;T1/T3④ 名额回归断言用)。
  @visibleForTesting
  int get debugActiveCount => _active;

  /// 排队中任务数(T2 FIFO 断言辅助)。
  @visibleForTesting
  int get debugQueuedCount => _queue.length;

  @visibleForTesting
  int get generation => _generation;

  /// 提交任务:同 assetId+variant 未终态任务自动共享(每订阅者独立句柄)。
  ThumbHandle submit(
    String assetId,
    Future<Uint8List?> Function(ThumbTaskContext ctx) job, {
    ThumbVariant variant = ThumbVariant.large,
  }) {
    final key = '$assetId:${variant.diskTag}';
    final existing = _dedup[key];
    if (existing != null) return _subscribe(existing);
    final task = _Task(this, assetId, variant, job, _generation);
    _dedup[key] = task;
    _queue.add(task);
    _pump();
    return _subscribe(task);
  }

  /// 会话清空(W1 #6 写死):① 终止全部运行任务(置标记+按序 abort+句柄 null
  /// 完成+取消 watchdog);② 同步撤销全部队列(句柄同样 null 完成)、清运行
  /// 集合/去重表/计数;③ 代数自增——旧任务 late 完成对旧代一律 no-op。
  void clear() {
    _generation++;
    for (final t in _running.toList()) {
      t.terminal = true;
      t.ctx._markCancelled();
      _cancelWatchdog(t);
      t.ctx._abortAll();
      for (final s in t.subs) {
        if (!s.completer.isCompleted) s.completer.complete(null);
        s.done = true;
      }
      t.subs.clear();
      t.slotHeld = false;
    }
    for (final t in _queue) {
      t.terminal = true;
      t.ctx._markCancelled();
      for (final s in t.subs) {
        if (!s.completer.isCompleted) s.completer.complete(null);
        s.done = true;
      }
      t.subs.clear();
    }
    _queue.clear();
    _running.clear();
    _active = 0;
    _dedup.clear();
  }

  /// 测试隔离(全局 tearDown 用):clear + 代数归零。
  @visibleForTesting
  void reset() {
    clear();
    _generation = 0;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  ThumbHandle _subscribe(_Task t) {
    final sub = _Sub();
    t.subs.add(sub);
    void cancelSub() {
      if (sub.done) return; // cancel 幂等;终态后再 cancel 无操作
      sub.done = true;
      t.subs.remove(sub);
      if (!sub.completer.isCompleted) sub.completer.complete(null);
      if (t.subs.isEmpty && !t.terminal) {
        _terminate(t, timeout: false); // 最后订阅者离开 → 终止
      }
    }

    return ThumbHandle._(cancelSub, sub.completer.future);
  }

  void _pump() {
    while (_active < concurrency && _queue.isNotEmpty) {
      final t = _queue.removeAt(0);
      if (t.terminal) continue; // 排队态已被撤销(最后订阅者 cancel),job 不执行
      _running.add(t);
      _start(t);
    }
  }

  void _start(_Task t) {
    t.slotHeld = true;
    _active++;
    t.watchdog = Timer(taskDeadline, () => _terminate(t, timeout: true));
    // 终态处理即挂(submit 时):job 迟到异常一律在此吞掉(W1 #5)
    Future<Uint8List?> root;
    try {
      root = t.job(t.ctx);
    } catch (e, st) {
      AppLog.error('thumb-pipeline', 'job 同步异常(${t.assetId})', e);
      root = Future<Uint8List?>.error(e, st);
    }
    root.then(
      (v) => _onJobValue(t, v),
      onError: (Object e, StackTrace st) => _onJobError(t, e, st),
    );
  }

  /// 任务终止(cancel 最后订阅者 / deadline / 内部复用):timeout=true 时订阅者
  /// 以超时异常终态,否则(取消)以 null 完成。
  void _terminate(_Task t, {required bool timeout}) {
    if (t.terminal) return; // deadline 与 cancel 竞态以先到者为准
    t.terminal = true;
    t.ctx._markCancelled(); // 先置位再 abort:job 下一 await 边界即短路
    _cancelWatchdog(t);
    t.ctx._abortAll();
    for (final s in t.subs) {
      if (s.completer.isCompleted) continue;
      if (timeout) {
        s.completer.completeError(
          TimeoutException('缩略图任务超时(${t.assetId})', t.pipeline.taskDeadline),
        );
      } else {
        s.completer.complete(null);
      }
    }
    t.subs.clear();
    _release(t);
    if (identical(_dedup[t.key], t)) _dedup.remove(t.key);
    _running.remove(t);
  }

  void _onJobValue(_Task t, Uint8List? v) {
    if (t.generation != _generation) return; // 旧代僵尸 job:late 完成一律 no-op
    if (t.terminal) return; // 已被 cancel/超时清算(名额已释放,防双释放)
    t.terminal = true;
    _cancelWatchdog(t);
    for (final s in t.subs) {
      if (!s.completer.isCompleted) s.completer.complete(v);
    }
    t.subs.clear();
    _release(t);
    if (identical(_dedup[t.key], t)) _dedup.remove(t.key);
    _running.remove(t);
  }

  void _onJobError(_Task t, Object e, StackTrace st) {
    if (t.generation != _generation) {
      // 终态/clear 后 job 迟到抛出的异常:管线内吞掉 + AppLog 留痕(W1 #5/D2)
      AppLog.error('thumb-pipeline', 'job 迟到异常已吞(${t.assetId})', e);
      return;
    }
    if (t.terminal) {
      AppLog.error('thumb-pipeline', 'job 迟到异常已吞(${t.assetId})', e);
      return;
    }
    t.terminal = true;
    _cancelWatchdog(t);
    for (final s in t.subs) {
      if (!s.completer.isCompleted) s.completer.completeError(e, st);
    }
    t.subs.clear();
    _release(t);
    if (identical(_dedup[t.key], t)) _dedup.remove(t.key);
    _running.remove(t);
  }

  /// 名额释放全路径幂等(releaseOnce):每任务 [slotHeld] 一次性令牌,旧代 late
  /// 清算 no-op——cancel/deadline 立即释放与 job 迟到 finally 只生效首次。
  void _release(_Task t) {
    if (!t.slotHeld) return;
    if (t.generation != _generation) return;
    t.slotHeld = false;
    if (_active > 0) _active--;
    _pump();
  }

  void _cancelWatchdog(_Task t) {
    t.watchdog?.cancel();
    t.watchdog = null;
  }
}
