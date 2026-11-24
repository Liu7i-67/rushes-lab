/// 回收站页(B5 功能点 2,对标 web FolderTrashModal 移动版;仅恢复):
/// GET /assets/trash + POST /assets/{id}/restore;分页=滚到底自动加载。
/// 入口显隐三态(web ProjectDetailPage canSeeTrash 实码对齐):
/// 普通夹 = my_can_admin 或 my_delete_grant;sensitive 夹仅系统 admin。
/// 视觉迁移:PageHeader(17 标题 + 返回)+ 卡片行(AppCard/AppRow)。
/// 快速滚动(app-fast-scroll F4):itemCount=_total 正确高度 + PagedWindow
/// 取数(恒 DESC,无排序切换)+ 未加载区骨架行 + 右缘 FastScrollBar;
/// 滚到底/骨架命中/onSeek 三路都汇入 _ensureVisibleLoaded(单批 500;
/// 在途守卫/pending 续补决策核心抽至 core/ensure_planner.dart,P2-3)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/ensure_planner.dart';
import '../../core/fmt.dart';
import '../../core/paged_window.dart';
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/fast_scroll_bar.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'asset_writeback.dart';

/// 入口闸门(web canSeeTrash 实码同式:canDeleteFiles && (!is_sensitive || admin))。
/// 纯函数可单测;参数三态:my_can_*/my_delete_grant 详情未到=null(视为 false)。
bool canSeeTrash({
  required bool? myCanAdmin,
  required bool? myDeleteGrant,
  required bool isSensitive,
  required bool isSystemAdmin,
}) {
  final canDeleteFiles = (myCanAdmin ?? false) || (myDeleteGrant ?? false);
  return canDeleteFiles && (!isSensitive || isSystemAdmin);
}

/// 距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

/// 快速滚动条显隐阈值(D4:小列表滚动条是噪音)。
const _barMinItems = 100;

/// 音频扩展名(preview_kind 八类判定不含音频,就地补判)。
const _kAudioExts = <String>['.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg'];

/// 回收站行首图标按资产类型分型(kind 判定走 detectKind 钉子)。
@visibleForTesting
IconData trashKindIcon({required String filename, String? contentType}) {
  final name = filename.toLowerCase();
  if ((contentType ?? '').toLowerCase().startsWith('audio/') ||
      _kAudioExts.any(name.endsWith)) {
    return Icons.graphic_eq;
  }
  return switch (detectKind(filename: filename, contentType: contentType)) {
    PreviewKind.image || PreviewKind.heic => Icons.image_outlined,
    PreviewKind.video => Icons.videocam_outlined,
    PreviewKind.livp => Icons.photo_camera_outlined,
    PreviewKind.pdf ||
    PreviewKind.markdown ||
    PreviewKind.text => Icons.description_outlined,
    PreviewKind.unsupported => Icons.insert_drive_file_outlined,
  };
}

class TrashPage extends StatefulWidget {
  const TrashPage({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  final String folderId;
  final String folderName;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  static const _pageSize = 500; // 后端单窗口上限

  final _items = <Asset>[];
  final _scroll = ScrollController();
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  var _loadMoreFailed = false;
  var _restoringId = '';
  String? _error;

  /// 在途期间的更远补齐目标(裸显示序,不含一页余量——P2-3 统一语义,
  /// 消费时再 + 一页余量换算缺口;完成后由 _fetchGap 续批)。
  int? _pendingTarget;

  /// 显示序 ↔ offset 窗口模型(回收站恒 DESC、无排序切换;_refresh/恢复
  /// 改动 _total/_items 后随派生值自然更新,无需显式重建)。
  PagedWindow get _window =>
      PagedWindow(total: _total, loaded: _items.length, descending: true);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _refresh();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _loadMoreThreshold) {
      // 视口贴近全量列表尾部:补齐到末尾(途中骨架由逐行命中兜底)。
      _ensureVisibleLoaded(_total);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreFailed = false;
    });
    try {
      final page = await session.api!.ops.listTrash(
        widget.folderId,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total.toInt();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e, '回收站加载失败,请下拉重试');
        _loading = false;
      });
    }
  }

  /// 泛化的补齐加载(原 _loadMore):决策核心(整页在途/错误闸、失败闸
  /// force 放行、在途记 pending、全量加载短路)由 EnsurePlanner 决定
  /// (P2-3 抽取;pending 统一存裸 displayEnd,消费时再 + 一页余量换算
  /// 缺口),本页保留单批 fetch 策略与失败 UI。滚动到底/骨架命中/onSeek
  /// 三路都汇到这里。
  ///
  /// [force] = 显式用户动作(重试条点按 / 重新 seek):失败态也放行。
  /// 失败态(_loadMoreFailed)拦住自动触发——骨架行命中随每次重建重放,
  /// 不拦会形成「失败→重建→重试」风暴;失败后走重试条手动重试。
  Future<void> _ensureVisibleLoaded(
    int displayEnd, {
    bool force = false,
  }) async {
    final decision = EnsurePlanner.decide(
      window: _window,
      displayEnd: displayEnd,
      margin: _pageSize,
      loading: _loading,
      hasError: _error != null,
      loadMoreFailed: _loadMoreFailed,
      force: force,
      loadingMore: _loadingMore,
      pendingTarget: _pendingTarget,
    );
    switch (decision) {
      case EnsureIgnore():
        return;
      case EnsureRecordPending(displayEnd: final target):
        _pendingTarget = target; // 裸显示序;续补消费时再 + 一页余量
        return;
      case EnsureFetch(:final start, :final end):
        await _fetchGap(start, end);
    }
  }

  /// 拉取后端 offset 窗口 [start, end)(决策层已换算的缺口,恒 DESC 即
  /// offset=显示序;单批封顶 500,后端单窗口上限即 500)。失败置
  /// _loadMoreFailed + 清 pending + toast(重试条入口不变);成功后若在途
  /// 期间目标被推远则续批(有进展才续,无进展清 pending 防死循环;缺口
  /// 已尽时 gapFor 返回 null,空转返回)。
  Future<void> _fetchGap(int start, int end) async {
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    var progressed = false; // 本批合并是否有新增(决定是否续批,防死循环)
    try {
      final page = await session.api!.ops.listTrash(
        widget.folderId,
        limit: _pageSize,
        offset: start,
      );
      if (!mounted) return;
      setState(() {
        final before = _items.length;
        _mergeLoaded(page.items);
        progressed = _items.length > before;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
        _pendingTarget = null;
      });
      toast(context, errorMessage(e, '加载失败,请重试'), tone: ToastTone.error);
      return;
    }
    final pending = EnsurePlanner.nextRound(
      pendingTarget: _pendingTarget,
      progressed: progressed,
    );
    _pendingTarget = null;
    if (pending != null) {
      final gap = EnsurePlanner.gapFor(_window, pending, _pageSize);
      if (gap != null) await _fetchGap(gap.$1, gap.$2); // 缺口已尽时空转返回
    }
  }

  /// append + 按 id 去重兜底(D6:恢复/静默刷新与补齐并发时防重复行)。
  /// offset 天然对齐前提(P2-4/需求 D12,未观测到,记前提):在途响应反映
  /// 请求时点的后端状态——恢复提交前后端同步移除、补齐响应按请求时点切片,
  /// 拼接边界才能无缝;若后端在恢复提交后才计算响应窗口,拼接边界会缺一行
  /// 且尾行骨架永久残留。
  void _mergeLoaded(List<Asset> incoming) {
    final seen = <String>{for (final a in _items) a.id};
    for (final a in incoming) {
      if (seen.add(a.id)) _items.add(a);
    }
  }

  /// 骨架行命中 → 帧末补齐一次(post-frame,不在 build 期 setState;
  /// 在途/无缺口由守卫挡住,逐行命中不会风暴)。
  void _scheduleEnsureFromSkeleton(int displayIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureVisibleLoaded(displayIndex + 1);
    });
  }

  Future<void> _restore(Asset a) async {
    setState(() => _restoringId = a.id);
    try {
      await session.api!.ops.restore(a.id);
      AppLog.info('trash', '已恢复:${a.filename} → ${widget.folderName}');
      if (!mounted) return;
      setState(() {
        _items.removeWhere((x) => x.id == a.id);
        _total = (_total - 1).clamp(0, 1 << 31);
        _restoringId = '';
        // 窗口模型随派生值更新:前后端同步移除,offset 天然对齐(F4)。
      });
      notifyAssetMutation(widget.folderId); // 列表计数恢复 → 宫格+folders 刷新
      toast(
        context,
        '「${a.filename}」已恢复至 ${widget.folderName}',
        tone: ToastTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoringId = '');
      toast(context, errorMessage(e, '恢复失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '回收站 · ${widget.folderName}',
            subtitle: _total > 0 ? '共 $_total 个已删除文件' : null,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? ErrorView(message: _error!, onRetry: _refresh)
                : _items.isEmpty
                ? const EmptyState(
                    icon: Icons.delete_outline,
                    message: '回收站是空的',
                    description: '删除的素材会暂存在这里,可随时恢复。',
                  )
                : _list(context),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    // 滚动条显隐(D4):total≥100;loading/error/empty 三态根本走不到
    // 本方法,天然无滚动条。
    final barVisible = _total >= _barMinItems;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.separated(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    Tk.spacePage,
                    Tk.spaceMd,
                    Tk.spacePage,
                    Tk.spaceXl,
                  ),
                  itemCount: _total,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: Tk.spaceSm),
                  itemBuilder: (context, i) {
                    final a = _window.assetAt(i, _items);
                    if (a == null) {
                      // 未加载区:骨架行 + 帧末补齐(F4;不可点/不可恢复)。
                      _scheduleEnsureFromSkeleton(i);
                      return const TrashRowSkeleton(
                        key: Key('trash_row_skeleton'),
                      );
                    }
                    return AppCard(
                      padding: EdgeInsets.zero,
                      child: AppRow(
                        leading: Icon(
                          trashKindIcon(
                            filename: a.filename,
                            contentType: a.contentType,
                          ),
                        ),
                        title: a.filename,
                        subtitle:
                            '${fmtBytes(a.sizeBytes)} · 删除于 ${a.deletedAt == null ? '—' : fmtDate(a.deletedAt!)}',
                        showChevron: false,
                        trailing: _restoringId == a.id
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.restore_outlined),
                                tooltip: '恢复到文件夹',
                                onPressed: () => _restore(a),
                              ),
                      ),
                    );
                  },
                ),
              ),
              // 右缘滚动条(F2):Positioned 钉满右缘高,FastScrollBar 自身
              // 吃 28 热区;visible=false 时组件内部渲染 shrink。
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: FastScrollBar(
                  controller: _scroll,
                  total: _total,
                  visible: barVisible,
                  // seek 是显式动作:失败态也重试(force)。
                  onSeek: (displayIndex) =>
                      _ensureVisibleLoaded(displayIndex + 1, force: true),
                ),
              ),
            ],
          ),
        ),
        if (_loadingMore) const LinearProgressIndicator(minHeight: 2),
        if (_loadMoreFailed && !_loadingMore) _retryBar(context),
      ],
    );
  }

  Widget _retryBar(BuildContext context) {
    final color = context.tk.danger;
    return InkWell(
      onTap: () => _ensureVisibleLoaded(_total, force: true),
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: Tk.spaceXs),
            Text(
              '加载失败,点击重试',
              style: TextStyle(fontSize: Tk.fzXs, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 回收站骨架行(F4/D7):未加载区灰条占位,静态无动画。骨面色取
/// ListSkeleton 同款 surface3;结构对齐 AppCard 行(34 图标底 + 标题 13 /
/// 副标题 11 双条),minHeight 56 与 AppRow 一致。
class TrashRowSkeleton extends StatelessWidget {
  const TrashRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    Widget bone({double? widthFactor, required double height}) {
      final block = Container(
        height: height,
        decoration: BoxDecoration(
          color: tk.surface3,
          borderRadius: BorderRadius.circular(Tk.rSm),
        ),
      );
      if (widthFactor == null) return block;
      return FractionallySizedBox(widthFactor: widthFactor, child: block);
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tk.surface3,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bone(height: 13),
                    const SizedBox(height: Tk.spaceSm),
                    bone(height: 11, widthFactor: 0.55),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
