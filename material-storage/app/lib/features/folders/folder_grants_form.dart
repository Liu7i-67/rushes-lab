/// FolderGrantForm — 普通一级夹 grant 添加表单(B6;自 folder_grants_sheet.dart
/// 拆分):SubjectPicker + 多 level chips(一次授多 level;**无有效期控件**,
/// 后端只收 levels+主体恒永久),多主体逐个 POST。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/subject_picker.dart';

/// grant level 枚举与展示(web LEVEL_META/LEVEL_ORDER 同款:上传/下载/查看)。
const kGrantLevels = <(String, String)>[
  ('uploader', '上传'),
  ('downloader', '下载'),
  ('viewer', '查看'),
];

String grantLevelLabel(String level) =>
    kGrantLevels.firstWhere((o) => o.$1 == level,
        orElse: () => (level, level)).$2;

class FolderGrantForm extends StatefulWidget {
  const FolderGrantForm({super.key, required this.folder, required this.onDone});

  final Folder folder;
  final VoidCallback onDone;

  @override
  State<FolderGrantForm> createState() => _FolderGrantFormState();
}

class _FolderGrantFormState extends State<FolderGrantForm> {
  var _subjects = const <Subject>[];
  var _levels = <String>{'viewer'}; // 默认勾「查看」(web useState(['viewer']))
  var _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_subjects.isEmpty) {
      setState(() => _error = '请选至少一个主体');
      return;
    }
    if (_levels.isEmpty) {
      setState(() => _error = '请至少勾选一个权限');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final levels = [
      for (final (value, _) in kGrantLevels)
        if (_levels.contains(value)) value,
    ];
    var ok = 0;
    var fail = 0;
    String? firstError;
    for (final s in _subjects) {
      try {
        await session.api!.foldersOps.addGrant(
          widget.folder.id,
          userId: s.kind == SubjectKind.user ? s.id : null,
          groupId: s.kind == SubjectKind.group ? s.id : null,
          levels: levels,
        );
        ok++;
      } catch (e) {
        fail++;
        firstError ??= '${s.name}: $e';
      }
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(
              '已为 $ok 个主体添加授权${fail > 0 ? ' · 失败 $fail' : ''}')));
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '添加失败');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加 grant → ${widget.folder.name}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text('主体(用户 / 用户组)',
                style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
            SubjectPicker(
              value: _subjects,
              onChanged: (v) => setState(() {
                _subjects = v;
                _error = null;
              }),
              preset: mePreset(),
            ),
            const SizedBox(height: 12),
            const Text('权限(可多选,一次授予;恒永久)',
                style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in kGrantLevels)
                  FilterChip(
                    label: Text(label),
                    selected: _levels.contains(value),
                    onSelected: (_) => setState(() {
                      if (!_levels.remove(value)) {
                        _levels.add(value);
                      }
                      _levels = {..._levels};
                    }),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (_levels.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('至少勾选一个权限',
                    style: TextStyle(fontSize: Tk.fzXs, color: Tk.amber)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: Tk.fzSm)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : widget.onDone,
                  child: const Text('返回'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? '添加中…' : '添加'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
