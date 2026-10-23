/// InitialGrantsField — 新建项目初始权限编辑器(B6 §8.5):权限模板选择
/// (展开为 initial_grants 行)+ SubjectPicker + 每行 RoleChips + 移除;
/// 行上限 50,「不使用模板」=清空重来,取消=维持现状。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/role_chips.dart';

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

List<GrantRowData> templateToRows(GrantTemplate t) => [
  for (final it in t.items)
    GrantRowData(
      kind: it.kind,
      id: it.id,
      name: it.name,
      roles: {...it.roles},
      missing: it.missing,
    ),
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

  /// 模板展示文案(字段关闭态与弹层行共用;含「不使用模板」null 项)。
  static String _label(GrantTemplate? t) =>
      t == null ? '不使用模板' : '${t.name}${t.isDefault ? '(默认)' : ''}';

  /// SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,移除即丢。
  void _applySubjects(List<Subject> subjects) {
    final byKey = {for (final r in widget.value) r.key: r};
    widget.onChanged([
      for (final s in subjects)
        byKey['${s.kind.name}:${s.id}'] ??
            GrantRowData(
              kind: s.kind.name,
              id: s.id,
              name: s.name,
              roles: {'viewer'},
            ),
    ]);
  }

  /// 模板切换:逐条预填(items 每 item 一行+各自角色);「不使用模板」清空重来。
  /// 默认模板不预选(创建后由后端直通合并,web PR-3 同款)。
  Future<void> _applyTemplate(GrantTemplate? t) async {
    if (t == null) {
      widget.onChanged([]);
      return;
    }
    // 选中模板可能是弹层打开后才加载完成的行外对象,直接展开
    widget.onChanged(templateToRows(t));
  }

  /// 模板弹层选择(I2:替代下拉,可搜索):null 项经 PickerOption 包装——
  /// 选中「不使用模板」返回非 null option(value=null → 清空),取消返回
  /// null(维持现状),语义与原下拉完全一致。
  Future<void> _pickTemplate(List<GrantTemplate> templates) async {
    final picked = await showPickerSheet<PickerOption<GrantTemplate>>(
      context: context,
      title: '权限模板',
      items: [
        const PickerOption<GrantTemplate>(null),
        for (final t in templates) PickerOption<GrantTemplate>(t),
      ],
      initial: PickerOption<GrantTemplate>(_selectedTemplate(templates)),
      labelOf: (o) => _label(o.value),
      searchTextHint: '搜索模板…',
    );
    if (picked == null || !mounted) return; // 取消 = 维持现状
    final t = picked.value;
    setState(() {
      _selectedId = t?.id;
      _applyTemplate(t);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<List<GrantTemplate>>(
          future: _templates,
          builder: (context, snap) {
            final templates = snap.data ?? const <GrantTemplate>[];
            // 显式选中的模板不在(或加载失败)时按未选渲染,显示 hint
            // (原下拉 value 命中语义不变)
            final current = _selectedTemplate(templates);
            return PickerField(
              value: current == null ? null : _label(current),
              hint: '权限模板(可选)',
              onTap: () => _pickTemplate(templates),
            );
          },
        ),
        const SizedBox(height: Tk.spaceSm),
        Text(
          '选模板预填后可增删行/改角色,或直接手选主体:',
          style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceXs),
        SubjectPicker(
          value: [
            for (final r in widget.value)
              Subject(
                kind: r.kind == 'user' ? SubjectKind.user : SubjectKind.group,
                id: r.id,
                name: _rowName(r),
              ),
          ],
          onChanged: _applySubjects,
          preset: mePreset(),
        ),
        if (widget.value.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceSm),
          Text(
            '${widget.value.length}/$kInitialGrantsMax 行',
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          ),
          for (final r in widget.value)
            _RowCard(
              row: r,
              name: _rowName(r),
              onRoles: (roles) => widget.onChanged([
                for (final x in widget.value)
                  if (x.key == r.key)
                    GrantRowData(
                      kind: x.kind,
                      id: x.id,
                      name: x.name,
                      roles: roles,
                      missing: x.missing,
                    )
                  else
                    x,
              ]),
              onRemove: () => widget.onChanged(
                widget.value.where((x) => x.key != r.key).toList(),
              ),
            ),
        ],
      ],
    );
  }

  /// 字段/弹层回显:显式选中的模板(不存在/已加载失败回 null 显示 hint)。
  GrantTemplate? _selectedTemplate(List<GrantTemplate> templates) {
    final id = _selectedId;
    if (id == null) return null;
    for (final t in templates) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 初始权限的一行:主体(名/类型)+ RoleChips + 移除(主体已删带「已删除」)。
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
    final tk = context.tk;
    final isUser = row.kind == 'user';
    return Container(
      margin: const EdgeInsets.only(top: Tk.spaceSm),
      padding: const EdgeInsets.all(Tk.spaceMd),
      decoration: BoxDecoration(
        color: tk.surface2,
        border: Border.all(color: tk.line),
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isUser ? tk.goldSoft : tk.surface3,
                child: Text(
                  isUser
                      ? (name.isEmpty
                            ? '?'
                            : name.characters.first.toUpperCase())
                      : '群',
                  style: TextStyle(
                    fontSize: Tk.fzXs,
                    color: isUser ? tk.goldInk : tk.ink2,
                  ),
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    fontWeight: FontWeight.w500,
                    color: tk.ink,
                  ),
                ),
              ),
              Text(
                isUser ? '用户' : '群组',
                style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
              ),
              if (row.missing) ...[
                const SizedBox(width: 6),
                Text(
                  '已删除',
                  style: TextStyle(fontSize: Tk.fzXs, color: tk.warn),
                ),
              ],
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 16),
                tooltip: '移除该主体',
                onPressed: onRemove,
              ),
            ],
          ),
          RoleChips(value: row.roles, onChanged: onRoles),
        ],
      ),
    );
  }
}
