/// B0DownloadPocPage — Android 落盘技术验证(方案 §16 B0②;真机结论后随 B4
/// 正式实现移除):asset_id → download-link 下载到 app cache → 两路独立落盘
/// ①photo_manager 系统图库 ②media_store_plus Downloads/浣花视界/。
/// 两路互不阻塞、各自独立报 成功+落点 / 失败+完整错误(真机取证)。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/ms_api.dart' show ApiException, MsApi;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import 'b0_sink_plan.dart';
import 'b0_sinks.dart';

class B0DownloadPocPage extends StatefulWidget {
  const B0DownloadPocPage({
    super.key,
    this.api,
    this.gallerySink,
    this.downloadsSink,
  });

  /// 测试注入;缺省取现役 session 客户端(projects/folders/assets 三域)。
  final MsApi? api;

  /// 平台通道结果注入(PC 单测用);缺省走 b0_sinks.dart 真插件通道。
  final Future<B0SinkOutcome> Function(File file, B0AssetKind kind)?
      gallerySink;
  final Future<B0SinkOutcome> Function(File file)? downloadsSink;

  @override
  State<B0DownloadPocPage> createState() => _B0DownloadPocPageState();
}

class _B0DownloadPocPageState extends State<B0DownloadPocPage> {
  MsApi get _api => widget.api ?? session.api!;

  final _assetIdCtrl = TextEditingController();
  bool _busy = false;
  Asset? _asset;
  String? _localPath;
  B0SinkOutcome? _gallery;
  B0SinkOutcome? _downloads;

  @override
  void dispose() {
    _assetIdCtrl.dispose();
    super.dispose();
  }

  /// 取宫格第一页第一个:projects → folders → assets(GET /assets 需 folder_id)。
  Future<void> _pickFirstAsset() async {
    setState(() => _busy = true);
    try {
      final projects = await _api.projects.list();
      if (projects.isEmpty) throw StateError('无项目');
      final folders = await _api.folders.list(projects.first.id);
      if (folders.isEmpty) throw StateError('首个项目无文件夹');
      final page = await _api.assets.list(folders.first.id, limit: 1, offset: 0);
      if (page.items.isEmpty) throw StateError('首文件夹无资产');
      _assetIdCtrl.text = page.items.first.id;
      setState(() => _asset = page.items.first);
    } catch (e) {
      _say('取第一个资产失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String msg) =>
      AppLog.info('b0', msg); // 仅供日志检索;UI 结果见双路卡片

  Future<void> _run() async {
    final id = _assetIdCtrl.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先输入 asset_id 或点「取第一页第一个」')));
      return;
    }
    setState(() {
      _busy = true;
      _asset = null;
      _localPath = null;
      _gallery = null;
      _downloads = null;
    });
    try {
      final url = await _api.assets.downloadLink(id);
      // 文件名优先取资产行;手输 id 时从下载 URL 末段还原(供分类与命名)
      final urlName = Uri.decodeComponent(Uri.parse(url)
          .pathSegments
          .lastWhere((s) => s.isNotEmpty, orElse: () => ''));
      final name = (_asset?.filename.isNotEmpty ?? false)
          ? _asset!.filename
          : (urlName.isNotEmpty ? urlName : 'b0_poc.bin');
      final cache = await getTemporaryDirectory();
      final save = '${cache.path}/b0_poc_$name';
      await _api.assets.downloadTo(url, save);
      setState(() => _localPath = save);

      // 双路编排(纯函数,可注入平台通道结果):并发启动、互不阻塞;
      // runBothSinks 内部为两路各复制独立副本(Downloads 路 saveFile 会删源,
      // 共用同一文件会让图库路慢一步读不到 → 竞态假失败)
      final kind =
          classifyAsset(filename: name, contentType: _asset?.contentType);
      final (g, d) = await runBothSinks(
        File(save),
        kind,
        gallery: widget.gallerySink ?? b0SaveToGallery,
        downloads: widget.downloadsSink ?? b0SaveToDownloads,
      );
      if (mounted) setState(() => _gallery = g);
      if (mounted) setState(() => _downloads = d);

      // §6:落盘成功后删临时文件;两路全败则保留供取证
      if (g.isOk || d.isOk) {
        File(save).delete().ignore();
      } else {
        AppLog.error('b0', '两路均失败,临时文件保留:$save');
      }
    } on ApiException catch (e) {
      _say('下载失败:${e.message}');
      _showResult('下载失败:${e.message}');
    } catch (e) {
      _say('下载失败:$e');
      _showResult('下载失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showResult(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(msg, style: const TextStyle(fontSize: 12))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('B0 落盘验证(Android)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '下载一个资产到应用缓存后,分别执行两路落盘并独立报结果:'
            '① photo_manager 存系统图库;② media_store_plus 写 '
            'Download/浣花视界/。一路失败不影响另一路。',
            style: TextStyle(fontSize: 13, color: Tk.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _assetIdCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(
                labelText: 'asset_id', hintText: '粘贴资产 ID'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
              onPressed: _busy ? null : _pickFirstAsset,
              child: const Text('取第一页第一个'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _run,
              child: Text(_busy ? '执行中…' : '下载并双路落盘'),
            ),
          ]),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (_localPath != null)
            _Card(
              title: '下载缓存(已就绪)',
              ok: true,
              detail: _localPath!,
            ),
          _Card(
            title: '① 图库路(photo_manager)',
            ok: _gallery?.isOk,
            detail: _gallery?.detail ?? '待执行',
          ),
          _Card(
            title: '② Downloads 路(media_store_plus)',
            ok: _downloads?.isOk,
            detail: _downloads?.detail ?? '待执行',
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.ok, required this.detail});

  final String title;
  final bool? ok; // null=未执行
  final String detail;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (ok) {
      true => (Icons.check_circle, Tk.green),
      false => (Icons.error, Tk.red),
      null => (Icons.hourglass_empty, Tk.subtle),
    };
    return Card(
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 6),
            SelectableText(detail,
                style: const TextStyle(fontSize: 12, color: Tk.muted)),
          ],
        ),
      ),
    );
  }
}
