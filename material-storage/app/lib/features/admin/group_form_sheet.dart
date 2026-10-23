/// 用户组建/编表单(B8 功能点 3;web GroupFormModal 移动版):名称/描述/
/// 组级开关(建组态四开关随表单提交;编辑态五开关 tri-state——仅改动过才随
/// PATCH 携带,directory.py None=不动防静默撤权);艺人账号子开关随父开关联动。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/form_text_field.dart';
import 'admin_form_skeleton.dart';

/// 打开建/编组表单;返回是否成功提交。
Future<bool> showGroupFormSheet(
  BuildContext context, {
  DirectoryGroup? group,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GroupFormSheet(group: group),
  );
  return ok ?? false;
}

class _GroupFormSheet extends StatefulWidget {
  const _GroupFormSheet({this.group});

  final DirectoryGroup? group;

  @override
  State<_GroupFormSheet> createState() => _GroupFormSheetState();
}

class _GroupFormSheetState extends State<_GroupFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.group?.name ?? '',
  );
  late final TextEditingController _desc = TextEditingController(
    text: widget.group?.description ?? '',
  );
  late final _flags = <String, bool>{
    'can_create_project': widget.group?.canCreateProject ?? false,
    'can_delete_project': widget.group?.canDeleteProject ?? false,
    'can_manage_folder_templates':
        widget.group?.canManageFolderTemplates ?? false,
    'can_create_artist_account': widget.group?.canCreateArtistAccount ?? false,
    'can_delete_files': widget.group?.canDeleteFiles ?? false,
  };

  /// tri-state:仅改动过的开关随 PATCH 携带(建组态 = 全部按表单值携带)。
  final _touched = <String>{};
  String? _error;
  var _submitting = false;

  bool get _isEdit => widget.group != null;

  void _setFlag(String key, bool v) {
    setState(() {
      _flags[key] = v;
      _touched.add(key);
      // 父开关 true→false 转变瞬间复位子开关并显式携带 false 清 tuple
      // (web GroupFormModal onChange 同款;勿改成 watch+effect 形态)
      if (key == 'can_create_project' && !v) {
        _flags['can_create_artist_account'] = false;
        _touched.add('can_create_artist_account');
      }
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) {
      if (name.isEmpty) setState(() => _error = '请输入组名');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = session.api!.directory;
      if (_isEdit) {
        final g = widget.group!;
        bool? tri(String key) =>
            _touched.contains(key) ? _flags[key] : null; // null=字段省略不动
        await api.updateGroup(
          g.id,
          name: name,
          description: _desc.text.trim(),
          canCreateProject: tri('can_create_project'),
          canDeleteProject: tri('can_delete_project'),
          canManageFolderTemplates: tri('can_manage_folder_templates'),
          canCreateArtistAccount: tri('can_create_artist_account'),
          canDeleteFiles: tri('can_delete_files'),
        );
      } else {
        await api.createGroup(
          name: name,
          description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          canCreateProject: _flags['can_create_project']!,
          canManageFolderTemplates: _flags['can_manage_folder_templates']!,
          canCreateArtistAccount: _flags['can_create_artist_account']!,
          canDeleteFiles: _flags['can_delete_files']!,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 重名透传
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
    final g = widget.group;
    // F5 同口径:内联骨架收口 FormSkeleton(与用户/模板表单共用一处实现)
    return FormSkeleton(
      title: _isEdit ? '编辑用户组 — ${g!.name}' : '新建用户组',
      submitLabel: _isEdit ? '保存' : '创建',
      submitting: _submitting,
      onSubmit: _submit,
      error: _error,
      children: [
        AppTextField(controller: _name, label: '组名'),
        const SizedBox(height: 10),
        AppTextField(controller: _desc, label: '描述(可选)', maxLength: 1024),
        _flagTile(
          'can_create_project',
          '允许组成员新建项目',
          '组内成员可自行新建项目,并自动成为所建项目的管理员',
        ),
        // 子开关仅父开关开启时展示(建组态与编辑态均适用)
        if (_flags['can_create_project'] == true)
          Padding(
            padding: const EdgeInsets.only(left: Tk.spaceLg),
            child: _flagTile(
              'can_create_artist_account',
              '新建项目时创建艺人账号',
              '组内成员新建项目时可同步开通艺人账号',
            ),
          ),
        _flagTile(
          'can_manage_folder_templates',
          '允许组成员管理目录模板',
          '可维护目录模板(新建/编辑/删除),并在新建项目时选用',
        ),
        if (_isEdit)
          _flagTile(
            'can_delete_project',
            '允许组成员删除项目',
            '逻辑删除,数据保留,可在「已删除项目」中恢复',
          ),
        _flagTile(
          'can_delete_files',
          '允许组成员删除文件与文件夹',
          '软删除,可在回收站恢复或彻底删除;敏感目录不在此列',
        ),
      ],
    );
  }

  Widget _flagTile(String key, String label, String tip) {
    final tk = context.tk;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        label,
        style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
      ),
      subtitle: Text(
        tip,
        style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3, height: 1.5),
      ),
      value: _flags[key] ?? false,
      onChanged: (v) => _setFlag(key, v),
    );
  }
}
