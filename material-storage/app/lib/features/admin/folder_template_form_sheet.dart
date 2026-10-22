/// 目录模板表单拆件(B8 功能点 6;web TemplateFormModal 移动版):
/// 模板名/描述/条目行(项目根下相对路径,保存时全量替换,1..200 条)+
/// 前端路径校验(镜像后端 _validate_entry_paths 明显非法项,后端仍复检 422)+
/// 只读树预览(输入即所得,缩进列表呈现)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'admin_form_skeleton.dart';

/// 打开建/编目录模板表单;返回是否成功提交。
Future<bool> showFolderTemplateFormSheet(BuildContext context,
        {FolderTemplate? template}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FolderTemplateFormSheet(template: template),
  );
  return ok ?? false;
}

/// 单条路径前端校验(web pathErrorOf 同款;后端仍复检)。
String? folderTemplatePathError(String raw) {
  final p = raw.trim();
  if (p.isEmpty) return '路径为空';
  if (p.startsWith('/') || p.endsWith('/')) return '不能以 / 开头或结尾';
  final segs = p.split('/');
  if (segs.any((s) => s.isEmpty)) return '含空段(连续 //)';
  if (segs.length > 10) return '层级超 10 段';
  for (final s in segs) {
    if (s == '.' || s == '..') return '段「$s」非法';
    if (s.contains('\\')) return '段不能含反斜杠 \\';
    if (s != s.trim()) return '段「$s」首尾含空白';
    if (s.length > 255) return '单段超 255 字符';
  }
  if (p.length > 600) return '总长超 600 字符';
  return null;
}

/// paths → 树行(纯函数;「(深度, 名称)」缩进展示,去重节点计数与后端
/// 规则 7 同口径——各 path 按段展开去重)。
List<(int, String)> pathsToTreeRows(List<String> paths) {
  final seen = <String>{};
  final rows = <(int, String)>[];
  for (final path in paths) {
    var acc = '';
    for (final seg in path.split('/')) {
      acc = acc.isEmpty ? seg : '$acc/$seg';
      if (seen.add(acc)) rows.add((acc.split('/').length - 1, seg));
    }
  }
  return rows;
}

int dedupNodeCount(List<String> paths) => pathsToTreeRows(paths).length;

class _FolderTemplateFormSheet extends StatefulWidget {
  const _FolderTemplateFormSheet({this.template});

  final FolderTemplate? template;

  @override
  State<_FolderTemplateFormSheet> createState() =>
      _FolderTemplateFormSheetState();
}

class _FolderTemplateFormSheetState extends State<_FolderTemplateFormSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.template?.name ?? '');
  late final TextEditingController _desc =
      TextEditingController(text: widget.template?.description ?? '');
  late var _paths = <String>[
    for (final e in widget.template?.entries ?? const <FolderTemplateEntry>[])
      e.path,
  ];
  String? _error;
  var _submitting = false;

  bool get _isEdit => widget.template != null;

  Future<void> _addRow() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加目录'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '相对路径(以 / 分隔层级)',
            hintText: '素材/视频/原始',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('添加')),
        ],
      ),
    );
    if (path == null) return;
    final err = folderTemplatePathError(path);
    if (err != null) {
      setState(() => _error = '第 ${_paths.length + 1} 条:$err');
      return;
    }
    if (_paths.contains(path.trim())) {
      setState(() => _error = '路径重复:「${path.trim()}」');
      return;
    }
    setState(() {
      _error = null;
      _paths = [..._paths, path.trim()];
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入模板名');
      return;
    }
    if (_paths.isEmpty) {
      setState(() => _error = '请至少添加一个目录');
      return;
    }
    if (_paths.length > 200) {
      setState(() => _error = '目录条目不能超过 200 条');
      return;
    }
    for (var i = 0; i < _paths.length; i++) {
      final err = folderTemplatePathError(_paths[i]);
      if (err != null) {
        setState(() => _error = '第 ${i + 1} 行:$err');
        return;
      }
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final desc = _desc.text.trim();
    try {
      final api = session.api!.adminTemplates;
      if (_isEdit) {
        await api.updateFolderTemplate(
          widget.template!.id,
          name: name,
          // description 恒携带:空串传显式 null = 清空(P3-3;grant 表单同款三元,
          // web AdminFolderTemplatesPage 编辑态 `|| null` 同口径)
          description: desc.isEmpty ? null : desc,
          paths: _paths,
        );
      } else {
        await api.createFolderTemplate(
          name,
          description: desc.isEmpty ? null : desc,
          paths: _paths,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 重名/422 路径校验透传
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '提交失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final treeRows = pathsToTreeRows(_paths);
    // F5:内联骨架(限高 0.85 + 滚动 + 键盘避让 + 错误行 + 提交键)收口
    // FormSkeleton,与权限模板表单共用一处实现
    return FormSkeleton(
      title: _isEdit ? '编辑目录模板 — ${t!.name}' : '新建目录模板',
      submitLabel: _isEdit ? '保存' : '创建',
      submitting: _submitting,
      onSubmit: _submit,
      error: _error,
      maxHeightFactor: 0.85,
      children: [
        TextField(
          controller: _name,
          autofocus: !_isEdit,
          decoration: const InputDecoration(
              labelText: '模板名', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _desc,
          maxLength: 1024,
          decoration: const InputDecoration(
              labelText: '描述(可选)', border: OutlineInputBorder()),
        ),
        Text(
          '目录条目(${_paths.length}/200,每条为项目根下相对路径,'
          '保存时全量替换)',
          style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted),
        ),
        for (final (i, path) in _paths.indexed)
          ListTile(
            visualDensity: VisualDensity.compact,
            dense: true,
            leading: const Icon(Icons.folder_outlined, size: 18),
            title: Text(path, style: const TextStyle(fontSize: Tk.fzMd)),
            trailing: IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => setState(() {
                _paths = [..._paths]..removeAt(i);
              }),
            ),
          ),
        OutlinedButton.icon(
          onPressed: _addRow,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加目录'),
        ),
        // 只读树预览(输入即所得;web Tree 预览的移动简化)
        if (treeRows.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Tk.fill,
              borderRadius: BorderRadius.circular(Tk.rSm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '目录树预览 · ${_paths.length} 条路径 · '
                    '去重后 ${treeRows.length} 个目录',
                    style:
                        const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
                for (final (depth, seg) in treeRows)
                  Padding(
                    padding: EdgeInsets.only(left: depth * 14.0, top: 2),
                    child: Text('└ $seg',
                        style: const TextStyle(
                            fontSize: Tk.fzSm, color: Tk.muted)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
