/// PreviewPage — 预览页(B2 §8.2):暗色画布(#141210)+ 顶部 ‹n/N› + 胶片条
/// (列表序列切张、边界即停)+ 底部元数据卡;B4 功能点 4①:下载钮点亮
/// (入队 TransferQueue kind=download,落盘矩阵见 services/downloads.dart);
/// B5 功能点 3/4:元数据卡「编辑」打标 + 分享/申请权限钮点亮;
/// P3(mobile-ux-polish):去顶部左右切换钮,单指横滑切张。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/downloads.dart';
import '../../theme/tokens.dart';
import 'filmstrip.dart';
import 'meta_panel.dart';
import 'preview_actions.dart';
import 'preview_media.dart';
import 'request_access_sheet.dart';
import '../assets/batch_tag_sheet.dart';
import '../share/share_create_sheet.dart';

/// 路由参数:进入预览时的列表序列 + 起点 + 宫格页单夹详情的下载权
/// (三态:bool=详情可信值;null=详情未到/失败,提示退回中性口径)
/// + where 显示路径(下载任务归属,项目/文件夹)。
class PreviewArgs {
  PreviewArgs({
    required this.items,
    required this.index,
    required this.folderId,
    required this.canDownload,
    this.where,
  });

  final List<Asset> items;
  final int index;
  final String folderId;
  final bool? canDownload;
  final String? where;
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

  // P3(mobile-ux-polish):横滑切张的位移累计与放大态(PreviewMedia 回报)
  var _swipeDx = 0.0;
  var _mediaZoomed = false;

  void _go(bool forward) {
    final moved = forward ? _pager.next() : _pager.prev(); // 边界即停
    if (moved) _onPageSwitched();
  }

  /// P1-1(测试实证缺陷修复):切张(横滑/胶片条跳张)统一复位横滑与缩放态。
  /// 新 PreviewMedia 的 _zoomed 从 false 起步、不会再触发 onZoomChanged,若不
  /// 清 _mediaZoomed,外层拖动回调保持置空,跳张后横滑永久失活(复现:放大
  /// 图片张 → 胶片条跳非图片张 → 单指横滑不切页)。
  void _onPageSwitched() {
    _swipeDx = 0;
    if (_mediaZoomed) {
      setState(() => _mediaZoomed = false);
    } else {
      setState(() {});
    }
  }

  /// P3 横滑切张(外层路):单指左滑→next/右滑→prev(位移或速度过阈值任一
  /// 即触发,阈值口径与内层 InteractiveViewer 协作路一致);放大态不切
  /// (双保险);边界即停由 pager 保证。图片分支的横滑被 InteractiveViewer
  /// 的 scale 识别器持有,经 [PreviewMedia.onSwipe] 内层路上报,两路不双触发。
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

  /// 下载当前张(B4 功能点 4①):入队即回(进度/取消/重试在传输页),
  /// 完成去处 toast 由 worker 落盘后报(「已存入相册/Download/浣花视界」)。
  void _downloadCurrent() {
    enqueueDownload(
      asset: _current,
      where: widget.args.where ?? widget.args.folderId,
    );
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('已加入下载队列:${_current.filename}')),
    );
  }

  /// 分享当前张(B5 功能点 4):单资产 share_create_sheet(有效期四档,
  /// requires_login 恒 true,无提取码/下载开关)。
  Future<void> _shareCurrent() => showShareSheet(context,
      kind: 'asset',
      targetId: _current.id,
      targetLabel: _current.filename);

  /// 申请权限(B5 功能点 4):下载权=false 时入口可点(动作在 PreviewActions
  /// 闸门;后端 403 最终裁决)。
  Future<void> _requestAccess() => showRequestAccessSheet(context,
      targetType: 'asset',
      targetId: _current.id,
      targetName: _current.filename);

  /// 详情打标(B5 功能点 3):元数据卡「编辑」→ AssetTagEditor 移动版
  /// (单条不传 labels_mode,后端默认 replace);保存后回填当前张即时生效,
  /// 宫格侧由 `assets:<folderId>` 失效驱动静默刷新。
  Future<void> _editMeta() async {
    final updated = await showTagEditSheet(context,
        asset: _current, folderId: widget.args.folderId);
    if (updated != null && mounted) {
      setState(() => widget.args.items[_pager.index] = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.args.items.length;
    final multi = total > 1;
    return Scaffold(
      backgroundColor: Tk.dark,
      appBar: AppBar(
        backgroundColor: Tk.dark,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            // P3:去顶部左右切换钮(改横滑手势),保留 n / N 计数 + 文件名
            if (multi)
              Text(
                '${_pager.index + 1} / $total',
                style: const TextStyle(fontSize: 13),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _current.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            // P3:横滑切张挂 PreviewMedia 外层(视频/文档/失败卡等分支统一走
            // 这条路;单指横滑外层 HorizontalDrag 识别器先于内层 scale 识别器
            // 过 slop,arena 归外层)。放大态置空拖动回调(不注册识别器,不进
            // arena)——单指拖动完整交给 InteractiveViewer 平移;双指捏合缩放
            // 由内层 scale 识别器处理,不受影响。换 key 切张重建:预览态
            // (视频/文本/失败卡)不串张。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart:
                  _mediaZoomed ? null : (_) => _swipeDx = 0,
              onHorizontalDragUpdate:
                  _mediaZoomed ? null : (d) => _swipeDx += d.delta.dx,
              onHorizontalDragEnd: _mediaZoomed ? null : _onSwipeEnd,
              child: PreviewMedia(
                key: ValueKey(_current.id),
                asset: _current,
                onSwipe: _go,
                onZoomChanged: (z) {
                  if (_mediaZoomed != z) setState(() => _mediaZoomed = z);
                },
              ),
            ),
          ),
          if (multi)
            Filmstrip(
              items: widget.args.items,
              index: _pager.index,
              onSelect: (i) {
                _pager.moveTo(i);
                _onPageSwitched(); // P1-1:跳张同走切张收口,复位缩放态
              },
            ),
          MetaPanel(asset: _current, onEdit: _editMeta),
          PreviewActions(
            canDownload: widget.args.canDownload,
            onDownload: _downloadCurrent,
            onShare: _shareCurrent,
            onRequest: _requestAccess,
          ),
        ],
      ),
    );
  }
}
