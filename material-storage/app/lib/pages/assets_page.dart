import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/ms_api.dart';
import '../main.dart' show api;
import '../models.dart';
import '../services/album.dart';
import '../services/livp.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage(
      {super.key, required this.folderId, required this.folderName});

  final String folderId;
  final String folderName;

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  late Future<AssetPage> _future;
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _future = api.assets(widget.folderId);
  }

  void _reload() => setState(() => _future = api.assets(widget.folderId));

  void _say(String msg) {
    debugPrint(msg);
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
    if (_log.length > 6) _log.removeRange(6, _log.length);
  }

  // ─── 上传:iOS=相册实况;其他平台=文件选 .livp(PC 验证链路)──────────────
  Future<void> _upload() async {
    try {
      if (AlbumService.isSupported) {
        await AlbumService.ensurePermission();
        if (!mounted) return;
        final picked = await AlbumService.pickLivePhotos(context);
        if (picked.isEmpty) return;
        var i = 0;
        for (final e in picked) {
          i++;
          _say('打包实况 ${e.title ?? e.id}($i/${picked.length})…');
          final bytes = await AlbumService.entityToLivp(e);
          final name = _livpNameOf(e);
          _say('上传 $name …');
          final asset = await api.uploadBytes(
            folderId: widget.folderId,
            filename: name,
            bytes: bytes,
            onPartsDone: (d, t) => _say('$name 分片 $d/$t'),
          );
          _say('✓ 已上传:${asset.filename}');
        }
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['livp'],
          withData: true,
        );
        final f = result?.files.single;
        if (f == null || f.bytes == null) return;
        _say('上传 ${f.name} …');
        final asset = await api.uploadBytes(
          folderId: widget.folderId,
          filename: f.name,
          bytes: f.bytes!,
          onPartsDone: (d, t) => _say('${f.name} 分片 $d/$t'),
        );
        _say('✓ 已上传:${asset.filename}');
      }
      _reload();
    } on ApiException catch (e) {
      _say('上传失败:${e.message}');
    } catch (e) {
      _say('上传失败:$e');
    }
  }

  String _livpNameOf(dynamic e) {
    final title = (e.title as String?) ?? 'IMG_${e.id}';
    final base = title.contains('.')
        ? title.substring(0, title.lastIndexOf('.'))
        : title;
    return '$base.livp';
  }

  // ─── 下载:iOS livp → 存相册;其他 → 存系统临时目录(PC 顺带验证解包)─────
  Future<void> _download(Asset a) async {
    if (a.isLivp && AlbumService.isSupported) {
      await _downloadLivp(a);
      return;
    }
    try {
      final url = await api.downloadLink(a.id, asAttachment: true);
      final save = '${Directory.systemTemp.path}/${a.filename}';
      _say('下载 ${a.filename} …');
      await api.downloadTo(url, save);
      _say('✓ 已保存:$save');
      if (a.isLivp) {
        // PC/Android:验证容器可解包(不存相册)
        final bytes = await File(save).readAsBytes();
        final parts = LivpService.decode(bytes);
        _say('✓ livp 解包 OK:静态图 ${parts.image.name}'
            '${parts.video != null ? ' + 视频 ${parts.video!.name}' : ' (无视频)'}');
      }
    } on ApiException catch (e) {
      _say('下载失败:${e.message}');
    } catch (e) {
      _say('下载失败:$e');
    }
  }

  Future<void> _downloadLivp(Asset a) async {
    try {
      final url = await api.downloadLink(a.id, asAttachment: true);
      final dir = Directory.systemTemp;
      final save = '${dir.path}/${a.filename}';
      _say('下载 ${a.filename} …');
      await api.downloadTo(url, save);
      final bytes = await File(save).readAsBytes();
      await AlbumService.saveLivpToAlbum(bytes);
      _say('✓ 已存入相册(实况照片)');
    } on ApiException catch (e) {
      _say('下载失败:${e.message}');
    } catch (e) {
      _say('存相册失败:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _upload,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(AlbumService.isSupported ? '上传实况' : '上传 livp'),
      ),
      body: Column(
        children: [
          if (_log.isNotEmpty)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in _log.take(3))
                    Text(l,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          Expanded(
            child: FutureBuilder<AssetPage>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: FilledButton.tonal(
                        onPressed: _reload, child: Text('${snap.error}')),
                  );
                }
                final items = snap.data?.items ?? const [];
                if (items.isEmpty) {
                  return const Center(child: Text('空文件夹'));
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final a = items[i];
                      return ListTile(
                        leading: Icon(a.isLivp
                            ? Icons.motion_photos_on_outlined
                            : Icons.insert_drive_file_outlined),
                        title: Text(a.filename,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${_fmtSize(a.sizeBytes)} · ${a.createdAt.length >= 10 ? a.createdAt.substring(0, 10) : a.createdAt}'),
                        trailing: a.isLivp && AlbumService.isSupported
                            ? FilledButton.tonal(
                                onPressed: () => _downloadLivp(a),
                                child: const Text('存相册'),
                              )
                            : IconButton(
                                icon: const Icon(Icons.download_outlined),
                                onPressed: () => _download(a),
                              ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtSize(num n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
