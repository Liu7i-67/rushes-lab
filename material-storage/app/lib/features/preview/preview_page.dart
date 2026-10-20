/// PreviewPage — 预览页(B2 §8.2):暗色画布(#141210)+ 顶部 ‹n/N› + 胶片条
/// (列表序列切张、边界即停)+ 底部元数据卡;B4 功能点 4①:下载钮点亮
/// (入队 TransferQueue kind=download,落盘矩阵见 services/downloads.dart);
/// B5 功能点 3/4:元数据卡「编辑」打标 + 分享/申请权限钮点亮。
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

  void _go(bool forward) {
    final moved = forward ? _pager.next() : _pager.prev(); // 边界即停
    if (moved) setState(() {});
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
            if (multi) ...[
              IconButton(
                onPressed: _pager.canPrev ? () => _go(false) : null,
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一个',
              ),
              Text(
                '${_pager.index + 1} / $total',
                style: const TextStyle(fontSize: 13),
              ),
              IconButton(
                onPressed: _pager.canNext ? () => _go(true) : null,
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一个',
              ),
            ],
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
            // 换 key 切张重建:预览态(视频/文本/失败卡)不串张(web 同哲学)
            child: PreviewMedia(
              key: ValueKey(_current.id),
              asset: _current,
            ),
          ),
          if (multi)
            Filmstrip(
              items: widget.args.items,
              index: _pager.index,
              onSelect: (i) => setState(() => _pager.moveTo(i)),
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
