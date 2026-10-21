/// ApprovalCard — 审批行卡片(B7 §8.6,web ApprovalRow 移动版):
/// 状态徽标 + 申请人 + 动作 + 对象(target_name 优先)+ 用途 reason +
/// 有效时长/决策备注;待审 + scope=all 显示 通过/拒绝(带确认)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// 状态 → 徽标 tone(pending=amber/approved=green/rejected=red/其余=neutral)。
BadgeTone statusTone(String status) => switch (status) {
      'pending' => BadgeTone.amber,
      'approved' => BadgeTone.green,
      'rejected' => BadgeTone.red,
      _ => BadgeTone.neutral,
    };

/// 有效时长(web formatDuration 实况):分/时/天取整;null=永久。
String fmtDuration(int? seconds) {
  if (seconds == null) return '永久';
  if (seconds < 3600) return '${(seconds / 60).round()} 分';
  if (seconds < 86400) return '${(seconds / 3600).round()} 时';
  return '${(seconds / 86400).round()} 天';
}

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.decidable,
    this.busy = false,
    this.onApprove,
    this.onReject,
  });

  final Approval approval;

  /// scope=all 且 status=pending 才出决策按钮(web canDecide 同口径)。
  final bool decidable;

  /// 决策请求 in-flight(按钮禁用防连点)。
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final a = approval;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Tk.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Badge(label: a.statusLabel, tone: statusTone(a.status)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${a.targetTypeLabel} · ${a.targetLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${a.requesterName ?? '用户'} 申请${a.actionLabel}'
            ' · ${fmtDuration(a.durationSeconds)}',
            style: const TextStyle(fontSize: 12.5, color: Tk.muted),
          ),
          const SizedBox(height: 6),
          Text(
            a.reason,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
          if ((a.decisionNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('说明:${a.decisionNote}',
                style: const TextStyle(
                    fontSize: 12, color: Tk.subtle, fontStyle: FontStyle.italic)),
          ],
          if (decidable) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : onReject,
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : onApprove,
                  child: const Text('批准'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
