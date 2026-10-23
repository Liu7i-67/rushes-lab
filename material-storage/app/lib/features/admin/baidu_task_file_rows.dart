/// 百度备份任务文件明细行(自 baidu_task_file_list.dart 拆出,渲染零变化):
/// 单行=相对路径 + 状态/字节/尝试次数字段 + 失败原因 + 行内操作。
/// 操作分流:普通失败行「重试」(non_retryable 置灰)、key_conflict 行
/// 「随机后缀」直发、菜单「覆盖导入」(确认点名占用者)。归属闸门由父级传入
/// isOwner,非本人行全部置灰并给出「仅任务归属者可操作」提示;实际动作由
/// 父级执行(onAction),本件只负责展示与菜单编排。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import 'baidu_file_actions.dart';
import 'baidu_task_labels.dart';

/// 非本人任务的操作提示(操作端点 _own_task 守门,admin 观测不越权)。
const kOwnerOnlyOpsHint = '仅任务归属者可操作';

class BaiduTaskFileRow extends StatelessWidget {
  const BaiduTaskFileRow({
    super.key,
    required this.task,
    required this.file,
    required this.plan,
    required this.isOwner,
    required this.onAction,
  });

  final AdminBaiduTask task;
  final AdminBaiduTaskFile file;
  final FileActionPlan plan;
  final bool isOwner;

  /// 执行行操作:'retry' / 'random-suffix' / 'overwrite'。
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final row = file;
    return ListTile(
      visualDensity: VisualDensity.compact,
      dense: true,
      title: Text(
        row.relPath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: Tk.fzMd, color: tk.ink),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${fileStatusText(row.status)} · ${fmtBytes(row.bytesDone)} · '
            '尝试 ${row.attempts} 次',
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          ),
          if (row.status == 'failed' &&
              row.lastError != null &&
              row.lastError!.isNotEmpty)
            Text(
              row.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Tk.fzXs, color: tk.danger),
            ),
        ],
      ),
      trailing: _opsMenu(context),
      onTap: plan.hasAny && isOwner ? () => _openRowOps(context) : null,
    );
  }

  Widget _opsMenu(BuildContext context) {
    final tk = context.tk;
    final row = file;
    if (!plan.hasAny) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 普通失败行:重试(non_retryable 置灰 = disabled,结构性失败不可自愈);
        // 他人任务全部操作一并置灰(P2-4:_own_task 守门必 404,前端先收敛,
        // 原因见表头 amber「仅任务归属者可操作」)。F2:文字钮加高至 44 触控,
        // shrinkWrap 收边距保持视觉紧凑
        if (plan.canRetry)
          TextButton(
            style: _kRowTextButtonStyle,
            onPressed: isOwner && !row.nonRetryable
                ? () => onAction('retry')
                : null,
            child: Text(
              row.nonRetryable ? '不可重试' : '重试',
              style: TextStyle(
                fontSize: Tk.fzSm,
                color: isOwner && !row.nonRetryable ? tk.goldInk : tk.ink3,
              ),
            ),
          ),
        // key_conflict 行:随机后缀直发(web 同款;换 key 非破坏性)
        if (plan.canResolveConflict)
          TextButton(
            style: _kRowTextButtonStyle,
            onPressed: isOwner ? () => onAction('random-suffix') : null,
            child: Text(
              '随机后缀',
              style: TextStyle(
                fontSize: Tk.fzSm,
                color: isOwner ? null : tk.ink3,
              ),
            ),
          ),
        if (plan.canOverwrite || plan.canResolveConflict)
          // F2:更多操作钮回标准 24 图标(原 18 过小,触控不达标)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_vert),
            tooltip: isOwner ? '更多操作' : kOwnerOnlyOpsHint,
            onPressed: isOwner ? () => _openRowOps(context) : null,
          ),
      ],
    );
  }

  Future<void> _openRowOps(BuildContext context) async {
    final tk = context.tk;
    final row = file;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (plan.canRetry && row.nonRetryable)
              ListTile(
                enabled: false,
                leading: const Icon(Icons.refresh),
                title: const Text('重试(不可用)'),
                subtitle: const Text(kNonRetryableTip),
              ),
            if (plan.canOverwrite || plan.canResolveConflict)
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('覆盖导入'),
                subtitle: Text(
                  confirmText(row, plan).$2,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                iconColor: tk.danger,
                onTap: () => Navigator.of(context).pop('overwrite'),
              ),
            if (plan.canResolveConflict)
              ListTile(
                leading: const Icon(Icons.shuffle_outlined),
                title: const Text('随机后缀导入'),
                subtitle: const Text(kRandomSuffixTip),
                onTap: () => Navigator.of(context).pop('random-suffix'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    onAction(action);
  }
}

/// 密排行内文字钮通用样式(F2):44×44 触控下限 + shrinkWrap 收默认外边距,
/// 视觉紧凑、触控达标。
final ButtonStyle _kRowTextButtonStyle = TextButton.styleFrom(
  minimumSize: const Size(44, 44),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: Tk.spaceSm),
);
