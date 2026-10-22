/// SubjectPicker — 统一选择权限主体(B6 §9;web SubjectPicker 移动版):
/// 用户 / 用户组 两段切换 + 已选汇总 chips(跨段可见)。#154 部门轴下线,
/// 仅剩 user / group 两类。主体语义:user → {user_id}, group → {group_id}。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'user_picker.dart';

enum SubjectKind { user, group }

/// 权限主体(kind+id;name 仅供回显)。
class Subject {
  const Subject({required this.kind, required this.id, required this.name});

  final SubjectKind kind;
  final String id; // users.id / groups.id UUID
  final String name;

  @override
  bool operator ==(Object other) =>
      other is Subject && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// me → 预置候选(web preset 同语义;null 安全由调用方保证已登录)。
List<UserBrief> mePreset() {
  final me = session.me;
  return [
    if (me != null)
      UserBrief(id: me.id, name: '${me.name}(自己)'),
  ];
}

class SubjectPicker extends StatefulWidget {
  const SubjectPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.preset,
  });

  final List<Subject> value;
  final ValueChanged<List<Subject>> onChanged;

  /// 用户段空 query 预置候选(通常 = 自己)。
  final List<UserBrief>? preset;

  @override
  State<SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends State<SubjectPicker> {
  SubjectKind _tab = SubjectKind.user;

  List<Subject> get _users =>
      widget.value.where((s) => s.kind == SubjectKind.user).toList();
  List<Subject> get _groups =>
      widget.value.where((s) => s.kind == SubjectKind.group).toList();

  void _replace(List<Subject> next) => widget.onChanged(next);

  void _setUsers(List<UserBrief> users) {
    _replace([
      ..._groups,
      ...users.map((u) =>
          Subject(kind: SubjectKind.user, id: u.id, name: u.name)),
    ]);
  }

  void _setGroups(List<Subject> groups) {
    _replace([
      ..._users,
      ...groups,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<SubjectKind>(
          segments: const [
            ButtonSegment(
                value: SubjectKind.user,
                icon: Icon(Icons.person_outline, size: 16),
                label: Text('用户')),
            ButtonSegment(
                value: SubjectKind.group,
                icon: Icon(Icons.groups_outlined, size: 16),
                label: Text('用户组')),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: Tk.spaceSm),
        if (_tab == SubjectKind.user)
          UserPicker(
            value: [for (final u in _users) UserBrief(id: u.id, name: u.name)],
            onChanged: _setUsers,
            preset: widget.preset,
          )
        else
          _GroupPicker(value: _groups, onChanged: _setGroups),
        if (widget.value.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceSm),
          _SelectedSummary(
              value: widget.value,
              onRemove: (s) =>
                  _replace(widget.value.where((x) => x != s).toList())),
        ],
      ],
    );
  }
}

/// id 缩略(短 id 防越界;web `id.slice(0,n)+'…'` 同义)。
String _shortId(String id, int n) =>
    id.length > n ? '${id.substring(0, n)}…' : id;

/// 已选汇总(跨段可见;web _SelectedSummary 同语义):👤/🏷 前缀 + 可删 chip。
class _SelectedSummary extends StatelessWidget {
  const _SelectedSummary({required this.value, required this.onRemove});

  final List<Subject> value;
  final ValueChanged<Subject> onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Tk.spaceSm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: Wrap(
        spacing: Tk.spaceSm, // 6→spaceSm(A2 就近归档)
        runSpacing: Tk.spaceXs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 ${value.length} 项:',
              style: const TextStyle(fontSize: Tk.fzXs)),
          for (final s in value)
            InputChip(
              label: Text(
                '${s.kind == SubjectKind.user ? '👤' : '🏷'} '
                '${s.name.isEmpty ? _shortId(s.id, 12) : s.name}',
                style: const TextStyle(fontSize: Tk.fzXs),
              ),
              visualDensity: VisualDensity.compact,
              onDeleted: () => onRemove(s),
            ),
        ],
      ),
    );
  }
}

/// 用户组搜索多选(GET /groups?q=;250ms 停顿 + stale tag,web GroupPicker 同款)。
class _GroupPicker extends StatefulWidget {
  const _GroupPicker({required this.value, required this.onChanged});

  final List<Subject> value;
  final ValueChanged<List<Subject>> onChanged;

  @override
  State<_GroupPicker> createState() => _GroupPickerState();
}

class _GroupPickerState extends State<_GroupPicker> {
  final _controller = TextEditingController();
  List<GroupBrief> _options = const [];
  var _fetching = false;
  var _tag = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    final tag = ++_tag;
    setState(() => _fetching = true);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final groups = await session.api!.users.searchGroups(q: q);
        if (tag != _tag || !mounted) return;
        setState(() {
          _options = groups;
          _fetching = false;
        });
      } catch (_) {
        if (tag != _tag || !mounted) return;
        setState(() {
          _options = const [];
          _fetching = false;
        });
      }
    });
  }

  void _toggle(GroupBrief g) {
    final s = Subject(kind: SubjectKind.group, id: g.id, name: g.name);
    final next = List<Subject>.of(widget.value);
    if (!next.remove(s)) {
      next.add(s);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜用户组名',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _controller.clear();
                      _search('');
                    },
                  ),
          ),
          onChanged: _search,
        ),
        const SizedBox(height: Tk.spaceXs),
        Container(
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: _options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Tk.spaceMd),
                  child: Center(
                    child: Text(_fetching ? '搜索中…' : '无匹配项',
                        style: const TextStyle(fontSize: Tk.fzSm)),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _options.length,
                  itemBuilder: (context, i) {
                    final g = _options[i];
                    final selected =
                        widget.value.any((s) => s.id == g.id);
                    return ListTile(
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.groups_outlined, size: 20),
                      title: Text(g.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: Tk.fzMd)),
                      subtitle: Text(
                        '${_shortId(g.id, 18)}'
                        '${g.memberCount != null ? ' · ${g.memberCount} 人' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: Tk.fzXs),
                      ),
                      dense: true,
                      trailing:
                          selected ? const Icon(Icons.check, size: 18) : null,
                      onTap: () => _toggle(g),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
