/// PreviewPage — 预览页(墨色 + 金色,固定暗色画布 §4.3 / F9):暗色画布 +
/// 顶部 chrome(关闭 / n / N / 更多)+ 胶片条 + 元数据浮层 + 五项操作行;
/// 单击沉浸、横滑切张、浅色状态栏;下载入队 2s 就地反馈,详情为 F9
/// PreviewDetailSheet;canDownload=null 时经单夹详情补水(P1-3),且按当前素材
/// 的 folderId 逐夹解析(搜索跨文件夹结果,第二轮复验 P1)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/haptics.dart';
import '../../models/models.dart';
import '../../services/downloads.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import '../assets/batch_tag_sheet.dart';
import '../share/share_create_sheet.dart';
import 'filmstrip.dart';
import 'preview_chrome.dart';
import 'preview_detail_sheet.dart';
import 'preview_media.dart';
import 'preview_permissions.dart';
import 'request_access_sheet.dart';

/// 路由参数:列表序列 + 起点 + 下载权三态(bool=可信值;null=未到/失败)+ where。
/// [folderIds]/[wheres] 为逐素材上下文(asset.id → folderId / 展示路径),供
/// 搜索跨文件夹结果按当前素材取值;null=整组沿用 [folderId]/[where](旧入口)。
class PreviewArgs {
  PreviewArgs({
    required this.items,
    required this.index,
    required this.folderId,
    required this.canDownload,
    this.where,
    this.folderIds,
    this.wheres,
  });

  final List<Asset> items;
  final int index;
  final String folderId;
  final bool? canDownload;
  final String? where;
  final Map<String, String>? folderIds;
  final Map<String, String>? wheres;
}

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.args});

  final PreviewArgs args;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late final FilmstripPager _pager = FilmstripPager(
    length: widget.args.items.length,
    initial: widget.args.index,
  );

  Asset get _current => widget.args.items[_pager.index];

  /// 逐素材下载权解析(单夹详情补水;搜索跨文件夹结果按当前张 folderId)。
  late final _permissions = PreviewPermissions(
    folderIds: widget.args.folderIds,
    wheres: widget.args.wheres,
    folderId: widget.args.folderId,
    where: widget.args.where,
    canDownload: widget.args.canDownload,
  );

  // 横滑切张位移累计/放大态(PreviewMedia 回报)与沉浸态(单击切换,chrome 收合)
  var _swipeDx = 0.0, _mediaZoomed = false, _immersive = false;

  // 已入队就地态(asset.id 集合;2s 后复原,防重复入队窗口)
  final _queuedIds = <String>{}, _queuedTimers = <String, Timer>{};

  @override
  void initState() {
    super.initState();
    _permissions.addListener(_onPermissionsChanged);
    _permissions.ensure(_current);
  }

  /// 下载权解析完成(成功/失败均落缓存)后重建页面。
  void _onPermissionsChanged() {
    if (mounted) setState(() {});
  }

  void _go(bool forward) {
    final moved = forward ? _pager.next() : _pager.prev(); // 边界即停
    if (moved) _onPageSwitched();
  }

  /// 切张(横滑/胶片条跳张)统一复位横滑与缩放态,防跳张后横滑失活。
  void _onPageSwitched() {
    _swipeDx = 0;
    if (_mediaZoomed) {
      setState(() => _mediaZoomed = false);
    } else {
      setState(() {});
    }
    _permissions.ensure(_current); // 跨文件夹:切到未解析的夹时补水下载权
  }

  /// 单指左滑→next/右滑→prev(位移或速度过阈值任一即触发);放大态不切
  /// (双保险);图片分支经 PreviewMedia.onSwipe 内层路上报,两路不双触发。
  void _onSwipeEnd(DragEndDetails d) {
    final dx = _swipeDx;
    _swipeDx = 0;
    if (_mediaZoomed) return;
    final v = d.velocity.pixelsPerSecond.dx;
    if (dx < -kSwipeDistanceThreshold || v < -kSwipeVelocityThreshold) {
      _go(true);
    } else if (dx > kSwipeDistanceThreshold || v > kSwipeVelocityThreshold) {
      _go(false);
    }
  }

  /// 沉浸切换(状态栏由外层 AnnotatedRegion 恒保持浅色图标)。
  void _toggleImmersive() {
    Haptics.light();
    setState(() => _immersive = !_immersive);
  }

  /// 下载当前张:入队即回,按钮就地转「已入队 ✓」2s 复原。
  void _downloadCurrent() {
    final asset = _current;
    try {
      enqueueDownload(
        asset: asset,
        where: _permissions.whereOf(asset) ?? _permissions.folderIdOf(asset),
      );
    } catch (e) {
      toast(context, errorMessage(e, '下载任务创建失败,请稍后重试'), tone: ToastTone.error);
      return;
    }
    Haptics.light();
    setState(() => _queuedIds.add(asset.id));
    // P2-8:按资产 id 各持一个计时器,连下 A/B 互不取消复位。
    _queuedTimers.remove(asset.id)?.cancel();
    _queuedTimers[asset.id] = Timer(const Duration(seconds: 2), () {
      _queuedTimers.remove(asset.id);
      if (!mounted) return;
      setState(() => _queuedIds.remove(asset.id));
    });
  }

  /// 分享当前张:单资产 share_create_sheet(有效期四档)。
  Future<void> _shareCurrent() => showShareSheet(
    context,
    kind: 'asset',
    targetId: _current.id,
    targetLabel: _current.filename,
  );

  /// 申请权限:下载权=false 时入口可点(后端 403 最终裁决)。
  Future<void> _requestAccess() => showRequestAccessSheet(
    context,
    targetType: 'asset',
    targetId: _current.id,
    targetName: _current.filename,
  );

  /// 详情面板(F9):文件名/类型/大小/时间/位置/标签/备注。
  Future<void> _showDetail() => showPreviewDetailSheet(
    context,
    asset: _current,
    where: _permissions.whereOf(_current) ?? _permissions.folderIdOf(_current),
  );

  /// 顶部「更多」:详情 / 分享 / 申请权限(已知无权时)。
  Future<void> _showMore() async {
    final action = await showPreviewMoreSheet(
      context,
      canRequest: _permissions.canDownloadFor(_current) == false,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case PreviewMoreAction.detail:
        await _showDetail();
      case PreviewMoreAction.share:
        await _shareCurrent();
      case PreviewMoreAction.request:
        await _requestAccess();
    }
  }

  /// 打标面板:保存后回填当前张即时生效;宫格侧由 `assets:<folderId>` 失效刷新。
  Future<void> _editMeta() async {
    final updated = await showTagEditSheet(
      context,
      asset: _current,
      folderId: _permissions.folderIdOf(_current),
    );
    if (updated != null && mounted) {
      setState(() => widget.args.items[_pager.index] = updated);
    }
  }

  @override
  void dispose() {
    _permissions.removeListener(_onPermissionsChanged);
    _permissions.dispose();
    for (final timer in _queuedTimers.values) {
      timer.cancel();
    }
    _queuedTimers.clear();
    super.dispose();
  }

  /// 沉浸收合容器——Offstage 树上不可见,AnimatedSize/Opacity 过渡与淡入。
  Widget _chrome({required bool top, required Widget child}) {
    return PreviewChromeSlot(top: top, immersive: _immersive, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.args.items.length;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 预览画布恒暗:状态栏透明 + 浅色图标(沉浸态同样口径);退出路由时
      // 由目的页的 AnnotatedRegion/AppBar 自动恢复。
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Tk.previewBg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Tk.previewBg,
        body: Column(
          children: [
            _chrome(
              top: true,
              child: PreviewTopBar(
                index: _pager.index,
                total: total,
                onClose: () => Navigator.of(context).maybePop(),
                onMore: _showMore,
              ),
            ),
            Expanded(
              // 横滑切张挂 PreviewMedia 外层(视频/文档/失败卡统一走此路);
              // 放大态置空拖动回调,单指拖动完整交给 InteractiveViewer 平移。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: _mediaZoomed
                    ? null
                    : (_) => _swipeDx = 0,
                onHorizontalDragUpdate: _mediaZoomed
                    ? null
                    : (d) => _swipeDx += d.delta.dx,
                onHorizontalDragEnd: _mediaZoomed ? null : _onSwipeEnd,
                child: PreviewMedia(
                  key: ValueKey(_current.id),
                  asset: _current,
                  onSwipe: _go,
                  onZoomChanged: (z) {
                    if (_mediaZoomed != z) setState(() => _mediaZoomed = z);
                  },
                  onSingleTap: _toggleImmersive,
                ),
              ),
            ),
            _chrome(
              top: false,
              child: PreviewBottomChrome(
                items: widget.args.items,
                index: _pager.index,
                asset: _current,
                onSelect: (i) {
                  _pager.moveTo(i);
                  _onPageSwitched();
                },
                onEdit: _editMeta,
                onTag: _editMeta,
                onDetail: _showDetail,
                canDownload: _permissions.canDownloadFor(_current),
                downloadQueued: _queuedIds.contains(_current.id),
                onDownload: _downloadCurrent,
                onShare: _shareCurrent,
                onRequest: _requestAccess,
                onDisabledTap: (reason) {
                  Haptics.light();
                  toast(context, reason);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
