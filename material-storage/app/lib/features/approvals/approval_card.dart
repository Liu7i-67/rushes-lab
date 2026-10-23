/// ApprovalCard — 审批卡(§6 F13,AppCard 风格):申请人首字 + 姓名/时间 +
/// 状态徽标;surface2 信息块(申请对象 / 权限 · 有效期 / 理由 / 决策备注);
/// 待审 + scope=all 显示 拒绝(ghost)/批准(金 Filled),busy 禁用防连点。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';

/// 状态 → 徽标 tone(pending=warn/approved=ok/rejected=danger/其余=neutral)。
BadgeTone statusTone(String status) => switch (status) {
  'pending' => BadgeTone.warn,
  'approved' => BadgeTone.ok,
  'rejected' => BadgeTone.danger,
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
    final tk = context.tk;
    final a = approval;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(Tk.spaceLg, 14, Tk.spaceLg, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tk.goldSoft,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _initial(a.requesterName),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tk.goldInk,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.requesterName ?? '用户',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: tk.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fmtRelativeTime(a.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Badge(label: a.statusLabel, tone: statusTone(a.status)),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: tk.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _InfoLine(
                  label: '申请对象',
                  value: '${a.targetTypeLabel} · ${a.targetLabel}',
                ),
                _InfoLine(
                  label: '权限 / 有效期',
                  value: '${a.actionLabel} · ${fmtDuration(a.durationSeconds)}',
                ),
                _InfoLine(
                  label: '理由',
                  value: a.reason.isEmpty ? '—' : a.reason,
                  maxLines: 3,
                ),
                if ((a.decisionNote ?? '').isNotEmpty)
                  _InfoLine(label: '决策备注', value: a.decisionNote!, maxLines: 3),
              ],
            ),
          ),
          if (decidable) ...[
            const SizedBox(height: Tk.spaceMd),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onReject,
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: Tk.spaceSm),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onApprove,
                    child: const Text('批准'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 申请人首字(空名兜底「用」)。
  static String _initial(String? name) {
    final n = name?.trim() ?? '';
    return n.isEmpty ? '用' : String.fromCharCode(n.runes.first);
  }
}

/// 信息块单行:左标签(13/ink3) + 右值(13/ink,右对齐,可截断)。
class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.label,
    required this.value,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: Tk.fzMd,
                height: 1.5,
                fontWeight: FontWeight.w500,
                color: tk.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
