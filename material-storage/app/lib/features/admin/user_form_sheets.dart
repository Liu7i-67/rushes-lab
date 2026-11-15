/// 建号表单(B8 功能点 2;web CreateUserModal 移动版):登录名(提交后不可改,
/// web 同款 pattern)/姓名/邮箱(可选)/用户组多选(可留空)。201 响应携带
/// 一次性临时密码,交调用方经 TempPasswordSheet 回显一次。
/// 用户模块组级授权开放(2026-11-15):非 admin 组字段数据源切换——仅
/// me.userCreateGroups 范围内本地选择(禁远程搜索;授权列表为空则字段不可选),
/// 提交体不变(后端 422 invalid_group_ids 兜底,F7)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/sheet_scaffold.dart';
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
  // 用户模块组级授权开放:非 admin 仅在授权目标组范围内选择(数据源/交互
  // 双切换;admin 走 GroupMultiSelect 远程搜索现状不变)。
  late final _restricted = !(session.me?.isSystemAdmin ?? false);
  late final _allowedGroups = session.me?.userCreateGroups ?? const <GroupBrief>[];
  var _groups = <DirectoryGroup>[]; // admin 选择值(GroupMultiSelect)
  var _picked = <GroupBrief>[]; // 非 admin 选择值(受限本地多选)
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
        groupIds: _restricted
            ? [for (final g in _picked) g.id]
            : [for (final g in _groups) g.id],
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
        if (_restricted)
          RestrictedGroupSelectField(
            allowed: _allowedGroups,
            value: _picked,
            onChanged: (v) => setState(() => _picked = v),
          )
        else
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

/// 受限用户组多选字段(用户模块组级授权开放):选项恒为 [allowed](建号表单
/// 传 me.userCreateGroups;组表单传已加载组列表),点按弹本地多选弹层
/// (无远程搜索,视觉对齐 RemotePickerSheet 选中行);[allowed] 为空时字段
/// 不可选(展示 [emptyHint]、点按无响应)。
class RestrictedGroupSelectField extends StatelessWidget {
  const RestrictedGroupSelectField({
    super.key,
    required this.allowed,
    required this.value,
    required this.onChanged,
    this.label = '所属用户组(仅限授权范围,可留空)',
    this.hint = '点击选择所属用户组',
    this.emptyHint = '你的账号未被授权选择用户组',
    this.pickTitle = '选择用户组',
  });

  final List<GroupBrief> allowed;
  final List<GroupBrief> value;
  final ValueChanged<List<GroupBrief>> onChanged;
  final String label;
  final String hint;
  final String emptyHint;
  final String pickTitle;

  /// 展示文案(口径同 GroupPickerField._display):单组名 / 多组「N 组」。
  String get _display {
    if (value.length > 1) return '${value.length} 组';
    return value.first.name;
  }

  Future<void> _pick(BuildContext context) async {
    if (allowed.isEmpty) return; // 授权列表为空:字段不可选
    // 选中集合 ValueNotifier(弹层行勾选与吸底完成钮共用一次装配,
    // _showRemotePickerSheet 同款形态);不 dispose(弹层短生命周期)。
    final selected = ValueNotifier<List<GroupBrief>>([
      ...{for (final g in value) g.id: g}.values, // 按 id 防御性去重
    ]);
    final picked = await showAppSheet<List<GroupBrief>>(
      context: context,
      title: pickTitle,
      bottomActions: [
        ValueListenableBuilder<List<GroupBrief>>(
          valueListenable: selected,
          builder: (ctx, sel, _) => PrimaryXl(
            label: '完成(${sel.length})',
            onPressed: () => Navigator.of(ctx).pop(List<GroupBrief>.of(sel)),
          ),
        ),
      ],
      child: _RestrictedGroupOptions(allowed: allowed, selected: selected),
    );
    if (picked == null) return; // 取消不动现值
    onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final selectable = allowed.isNotEmpty;
    return PickerField(
      label: label,
      value: value.isEmpty ? null : _display,
      hint: selectable ? hint : emptyHint,
      onTap: selectable ? () => _pick(context) : () {},
    );
  }
}

/// 受限多选弹层本体(选项=allowed 全量;勾选即时回填 notifier,完成钮 pop)。
class _RestrictedGroupOptions extends StatelessWidget {
  const _RestrictedGroupOptions({required this.allowed, required this.selected});

  final List<GroupBrief> allowed;
  final ValueNotifier<List<GroupBrief>> selected;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final listMax = (MediaQuery.sizeOf(context).height * 0.45).clamp(
      200.0,
      420.0,
    );
    return ValueListenableBuilder<List<GroupBrief>>(
      valueListenable: selected,
      builder: (ctx, sel, _) => Container(
        constraints: BoxConstraints(maxHeight: listMax),
        decoration: BoxDecoration(
          border: Border.all(color: tk.line),
          borderRadius: BorderRadius.circular(Tk.rSm),
        ),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: allowed.length,
          itemBuilder: (ctx, i) {
            final g = allowed[i];
            final isSel = sel.any((x) => x.id == g.id);
            return ListTile(
              dense: true,
              selected: isSel,
              selectedTileColor: tk.goldSoft,
              leading: Icon(Icons.groups_outlined, size: 20, color: tk.ink2),
              title: Text(
                g.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Tk.fzRowTitle,
                  color: isSel ? tk.goldInk : tk.ink,
                  fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              trailing: isSel ? Icon(Icons.check, size: 18, color: tk.gold) : null,
              onTap: () {
                final next = List<GroupBrief>.of(sel);
                final j = next.indexWhere((x) => x.id == g.id);
                if (j >= 0) {
                  next.removeAt(j);
                } else {
                  next.add(g);
                }
                selected.value = next;
              },
            );
          },
        ),
      ),
    );
  }
}
