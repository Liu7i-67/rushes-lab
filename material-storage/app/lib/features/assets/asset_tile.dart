/// 资产列表行(宫格页 MVP 版式):类型图标 + 文件名 + 大小/日期 + 下载动作。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../models/models.dart';

class AssetTile extends StatelessWidget {
  const AssetTile({
    super.key,
    required this.asset,
    required this.onDownload,
    this.onSaveToAlbum,
  });

  final Asset asset;
  final VoidCallback onDownload;

  /// iOS 实况照片的「存相册」动作;null 时落到通用下载按钮。
  final VoidCallback? onSaveToAlbum;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    return ListTile(
      leading: Icon(
        a.isLivp
            ? Icons.motion_photos_on_outlined
            : Icons.insert_drive_file_outlined,
      ),
      title: Text(
        a.filename,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${fmtBytes(a.sizeBytes)} · ${fmtDate(a.createdAt)}'),
      trailing: onSaveToAlbum != null && a.isLivp
          ? FilledButton.tonal(
              onPressed: onSaveToAlbum,
              child: const Text('存相册'),
            )
          : IconButton(
              icon: const Icon(Icons.download_outlined),
              onPressed: onDownload,
            ),
    );
  }
}
