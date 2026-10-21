/// BaiduPage — 网盘备份用户侧完整页(B9 §8.10,web BaiduBackupDrawer 移动版):
/// 绑定状态卡(已绑定/已过期/未绑定 + 账号·授权期 + 绑定/重绑/切换账号 +
/// 解绑确认 + 新建备份任务闸门)+ 任务列表(仅本人,服务端分页「加载更多」;
/// 行=状态徽标/进度/字节/ETA/失败原因 + 取消/全部重试失败/删除/查看)。
/// 状态文案与频控、key 冲突语义透传后端 detail(baidu_task_labels 中文映射)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import 'baidu_binding_card.dart';
import 'baidu_task_card.dart';

class BaiduPage extends StatefulWidget {
  const BaiduPage({super.key, this.api});

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  @override
  State<BaiduPage> createState() => _BaiduPageState();
}

class _BaiduPageState extends State<BaiduPage> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;

  BaiduBindingInfo? _binding;
  var _bindingLoaded = false;
  var _tasks = <BaiduTask>[];
  var _total = 0;
  var _loading = true;
  String? _error;
  var _busy = false; // 行操作互斥(取消/重试/删除)

  /// 总线失效回调引用(dispose 摘监听须同一 tear-off)。
  late final VoidCallback _onTasksInvalidated = _reload;

  @override
  void initState() {
    super.initState();
    // P2-3:挂 baidu-tasks 失效总线(新建任务页创建成功 invalidate 本 scope;
    // 本页在导航栈下仍 mounted,收到即刷新)。与 pushNamed 返回值刷新
    // (onNewTask 弹层关闭通道)双通道并存,弹层返回 false 等场景也有兜底。
    RefreshBus.I.addListener('baidu-tasks', _onTasksInvalidated);
    _reload();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('baidu-tasks', _onTasksInvalidated);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final status = await _api.bindingStatus();
      final page = await _api.listTasks(limit: 20);
      if (!mounted) return;
      setState(() {
        _binding = status;
        _bindingLoaded = true;
        _tasks = page.items;
        _total = page.total;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e, '网盘备份加载失败');
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    try {
      final page = await _api.listTasks(limit: 20, offset: _tasks.length);
      if (!mounted) return;
      setState(() {
        final known = _tasks.map((t) => t.id).toSet();
        _tasks.addAll(page.items.where((t) => !known.contains(t.id)));
        _total = page.total;
      });
    } catch (_) {}
  }

  Future<void> _unbind() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解绑百度网盘账号?'),
        content:
            const Text('将取消名下进行中的备份任务并作废全部断点;历史任务记录保留。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(foregroundColor: Tk.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _api.unbind();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('已解绑百度网盘账号')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      // 传输层异常(断网/超时)中文兜底,勿渲染原始异常对象(§4.1)
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(errorMessage(e, '解绑失败,请稍后重试'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  /// 行操作(取消/全部重试失败/删除):403/409/429 detail 透传,429 不自动重试。
  Future<void> _rowAction(BaiduTask t, String action) async {
    if (_busy) return;
    // 确认口径同 web Popconfirm:取消(未完成文件停止导入,已完成保留)与
    // 删除(仅记录,已导入文件不受影响)需确认;全部重试失败直发
    if (action == 'cancel' || action == 'delete') {
      final (title, content, okText) = action == 'cancel'
          ? ('取消该任务?', '未完成文件将停止导入(已完成文件保留)。', '取消任务')
          : ('删除该任务记录?', '仅删除任务记录与进度,已导入的文件不受影响。', '删除');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(foregroundColor: Tk.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(okText),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'cancel':
          final r = await _api.cancelTask(t.id);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(r.finalized
                  ? '任务已取消'
                  : '取消请求已提交,任务将在最近检查点停止')));
        case 'retry-failed':
          await _api.retryFailed(t.id);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('失败文件已全部重新排队')));
        case 'delete':
          await _api.deleteTask(t.id);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('任务记录已删除')));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(errorMessage(e, '操作失败,请稍后重试'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘备份')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _reload)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: [
                      _bindingCard(),
                      const SizedBox(height: 12),
                      if (_tasks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(
                            child: Text('暂无备份任务 · 绑定账号后点「新建备份任务」开始',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 13, color: Tk.muted)),
                          ),
                        )
                      else
                        for (final t in _tasks)
                          BaiduTaskCard(
                            task: t,
                            busy: _busy,
                            onAction: (a) => _rowAction(t, a),
                          ),
                      if (_tasks.length < _total)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton(
                              onPressed: _loadMore,
                              child: const Text('加载更多')),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _bindingCard() => BaiduBindingCard(
        binding: _binding,
        loaded: _bindingLoaded,
        busy: _busy,
        onBind: () async {
          await Navigator.of(context).pushNamed('/baidu-bind');
          await _reload();
        },
        onNewTask: () async {
          final created = await Navigator.of(context).pushNamed('/baidu-new-task');
          if (created == true) await _reload();
        },
        onUnbind: _unbind,
      );
}
