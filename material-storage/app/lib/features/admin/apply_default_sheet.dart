/// 应用默认权限弹层(B8 功能点 5;web ApplyDefaultModal 移动版):
/// 多项目批量勾选(全量项目循环翻页拉全,归档项目后端列表天然不含)→
/// 单批 ≤100(接口上限)→ 确认(叠加不删文案)→ 逐项目结果呈现
/// (ApplyDefaultResultView 拆件)。require_system_admin,全 App 唯一应用
/// 默认入口;无默认模板时入口禁用(web hasDefault 同款)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'apply_default_result_view.dart';

/// 接口单批上限(ApplyDefaultIn project_ids 1..100)。
const kApplyDefaultBatchMax = 100;

/// 打开应用默认弹层;固定返回 void(结果在弹层内呈现)。
Future<void> showApplyDefaultSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _ApplyDefaultSheet(),
    );

class _ApplyDefaultSheet extends StatefulWidget {
  const _ApplyDefaultSheet();

  @override
  State<_ApplyDefaultSheet> createState() => _ApplyDefaultSheetState();
}

class _ApplyDefaultSheetState extends State<_ApplyDefaultSheet> {
  var _projects = <Project>[];
  var _selected = <String>{};
  var _loading = true;
  var _applying = false;
  String? _error;
  String _q = '';
  ApplyDefaultResult? _result;

  bool get _atLimit => _selected.length >= kApplyDefaultBatchMax;

  List<Project> get _filtered {
    final kw = _q.trim().toLowerCase();
    if (kw.isEmpty) return _projects;
    return _projects
        .where((p) =>
            p.name.toLowerCase().contains(kw) ||
            p.code.toLowerCase().contains(kw))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 全量项目(web useAllProjects 循环翻页;归档/已删项目后端列表天然不含,
    // API 预检 400 双保险)
    final out = <Project>[];
    try {
      for (var offset = 0;; offset += 100) {
        final page =
            await session.api!.projects.listPaged(limit: 100, offset: offset);
        out.addAll(page);
        if (page.length < 100) break;
      }
      if (!mounted) return;
      setState(() {
        _projects = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _apply() async {
    if (_selected.isEmpty || _applying) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('刷新 ${_selected.length} 个项目的默认权限?'),
        content: const Text(
            '将逐项目合并默认模板授权(叠加不删,不移除现有授权)。'
            '项目较多时耗时较长(满批可达数分钟),建议每批 20–30 个项目分次提交。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('开始刷新')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _applying = true);
    try {
      final result = await session.api!.adminTemplates.applyDefault(
          _projects
              .where((p) => _selected.contains(p.id))
              .map((p) => p.id)
              .toList());
      if (!mounted) return;
      setState(() {
        _result = result;
        _applying = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e.message; // 400 预检(无默认模板/归档项目)透传
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = '$e';
      });
    }
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) {
        if (_selected.length >= kApplyDefaultBatchMax) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('单批最多 $kApplyDefaultBatchMax 个项目(接口上限),'
                  '请分批刷新')));
          return;
        }
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result != null) {
      return ApplyDefaultResultView(
        result: result,
        projects: _projects,
        onDone: () => Navigator.of(context).pop(),
      );
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('刷新默认权限',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                '叠加不删:只补缺失的默认模板授权,不移除项目现有授权;'
                '单批最多 100 个项目(接口上限),满批可达数分钟,建议每批 20–30 个分次提交。',
                style: TextStyle(fontSize: 11.5, color: Tk.muted, height: 1.5),
              ),
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '搜项目名 / 编码…',
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12.5)),
                ),
              Expanded(child: _projectList()),
              Row(children: [
                Text('已选 ${_selected.length}/$kApplyDefaultBatchMax',
                    style: const TextStyle(fontSize: 12, color: Tk.muted)),
                const Spacer(),
                TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => setState(() => _selected = <String>{}),
                  child: const Text('清空'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _selected.isEmpty || _applying ? null : _apply,
                  child: Text(_applying ? '刷新中…' : '刷新'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _projectList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final list = _filtered;
    if (list.isEmpty) {
      return const Center(
          child: Text('暂无可刷新的项目(归档项目不支持)',
              style: TextStyle(color: Tk.muted, fontSize: 12.5)));
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView.builder(
        itemCount: list.length,
        itemBuilder: (context, i) {
          final p = list[i];
          final checked = _selected.contains(p.id);
          final disabled = _atLimit && !checked;
          return CheckboxListTile(
            visualDensity: VisualDensity.compact,
            value: checked,
            // 到达单批上限后禁止再勾(提示分批)
            onChanged: disabled ? null : (_) => _toggle(p.id),
            title: Text('${p.name}(${p.code})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5, color: disabled ? Tk.subtle : Tk.fg)),
          );
        },
      ),
    );
  }
}
