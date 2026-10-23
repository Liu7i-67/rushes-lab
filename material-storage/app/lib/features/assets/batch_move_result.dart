/// BatchMoveResultView — 批量移动结果视图(P2-10 从 assets_body 迁出,
/// 职责归位):主行沿用用户口径,跳过按原因分组并显示文件名,待同步权限
/// 单独一行。纯展示,数据由 batch_move_sheet 提交结果传入。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';

/// 跳过行显示名:文件名命中显示文件名;缺名兜底截断 id 并注明。
String batchMoveSkipLabel(String assetId, Map<String, String>? assetNames) {
  final name = assetNames?[assetId];
  if (name != null && name.isNotEmpty) return name;
  final short = assetId.length > 12 ? '${assetId.substring(0, 12)}…' : assetId;
  return '$short(未取得文件名)';
}

/// 批量移动结果视图(纯展示;batch_move_sheet 的确认子件)。
class BatchMoveResultView extends StatelessWidget {
  const BatchMoveResultView({
    super.key,
    required this.result,
    required this.submitted,
    this.assetNames,
  });

  final AssetBatchMoveResult result;
  final int submitted;
  final Map<String, String>? assetNames;

  @override
  Widget build(BuildContext context) {
    final pending = result.fgaPending.length;
    final skipped = result.skipped;
    final headline = result.movedCount == 0
        ? '本次未移动任何文件(共提交 $submitted 个)'
        : skipped.isEmpty
        ? '成功移动 ${result.movedCount} 个文件(共提交 $submitted 个)'
        : '已移动 ${result.movedCount} 项,${skipped.length} 项跳过'
              '(共提交 $submitted 个)';
    final groups = <String, List<AssetBatchMoveSkip>>{};
    for (final s in skipped) {
      groups.putIfAbsent(s.reason, () => []).add(s);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline),
        for (final e in groups.entries) ...[
          const SizedBox(height: Tk.spaceSm),
          Text(
            '${AssetBatchMoveSkip.reasonLabel(e.key)} ${e.value.length} 项',
            style: const TextStyle(
              fontSize: Tk.fzSm,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            e.value
                .take(20)
                .map((s) => '· ${batchMoveSkipLabel(s.assetId, assetNames)}')
                .join('\n'),
            maxLines: 20,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (pending > 0) ...[
          const SizedBox(height: Tk.spaceSm),
          Text(
            '权限同步待完成 $pending 个:文件已移动,系统将自动重试修复。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
