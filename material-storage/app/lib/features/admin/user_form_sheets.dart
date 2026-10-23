/// 建号表单(B8 功能点 2;web CreateUserModal 移动版):登录名(提交后不可改,
/// web 同款 pattern)/姓名/邮箱(可选)/用户组多选(可留空)。201 响应携带
/// 一次性临时密码,交调用方经 TempPasswordSheet 回显一次。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/form_text_field.dart';
import 'admin_form_skeleton.dart';
import 'group_multi_select.dart';

/// web CreateUserModal 用户名规则同款(仅字母/数字/._- 组成,2-64)。
final RegExp kDirectoryUsernamePattern = RegExp(r'^[a-zA-Z0-9._-]+$');

/// 打开建号表单;返回创建结果(调用方据此展示临时密码+刷新列表)。
Future<DirectoryUserCreated?> showCreateUserSheet(BuildContext context) =>
    showModalBottomSheet<DirectoryUserCreated>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _CreateUserSheet(),
    );

class _CreateUserSheet extends StatefulWidget {
  const _CreateUserSheet();

  @override
  State<_CreateUserSheet> createState() => _CreateUserSheetState();
}

class _CreateUserSheetState extends State<_CreateUserSheet> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  var _groups = <DirectoryGroup>[];
  String? _error;
  var _submitting = false;

  Future<void> _submit() async {
    final username = _username.text.trim();
    final name = _name.text.trim();
    final err =
        requiredValidator(username, min: 2, max: 64) ??
        (kDirectoryUsernamePattern.hasMatch(username)
            ? null
            : '仅字母/数字/._- 组成') ??
        requiredValidator(name);
    if (err != null || _submitting) {
      if (err != null) setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final out = await session.api!.directory.createUser(
        username: username,
        name: name,
        email: _email.text.trim(),
        groupIds: [for (final g in _groups) g.id],
      );
      if (!mounted) return;
      Navigator.of(context).pop(out);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 重名 / 422 invalid_group_ids 透传
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '创建失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return FormSkeleton(
      title: '新建本地用户',
      submitLabel: '创建',
      submitting: _submitting,
      onSubmit: _submit,
      error: _error,
      children: [
        AppTextField(
          controller: _username,
          label: '登录名(拼音/工号,登录用)',
          hint: '提交后不可改;本地用户无飞书身份,登录名是唯一标识',
        ),
        const SizedBox(height: 10),
        AppTextField(controller: _name, label: '姓名'),
        const SizedBox(height: 10),
        AppTextField(
          controller: _email,
          label: '邮箱(可选)',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 10),
        GroupMultiSelect(
          value: _groups,
          onChanged: (v) => setState(() => _groups = v),
        ),
        const SizedBox(height: 6),
        Text(
          '创建成功后会显示一次性临时密码,用户首次登录需改密。',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
      ],
    );
  }
}
