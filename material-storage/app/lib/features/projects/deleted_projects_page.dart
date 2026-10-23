/// DeletedProjectsPage — 已删除项目回收站(B6 §8.5;2026-10 墨金重做):
/// PageHeader(返回/已删除项目/仅项目删除人可见)+ 搜索 + 卡片列表
/// (name/code/删除人/时间 + 恢复),滚动到底自动加载(替代「加载更多」按钮),
/// 单行恢复(danger 确认)。入口=我的→「回收站(项目)」,仅 is_project_deleter
/// 可见;恢复成功 invalidate projects scope。403 detail 透传保留。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../../widgets/toast.dart';

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

  /// P2-2 加载更多防连点 + 代际 tag:搜索 reload 使 tag 自增,旧 loadMore 的
  /// 迟到响应按 tag 不匹配丢弃,不污染新词列表。
  var _loadingMore = false;
  var _reloadTag = 0;

  /// P2-1 恢复防重:restore await 期间禁用行内按钮并拦下重复调用。
  var _restoring = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 拉第一页并整表替换(搜索词变化/恢复后);[q] 传 null = 沿用当前词。
  Future<void> _reload() async {
    final tag = ++_reloadTag;
    try {
      final page = await session.api!.projectsOps.listDeleted(
        q: _q,
        limit: kDeletedProjectsPageSize,
        offset: 0,
      );
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
        offset: _items.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      toast(context, errorMessage(e, '加载更多失败,可再次滚动重试'), tone: ToastTone.error);
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
      toast(context, errorMessage(e, '恢复失败,请稍后重试'), tone: ToastTone.error);
    } finally {
      _restoring = false;
      if (mounted) setState(() {});
    }
  }

  void _search(String v) {
    _q = v.trim();
    setState(() => _loading = true);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(back: true, title: '已删除项目', subtitle: '仅项目删除人可见'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceMd,
              Tk.spacePage,
              Tk.spaceSm,
            ),
            child: SearchField(hintText: '搜项目代号 / 名称…', onSubmitted: _search),
          ),
          if (!_loading && _error == null && _q.isEmpty && _total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                0,
                Tk.spacePage,
                Tk.spaceSm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '共 $_total 个已删除项目',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
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
              SizedBox(
                height: constraints.maxHeight,
                child: Center(
                  child: EmptyState(
                    icon: Icons.delete_sweep_outlined,
                    message: _q.isEmpty ? '没有已删除的项目' : '无匹配项目',
                    description: _q.isEmpty ? '删除的项目会保留在这里,可随时恢复。' : null,
                  ),
                ),
              ),
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
          if ((n is ScrollUpdateNotification || n is OverscrollNotification) &&
              n.metrics.extentAfter < _kLoadMoreThreshold) {
            _loadMore();
          }
          return false;
        },
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            Tk.spaceXs,
            Tk.spacePage,
            Tk.spaceXl,
          ),
          itemCount: _items.length + (_loadingMore ? 1 : 0),
          itemBuilder: (context, i) {
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
            return _DeletedCard(
              project: _items[i],
              restoring: _restoring,
              onRestore: () => _restore(_items[i]),
            );
          },
        ),
      ),
    );
  }
}

/// 单个已删除项目卡:name(code) + 删除时间/操作人 + 恢复按钮。
class _DeletedCard extends StatelessWidget {
  const _DeletedCard({
    required this.project,
    required this.restoring,
    required this.onRestore,
  });

  final DeletedProject project;
  final bool restoring;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final tk = context.tk;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Tk.spaceMd),
      padding: EdgeInsets.zero,
      child: AppRow(
        leading: Icon(Icons.folder_delete_outlined, color: tk.ink2),
        title: '${p.name}(${p.code})',
        subtitle:
            '删除于 ${p.deletedAt.isEmpty ? '—' : fmtDate(p.deletedAt)}'
            '${p.deletedByName == null ? '' : ' · ${p.deletedByName}'}',
        showChevron: false,
        trailing: TextButton.icon(
          icon: const Icon(Icons.restore_from_trash_outlined, size: 16),
          label: const Text('恢复'),
          onPressed: restoring ? null : onRestore,
        ),
      ),
    );
  }
}
