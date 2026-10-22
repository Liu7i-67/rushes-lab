/// DeletedProjectsPage — 已删除项目回收站(B6 §8.5;app-polish E10 精修):
/// 列表(q 过 code/name,deleted_at 倒序,带删除人)+ 滚动到底自动加载
/// (替代「加载更多」按钮)+ 单行恢复(danger 确认)。顶部说明收进可关闭
/// 提示卡(默认展示一次,可收起);错误走 errorMessage;恢复成功 toast。
/// 入口=我的→「回收站(项目)」,仅 is_project_deleter 可见(后端 deleted/
/// restore 双端点 require_project_deleter 同口径);恢复成功 invalidate
/// projects scope。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/toast.dart';
import '../../core/fmt.dart';

/// 分页页大小(web DELETED_PROJECTS_PAGE_SIZE 同款)。
const kDeletedProjectsPageSize = 20;

/// 距底不足此距离即预取下一页(自动加载阈值)。
const _kLoadMoreThreshold = 200.0;

class DeletedProjectsPage extends StatefulWidget {
  const DeletedProjectsPage({super.key});

  @override
  State<DeletedProjectsPage> createState() => _DeletedProjectsPageState();
}

class _DeletedProjectsPageState extends State<DeletedProjectsPage> {
  String _q = '';
  final _items = <DeletedProject>[];
  var _total = 0;
  var _loading = true;
  String? _error;
  var _infoOpen = true;

  /// P2-2 加载更多防连点 + 代际 tag(参照 pickers stale tag 模式):
  /// 搜索 reload 使 tag 自增,旧 loadMore 的迟到响应按 tag 不匹配丢弃,
  /// 不污染新词列表。
  var _loadingMore = false;
  var _reloadTag = 0;

  /// P2-1 恢复防重:restore await 期间禁用行内按钮并拦下重复调用。
  var _restoring = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 拉第一页并整表替换(搜索词变化/恢复后);[q] 传 null = 沿用当前词。
  Future<void> _reload() async {
    final tag = ++_reloadTag;
    try {
      final page = await session.api!.projectsOps
          .listDeleted(q: _q, limit: kDeletedProjectsPageSize, offset: 0);
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _error = e.message; // 403 detail 透传(非 is_project_deleter 深链兜底)
        _loading = false;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _error = errorMessage(e, '回收站加载失败');
        _loading = false;
      });
    }
  }

  /// 追加下一页(自动加载;P2-2:_loadingMore 防连点,_items.length >= _total
  /// 取尽守卫,快照代际 tag 防搜索 reload 后旧响应追加进新词列表);
  /// 失败 toast 可见反馈,再次滚动重试。
  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    final tag = _reloadTag;
    setState(() => _loadingMore = true);
    try {
      final page = await session.api!.projectsOps.listDeleted(
          q: _q,
          limit: kDeletedProjectsPageSize,
          offset: _items.length);
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      toast(context, errorMessage(e, '加载更多失败,可再次滚动重试'),
          tone: ToastTone.error);
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _restore(DeletedProject p) async {
    if (_restoring) return; // P2-1 防连点(守卫须在首个 await 前同步生效)
    final ok = await showAppConfirm(
      context,
      title: '恢复项目「${p.name}」?',
      content: '恢复后立即回到项目列表,原成员权限不变。',
      confirmLabel: '恢复',
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    try {
      await session.api!.projectsOps.restore(p.id);
      RefreshBus.I.invalidate('projects');
      if (!mounted) return;
      toast(context, '项目「${p.name}」已恢复', tone: ToastTone.success);
      _reload();
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '恢复失败,请稍后重试'),
          tone: ToastTone.error);
    } finally {
      _restoring = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站(项目)')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              hintText: '搜项目代号 / 名称…',
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) {
              _q = v.trim();
              setState(() => _loading = true);
              _reload();
            },
          ),
        ),
        // E10:顶部说明收进可关闭提示卡(不再常驻占三行)
        if (_infoOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Tk.spaceLg, Tk.spaceXs, Tk.spaceLg, 0),
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                  Tk.spaceMd, Tk.spaceXs, Tk.spaceXs, Tk.spaceXs),
              decoration: const BoxDecoration(
                color: Tk.surface2,
                borderRadius: BorderRadius.all(Radius.circular(Tk.rMd)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline,
                        size: 16, color: Tk.muted),
                  ),
                  const SizedBox(width: Tk.spaceSm),
                  const Expanded(
                    child: Text(
                      '已删除的项目对所有成员隐藏,数据与授权保留;恢复后立即回到项目列表。',
                      style: TextStyle(
                          fontSize: Tk.fzXs, color: Tk.muted, height: 1.5),
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      tooltip: '收起',
                      icon: const Icon(Icons.close, color: Tk.subtle),
                      onPressed: () => setState(() => _infoOpen = false),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: constraints.maxHeight, child: Center(
                child: EmptyState(
                  icon: Icons.delete_sweep_outlined,
                  message: _q.isEmpty ? '没有已删除的项目' : '无匹配项目',
                ),
              )),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      // E10:滚动到底(距底 <200px)自动加载。NotificationListener 恒派发
      // (含内容不足一屏的 overscroll),不受 physics 钳制影响
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 更新与越界(overscroll)都要:内容不足一屏时只有越界通知
          if ((n is ScrollUpdateNotification || n is OverscrollNotification) &&
              n.metrics.extentAfter < _kLoadMoreThreshold) {
            _loadMore();
          }
          return false;
        },
        child: ListView.separated(
          itemCount: _items.length + (_loadingMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            // E10:底部加载指示(自动加载 in-flight;替代「加载更多」按钮)
            if (i >= _items.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: Tk.spaceMd),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final p = _items[i];
            return ListTile(
              leading: const Icon(Icons.folder_delete_outlined),
              title: Text('${p.name}(${p.code})',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '删除于 ${p.deletedAt.isEmpty ? '—' : fmtDate(p.deletedAt)}'
                '${p.deletedByName == null ? '' : ' · ${p.deletedByName}'}',
                style: const TextStyle(fontSize: Tk.fzXs),
              ),
              trailing: TextButton.icon(
                icon: const Icon(Icons.restore_from_trash_outlined, size: 16),
                label: const Text('恢复'),
                onPressed: _restoring ? null : () => _restore(p),
              ),
            );
          },
        ),
      ),
    );
  }
}
