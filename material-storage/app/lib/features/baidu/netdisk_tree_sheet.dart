/// NetdiskTreePickerPage — 百度网盘目录树选择器(B9 §8.10,web
/// BaiduNewTaskModal 左栏移动版):懒加载=展开拉子级
/// (GET /baidu/backup/netdisk/folders?path=),loading/空/错误态齐全(错误可
/// 重试,不置 loaded 死态);文件行灰显不可选(「选目录创建任务」语义);
/// truncated 追加「目录过大」提示行;点选目录高亮,AppBar 勾选返回路径
/// (根目录不可作源——web 同口径)。刷新=重挂树。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';

/// 打开选择器;返回选定网盘目录绝对路径(取消/未选返回 null)。
Future<String?> showNetdiskTreePicker(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const NetdiskTreePickerPage()),
  );
}

/// 树节点状态(懒加载:children=null=未拉取;error!=null=拉取失败可重试)。
class NetdiskNode {
  NetdiskNode(this.entry);

  final BaiduNetdiskEntry entry;
  List<NetdiskNode>? children;
  var expanded = false;
  var loading = false;
  String? error;
  var truncated = false;
}

/// 展开后的可见行(node, depth)。
typedef NetdiskRow = (NetdiskNode, int);

class NetdiskTreePickerPage extends StatefulWidget {
  const NetdiskTreePickerPage({super.key, this.api});

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  @override
  State<NetdiskTreePickerPage> createState() => _NetdiskTreePickerPageState();
}

class _NetdiskTreePickerPageState extends State<NetdiskTreePickerPage> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;

  List<NetdiskNode>? _roots;
  var _rootTruncated = false;
  String? _rootError;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  Future<void> _loadRoot() async {
    setState(() {
      _roots = null;
      _rootError = null;
      _rootTruncated = false;
      _selected = null;
    });
    try {
      final r = await _api.netdiskFolders('/');
      if (!mounted) return;
      setState(() {
        _roots = [for (final e in r.list) NetdiskNode(e)];
        _rootTruncated = r.truncated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _rootError = errorMessage(e, '读取百度网盘目录失败'));
    }
  }

  /// 展开/收起;首次展开拉子级(文件行不进树;错误态留重试不标记已加载)。
  Future<void> _toggle(NetdiskNode node) async {
    if (node.loading) return;
    if (node.expanded) {
      setState(() => node.expanded = false);
      return;
    }
    if (node.children == null) {
      setState(() {
        node.loading = true;
        node.error = null;
      });
      try {
        final r = await _api.netdiskFolders(node.entry.path);
        if (!mounted) return;
        setState(() {
          node.loading = false;
          node.children = [for (final e in r.list) NetdiskNode(e)];
          node.truncated = r.truncated;
          node.expanded = true;
        });
      } catch (e) {
        if (!mounted) return;
        // 不置 children:节点保持未加载,重试点开再拉
        setState(() {
          node.loading = false;
          node.error = errorMessage(e, '读取网盘子目录失败');
        });
      }
    } else {
      setState(() => node.expanded = true);
    }
  }

  /// 深度优先铺平可见行(折叠子树跳过;文件行灰显不可选,web 同「选目录
  /// 创建任务」语义)。
  List<Widget> _rows(List<NetdiskNode> nodes, int depth) => [
        for (final n in nodes)
          if (n.entry.isDir) ...[
            _dirRow(n, depth),
            if (n.expanded && n.children != null)
              ..._rows(n.children!, depth + 1),
          ] else
            _fileRow(n.entry, depth),
      ];

  /// 文件行:仅展示不可选(灰显+大小;web FileTypeIcon 语义收敛为通用图标)。
  Widget _fileRow(BaiduNetdiskEntry e, int depth) => ListTile(
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.only(left: 12.0 + depth * 16, right: 8),
        enabled: false,
        leading: const Icon(Icons.insert_drive_file_outlined,
            size: 18, color: Tk.subtle),
        title: Text(e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Tk.subtle)),
        trailing: Text(fmtBytes(e.sizeBytes ?? 0),
            style: const TextStyle(fontSize: 11, color: Tk.subtle)),
      );

  Widget _dirRow(NetdiskNode n, int depth) {
    final e = n.entry;
    final selected = _selected == e.path;
    return Column(
      children: [
        ListTile(
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.only(left: 12.0 + depth * 16, right: 8),
          leading: Icon(
            n.error != null
                ? Icons.error_outline
                : n.expanded
                    ? Icons.folder_open_outlined
                    : Icons.folder_outlined,
            size: 20,
            color: n.error != null ? Tk.red : Tk.muted,
          ),
          title: Text(e.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5,
                  color: selected ? Tk.accentStrong : Tk.fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
          subtitle: n.loading
              ? const Text('加载中…', style: TextStyle(fontSize: 11))
              : n.error != null
                  ? Text(n.error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Tk.red))
                  : null,
          trailing: IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
                n.expanded
                    ? Icons.expand_less
                    : Icons.expand_more,
                size: 20),
            onPressed: () => _toggle(n),
          ),
          tileColor: selected ? Tk.accentFaint : null,
          onTap: () {
            // 点行=选定来源;子目录未加载时顺带展开(web 树点选/展开同位)
            setState(() => _selected = e.path);
            if (!n.expanded) _toggle(n);
          },
        ),
        if (n.truncated && n.expanded)
          Padding(
            padding: EdgeInsets.only(left: 28.0 + depth * 16, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('目录过大,仅显示部分内容',
                  style: TextStyle(fontSize: 11, color: Tk.amber,
                      fontStyle: FontStyle.italic)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择网盘目录'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loadRoot,
          ),
          IconButton(
            tooltip: '确定',
            icon: const Icon(Icons.check),
            onPressed: _selected == null || _selected == '/'
                ? null
                : () => Navigator.of(context).pop(_selected),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _selected == null
                    ? '未选择(点选目录;不支持整盘根目录)'
                    : '已选来源:$_selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: _selected == null ? Tk.subtle : Tk.accentStrong),
              ),
            ),
          ),
          const Divider(height: 16),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_rootError != null) {
      return ErrorView(message: _rootError!, onRetry: _loadRoot);
    }
    final roots = _roots;
    if (roots == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (roots.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('网盘为空或读取失败,可点右上刷新',
              style: TextStyle(fontSize: 13, color: Tk.muted)),
          const SizedBox(height: 8),
          TextButton(onPressed: _loadRoot, child: const Text('重试')),
        ]),
      );
    }
    return ListView(children: [
      ..._rows(roots, 0),
      if (_rootTruncated)
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('目录过大,仅显示部分内容',
                style: TextStyle(
                    fontSize: 11,
                    color: Tk.amber,
                    fontStyle: FontStyle.italic)),
          ),
        ),
    ]);
  }
}
