/// NetdiskTreePickerPage — 百度网盘目录树选择器(B9 §8.10):懒加载=展开拉
/// 子级,loading/空/错误态齐全;文件行灰显不可选;truncated 提示「目录过大」;
/// 点选目录金色浅底高亮,页首勾选返回路径(根目录不可作源)。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';

Future<String?> showNetdiskTreePicker(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const NetdiskTreePickerPage()),
    );

class NetdiskNode {
  NetdiskNode(this.entry);

  final BaiduNetdiskEntry entry;
  List<NetdiskNode>? children;
  var expanded = false;
  var loading = false;
  String? error;
  var truncated = false;
}

class NetdiskTreePickerPage extends StatefulWidget {
  const NetdiskTreePickerPage({super.key, this.api});

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
        setState(() {
          node.loading = false;
          node.error = errorMessage(e, '读取网盘子目录失败');
        });
      }
    } else {
      setState(() => node.expanded = true);
    }
  }

  List<Widget> _rows(
    BuildContext context,
    List<NetdiskNode> nodes,
    int depth,
  ) => [
    for (final n in nodes)
      if (n.entry.isDir) ...[
        _dirRow(context, n, depth),
        if (n.expanded && n.children != null)
          ..._rows(context, n.children!, depth + 1),
      ] else
        _fileRow(context, n.entry, depth),
  ];

  Widget _fileRow(BuildContext context, BaiduNetdiskEntry e, int depth) {
    final tk = context.tk;
    final style = TextStyle(fontSize: Tk.fzMd, color: tk.ink3);
    return ListTile(
      contentPadding: EdgeInsets.only(left: 12.0 + depth * 16, right: 12),
      enabled: false,
      leading: Icon(Icons.insert_drive_file_outlined, size: 18, color: tk.ink3),
      title: Text(
        e.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
      trailing: Text(
        fmtBytes(e.sizeBytes ?? 0),
        style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
      ),
    );
  }

  Widget _dirRow(BuildContext context, NetdiskNode n, int depth) {
    final tk = context.tk;
    final e = n.entry;
    final selected = _selected == e.path;
    final icon = n.error != null
        ? Icons.error_outline
        : n.expanded
        ? Icons.folder_open_outlined
        : Icons.folder_outlined;
    final iconColor = n.error != null
        ? tk.danger
        : selected
        ? tk.goldInk
        : tk.ink2;
    final subtitle = n.loading
        ? Text(
            '加载中…',
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          )
        : n.error == null
        ? null
        : Text(
            n.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: Tk.fzXs, color: tk.danger),
          );
    return Column(
      children: [
        ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          contentPadding: EdgeInsets.only(left: 12.0 + depth * 16, right: 4),
          leading: Icon(icon, size: 20, color: iconColor),
          title: Text(
            e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: Tk.fzRowTitle,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? tk.goldInk : tk.ink,
            ),
          ),
          subtitle: subtitle,
          trailing: IconButton(
            tooltip: n.expanded ? '收起' : '展开',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              n.expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
            ),
            onPressed: () => _toggle(n),
          ),
          tileColor: selected ? tk.goldSoft : null,
          onTap: () {
            setState(() => _selected = e.path);
            if (!n.expanded) _toggle(n);
          },
        ),
        if (n.truncated && n.expanded)
          _truncatedHint(context, 28.0 + depth * 16),
      ],
    );
  }

  Widget _truncatedHint(BuildContext context, double left) {
    final tk = context.tk;
    return Padding(
      padding: EdgeInsets.fromLTRB(left, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '目录过大,仅显示部分内容',
          style: TextStyle(
            fontSize: Tk.fzXs,
            color: tk.warn,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final canConfirm = _selected != null && _selected != '/';
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '选择网盘目录',
            actions: [
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: _loadRoot,
              ),
              IconButton(
                tooltip: '确定',
                icon: const Icon(Icons.check),
                onPressed: canConfirm
                    ? () => Navigator.of(context).pop(_selected)
                    : null,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _selected == null ? '未选择(点选目录;不支持整盘根目录)' : '已选来源:$_selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  color: _selected == null ? tk.ink3 : tk.goldInk,
                ),
              ),
            ),
          ),
          Divider(height: Tk.spaceLg, color: tk.line),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_rootError != null) {
      return ErrorView(message: _rootError!, onRetry: _loadRoot);
    }
    final roots = _roots;
    if (roots == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (roots.isEmpty) {
      return const EmptyState(message: '网盘为空或读取失败');
    }
    return ListView(
      padding: const EdgeInsets.all(Tk.spaceSm),
      children: [
        ..._rows(context, roots, 0),
        if (_rootTruncated) _truncatedHint(context, 28),
      ],
    );
  }
}
