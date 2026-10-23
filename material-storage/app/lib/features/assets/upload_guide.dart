/// upload_guide — 上传空态引导 + 跳过清单(upload_sheet 拆件,F8):
/// - [UploadEmptyGuide]:空文件夹图标圆底 + 标题 + 说明 + 上传主操作;
///   已知无上传权时只留说明文案。
/// - [UploadSkip] / [showUploadSkipsSheet]:上传跳过明细(文件名 + 用户可读
///   原因),由汇总 toast 的「查看」action 打开。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/sheet_scaffold.dart';

/// 空文件夹引导(上传第二入口;my_can_upload 已知 false 时 [enabled]=false)。
class UploadEmptyGuide extends StatelessWidget {
  const UploadEmptyGuide({super.key, this.enabled = true, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return const EmptyState(
        icon: Icons.image_outlined,
        message: '空文件夹',
        description: '当前账号没有上传权限,可联系管理员申请。',
      );
    }
    return EmptyState(
      icon: Icons.image_outlined,
      message: '这个文件夹还没有素材',
      description: '上传第一批素材,或从其他文件夹移动进来。',
      actionLabel: '上传素材',
      onAction: onTap,
    );
  }
}

/// 单项跳过明细:文件名 + 用户可读原因(经 errorMessage 中文兜底,
/// 勿直出 StateError/FileSystemException 原文)。
class UploadSkip {
  const UploadSkip({required this.filename, required this.reason});

  final String filename;
  final String reason;

  static String reasonOf(Object error) => errorMessage(error, '无法读取该文件,已跳过');
}

/// 跳过清单 sheet(文件名+原因;由汇总 toast 的「查看」action 打开)。
Future<void> showUploadSkipsSheet(
  BuildContext context, {
  required List<UploadSkip> skips,
  String? where,
}) {
  return showAppSheet<void>(
    context: context,
    title: where == null ? '跳过的文件(${skips.length})' : '跳过的文件 · $where',
    maxHeightFactor: 0.6,
    bottomActions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('知道了'),
      ),
    ],
    child: ListView.builder(
      shrinkWrap: true,
      itemCount: skips.length,
      itemBuilder: (context, i) {
        final s = skips[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_present_outlined, size: 20),
          title: Text(
            s.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: Tk.fzMd),
          ),
          subtitle: Text(
            s.reason,
            style: TextStyle(fontSize: Tk.fzXs, color: context.tk.ink3),
          ),
        );
      },
    ),
  );
}
