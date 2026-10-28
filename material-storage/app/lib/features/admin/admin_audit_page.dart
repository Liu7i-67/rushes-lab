/// AdminAuditPage — 审计(B8 功能点 4;web AdminAuditPage 移动版):
/// 快捷 chip 轨 + 事件类型/项目/操作者/单日时间四项精细筛选(收拢右侧
/// endDrawer,页头「筛选」钮进入;生效筛选数>0 时按钮带 Material Badge 计数)+
/// 金色竖线时间线 + 分页自动加载 + CSV 导出(dio 带会话,禁 url_launcher)。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api/audit_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'admin_auto_load.dart';
import 'audit_event_card.dart';
import 'audit_export.dart';
import 'audit_filter_bar.dart';

const _kAuditPageSize = 30; // 页大小(web AdminAuditPage PAGE_SIZE 同款)

class AdminAuditPage extends StatefulWidget {
  const AdminAuditPage({super.key});

  @override
  State<AdminAuditPage> createState() => _AdminAuditPageState();
}

class _AdminAuditPageState extends State<AdminAuditPage>
    with AutoLoadScroll<AdminAuditPage> {
  String _eventType = '';
  UserBrief? _actor; // null=全部(操作者筛选;value=users.id UUID)
  String _projectId = '';
  DateTime? _day;
  var _items = <AuditEvent>[];
  var _loading = true;
  var _loadingMore = false;
  var _exporting = false;
  String? _error;
  var _reloadTag = 0;
  var _projects = <Project>[];

  /// 审计无 total 字段:单页不足 _kAuditPageSize 即视为取完,停止触发(F6)。
  var _exhausted = false;

  AuditFilter get _filter => AuditFilter(
    eventType: _eventType,
    actorUserId: _actor?.id ?? '',
    projectId: _projectId,
    from: _day == null
        ? null
        : DateTime(
            _day!.year,
            _day!.month,
            _day!.day,
          ).toUtc().toIso8601String(),
    to: _day == null
        ? null
        : DateTime(
            _day!.year,
            _day!.month,
            _day!.day,
            23,
            59,
            59,
            999,
          ).toUtc().toIso8601String(),
  );

  @override
  void onAutoLoad() => _loadMore();

  @override
  void initState() {
    super.initState();
    _reload();
    _loadProjects();
  }

  /// 全量项目(web useAllProjects 循环翻页拉全;limit=100 单页)。
  Future<void> _loadProjects() async {
    final out = <Project>[];
    try {
      for (var offset = 0; ; offset += 100) {
        final page = await session.api!.projects.listPaged(
          limit: 100,
          offset: offset,
        );
        out.addAll(page);
        if (page.length < 100) break;
      }
      if (!mounted) return;
      setState(() => _projects = out);
    } catch (_) {
      // 项目筛选选项加载失败不阻塞审计列表(选项缺失而已)
    }
  }

  Future<void> _reload() async {
    final tag = ++_reloadTag;
    setState(() {
      _loading = _items.isEmpty;
      _exhausted = false;
    });
    try {
      final items = await session.api!.audit.list(
        filter: _filter,
        limit: _kAuditPageSize,
        offset: 0,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
        _exhausted = items.length < _kAuditPageSize;
      });
    } on ApiException catch (e) {
      _fail(tag, e.message);
    } catch (e) {
      _fail(tag, errorMessage(e, '加载失败,请稍后重试'));
    }
  }

  /// 到底自动加载(F6):守卫在途/未满页;失败 toast,滚动可再次触发。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _exhausted) return;
    setState(() => _loadingMore = true);
    final tag = _reloadTag;
    try {
      final items = await session.api!.audit.list(
        filter: _filter,
        limit: _kAuditPageSize,
        offset: _items.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items = [..._items, ...items];
        _loadingMore = false;
        if (items.length < _kAuditPageSize) _exhausted = true;
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
  }

  /// CSV 导出:dio 带会话拉字节 → 落盘矩阵(禁 url_launcher);结果 toast。
  Future<void> _exportCsv() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final (bytes, disposition) = await session.api!.audit.exportCsv(
        filter: _filter,
      );
      if (!mounted) return;
      if (!looksLikeCsv(bytes)) {
        toast(context, '导出响应异常(非 CSV),请稍后再试', tone: ToastTone.error);
        return;
      }
      // 文件名取响应头 Content-Disposition,解析失败回落时间戳名(P2-5)
      final filename = csvFilenameFromDisposition(disposition, DateTime.now());
      final summary = await saveExportedCsv(bytes, filename);
      if (!mounted) return;
      toast(context, '已导出 $filename:$summary', tone: ToastTone.success);
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 403/422 detail 透传
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '导出失败,请稍后重试'), tone: ToastTone.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 单日筛选:选完即重查(00:00/23:59:59.999 本地→UTC 折算在 _filter)。
  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    setState(() => _day = d);
    _reload();
  }

  void _setEventType(String v) {
    if (_eventType == v) return;
    setState(() => _eventType = v);
    _reload();
  }

  /// 重置筛选(抽屉「重置」回调):四值清空后重查,即时生效语义不变。
  void _resetFilters() {
    setState(() {
      _eventType = '';
      _projectId = '';
      _actor = null;
      _day = null;
    });
    _reload();
  }

  /// 生效筛选计数 = 四项之和(eventType≠''/projectId≠''/actor≠null/day≠null);
  /// chip 轨改 eventType 同计入,口径为「当前生效筛选总数」。
  int get _activeFilterCount =>
      (_eventType.isEmpty ? 0 : 1) +
      (_projectId.isEmpty ? 0 : 1) +
      (_actor == null ? 0 : 1) +
      (_day == null ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    // 抽屉宽度:min(屏宽×0.85, 400),由外层 Drawer 控制
    final drawerWidth = math.min(
      MediaQuery.sizeOf(context).width * 0.85,
      400.0,
    );
    return Scaffold(
      // 4 项精细筛选收拢右侧抽屉;抽屉受控无状态,改动回调即 _reload
      endDrawer: Drawer(
        width: drawerWidth,
        child: AuditFilterDrawer(
          eventType: _eventType,
          projectId: _projectId,
          actor: _actor,
          day: _day,
          projects: _projects,
          onEventTypeChanged: _setEventType,
          onProjectChanged: (v) {
            setState(() => _projectId = v);
            _reload();
          },
          onActorChanged: (v) {
            setState(() => _actor = v.isEmpty ? null : v.first);
            _reload();
          },
          onPickDate: _pickDay,
          onClearDate: () {
            setState(() => _day = null);
            _reload();
          },
          onReset: _resetFilters,
        ),
      ),
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '审计日志',
            subtitle: '关键操作留痕，保留 180 天',
            actions: [
              // 「筛选」钮需 Scaffold.of 开 endDrawer,PageHeader 不下发
              // context,用 Builder 取 Scaffold 内层 context
              Builder(
                builder: (btnCtx) {
                  final btn = IconButton(
                    key: const Key('audit_filter_btn'),
                    tooltip: '筛选',
                    onPressed: () => Scaffold.of(btnCtx).openEndDrawer(),
                    icon: const Icon(Icons.tune),
                  );
                  // 生效筛选数>0 时套 Material 3 Badge 显示计数
                  // (material 的 Badge,非 widgets/badge.dart 自研同名件)
                  final n = _activeFilterCount;
                  return n > 0 ? Badge(label: Text('$n'), child: btn) : btn;
                },
              ),
              IconButton(
                tooltip: '导出 CSV',
                onPressed: _exporting ? null : _exportCsv,
                icon: _exporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
              ),
            ],
          ),
          AuditQuickChips(value: _eventType, onChanged: _setEventType),
          const SizedBox(height: Tk.spaceSm),
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
      return const EmptyState(icon: Icons.history, message: '无匹配记录');
    }
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        0,
        Tk.spacePage,
        Tk.space2xl,
      ),
      children: [
        SectionCard(
          children: [for (final e in _items) AuditEventCard(event: e)],
        ),
        // 首页未满页 = 已取完:仅留收尾缝;否则 F6 自动加载指示器
        if (_exhausted)
          const SizedBox(height: Tk.spaceXl)
        else
          AutoLoadFooter(loading: _loadingMore, onTap: _loadMore),
      ],
    );
  }
}
