/// 组成员管理(B8 功能点 3;web GroupMembersDrawer 移动版):B6 UserPicker
/// 搜人加成员(批量逐个提交,首个错误继续余下)、组内搜索过滤(username/
/// name/email 前端过滤)、移出(确认 → DELETE,即时失去组权限)。
/// 成功增删后抽屉**驻留**(刷新成员列表,不自动关闭;web 同款),调用方在
/// 抽屉关闭后刷新组列表。
/// app-polish-3 E5:添加成员改 UserPickerField 弹层形态(点按弹层搜索勾选,
/// 底部「完成(N)」回填;选后仍走下方「添加所选成员」批量提交,数据流不变)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/pickers/user_picker_field.dart';
import '../../widgets/search_field.dart';
import '../../widgets/toast.dart';

/// 打开成员管理;增删成功抽屉驻留(web 同款),关闭后调用方刷新组列表。
Future<void> showGroupMembersSheet(
    BuildContext context, DirectoryGroup group) async {
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
        .where((m) => [m.username, m.name, m.email]
            .any((v) => (v ?? '').toLowerCase().contains(kw)))
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
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Tk.spaceXl, 0, Tk.spaceXl, Tk.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('成员 — ${widget.group.name}(${_members.length} 人)',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Tk.spaceMd),
              UserPickerField(
                value: _selected,
                multiple: true,
                label: '添加成员',
                hint: '搜索并选择用户',
                onChanged: (v) => setState(() => _selected = v),
              ),
              const SizedBox(height: Tk.spaceSm),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty || _busy ? null : _addSelected,
                  child: Text(_busy ? '添加中…' : '添加所选成员'),
                ),
              ),
              const SizedBox(height: Tk.spaceSm),
              SearchField(
                hintText: '在组内搜索 — 用户名 / 姓名 / 邮箱',
                onChanged: (v) => setState(() => _memberQ = v),
              ),
              const SizedBox(height: Tk.spaceSm),
              Expanded(child: _list(filtered)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(List<GroupMember> filtered) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: const TextStyle(color: Tk.muted, fontSize: Tk.fzSm)));
    }
    if (filtered.isEmpty) {
      return const Center(
          child: Text('暂无成员',
              style: TextStyle(color: Tk.muted, fontSize: Tk.fzSm)));
    }
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final m = filtered[i];
        final sub = StringBuffer(m.username ?? '—');
        if (m.email != null && m.email!.isNotEmpty) sub.write(' · ${m.email}');
        return ListTile(
          visualDensity: VisualDensity.compact,
          title: Row(children: [
            Flexible(
                child: Text(m.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (!m.isActive)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('已停用',
                    style: TextStyle(fontSize: Tk.fzXs, color: Tk.red)),
              ),
          ]),
          subtitle: Text(sub.toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Tk.fzXs)),
          trailing: TextButton(
            onPressed: () => _remove(m),
            child: const Text('移出', style: TextStyle(color: Tk.red)),
          ),
        );
      },
    );
  }
}
