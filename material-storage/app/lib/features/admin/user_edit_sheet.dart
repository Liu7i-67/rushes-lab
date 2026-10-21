/// 编辑用户表单(B8 功能点 2;web EditUserModal 移动版):详情回显后才可保存
/// (防空 group_ids 全量同步清光所属组——web 双保险同款);email 留空提交=
/// 显式 null 清空(D6),group_ids 全量同步(D3);登录名只读。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'admin_form_skeleton.dart';
import 'group_multi_select.dart';

/// 打开编辑表单;返回是否成功提交(调用方据此刷新列表)。
Future<bool> showEditUserSheet(BuildContext context, DirectoryUser user) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _EditUserSheet(user: user),
  );
  return ok ?? false;
}

class _EditUserSheet extends StatefulWidget {
  const _EditUserSheet({required this.user});

  final DirectoryUser user;

  @override
  State<_EditUserSheet> createState() => _EditUserSheetState();
}

class _EditUserSheetState extends State<_EditUserSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.user.name);
  late final TextEditingController _email =
      TextEditingController(text: widget.user.email ?? '');
  List<DirectoryGroup> _groups = const [];
  DirectoryUserDetail? _detail;
  String? _error;
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await session.api!.directory.getUser(widget.user.id);
      if (!mounted) return;
      final all = await session.api!.directory.listGroups(limit: 200);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _groups = all.where((g) => d.groupIds.contains(g.id)).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '详情加载失败,请关闭后重试(未回显前不可保存)');
    }
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final err = requiredValidator(name);
    if (err != null || _submitting) {
      if (err != null) setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await session.api!.directory.updateUser(
        widget.user.id,
        name: name,
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        groupIds: [for (final g in _groups) g.id],
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 422 invalid_group_ids 透传
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '保存失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return FormSkeleton(
      title: '编辑用户 — ${widget.user.name}',
      submitLabel: '保存',
      submitting: _submitting,
      onSubmit: _submit,
      error: _error,
      submitEnabled: detail != null,
      children: [
        if (detail == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          Text('登录名:${detail.username ?? '—'}(创建后不可改)',
              style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          const SizedBox(height: 10),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: '姓名', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: '邮箱',
              helperText: '留空提交 = 清空邮箱',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          GroupMultiSelect(
            value: _groups,
            onChanged: (v) => setState(() => _groups = v),
          ),
          const SizedBox(height: 6),
          const Text('保存按此处勾选全量同步;移出组将立即失去该组授予的全部权限',
              style: TextStyle(fontSize: Tk.fzXs, color: Tk.muted)),
        ],
      ],
    );
  }
}
