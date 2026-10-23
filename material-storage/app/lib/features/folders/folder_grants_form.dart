/// FolderGrantForm — 普通一级夹 grant 添加表单(B6;F7):SubjectPicker +
/// 多 level chips(一次授多 level;**无有效期控件**,后端只收 levels+主体
/// 恒永久),多主体逐个 POST。chips 用 AppChip,吸底 ghost 返回 + 金主添加。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/toast.dart';

/// grant level 枚举与展示(web LEVEL_META/LEVEL_ORDER 同款:上传/下载/查看)。
const kGrantLevels = <(String, String)>[
  ('uploader', '上传'),
  ('downloader', '下载'),
  ('viewer', '查看'),
];

String grantLevelLabel(String level) => kGrantLevels
    .firstWhere((o) => o.$1 == level, orElse: () => (level, level))
    .$2;

class FolderGrantForm extends StatefulWidget {
  const FolderGrantForm({
    super.key,
    required this.folder,
    required this.onDone,
  });

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
      toast(
        context,
        '已为 $ok 个主体添加授权${fail > 0 ? ' · 失败 $fail' : ''}',
        tone: ToastTone.success,
      );
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '添加失败');
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final labelStyle = TextStyle(fontSize: Tk.fzMd, color: tk.ink3);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '添加 grant → ${widget.folder.name}',
          style: TextStyle(
            fontSize: Tk.fzRowTitle,
            fontWeight: FontWeight.w600,
            color: tk.ink,
          ),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text('主体(用户 / 用户组)', style: labelStyle),
        SubjectPicker(
          value: _subjects,
          onChanged: (v) => setState(() {
            _subjects = v;
            _error = null;
          }),
          preset: mePreset(),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text('权限(可多选,一次授予;恒永久)', style: labelStyle),
        const SizedBox(height: Tk.spaceXs),
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceSm,
          children: [
            for (final (value, label) in kGrantLevels)
              AppChip(
                label: label,
                selected: _levels.contains(value),
                onTap: () => setState(() {
                  if (!_levels.remove(value)) {
                    _levels.add(value);
                  }
                  _levels = {..._levels};
                }),
              ),
          ],
        ),
        if (_levels.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceXs),
            child: Text(
              '至少勾选一个权限',
              style: TextStyle(fontSize: Tk.fzMd, color: tk.warn),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceSm),
            child: Text(
              _error!,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
            ),
          ),
        const SizedBox(height: Tk.spaceLg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onDone,
                child: const Text('返回'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryXl(
                onPressed: _submitting ? null : _submit,
                label: _submitting ? '添加中…' : '添加',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
