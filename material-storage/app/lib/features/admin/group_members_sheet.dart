/// 组成员管理(B8 功能点 3;web GroupMembersDrawer 移动版):B6 UserPicker
/// 搜人加成员(批量逐个提交,首个错误继续余下)、组内搜索过滤(username/
/// name/email 前端过滤)、移出(确认 → DELETE,即时失去组权限)。
/// 成功增删后抽屉**驻留**(刷新成员列表,不自动关闭;web 同款),调用方在
/// 抽屉关闭后刷新组列表。
/// app-polish-3 E5:添加成员改 UserPickerField 弹层形态(点按弹层搜索勾选,
/// 底部「完成(N)」回填;选后仍走底部「添加所选成员」批量提交,数据流不变)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/pickers/user_picker_field.dart';
import '../../widgets/search_field.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';

/// 打开成员管理;增删成功抽屉驻留(web 同款),关闭后调用方刷新组列表。
Future<void> showGroupMembersSheet(
  BuildContext context,
  DirectoryGroup group,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GroupMembersSheet(group: group),
  );
}

class _GroupMembersSheet extends StatefulWidget {
  const _GroupMembersSheet({required this.group});

  final DirectoryGroup group;

  @override
  State<_GroupMembersSheet> createState() => _GroupMembersSheetState();
}

class _GroupMembersSheetState extends State<_GroupMembersSheet> {
  var _members = <GroupMember>[];
  var _selected = <UserBrief>[];
  var _loading = true;
  var _busy = false;
  String? _error;
  String _memberQ = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final members = await session.api!.directory.listMembers(widget.group.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorMessage(e, '加载失败,请稍后重试');
      });
    }
  }

  List<GroupMember> get _filtered {
    final kw = _memberQ.trim().toLowerCase();
    if (kw.isEmpty) return _members;
    return _members
        .where(
          (m) => [
            m.username,
            m.name,
            m.email,
          ].any((v) => (v ?? '').toLowerCase().contains(kw)),
        )
        .toList();
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    var ok = 0;
    String? firstError;
    for (final u in _selected) {
      try {
        await session.api!.directory.addMember(widget.group.id, u.id);
        ok++;
      } on ApiException catch (e) {
        // 400 已禁用 / 409 已在组中:记首个错误继续余下——有意更优于 web
        // doAdd 的首错即停(批量加人尽量完成,失败明细一个 toast 说清)
        firstError ??= e.message;
      } catch (e) {
        firstError ??= errorMessage(e, '添加失败,请稍后重试');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected = const [];
    });
    if (firstError != null) {
      toast(context, firstError, tone: ToastTone.error);
    } else {
      toast(context, '已添加 $ok 名成员', tone: ToastTone.success);
    }
    // 成功后抽屉驻留:刷新成员列表,不自动关闭(web GroupMembersDrawer 同款)
    await _reload();
  }

  Future<void> _remove(GroupMember m) async {
    // F3:确认口径 `!= true`——取消 false / 遮罩关闭 null 均视为未确认
    final ok = await showAppConfirm(
      context,
      title: '把 ${m.name} 移出该组?',
      content: '其将立即失去该组授予的全部权限',
      confirmLabel: '移出',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.directory.removeMember(widget.group.id, m.userId);
      if (!mounted) return;
      toast(context, '已移出 ${m.name}', tone: ToastTone.success);
      // 成功后抽屉驻留:刷新成员列表,不自动关闭(web GroupMembersDrawer 同款)
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 404 透传
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return SheetScaffold(
      title: '成员 — ${widget.group.name}(${_members.length} 人)',
      // 保持原行为:标题行不带关闭钮(把手/遮罩/返回键关闭)
      showClose: false,
      maxHeightFactor: 0.85,
      bottomActions: [
        FilledButton(
          onPressed: _selected.isEmpty || _busy ? null : _addSelected,
          child: Text(_busy ? '添加中…' : '添加所选成员'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserPickerField(
            value: _selected,
            multiple: true,
            label: '添加成员',
            hint: '搜索并选择用户',
            onChanged: (v) => setState(() => _selected = v),
          ),
          const SizedBox(height: Tk.spaceSm),
          SearchField(
            hintText: '在组内搜索 — 用户名 / 姓名 / 邮箱',
            onChanged: (v) => setState(() => _memberQ = v),
          ),
          const SizedBox(height: Tk.spaceSm),
          _list(filtered),
        ],
      ),
    );
  }

  Widget _list(List<GroupMember> filtered) {
    final tk = context.tk;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Tk.spaceXl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Tk.spaceLg),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: tk.ink3, fontSize: Tk.fzMd),
        ),
      );
    }
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Tk.spaceXl),
        child: Text(
          '暂无成员',
          textAlign: TextAlign.center,
          style: TextStyle(color: tk.ink3, fontSize: Tk.fzMd),
        ),
      );
    }
    return SectionCard(children: [for (final m in filtered) _memberRow(m)]);
  }

  Widget _memberRow(GroupMember m) {
    final tk = context.tk;
    final sub = StringBuffer(m.username ?? '—');
    if (m.email != null && m.email!.isNotEmpty) sub.write(' · ${m.email}');
    return AppRow(
      leading: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tk.goldSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          m.name.trim().isEmpty ? '?' : m.name.trim().substring(0, 1),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: tk.goldInk,
          ),
        ),
      ),
      title: m.name,
      subtitle: sub.toString(),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!m.isActive) const Badge(label: '已停用', tone: BadgeTone.danger),
          TextButton(
            onPressed: () => _remove(m),
            child: Text('移出', style: TextStyle(color: tk.danger)),
          ),
        ],
      ),
      showChevron: false,
    );
  }
}
