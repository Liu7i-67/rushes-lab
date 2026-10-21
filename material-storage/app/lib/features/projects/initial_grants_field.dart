/// InitialGrantsField — 新建项目初始权限编辑器(B6 §8.5;web NewProjectModal
/// 权限组移动版):顶部权限模板 Select(仅显式选中时把模板条目展开为
/// initial_grants 行,可再增删改——后端无模板 id 入参)+ SubjectPicker 手选
/// + 每行主体各自 RoleChips + 移除。行上限 50(后端 INITIAL_GRANTS_MAX)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/role_chips.dart';

/// initial_grants 条数上限(routers/projects.py INITIAL_GRANTS_MAX)。
const kInitialGrantsMax = 50;

/// 一行初始权限:主体 + 该行自己的角色集(key=kind:id 稳定去重)。
class GrantRowData {
  GrantRowData({
    required this.kind,
    required this.id,
    required this.name,
    required this.roles,
    this.missing = false,
  });

  final String kind; // user / group
  final String id;
  final String name;
  final Set<String> roles;
  final bool missing; // 模板条目主体已删(提交会被存在性校验 400 拦)

  String get key => '$kind:$id';
}

/// 模板条目 → 行(角色集拷贝;web templateRows 同构)。
List<GrantRowData> templateToRows(GrantTemplate t) => [
      for (final it in t.items)
        GrantRowData(
            kind: it.kind, id: it.id, name: it.name,
            roles: {...it.roles}, missing: it.missing),
    ];

class InitialGrantsField extends StatefulWidget {
  const InitialGrantsField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final List<GrantRowData> value;
  final ValueChanged<List<GrantRowData>> onChanged;

  @override
  State<InitialGrantsField> createState() => _InitialGrantsFieldState();
}

class _InitialGrantsFieldState extends State<InitialGrantsField> {
  late final Future<List<GrantTemplate>> _templates = _load();

  /// 显式选中的模板 id(null = 不使用模板;web templateId 同语义)。
  String? _selectedId;

  Future<List<GrantTemplate>> _load() async {
    try {
      return await session.api!.adminTemplates.grantTemplates();
    } catch (_) {
      // 403/网络失败 → 静默降级为只有「不使用模板」(web 同口径)
      return const [];
    }
  }

  String _rowName(GrantRowData r) =>
      r.name.isEmpty ? _shortId(r.id, 12) : r.name;

  String _shortId(String id, int n) =>
      id.length > n ? '${id.substring(0, n)}…' : id;

  /// SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,移除即丢。
  void _applySubjects(List<Subject> subjects) {
    final byKey = {for (final r in widget.value) r.key: r};
    widget.onChanged([
      for (final s in subjects)
        byKey['${s.kind.name}:${s.id}'] ??
            GrantRowData(
                kind: s.kind.name, id: s.id, name: s.name,
                roles: {'viewer'}),
    ]);
  }

  /// 模板切换:逐条预填(items 每 item 一行+各自角色);「不使用模板」清空重来。
  /// 默认模板不预选(创建后由后端直通合并,web PR-3 同款)。
  Future<void> _applyTemplate(GrantTemplate? t) async {
    if (t == null) {
      widget.onChanged([]);
      return;
    }
    // 选中模板可能是在下拉打开后才加载完成的行外对象,直接展开
    widget.onChanged(templateToRows(t));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<List<GrantTemplate>>(
          future: _templates,
          builder: (context, snap) {
            final templates = snap.data ?? const <GrantTemplate>[];
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(Tk.rSm),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<GrantTemplate?>(
                  value: _selectedTemplate(templates),
                  isExpanded: true,
                  hint: const Text('权限模板(可选)',
                      style: TextStyle(fontSize: Tk.fzMd)),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('不使用模板')),
                    for (final t in templates)
                      DropdownMenuItem(
                        value: t,
                        child: Text(
                          '${t.name}${t.isDefault ? '(默认)' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: Tk.fzMd),
                        ),
                      ),
                  ],
                  onChanged: (t) => setState(() {
                    _selectedId = t?.id;
                    _applyTemplate(t);
                  }),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: Tk.spaceSm),
        const Text('选模板预填后可增删行/改角色,或直接手选主体:',
            style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
        const SizedBox(height: Tk.spaceXs),
        SubjectPicker(
          value: [
            for (final r in widget.value)
              Subject(
                  kind: r.kind == 'user' ? SubjectKind.user : SubjectKind.group,
                  id: r.id,
                  name: _rowName(r)),
          ],
          onChanged: _applySubjects,
          preset: mePreset(),
        ),
        if (widget.value.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('${widget.value.length}/$kInitialGrantsMax 行',
              style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          for (final r in widget.value)
            _RowCard(
              row: r,
              name: _rowName(r),
              onRoles: (roles) => widget.onChanged([
                for (final x in widget.value)
                  if (x.key == r.key)
                    GrantRowData(
                        kind: x.kind, id: x.id, name: x.name,
                        roles: roles, missing: x.missing)
                  else
                    x,
              ]),
              onRemove: () => widget
                  .onChanged(widget.value.where((x) => x.key != r.key).toList()),
            ),
        ],
      ],
    );
  }

  /// 下拉回显:显式选中的模板(不存在/已加载失败回 null 显示「不使用模板」)。
  GrantTemplate? _selectedTemplate(List<GrantTemplate> templates) {
    final id = _selectedId;
    if (id == null) return null;
    for (final t in templates) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 初始权限的一行:主体(名/类型)+ 该行自己的 RoleChips + 移除按钮
/// (web GrantRowCard 同构;主体已删的模板条目带「已删除」警示)。
class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.row,
    required this.name,
    required this.onRoles,
    required this.onRemove,
  });

  final GrantRowData row;
  final String name;
  final ValueChanged<Set<String>> onRoles;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isUser = row.kind == 'user';
    return Container(
      margin: const EdgeInsets.only(top: Tk.spaceSm),
      padding: const EdgeInsets.fromLTRB(Tk.spaceMd, Tk.spaceSm, Tk.spaceMd, 10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: isUser ? Tk.fg : Tk.border,
              child: Text(
                isUser
                    ? (name.isEmpty ? '?' : name.characters.first.toUpperCase())
                    : '群',
                style:
                    TextStyle(fontSize: Tk.fzXs, color: isUser ? Tk.surface : Tk.muted),
              ),
            ),
            const SizedBox(width: Tk.spaceSm),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: Tk.fzMd, fontWeight: FontWeight.w500)),
            ),
            Text(isUser ? '用户' : '群组',
                style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
            if (row.missing) ...[
              const SizedBox(width: 6),
              const Text('已删除',
                  style: TextStyle(fontSize: Tk.fzXs, color: Tk.amber)),
            ],
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 16),
              tooltip: '移除该主体',
              onPressed: onRemove,
            ),
          ]),
          RoleChips(value: row.roles, onChanged: onRoles),
        ],
      ),
    );
  }
}
