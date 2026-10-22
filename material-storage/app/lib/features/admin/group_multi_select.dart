/// 组多选(B8 建用户带组/编辑所属组共用;directory groups 简表 limit=200,
/// web CreateUserModal Select multiple 移动版):搜索过滤 + 已选 chips +
/// 勾选列表。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

class GroupMultiSelect extends StatefulWidget {
  const GroupMultiSelect({super.key, required this.value, required this.onChanged});

  final List<DirectoryGroup> value;
  final ValueChanged<List<DirectoryGroup>> onChanged;

  @override
  State<GroupMultiSelect> createState() => _GroupMultiSelectState();
}

class _GroupMultiSelectState extends State<GroupMultiSelect> {
  List<DirectoryGroup> _options = const [];
  var _fetching = true;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    setState(() => _fetching = true);
    try {
      final groups = await session.api!.directory.listGroups(q: q, limit: 200);
      if (!mounted) return;
      setState(() {
        _options = groups;
        _fetching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _options = const [];
        _fetching = false;
      });
    }
  }

  void _toggle(DirectoryGroup g) {
    final next = List<DirectoryGroup>.of(widget.value);
    if (!next.any((x) => x.id == g.id)) {
      next.add(g);
    } else {
      next.removeWhere((x) => x.id == g.id);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            labelText: '所属用户组(可多选,可留空)',
            prefixIcon: Icon(Icons.search, size: 20),
            border: OutlineInputBorder(),
          ),
          onChanged: _search,
        ),
        const SizedBox(height: Tk.spaceXs),
        if (widget.value.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Tk.spaceXs),
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final g in widget.value)
                  InputChip(
                    label: Text(g.name,
                        style: const TextStyle(fontSize: Tk.fzSm)),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => _toggle(g),
                  ),
              ],
            ),
          ),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: _options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Tk.spaceMd),
                  child: Center(
                      child: Text(_fetching ? '加载中…' : '无用户组',
                          style:
                              const TextStyle(fontSize: Tk.fzSm))),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _options.length,
                  itemBuilder: (context, i) {
                    final g = _options[i];
                    final selected = widget.value.any((x) => x.id == g.id);
                    return ListTile(
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.groups_outlined, size: 20),
                      title: Text(g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: Tk.fzMd)),
                      subtitle: Text('${g.memberCount} 人',
                          style: const TextStyle(
                              fontSize: Tk.fzXs, color: Tk.subtle)),
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
