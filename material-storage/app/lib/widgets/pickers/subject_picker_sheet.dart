/// SubjectPickerSheet — 主体(用户/用户组)双段多选弹层(app-polish-3 C4):
/// SegmentedButton 切段 + 各段远程搜索(250ms 防抖复用 remote_picker_sheet
/// 的 [RemoteSearcher],全库唯一实现)+ 勾选即时回填 + 底部「完成(N)」跨段
/// 合并返回 `List<Subject>`;取消(关闭钮/遮罩/返回)返回 null。行视觉复用
/// remoteTileOf/remoteStatus。依赖 subject_picker.dart 公开契约
/// Subject/SubjectKind(D 包重写该文件时保留,不受影响)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../buttons.dart';
import '../search_field.dart';
import '../sheet_scaffold.dart';
import 'remote_picker_sheet.dart';
import 'subject_picker.dart';

/// 弹主体选择弹层(用户段空 query 注入 preset;两段勾选合并为一个
/// `List<Subject>` 返回;N=0 也可点完成 = 显式清空)。
Future<List<Subject>?> showSubjectPickerSheet({
  required BuildContext context,
  required List<Subject> initial,
  List<UserBrief>? preset,
  String title = '添加用户 / 用户组',
}) {
  // Subject ==/hashCode 为 kind+id,Set 去重保序(初始值防御性去重)
  final selected = ValueNotifier<List<Subject>>(<Subject>{...initial}.toList());
  return showAppSheet<List<Subject>>(
    context: context,
    title: title,
    bottomActions: [
      ValueListenableBuilder<List<Subject>>(
        valueListenable: selected,
        builder: (nctx, sel, _) => PrimaryXl(
          label: '完成(${sel.length})',
          onPressed: () => Navigator.of(nctx).pop(List<Subject>.of(sel)),
        ),
      ),
    ],
    child: _SubjectPickerBody(selected: selected, preset: preset),
  );
}

class _SubjectPickerBody extends StatefulWidget {
  const _SubjectPickerBody({required this.selected, this.preset});

  final ValueNotifier<List<Subject>> selected;

  /// 用户段空 query 并入候选的预置项(通常 = 自己)。
  final List<UserBrief>? preset;

  @override
  State<_SubjectPickerBody> createState() => _SubjectPickerBodyState();
}

class _SubjectPickerBodyState extends State<_SubjectPickerBody> {
  SubjectKind _kind = SubjectKind.user;
  final _query = TextEditingController();
  late final RemoteSearcher<UserBrief> _userSearcher;
  late final RemoteSearcher<GroupBrief> _groupSearcher;

  @override
  void initState() {
    super.initState();
    _userSearcher =
        RemoteSearcher<UserBrief>((q) => session.api!.users.searchUsers(q: q))
          ..addListener(_rebuild)
          ..search('');
    _groupSearcher = RemoteSearcher<GroupBrief>(
      (q) => session.api!.users.searchGroups(q: q),
    )..addListener(_rebuild);
    widget.selected.addListener(_rebuild);
  }

  @override
  void dispose() {
    _userSearcher
      ..removeListener(_rebuild)
      ..dispose();
    _groupSearcher
      ..removeListener(_rebuild)
      ..dispose();
    widget.selected.removeListener(_rebuild);
    _query.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _runSearch(String q) {
    if (_kind == SubjectKind.user) {
      _userSearcher.search(q);
    } else {
      _groupSearcher.search(q);
    }
  }

  void _switchKind(SubjectKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    _runSearch(_query.text); // 换段按当前关键词重搜
  }

  /// 勾选(Subject ==/hashCode 为 kind+id,组合键天然去重)。
  void _toggle(Subject s) {
    final sel = List<Subject>.of(widget.selected.value);
    if (!sel.remove(s)) sel.add(s);
    widget.selected.value = sel;
  }

  /// 用户段候选(空 query 注入 preset,已出现的不重复;同 C1 口径)。
  List<UserBrief> get _visibleUsers {
    final opts = _userSearcher.options;
    final preset = widget.preset;
    if (_query.text.trim().isEmpty && preset != null) {
      final ids = opts.map((u) => u.id).toSet();
      return [...preset.where((p) => !ids.contains(p.id)), ...opts];
    }
    return opts;
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<SubjectKind>(
          segments: const [
            ButtonSegment(
              value: SubjectKind.user,
              icon: Icon(Icons.person_outline, size: 16),
              label: Text('用户'),
            ),
            ButtonSegment(
              value: SubjectKind.group,
              icon: Icon(Icons.groups_outlined, size: 16),
              label: Text('用户组'),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => _switchKind(s.first),
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            backgroundColor: tk.surface2,
            foregroundColor: tk.ink2,
            selectedBackgroundColor: tk.goldSoft,
            selectedForegroundColor: tk.goldInk,
            // 可切换控件:描边用 controlBorder(≥3:1)。
            side: BorderSide(color: tk.controlBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tk.rSm),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Tk.spaceSm),
          child: SearchField(
            controller: _query,
            hintText: '搜索…',
            onChanged: _runSearch,
          ),
        ),
        // 列表自封顶内滚(口径同 C1/ showPickerSheet,底线 200)
        Container(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * 0.45).clamp(
              200.0,
              420.0,
            ),
          ),
          decoration: BoxDecoration(
            border: Border.all(color: tk.line),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: _kind == SubjectKind.user ? _userList() : _groupList(),
        ),
      ],
    );
  }

  Widget _userList() {
    final options = _visibleUsers;
    if (options.isEmpty) return remoteStatus(context, _userSearcher.fetching);
    return ListView.builder(
      shrinkWrap: true,
      itemCount: options.length,
      itemBuilder: (context, i) {
        final u = options[i];
        return remoteTileOf(
          context,
          u,
          selected: widget.selected.value.contains(
            Subject(kind: SubjectKind.user, id: u.id, name: ''),
          ),
          onTap: () =>
              _toggle(Subject(kind: SubjectKind.user, id: u.id, name: u.name)),
        );
      },
    );
  }

  Widget _groupList() {
    final options = _groupSearcher.options;
    if (options.isEmpty) return remoteStatus(context, _groupSearcher.fetching);
    return ListView.builder(
      shrinkWrap: true,
      itemCount: options.length,
      itemBuilder: (context, i) {
        final g = options[i];
        return remoteTileOf(
          context,
          g,
          selected: widget.selected.value.contains(
            Subject(kind: SubjectKind.group, id: g.id, name: ''),
          ),
          onTap: () =>
              _toggle(Subject(kind: SubjectKind.group, id: g.id, name: g.name)),
        );
      },
    );
  }
}
