/// ThumbSignGate — 缩略图签名并发闸独立件(app-thumbnail-storm-fix W2 #11;
/// thumb-variant 批 A1 注册表键加 variant 维度):
/// 上限 6 FIFO;内部结构写死「sign job(根 future)+ waiter completer」两层,
/// waiter 显式三态 queued/running/abandoned;**race 计时器每 waiter 一个**
/// (20s,进入 running 态起算):waiter abandon/超时取消自身计时器,根 future
/// 终态取消该 job 全部剩余计时器;槽释放全路径幂等(slotHeld/releaseOnce 携
/// 代数),四类释放点(signer 成功/失败、race 放槽、abandonAwait 最后 waiter
/// 还槽、clear 归零)统一走它。被放弃 waiter 以取消异常完成(底层 signer 继续跑,
/// 落缓存供下次复用);全部 waiter 已放弃后根 future 迟到失败一律 swallow +
/// AppLog 留痕(防未处理异步异常经 onSystemError 弹报错页架空 D2)。
///
/// **键维度**:注册表 `_jobs` 以 `'$assetId:${variant.diskTag}'` 为键
/// ([_Job.key])——同 assetId 的 large/small 签名互不串闸;日志仍打纯 assetId。
///
/// Timer 纪律:唯一 Timer 是 per-waiter race 计时器,随 waiter 放弃/超时、根
/// 终态、clear 在调用栈内同步取消。
library;

import 'dart:async';

import '../services/app_log.dart';
import 'thumb_variant.dart';

/// waiter 被放弃(abandonAwait/clear)时收到的取消异常。
class ThumbSignAbandoned implements Exception {
  const ThumbSignAbandoned();

  @override
  String toString() => 'ThumbSignAbandoned: 签名等待已被放弃';
}

enum _WaiterState { queued, running, abandoned }

class _Waiter<T> {
  final completer = Completer<T>();
  Timer? race;
  _WaiterState state = _WaiterState.queued;
}

class _Job<T> implements SignJob<T> {
  _Job(this.assetId, this.variant, this.generation, this.run, this.onSettled);

  @override
  final String assetId;

  /// 规格变体(注册表键维度:同 assetId 的 large/small 各自独立 job)。
  final ThumbVariant variant;

  /// 注册表键:`'$assetId:${variant.diskTag}'`(_jobs 以此为键防互串)。
  String get key => '$assetId:${variant.diskTag}';

  @override
  final int generation;
  final Future<T> Function() run;
  final void Function()? onSettled;

  final waiters = <_Waiter<T>>[];
  bool started = false;
  bool slotHeld = false;
  bool _settled = false;

  @override
  bool get settled => _settled;

  Iterable<_Waiter<T>> activeWaiters() =>
      waiters.where((w) => w.state != _WaiterState.abandoned);
}

/// 闸内 sign job 句柄(ThumbnailCache._inflight 持有,按 settled/代数过滤旧条目)。
abstract class SignJob<T> {
  String get assetId;
  int get generation;

  /// 根 future 已终态(成功/失败)或 job 已被整体撤销/清出——不可再 join。
  bool get settled;
}

class ThumbSignGate<T> {
  ThumbSignGate({
    this.limit = 6,
    this.raceTimeout = const Duration(seconds: 20),
  });

  final int limit;
  final Duration raceTimeout;

  int _generation = 0;
  int _active = 0;
  final _jobs = <String, _Job<T>>{};
  final _fifo = <_Job<T>>[];

  int get generation => _generation;

  /// 占闸槽数(T6 闸上限/幂等断言用;生产勿消费)。
  int get activeCount => _active;

  /// 排队中 job 数(T6 排队态放弃断言用;生产勿消费)。
  int get queuedCount => _fifo.length;

  /// 在册 job 数(含放槽悬挂;诊断用)。
  int get pendingJobCount => _jobs.length;

  /// 新建 sign job 并入 FIFO(不立即占槽,首个 waiter 注册时才 _pump)。
  /// [onSettled] 根终态/job 撤销时回调一次(cache 用于按身份清 _inflight)。
  SignJob<T> open(
    String assetId,
    Future<T> Function() run, {
    ThumbVariant variant = ThumbVariant.large,
    void Function()? onSettled,
  }) {
    final job = _Job<T>(assetId, variant, _generation, run, onSettled);
    _jobs[job.key] = job;
    _fifo.add(job);
    return job;
  }

  void abandon(
    String assetId, {
    ThumbVariant variant = ThumbVariant.large,
    int? generation,
  }) {
    if (generation != null && generation != _generation) {
      return; // clear 后旧代 late 注册的 abandon 一律 no-op
    }
    final key = '$assetId:${variant.diskTag}';
    final job = _jobs[key];
    if (job == null || job.settled) return;
    final active = job.activeWaiters().toList();
    if (active.isEmpty) return; // waiter 已成功完成/出表:no-op
    // 被放弃的 waiter 无论何种状态总是先移除并以取消异常完成
    for (final w in active) {
      _cancelRace(w);
      w.state = _WaiterState.abandoned;
      if (!w.completer.isCompleted) {
        w.completer.completeError(const ThumbSignAbandoned());
      }
    }
    if (!job.started) {
      // 排队态:该 job 已无任何 waiter → 整体出 FIFO + 出注册表,不动闸计数
      _fifo.remove(job);
      if (identical(_jobs[key], job)) _jobs.remove(key);
      _settle(job);
    } else if (job.slotHeld) {
      // 运行态且是最后 waiter:还槽(计时器已逐个取消——计时器与还槽绑定为一件)
      _releaseSlot(job);
    }
  }

  /// 会话清空(W2 #11 写死):取消全部闸计时器、归零闸计数、所有 active waiter
  /// (queued+running)以取消异常完成、清注册表、代数自增。
  void clear() {
    _generation++;
    for (final job in _jobs.values) {
      for (final w in job.waiters) {
        _cancelRace(w);
        if (w.state == _WaiterState.abandoned) continue;
        w.state = _WaiterState.abandoned;
        if (!w.completer.isCompleted) {
          w.completer.completeError(const ThumbSignAbandoned());
        }
      }
      job.waiters.clear();
      _settle(job);
    }
    _jobs.clear();
    _fifo.clear();
    _active = 0;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  /// 注册一个 waiter:job 未启动则排队态(随 job 一起入闸),已启动(含放槽
  /// 悬挂)则立即 running 态并起自身 race 计时器。返回该 waiter 的 future。
  Future<T> addWaiter(SignJob<T> job) {
    final j = job as _Job<T>;
    if (j.settled) {
      throw StateError('sign job 已终态,不可 join(${j.assetId})');
    }
    final w = _Waiter<T>();
    j.waiters.add(w);
    // waiter future 挂内部 ignore 兜底:放弃/超时后无监听者也不产生未处理异常
    // (多监听彼此独立,正常 await 的调用方照常收到值/异常)
    w.completer.future.ignore();
    if (j.started) _promote(j, w); // join 到运行/悬挂签名:立即 running
    _pump();
    return w.completer.future;
  }

  void _pump() {
    while (_active < limit && _fifo.isNotEmpty) {
      final job = _fifo.removeAt(0);
      if (job.settled) continue;
      _start(job);
    }
  }

  void _start(_Job<T> job) {
    job.started = true;
    job.slotHeld = true;
    _active++;
    for (final w in job.activeWaiters().toList()) {
      _promote(job, w);
    }
    Future<T> root;
    try {
      root = job.run();
    } catch (e, st) {
      AppLog.error('thumb-sign-gate', 'signer 同步异常(${job.assetId})', e);
      root = Future<T>.error(e, st);
    }
    root.then(
      (v) => _onRootValue(job, v),
      onError: (Object e, StackTrace st) => _onRootError(job, e, st),
    );
  }

  void _promote(_Job<T> job, _Waiter<T> w) {
    if (w.state != _WaiterState.queued) return;
    w.state = _WaiterState.running;
    w.race = Timer(raceTimeout, () => _onRaceFire(job, w));
  }

  /// race 计时器到点:该 waiter 收 TimeoutException 出场;job 仍持槽且再无
  /// 其他活跃 waiter → 放槽(底层悬挂签名不强杀,10min 自愈)。
  void _onRaceFire(_Job<T> job, _Waiter<T> w) {
    if (w.state == _WaiterState.abandoned) return;
    _cancelRace(w);
    w.state = _WaiterState.abandoned;
    if (!w.completer.isCompleted) {
      w.completer.completeError(TimeoutException('签名等待超时', raceTimeout));
    }
    if (job.slotHeld && !job.settled && job.activeWaiters().isEmpty) {
      _releaseSlot(job);
    }
  }

  void _onRootValue(_Job<T> job, T v) {
    if (job.settled) return; // 已被 clear 整体终结
    _settle(job);
    _releaseSlot(job);
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    for (final w in job.waiters) {
      if (w.state == _WaiterState.abandoned) continue;
      w.state = _WaiterState.abandoned;
      _cancelRace(w);
      if (!w.completer.isCompleted) w.completer.complete(v);
    }
    job.waiters.clear();
    _pump();
  }

  void _onRootError(_Job<T> job, Object e, StackTrace st) {
    if (job.settled) return;
    _settle(job);
    _releaseSlot(job);
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    final active = job.activeWaiters().toList();
    if (active.isEmpty) {
      // 全部 waiter 已放弃/超时/清场:迟到失败仅留痕,不上抛(D2)
      AppLog.error('thumb-sign-gate', '签名失败(无活跃等待者,已吞)(${job.assetId})', e);
    } else {
      // 存在 active waiter:异常照常传播(立即失败释放管线名额,落降级)
      for (final w in active) {
        w.state = _WaiterState.abandoned;
        _cancelRace(w);
        if (!w.completer.isCompleted) w.completer.completeError(e, st);
      }
    }
    job.waiters.clear();
    _pump();
  }

  /// 槽释放全路径幂等(releaseOnce,携代数):旧代 late 释放 no-op。
  void _releaseSlot(_Job<T> job) {
    if (!job.slotHeld) return;
    if (job.generation != _generation) return;
    job.slotHeld = false;
    if (_active > 0) _active--;
    _pump();
  }

  void _cancelRace(_Waiter<T> w) {
    w.race?.cancel();
    w.race = null;
  }

  /// job 终态标记 + onSettled 回调(cache 清 _inflight);幂等。
  void _settle(_Job<T> job) {
    if (job._settled) return;
    job._settled = true;
    for (final w in job.waiters) {
      _cancelRace(w);
    }
    job.onSettled?.call();
  }
}
