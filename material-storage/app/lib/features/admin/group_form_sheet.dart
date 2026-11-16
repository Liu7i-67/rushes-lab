/// 用户组建/编表单(B8 功能点 3;web GroupFormModal 移动版):名称/描述/
/// 组级开关(建组态四开关随表单提交;编辑态五开关 tri-state——仅改动过才随
/// PATCH 携带,directory.py None=不动防静默撤权);艺人账号子开关随父开关联动。
/// 用户模块组级授权开放(2026-11-15 F3):「用户模块(可新建用户)」开关 +
/// 开启时「新建时可选择的用户组」多选(选项=组管理页已加载组列表;编辑态
/// 预填 userCreateGroupIds;关→提交 [] 撤权;开→校验 ≥1;未改动则 update
/// 不携带该字段,tri-state 同 flags)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/form_text_field.dart';
import 'admin_form_skeleton.dart';
import 'user_form_sheets.dart';

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

  // 用户模块组级授权开放(D1:授权态=目标组集合非空;开关 UI=集合非空的
  // 展示口径,独立 bool 仅驱动表单交互,不进提交体)。初始值取编辑态回显,
  // initState 内赋值(实例成员不可在字段初始化器引用 widget)。
  var _userModuleOn = false;
  var _userCreateIds = <String>{};

  /// 编辑态 tri-state:开关/勾选改动过才随 PATCH 携带(null=不动)。
  var _userModuleTouched = false;

  /// 目标组多选选项(组管理页同源:directory.listGroups limit 200)。
  var _targetOptions = <DirectoryGroup>[];
  String? _optionsError;
  String? _error;
  var _submitting = false;

  bool get _isEdit => widget.group != null;

  @override
  void initState() {
    super.initState();
    _userModuleOn = widget.group?.userCreateGroupIds.isNotEmpty ?? false;
    _userCreateIds = {...?widget.group?.userCreateGroupIds};
    _loadTargetOptions();
  }

  Future<void> _loadTargetOptions() async {
    try {
      final items = await session.api!.directory.listGroups(limit: 200);
      if (!mounted) return;
      setState(() {
        _targetOptions = items;
        _optionsError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _optionsError = '用户组加载失败');
    }
  }

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

  /// 用户模块开关:关→清空目标组(提交 [] = 撤销授权);开→待勾选 ≥1。
  void _setUserModule(bool v) {
    setState(() {
      _userModuleOn = v;
      _userModuleTouched = true;
      if (!v) _userCreateIds.clear();
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final err = name.isEmpty
        ? '请输入组名'
        // F3:开关开时至少选 1 个目标组才允许提交(授权态=集合非空,D1)
        : (_userModuleOn && _userCreateIds.isEmpty
            ? '开启「用户模块」需至少选择 1 个新建用户时可选择的用户组'
            : null);
    if (err != null || _submitting) {
      if (err != null) setState(() => _error = err);
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
          // tri-state 对齐 flags:未改动不携带(后端 None=不动);改动即全量
          // 终态(空集合=撤销授权)
          userCreateGroupIds:
              _userModuleTouched ? _userCreateIds.toList() : null,
        );
      } else {
        await api.createGroup(
          name: name,
          description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          canCreateProject: _flags['can_create_project']!,
          canManageFolderTemplates: _flags['can_manage_folder_templates']!,
          canCreateArtistAccount: _flags['can_create_artist_account']!,
          canDeleteFiles: _flags['can_delete_files']!,
          userCreateGroupIds:
              _userModuleOn ? _userCreateIds.toList() : const <String>[],
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 重名 / 422 目标组校验透传
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
        // 用户模块组级授权开放(F3):开关 + 开启时目标组多选,样式对齐上方开关行
        _userModuleTile(),
        if (_userModuleOn)
          Padding(
            padding: const EdgeInsets.only(left: Tk.spaceLg),
            child: _userModuleFields(),
          ),
      ],
    );
  }

  /// 「用户模块(可新建用户)」开关行(样式对齐 _flagTile;独立于五组级 flag,
  /// 授权态由 userCreateGroupIds 集合承载,D1 无单独 bool 落库)。
  Widget _userModuleTile() {
    final tk = context.tk;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        '用户模块(可新建用户)',
        style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
      ),
      subtitle: Text(
        '开启后组成员可见「用户」模块:查看自己创建的用户、新建用户、重置密码',
        style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3, height: 1.5),
      ),
      value: _userModuleOn,
      onChanged: _setUserModule,
    );
  }

  /// 目标组多选区:选项=组管理页已加载组列表(含本组,D5 不限制);加载中
  /// 占位、失败给点按重试;预填编辑态 userCreateGroupIds。
  Widget _userModuleFields() {
    final tk = context.tk;
    if (_targetOptions.isEmpty && _optionsError == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RestrictedGroupSelectField(
          allowed: [
            for (final g in _targetOptions)
              GroupBrief(id: g.id, name: g.name, memberCount: g.memberCount),
          ],
          value: [for (final id in _userCreateIds) _briefOf(id)],
          onChanged: (v) => setState(() {
            _userCreateIds = {for (final b in v) b.id};
            _userModuleTouched = true;
          }),
          label: '新建时可选择的用户组(可多选)',
          hint: '点击选择用户组',
          emptyHint: '暂无可选用户组',
          pickTitle: '选择新建用户可加入的用户组',
        ),
        if (_optionsError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: _loadTargetOptions,
              child: Text(
                '用户组加载失败,点按重试',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          '成员新建用户时只能把用户加入此处勾选的用户组;清空勾选并保存 = 撤销授权',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
      ],
    );
  }

  /// 已选 id → GroupBrief(选项未含时保底,防预填 id 丢失显示)。
  GroupBrief _briefOf(String id) {
    for (final g in _targetOptions) {
      if (g.id == id) {
        return GroupBrief(id: g.id, name: g.name, memberCount: g.memberCount);
      }
    }
    return GroupBrief(id: id, name: id);
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
