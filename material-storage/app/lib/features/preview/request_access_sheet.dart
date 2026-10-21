/// 申请权限 bottom sheet(B5 功能点 1/4,对标 web RequestAccessModal 移动版):
/// 动作=访问 access(**仅 target_type=sensitive_folder 可选**,web 同款禁用态)/
/// 下载 download(必填 duration_seconds,五档预设=web DURATION_PRESETS 实况);
/// reason 必填 ≥4 字(web min:4 同口径,前端拦截+后端 422 detail 透传);
/// **后端无「编辑」动作,勿做第三选项**(ApprovalCreateIn.action 仅 download|access)。
library;

import 'package:flutter/material.dart';

import '../../core/api/approvals_api.dart';
import '../../core/session.dart';
import '../../services/app_log.dart';

/// 打开申请面板。[targetType] 契约枚举:sensitive_folder|asset|project|folder。
/// 返回是否已提交成功。
Future<bool> showRequestAccessSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  required String targetName,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _RequestAccessSheet(
        targetType: targetType, targetId: targetId, targetName: targetName),
  );
  return ok ?? false;
}

/// action 可选集(sensitive_folder 才可选 access;下载恒可选)。纯函数可单测。
List<String> allowedActionsOf(String targetType) =>
    targetType == 'sensitive_folder' ? ['access', 'download'] : ['download'];

/// reason 前端校验(web min:4 message=「理由至少 4 个字」):null=合法。
String? reasonError(String raw) =>
    raw.trim().length < 4 ? '理由至少 4 个字' : null;

class _RequestAccessSheet extends StatefulWidget {
  const _RequestAccessSheet({
    required this.targetType,
    required this.targetId,
    required this.targetName,
  });

  final String targetType;
  final String targetId;
  final String targetName;

  @override
  State<_RequestAccessSheet> createState() => _RequestAccessSheetState();
}

class _RequestAccessSheetState extends State<_RequestAccessSheet> {
  late String _action = allowedActionsOf(widget.targetType).first;
  var _duration = 3600; // web initialValues:download 默认 1 小时
  final _reason = TextEditingController();
  var _submitting = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final err = reasonError(_reason.text);
    if (err != null || _submitting) {
      if (err != null && mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(err)));
      }
      return;
    }
    setState(() => _submitting = true);
    try {
      await session.api!.approvals.create(
        targetType: widget.targetType,
        targetId: widget.targetId,
        action: _action,
        durationSeconds: _action == 'download' ? _duration : null,
        reason: _reason.text.trim(),
      );
      AppLog.info('approval',
          '申请已提交:${widget.targetType}/$_action/${widget.targetName}');
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('申请已提交')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 403/400/422 detail 已由 ApiException/extractDetail 透传,原样展示
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('提交失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = allowedActionsOf(widget.targetType);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20, right: 20, top: 0),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('申请 — ${widget.targetName}',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('操作类型'),
          RadioGroup<String>(
            groupValue: _action,
            onChanged: (v) {
              if (v != null) setState(() => _action = v);
            },
            child: Column(children: [
              RadioListTile<String>(
                value: 'access',
                title: const Text('访问(进入敏感目录)'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                // 非 sensitive_folder 禁选(web 同款)
                enabled: allowed.contains('access'),
              ),
              RadioListTile<String>(
                value: 'download',
                title:
                    Text('下载(${widget.targetType == 'asset' ? '单文件' : '批量'})'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          if (_action == 'download') ...[
            const Text('有效期'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (label, seconds) in ApprovalsApi.durationPresets)
                  ChoiceChip(
                    label: Text(label),
                    selected: _duration == seconds,
                    onSelected: (_) => setState(() => _duration = seconds),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _reason,
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '申请理由(至少 4 个字)',
              hintText: '说明为什么需要这个权限,管理员会看到',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? '提交中…' : '提交申请'),
            ),
          ),
        ]),
      ),
    );
  }
}
