/// SearchPage — 搜索 tab(§6 F10):PageHeader 大标题 + 46 高搜索框 +
/// 类型 chip 横轨(全部/图片/视频/PDF/Markdown,客户端按 detectKind 过滤);
/// 300ms 防抖 + 取消过期请求(代际 tag + CancelToken)保留;结果放进
/// AppCard(行间 1px 分隔),ResultRow 已重做;50 截断提示保留。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../preview/preview_page.dart';
import 'result_row.dart';

/// 防抖窗口(§8.8 钉子 ~300ms,web SearchPage 同款)。
const kSearchDebounce = Duration(milliseconds: 300);

/// 截断阈值(后端 limit=50;web「结果超过 50 条」同口径)。
const kSearchLimit = 50;

enum _KindFilter { all, image, video, pdf, markdown }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  CancelToken? _cancel;
  int _gen = 0; // 代际 tag:响应回来时对不上即丢弃(旧不覆新)

  String? _query; // 已生效的词(null=未搜索态)
  List<SearchResult>? _results;
  String? _error;
  bool _loading = false;
  var _filter = _KindFilter.all;

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {});
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _query = null;
        _results = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(kSearchDebounce, () => _search(v.trim()));
  }

  /// 键盘提交即时搜索(不等防抖窗口);清空挂起的防抖避免重复请求。
  void _onSubmitted(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) return;
    _search(q);
  }

  Future<void> _search(String q) async {
    final gen = ++_gen;
    _cancel?.cancel();
    final token = CancelToken();
    _cancel = token;
    setState(() {
      _query = q;
      _loading = true;
    });
    try {
      final r = await session.api!.assets.search(
        q,
        limit: kSearchLimit,
        cancelToken: token,
      );
      if (gen != _gen || !mounted) return; // 过期响应丢弃
      setState(() {
        _results = r;
        _error = null;
      });
    } catch (e) {
      if (gen != _gen || !mounted) return;
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      setState(() => _error = errorMessage(e, '搜索失败'));
    } finally {
      if (gen == _gen && mounted) setState(() => _loading = false);
    }
  }

  void _open(SearchResult r) {
    final items = _results ?? const <SearchResult>[];
    Navigator.of(context).pushNamed(
      '/preview',
      arguments: PreviewArgs(
        items: [for (final x in items) x.asset],
        index: items.indexOf(r),
        folderId: r.asset.folderId ?? '',
        canDownload: null,
        where: r.where,
        // 跨文件夹结果:逐素材带 folderId/where,预览按当前张解析(第二轮
        // 复验 P1——整组共用一个 folderId 会把别夹素材的下载权/路径带错)。
        folderIds: {
          for (final x in items) x.asset.id: (x.asset.folderId ?? ''),
        },
        wheres: {for (final x in items) x.asset.id: x.where},
      ),
    );
  }

  /// 客户端类型过滤(不新增 API);图片含 heic/livp。
  bool _matchesFilter(SearchResult r) {
    final k = detectKind(
      filename: r.asset.filename,
      contentType: r.asset.contentType,
    );
    return switch (_filter) {
      _KindFilter.all => true,
      _KindFilter.image =>
        k == PreviewKind.image ||
            k == PreviewKind.heic ||
            k == PreviewKind.livp,
      _KindFilter.video => k == PreviewKind.video,
      _KindFilter.pdf => k == PreviewKind.pdf,
      _KindFilter.markdown => k == PreviewKind.markdown,
    };
  }

  List<SearchResult> get _filtered =>
      (_results ?? const <SearchResult>[]).where(_matchesFilter).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(title: '搜索', subtitle: '搜索文件名 / 标签 / 备注'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceMd,
              Tk.spacePage,
              0,
            ),
            child: SearchField(
              controller: _controller,
              hintText: '搜文件名 / 标签 / 备注',
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
            ),
          ),
          _filterRail(),
          if (_query != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                Tk.spaceXs,
                Tk.spacePage,
                Tk.spaceXs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _statusLine(),
                  style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
                ),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _filterRail() {
    Widget chip(_KindFilter f, String label) => AppChip(
      label: label,
      selected: _filter == f,
      onTap: () => setState(() => _filter = f),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.spaceSm,
      ),
      child: Row(
        spacing: Tk.spaceSm,
        children: [
          chip(_KindFilter.all, '全部'),
          chip(_KindFilter.image, '图片'),
          chip(_KindFilter.video, '视频'),
          chip(_KindFilter.pdf, 'PDF'),
          chip(_KindFilter.markdown, 'Markdown'),
        ],
      ),
    );
  }

  String _statusLine() {
    if (_loading) return '搜索中…';
    return '找到 ${_filtered.length} 个文件';
  }

  Widget _buildBody() {
    final q = _query;
    if (q == null) {
      return const EmptyState(
        icon: Icons.search_outlined,
        title: '输入关键词搜索项目内资产',
        message: '仅返回你有查看权限的文件夹内容',
      );
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: () => _search(q));
    }
    final results = _results;
    if (results == null) {
      return const ListSkeleton(rows: 4);
    }
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有命中「$q」的文件',
        message: '试试标签 / 文件名关键词',
      );
    }
    final tk = context.tk;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceXs,
        Tk.spacePage,
        Tk.spaceXl,
      ),
      children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < filtered.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: tk.line),
                ResultRow(
                  result: filtered[i],
                  query: q,
                  onTap: () => _open(filtered[i]),
                ),
              ],
            ],
          ),
        ),
        if (results.length >= kSearchLimit)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '结果超过 $kSearchLimit 条,MVP 截断 — 用更精确关键词缩小范围',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
            ),
          ),
      ],
    );
  }
}
