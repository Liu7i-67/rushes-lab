/// 权限模板表单拆件(B8 功能点 5;web TemplateFormModal 移动版):
/// 模板名/描述/设默认开关 + 授权条目(B6 SubjectPicker 主体行×独立 RoleChips,
/// 50 条上限 = INITIAL_GRANTS_MAX 同一常量口径)。items 编辑=全量替换。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/pickers/subject_picker.dart';
import 'admin_form_skeleton.dart';
import 'grant_template_row.dart';

/// 主体条数上限(后端 INITIAL_GRANTS_MAX 同一常量;超限 422 文案透传兜底)。
const kGrantTemplateItemsMax = 50;

/// 打开建/编模板表单;返回是否成功提交。
Future<bool> showGrantTemplateFormSheet(
  BuildContext context, {
  GrantTemplate? template,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GrantTemplateFormSheet(template: template),
  );
  return ok ?? false;
}

class _GrantTemplateFormSheet extends StatefulWidget {
  const _GrantTemplateFormSheet({this.template});

  final GrantTemplate? template;

  @override
  State<_GrantTemplateFormSheet> createState() =>
      _GrantTemplateFormSheetState();
}

class _GrantTemplateFormSheetState extends State<_GrantTemplateFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.template?.name ?? '',
  );
  late final TextEditingController _desc = TextEditingController(
    text: widget.template?.description ?? '',
  );
  late var _isDefault = widget.template?.isDefault ?? false;
  late var _rows = <GrantRow>[
    for (final it in widget.template?.items ?? const <GrantTemplateItem>[])
      GrantRow.fromItem(it),
  ];
  String? _error;
  var _submitting = false;

  bool get _isEdit => widget.template != null;

  /// SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,
  /// 移除的行丢弃(web applySubjects 同语义)。
  void _applySubjects(List<Subject> subjects) {
    setState(() {
      final prevByKey = {for (final r in _rows) r.key: r};
      _rows = [
        for (final s in subjects)
          prevByKey['${s.kind.name}:${s.id}'] ??
              GrantRow(
                key: '${s.kind.name}:${s.id}',
                kind: s.kind.name,
                id: s.id,
                name: s.name,
                roles: {'viewer'},
              ),
      ];
    });
  }

  List<Subject> get _subjects => [
    for (final r in _rows)
      Subject(
        kind: r.kind == 'group' ? SubjectKind.group : SubjectKind.user,
        id: r.id,
        name: r.name ?? r.id,
      ),
  ];

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入模板名');
      return;
    }
    if (_rows.isEmpty) {
      setState(() => _error = '请至少添加一个主体');
      return;
    }
    if (_rows.length > kGrantTemplateItemsMax) {
      setState(
        () =>
            _error = '条目超上限:最多 $kGrantTemplateItemsMax 条,当前 ${_rows.length} 条',
      );
      return;
    }
    if (_rows.any((r) => r.roles.isEmpty)) {
      setState(() => _error = '每行主体请至少勾选一个角色');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final desc = _desc.text.trim();
    try {
      final api = session.api!.adminTemplates;
      final items = [
        for (final r in _rows)
          GrantEntry(kind: r.kind, id: r.id, roles: r.roles.toList()),
      ];
      if (_isEdit) {
        await api.updateTemplate(
          widget.template!.id,
          name: name,
          // description 恒携带:空串传显式 null = 清空(P3-3;API 注释同口径)
          description: desc.isEmpty ? null : desc,
          isDefault: _isDefault,
          items: items,
        );
      } else {
        await api.createTemplate(
          name: name,
          description: desc.isEmpty ? null : desc,
          isDefault: _isDefault,
          items: items,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 重名/400 主体不存在/422 超限透传
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
    final tk = context.tk;
    // F5:内联骨架(限高 0.85 + 滚动 + 键盘避让 + 错误行 + 提交键)收口
    // FormSkeleton,与建号/编辑等表单共用一处实现
    return FormSkeleton(
      title: _isEdit ? '编辑权限模板 — ${t!.name}' : '新建权限模板',
      submitLabel: _isEdit ? '保存' : '创建',
      submitting: _submitting,
      onSubmit: _submit,
      error: _error,
      maxHeightFactor: 0.85,
      children: [
        AppTextField(controller: _name, label: '模板名'),
        const SizedBox(height: 10),
        AppTextField(controller: _desc, label: '描述(可选)', maxLength: 1024),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            '设为默认模板',
            style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
          ),
          subtitle: Text(
            '默认模板的授权会在项目创建时自动合并;每 org 至多一个默认,'
            '设为默认会自动取消原默认',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3, height: 1.5),
          ),
          value: _isDefault,
          onChanged: (v) => setState(() => _isDefault = v),
        ),
        Text(
          '授权条目(${_rows.length}/$kGrantTemplateItemsMax,'
          '每行主体各自勾选角色)',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
        const SizedBox(height: 6),
        SubjectPicker(value: _subjects, onChanged: _applySubjects),
        for (final r in _rows)
          GrantTemplateRow(
            row: r,
            onDelete: () => setState(() {
              _rows = _rows.where((x) => x.key != r.key).toList();
            }),
            onRolesChanged: (roles) => setState(() => r.roles = roles),
          ),
      ],
    );
  }
}
