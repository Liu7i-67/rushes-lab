/// SearchPage — 搜索 tab(B7 §8.8 + app-polish E9 精修):onSubmitted 即时
/// 搜索 + 300ms 防抖并存 + 取消过期请求(代际 tag + CancelToken 双保险,旧
/// 响应不覆盖新输入);统一 SearchField(主题圆角,去自定义半径);未搜索态
/// 引导卡(大图标+说明);结果行=缩略图+高亮+归属+类型徽标;点击 push 预览
/// (结果序列做胶片条);50 截断提示(web 同款文案);空态/无结果态。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../../widgets/search_field.dart';
import '../preview/preview_page.dart';
import 'result_row.dart';

/// 防抖窗口(§8.8 钉子 ~300ms,web SearchPage 同款)。
const kSearchDebounce = Duration(milliseconds: 300);

/// 截断阈值(后端 limit=50;web「结果超过 50 条」同口径)。
const kSearchLimit = 50;

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

  /// E9:键盘提交即时搜索(不等防抖窗口);清空挂起的防抖避免重复请求。
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
      final r =
          await session.api!.assets.search(q, limit: kSearchLimit, cancelToken: token);
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
    Navigator.of(context).pushNamed('/preview', arguments: PreviewArgs(
      items: [for (final x in items) x.asset],
      index: items.indexOf(r),
      folderId: r.asset.folderId ?? '',
      canDownload: null,
      where: r.where,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            // E9:统一 SearchField(圆角吃主题输入档,原自定义 10 已删)
            child: SearchField(
              controller: _controller,
              hintText: '搜文件名 / 标签 / 备注',
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
            ),
          ),
          // E9:常驻帮助行移除——仅已搜索态保留结果计数(未搜索态落引导卡)
          if (_query != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_statusLine(),
                    style: const TextStyle(
                        fontSize: Tk.fzSm, color: Tk.subtle)),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  String _statusLine() {
    if (_loading) return '搜索中…';
    return '找到 ${_results?.length ?? 0} 个文件';
  }

  Widget _buildBody() {
    final q = _query;
    // E9:未搜索态引导卡(大图标+说明,替代原空白菜区)
    if (q == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_outlined, size: 56, color: Tk.subtle),
            const SizedBox(height: Tk.spaceMd),
            const Text(
              '输入关键词搜索项目内资产',
              style: TextStyle(color: Tk.muted, fontSize: Tk.fzBody),
            ),
            const SizedBox(height: Tk.spaceSm),
            const Text(
              '仅返回你有查看权限的文件夹内容',
              style: TextStyle(color: Tk.subtle, fontSize: Tk.fzMd),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: () => _search(q));
    }
    final results = _results;
    if (results == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (results.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        Center(
          child: Text('没有命中「$q」的文件\n试试标签 / 文件名关键词',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Tk.subtle, fontSize: Tk.fzBody)),
        ),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
          Tk.spaceLg, 6, Tk.spaceLg, Tk.spaceXl),
      itemCount: results.length + (results.length >= kSearchLimit ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: Tk.spaceSm),
      itemBuilder: (context, i) {
        if (i >= results.length) {
          // 50 截断提示(web SearchPage 同款文案)
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '结果超过 $kSearchLimit 条,MVP 截断 — 用更精确关键词缩小范围',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: Tk.fzSm, color: Tk.subtle),
            ),
          );
        }
        final r = results[i];
        return ResultRow(result: r, query: q, onTap: () => _open(r));
      },
    );
  }
}
