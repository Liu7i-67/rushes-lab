/// PreviewPage — 预览页(B2 §8.2):暗色画布(#141210)+ 顶部 ‹n/N› + 胶片条
/// (列表序列切张、边界即停)+ 底部元数据卡;下载/分享/申请权限三钮占位禁用
/// (B4/B5 点亮);下载权=false 时下载钮附「申请权限」入口样式提示。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'filmstrip.dart';
import 'meta_panel.dart';
import 'preview_actions.dart';
import 'preview_media.dart';

/// 路由参数:进入预览时的列表序列 + 起点 + 宫格页单夹详情的下载权
/// (三态:bool=详情可信值;null=详情未到/失败,提示退回中性口径)。
class PreviewArgs {
  PreviewArgs({
    required this.items,
    required this.index,
    required this.folderId,
    required this.canDownload,
  });

  final List<Asset> items;
  final int index;
  final String folderId;
  final bool? canDownload;
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
          MetaPanel(asset: _current),
          PreviewActions(canDownload: widget.args.canDownload),
        ],
      ),
    );
  }
}
