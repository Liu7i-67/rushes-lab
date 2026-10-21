/// AdminBaiduTasksPage — 备份任务(管理)(B8 功能点 7;web AdminBaiduTasksPage
/// 移动版):全系统百度备份任务只读观测——状态 chips 筛选 + q 搜索
/// (用户名/姓名/源目录)+ 服务端分页 + 行点开详情(含文件明细与文件级三操作)。
/// 存在活动任务时 15s 轮询(web 同款;纯 setState 刷新不引依赖)。 admin 看
/// 原始 status,不做 queued 派生(方案 §3.2)。require_system_admin。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'baidu_task_detail_sheet.dart';
import 'baidu_task_labels.dart';

/// 列表页大小(web PAGE_SIZE 同款)。
const kAdminTasksPageSize = 20;

class AdminBaiduTasksPage extends StatefulWidget {
  const AdminBaiduTasksPage({super.key});

  @override
  State<AdminBaiduTasksPage> createState() => _AdminBaiduTasksPageState();
}

class _AdminBaiduTasksPageState extends State<AdminBaiduTasksPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  Timer? _poll;
  String _status = '';
  var _items = <AdminBaiduTask>[];
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  String? _error;
  var _reloadTag = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _poll?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _syncPoll() {
    final hasActive = _items.any((t) => t.isActive);
    if (hasActive && _poll == null) {
      // 存在活动任务(enumerating/running)时 15s 轮询,无则不轮(web 同款)
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _reload());
    } else if (!hasActive && _poll != null) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _reload() async {
    final tag = ++_reloadTag;
    setState(() => _loading = _items.isEmpty);
    try {
      final page = await session.api!.adminBaidu.listTasks(
        status: _status.isEmpty ? null : _status,
        q: _search.text.trim(),
        limit: kAdminTasksPageSize,
        offset: 0,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items = page.items;
        _total = page.total;
        _loading = false;
        _error = null;
      });
      _syncPoll();
    } on ApiException catch (e) {
      _fail(tag, e.message);
    } catch (e) {
      _fail(tag, '$e');
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final tag = _reloadTag;
    try {
      final page = await session.api!.adminBaidu.listTasks(
        status: _status.isEmpty ? null : _status,
        q: _search.text.trim(),
        limit: kAdminTasksPageSize,
        offset: _items.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _fail(int tag, String message) {
    if (tag != _reloadTag || !mounted) return;
    setState(() {
      _error = message; // 403 detail 透传(非 admin 深链兜底)
      _loading = false;
    });
    _syncPoll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份任务')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 300), _reload);
              },
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜用户名 / 姓名 / 源目录…',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (key, label) in const [
                  ('', '全部状态'),
                  ('enumerating', '清单准备中'),
                  ('running', '进行中'),
                  ('completed', '已完成'),
                  ('cancelled', '已取消'),
                  ('failed', '失败'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _status == key,
                      onSelected: (_) {
                        setState(() => _status = key);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('共 $_total 个任务',
                  style: const TextStyle(fontSize: 11.5, color: Tk.subtle)),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (_items.isEmpty) {
      return const EmptyState(message: '暂无备份任务');
    }
    return ListView.builder(
      itemCount: _items.length + (_items.length < _total ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? '加载中…' : '加载更多')),
          );
        }
        return _TaskRow(task: _items[i], onChanged: _reload);
      },
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onChanged});

  final AdminBaiduTask task;
  final VoidCallback onChanged;

  BadgeTone get _tone => baiduTaskTone(task.status);

  @override
  Widget build(BuildContext context) {
    final t = task;
    // enumerating 阶段清单未就绪(聚合列 NULL→0),不渲染进度(web 同款改进)
    return ListTile(
      visualDensity: VisualDensity.compact,
      title: Row(children: [
        Flexible(
          child: Text(t.user.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        Badge(label: kTaskStatusLabels[t.status] ?? t.status, tone: _tone),
        const Spacer(),
        if (t.failedFiles > 0)
          Text('失败 ${t.failedFiles}',
              style: const TextStyle(fontSize: 11, color: Tk.red)),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.sourceDir,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5)),
          Text(
            '${t.project.name} / ${t.targetFolder?.name ?? '已删'} · '
            '${t.status == 'enumerating' ? '清单准备中' : '${t.progressPct}%'} · '
            '创建于 ${fmtIsoShort(t.createdAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11,
                color: t.targetFolder == null ? Tk.amber : Tk.muted),
          ),
          if (t.failReason != null)
            Text(
                '失败原因:${kFailReasonLabels[t.failReason] ?? t.failReason}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Tk.red)),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        // 详情内文件级操作成功后返回 true → 刷新列表(任务状态/计数可能已变)
        final changed = await showBaiduTaskDetailSheet(context, t);
        if (changed) onChanged();
      },
    );
  }
}
