/// AdminBaiduTasksPage — 备份任务(管理)(B8 功能点 7;web AdminBaiduTasksPage
/// 移动版):全系统百度备份任务只读观测——状态 chip 筛选 + q 搜索
/// (用户名/姓名/源目录)+ 服务端分页 + 行点开详情(含文件明细与文件级三操作)。
/// 存在活动任务时 15s 轮询(web 同款;纯 setState 刷新不引依赖)。 admin 看
/// 原始 status,不做 queued 派生(方案 §3.2)。require_system_admin。
/// 视觉:PageHeader + 状态 chip 轨 + SectionCard 行卡。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../../widgets/toast.dart';
import 'admin_auto_load.dart';
import 'baidu_task_detail_sheet.dart';
import 'baidu_task_labels.dart';

/// 列表页大小(web PAGE_SIZE 同款)。
const kAdminTasksPageSize = 20;

class AdminBaiduTasksPage extends StatefulWidget {
  const AdminBaiduTasksPage({super.key});

  @override
  State<AdminBaiduTasksPage> createState() => _AdminBaiduTasksPageState();
}

class _AdminBaiduTasksPageState extends State<AdminBaiduTasksPage>
    with AutoLoadScroll<AdminBaiduTasksPage> {
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
    super.initState(); // AutoLoadScroll:挂滚动监听
    _reload();
  }

  @override
  void onAutoLoad() => _loadMore();

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
      _fail(tag, errorMessage(e, '加载失败,请稍后重试'));
    }
  }

  /// 到底自动加载(F6):加载中/已取全守卫;失败 toast,滚动可再次触发。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _items.length >= _total) return;
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      toast(context, errorMessage(e, '加载失败,请稍后重试'), tone: ToastTone.error);
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
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '备份任务',
            subtitle: _loading ? '全站备份视图' : '全站 $_total 个任务 · 只读观测',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              0,
            ),
            child: SearchField(
              controller: _search,
              hintText: '搜用户名 / 姓名 / 源目录…',
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _reload);
              },
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                Tk.spaceSm,
                Tk.spacePage,
                0,
              ),
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
                    padding: const EdgeInsets.only(right: Tk.spaceSm),
                    child: AppChip(
                      label: label,
                      selected: _status == key,
                      onTap: () {
                        setState(() => _status = key);
                        _reload();
                      },
                    ),
                  ),
              ],
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
      return const EmptyState(
        icon: Icons.cloud_off_outlined,
        message: '暂无备份任务',
      );
    }
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.space2xl,
      ),
      children: [
        SectionCard(
          children: [
            for (final t in _items) _TaskRow(task: t, onChanged: _reload),
          ],
        ),
        if (_items.length < _total)
          AutoLoadFooter(loading: _loadingMore, onTap: _loadMore),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onChanged});

  final AdminBaiduTask task;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final t = task;
    // enumerating 阶段清单未就绪(聚合列 NULL→0),不渲染进度(web 同款改进)
    final progress = t.status == 'enumerating' ? '清单准备中' : '${t.progressPct}%';
    final target = t.targetFolder?.name ?? '已删';
    return AppRow(
      leading: const Icon(Icons.cloud_outlined),
      title: t.user.name,
      subtitle:
          '${t.sourceDir} · ${t.project.name} / $target · $progress'
          ' · 创建于 ${fmtIsoShort(t.createdAt)}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.failedFiles > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '失败 ${t.failedFiles}',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
              ),
            ),
          Badge(
            label: kTaskStatusLabels[t.status] ?? t.status,
            tone: baiduTaskTone(t.status),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 18, color: tk.ink3),
        ],
      ),
      onTap: () async {
        // 详情内文件级操作成功后返回 true → 刷新列表(任务状态/计数可能已变)
        final changed = await showBaiduTaskDetailSheet(context, t);
        if (changed) onChanged();
      },
    );
  }
}
