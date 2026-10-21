/// TransferQueue — app 级传输队列单例(方案 §7 / B3 功能点 3)。
///
/// 全局 FIFO 并发 2(上传下载混排);取消=CancelToken(上传尽力 abort 清悬挂
/// 分片由 worker 内部负责,abort 失败不阻塞取消态——取消即刻落终态、槽位立即
/// 让出);重试=同描述重新入队从头来(无断点续传);清已完成只清终态。
///
/// mobile-ux-polish-2 起任务**快照持久化**(R4c):入队/状态变化去抖落盘
/// `transfers.json`,启动恢复(终态原样/非终态标「进程中断」,见
/// transfer_store.dart);恢复记录无可执行 worker,重试降级为提示重新发起。
/// 前台服务联动(R4d):活跃任务数(queued+running)经 [TransferForeground.sync]
/// 上报,入队/收尾/取消/移除/清理/恢复全状态机变化点覆盖,全终态必停。
///
/// 不引状态管理框架,裸 ChangeNotifier;worker 注入 + 时钟注入 + 无真实 IO,
/// PC 可用假时钟单测状态机/FIFO/取消/重试。测试可自建实例(store/去抖定时器
/// 可注入),页面默认挂 [I]。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/assets_api.dart' show UploadAmbiguousException;
import '../api/ms_api.dart' show ApiException, errorMessage;
import '../../services/app_log.dart';
import '../../services/media_save.dart' show SaveAbortException;
import '../../services/notifier.dart';
import '../../services/transfer_foreground.dart';
import 'transfer_store.dart';
import 'transfer_task.dart';

class TransferQueue extends ChangeNotifier {
  TransferQueue({
    int? concurrency,
    DateTime Function()? now,
    TransferStore? store,
    void Function(Duration, void Function())? schedule,
  })  : _now = now ?? DateTime.now,
        _schedule = schedule ?? _defaultSchedule,
        _concurrency = concurrency ?? 2 {
    _store = store;
  }

  static void _defaultSchedule(Duration d, void Function() cb) => Timer(d, cb);

  /// 全局单例(页面/badge 经此订阅;测试可自建实例隔离)。
  static final TransferQueue I = TransferQueue();

  final int _concurrency;
  final DateTime Function() _now;

  /// R4c:快照存储(null=仅内存,现有单测/降级口径);[schedule] 注入去抖
  /// 定时器(测试手动触发,同 TransferNotifyBatcher 注入口径)。
  TransferStore? _store;
  final void Function(Duration, void Function()) _schedule;

  /// R4c:变化点即时编码的最新快照(去抖只合并 IO,不合并编码时刻)+ 去抖
  /// 代次号(陈旧回调 no-op)。
  String? _pendingSnapshot;
  var _persistSeq = 0;

  /// 展示列表:新任务插顶(重试/入队即到列表首,web TaskCenter 同观感)。
  final _tasks = <TransferTask>[];

  /// FIFO 等待线(id 序=入队序,与展示序无关)。
  final _waiting = <String>[];
  final _runningIds = <String>{};
  final _requests = <String, TransferRequest>{};
  final _tokens = <String, CancelToken>{};
  var _seq = 0;

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  TransferTask? byId(String id) =>
      _tasks.where((t) => t.id == id).firstOrNull;

  // ── 派生计数(宫格迷你条 / TabBar badge 的唯一数据源,单测钉死口径)────

  /// running 总数(上/下载混排)= TabBar 传输格 badge。
  int get runningCount => _countOf(TransferStatus.running);

  int runningCountOf(TransferKind kind) =>
      _tasks.where((t) => t.kind == kind && t.status == TransferStatus.running).length;

  int _countOf(TransferStatus s) =>
      _tasks.where((t) => t.status == s).length;

  /// 上传任务总数(全状态)——迷你条分母 m。
  int get uploadCount =>
      _tasks.where((t) => t.kind == TransferKind.upload).length;

  /// 已完成(done)上传数——迷你条分子 n。
  int get uploadDoneCount => _tasks
      .where((t) =>
          t.kind == TransferKind.upload && t.status == TransferStatus.done)
      .length;

  /// 活动上传(queued+running)数——迷你条显隐条件(有活动上传才显示)。
  int get activeUploadCount => _tasks
      .where((t) =>
          t.kind == TransferKind.upload &&
          (t.status == TransferStatus.queued ||
              t.status == TransferStatus.running))
      .length;

  /// 迷你条字节进度 0..1:done 上传按满格计 + 活动上传按 doneBytes,
  /// 随 n/m 单调爬升;总字节未知(全 0)时 null → UI 转 indeterminate。
  double? get uploadByteProgress {
    var doneB = 0, totalB = 0;
    for (final t in _tasks) {
      if (t.kind != TransferKind.upload) continue;
      totalB += t.totalBytes;
      if (t.status == TransferStatus.done) {
        doneB += t.totalBytes;
      } else if (t.status == TransferStatus.running ||
          t.status == TransferStatus.queued) {
        doneB += t.doneBytes;
      }
    }
    if (totalB <= 0) return null;
    return (doneB / totalB).clamp(0.0, 1.0);
  }

  // ── R4c:快照持久化与启动恢复 ────────────────────────────────────────────

  /// 挂默认持久化(应用支持目录 transfers.json)并从快照恢复;main 挂接一次。
  /// 存储打开失败(测试环境无插件通道等)静默降级仅内存,任务照常跑。
  Future<void> attachDefaultStore() async {
    if (_store != null) return;
    final store = await TransferStore.openDefault();
    if (store == null) return;
    await attachStore(store);
  }

  /// 挂持久化并从快照恢复([store]=恢复源;若队列已带存储(构造注入)则写盘
  /// 仍走原存储——测试场景「read 源 + write 捕获」分离注入)。恢复口径:终态
  /// 任务原样还原、非终态已由 [decodeTasks] 标 failed「进程中断」;恢复记录置于
  /// 列表底部(展示序=最新在上,历史最旧);id 序号续接快照最大值,防新任务撞
  /// id。恢复后内容与快照不一致(坏 JSON/非终态改写)→ 立即重写一致快照(清空
  /// 重来,不崩溃、不留半截状态);一致或文件缺失则不重写。
  @visibleForTesting
  Future<void> attachStore(TransferStore store) async {
    _store ??= store;
    final raw = await store.read();
    final restored = raw == null ? null : decodeTasks(raw);
    if (restored != null && restored.isNotEmpty) {
      for (final t in restored) {
        _tasks.add(t);
        final m = RegExp(r'^t(\d+)$').firstMatch(t.id);
        if (m != null) {
          final n = int.parse(m.group(1)!);
          if (n > _seq) _seq = n;
        }
      }
      AppLog.info('transfer', '快照恢复 ${restored.length} 条历史记录');
    }
    if (raw != null) {
      // 快照原文存在即重写一份一致快照(终态 roundtrip 恒等:encode∘decode 对
      // 纯终态快照=identity;坏 JSON → 空快照;非终态改写 → 一致快照——均绕过
      // 去抖立即落,保证下次启动所见即本进程恢复口径)
      _persistNow();
    }
    _syncForeground();
    notifyListeners();
  }

  /// 状态变化点统一走此:**变化时刻即编码**快照入 [_pendingSnapshot](状态=
  /// 变化点口径,进度回调不落盘不编码,收尾再落终值);去抖窗口内只挂一个
  /// 定时器,代次号守卫:仅最新代次的回调真正落盘(测试注入收集全部回调/真实
  /// Timer 均适配,陈旧回调 no-op,不重复写)。无存储=仅内存。
  /// 注意:入队侧先编码后 [_pump](快照记「入队」变化点的 queued 态)。
  void _schedulePersist() {
    _pendingSnapshot = encodeTasks(_tasks);
    if (_store == null) return;
    final seq = ++_persistSeq;
    _schedule(kPersistDebounce, () {
      if (seq != _persistSeq) return; // 陈旧回调:已被更新的变化点取代
      _persistNow();
    });
  }

  /// 立即落盘(attachStore 的一致性重写也走此,绕过去抖;使一切在途回调失效)。
  void _persistNow() {
    _persistSeq++;
    final store = _store;
    if (store == null) return;
    final content = _pendingSnapshot ?? encodeTasks(_tasks);
    store.write(content).catchError((Object e) {
      AppLog.error('transfer', '传输快照写盘失败(下次状态变化重试)', e);
    });
  }

  /// R4d:活跃任务数(queued+running)同步前台服务。入队/收尾/取消/移除/
  /// 清理/恢复全状态机变化点统一经此上报(全终态必停,不留常驻);无 Android
  /// /未初始化时 no-op。
  void _syncForeground() {
    TransferForeground.I
        .sync(_countOf(TransferStatus.queued) + _countOf(TransferStatus.running))
        .ignore();
  }

  // ── 队列操作 ────────────────────────────────────────────────────────────

  /// 入队(排队尾,FIFO);返回任务 id。并发有空位则立即启动。
  String enqueue(TransferRequest req) {
    _seq += 1;
    final id = 't$_seq';
    _tasks.insert(
        0,
        TransferTask(
          id: id,
          kind: req.kind,
          filename: req.filename,
          where: req.where,
          totalBytes: req.totalBytes,
          startedAt: _now(),
        ));
    _requests[id] = req;
    _waiting.add(id);
    // P8(mobile-ux-polish):首次建传输任务才请求系统通知权限(app 启动不弹;
    // 幂等 + 失败静默,不阻塞入队)
    Notifier.I.ensurePermission().ignore();
    _schedulePersist(); // R4c:入队即快照(先于 _pump,记「入队」变化点)
    _pump();
    _syncForeground(); // R4d:有活跃任务 → 前台服务
    notifyListeners();
    return id;
  }

  /// 取消:queued 直接落终态不出队线;running 立即落终态+触发 CancelToken,
  /// 槽位即刻让出(不等 worker 收尾——abort 尽力,失败不阻塞取消态)。
  Future<void> cancel(String id) async {
    final task = byId(id);
    if (task == null || task.status.isTerminal) return;
    task.status = TransferStatus.canceled;
    task.error = null;
    _waiting.remove(id);
    final wasRunning = _runningIds.remove(id);
    if (wasRunning) {
      _tokens.remove(id)?.cancel('用户取消');
      _pump();
    }
    _schedulePersist(); // R4c:取消即终态,快照更新
    _syncForeground(); // R4d:可能因此全终态 → 停服务
    notifyListeners();
  }

  /// 重试=同描述重新入队从头来(非续传):旧任务移出列表,新任务排队尾。
  /// 仅终态可重试;done 不给重试(同名重传必撞后端 409 查重,徒增困惑);
  /// 恢复的历史记录(R4c,无可执行 worker——源信息不可序列化,见
  /// transfer_store.dart 头注释)降级:原地把 error 改写为「重新发起」提示
  /// (卡片即提示),不产新任务,返回 null。
  String? retry(String id) {
    final task = byId(id);
    if (task == null || !task.status.isTerminal) return null;
    if (task.status == TransferStatus.done) return null;
    final req = _requests[id];
    if (req == null) {
      task.error = '历史记录,请重新发起传输';
      notifyListeners();
      return null;
    }
    _tasks.remove(task);
    _requests.remove(id);
    _schedulePersist(); // R4c:旧任务移出列表,快照更新(新任务由 enqueue 落)
    return enqueue(req);
  }

  /// 移除单个任务(仅终态;活动任务请先取消)。
  void remove(String id) {
    final task = byId(id);
    if (task == null || !task.status.isTerminal) return;
    _tasks.remove(task);
    _requests.remove(id);
    _tokens.remove(id);
    _schedulePersist(); // R4c
    notifyListeners();
  }

  /// 清已完成:只清终态(done/failed/canceled),活动任务保留。
  void clearFinished() {
    _tasks.removeWhere((t) {
      if (!t.status.isTerminal) return false;
      _requests.remove(t.id);
      return true;
    });
    _schedulePersist(); // R4c
    notifyListeners();
  }

  // ── 内部:启动/收尾 ────────────────────────────────────────────────────

  void _pump() {
    while (_runningIds.length < _concurrency && _waiting.isNotEmpty) {
      final id = _waiting.removeAt(0);
      _start(id);
    }
  }

  void _start(String id) {
    final task = byId(id);
    final req = _requests[id];
    // 竞态防御:等待期被取消/移除的任务不再启动(取消态优先)
    if (task == null || req == null || task.status != TransferStatus.queued) {
      return;
    }
    task.status = TransferStatus.running;
    _runningIds.add(id);
    final token = CancelToken();
    _tokens[id] = token;
    // P2-5 防御钉子:worker 调用本身包 try/catch。约定 worker 是 async 闭包
    // (抛错落 failed future,走下方 catchError),但若实现同步抛(async 前的
    // 参数求值/闭包体首行同步 throw),异常会沿 _pump → enqueue 同步炸穿
    // 入队方(如上传面板逐项入队循环),殃及整批。这里兜住:同步抛同样走
    // _settle 统一收尾——该任务落 failed、槽位正常让出、队列状态机不破。
    Future<void> running;
    try {
      running = req.worker((done) {
        // 取消后进度回调让位(取消态不回写进度)
        if (task.status == TransferStatus.running) {
          task.doneBytes = done;
          notifyListeners();
        }
      }, token);
    } catch (e) {
      _settle(id, TransferStatus.failed, _errMsg(e));
      return;
    }
    running.then((_) {
      _settle(id, TransferStatus.done, null);
    }).catchError((Object e) {
      // 取消竞态:取消已落终态,worker 的事后异常(含 abort 失败)不覆盖取消态
      if (task.status == TransferStatus.canceled) return;
      if (e is UploadAmbiguousException) {
        // §4.1:complete 响应丢失 → failed+特定文案,禁自动重传(本队列本就
        // 无自动重试;文案提醒用户先核实再手动操作)
        _settle(id, TransferStatus.failed, '可能已上传,请先在素材列表核实');
      } else {
        _settle(id, TransferStatus.failed, _errMsg(e));
      }
    });
  }

  void _settle(String id, TransferStatus status, String? error) {
    _runningIds.remove(id);
    _tokens.remove(id);
    final task = byId(id);
    if (task != null && !task.status.isTerminal) {
      task
        ..status = status
        ..error = error
        ..doneBytes = status == TransferStatus.done ? task.totalBytes : task.doneBytes;
      if (status == TransferStatus.failed) {
        AppLog.error('transfer', '任务失败 ${task.filename}', error);
      }
      // P8(mobile-ux-polish):后台终态系统通知(前台 gate 丢弃,维持应用内
      // 现状)。上传完成/上传失败/下载失败在队列统一收尾处上报;下载成功在
      // downloads.dart 收尾处带保存摘要上报,此处不再重复(防双份)。
      if (status == TransferStatus.failed) {
        Notifier.I.taskFinished(
            kind: task.kind,
            ok: false,
            filename: task.filename,
            detail: error ?? '传输失败');
      } else if (status == TransferStatus.done &&
          task.kind == TransferKind.upload) {
        Notifier.I.taskFinished(
            kind: task.kind, ok: true, filename: task.filename);
      }
    }
    _pump();
    _schedulePersist(); // R4c:收尾落终值(进度字段口径)
    _syncForeground(); // R4d:可能因此全终态 → 停服务
    notifyListeners();
  }

  /// 任务 error 字段文案(B9 P2-5 收敛):用户可见 detail 类异常透传 message
  /// (ApiException=后端 detail;SaveAbortException=下载落盘分路中文文案);
  /// 其余(DioException 断网/超时、StateError 等)统一落中文兜底——传输队列
  /// 卡片不再出现「DioException …」英文裸渲染。
  static String _errMsg(Object e) => switch (e) {
        ApiException(:final message) => message,
        SaveAbortException(:final message) => message,
        _ => errorMessage(e, '传输失败,请稍后重试'),
      };
}
