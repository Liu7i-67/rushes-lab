/// 申请权限 bottom sheet(B5 功能点 1/4,对标 web RequestAccessModal 移动版):
/// 动作=访问 access(**仅 target_type=sensitive_folder 可选**,web 同款禁用态)/
/// 下载 download(必填 duration_seconds,五档预设=web DURATION_PRESETS 实况);
/// reason 必填 ≥4 字(web min:4 同口径,前端拦截+后端 422 detail 透传);
/// **后端无「编辑」动作,勿做第三选项**(ApprovalCreateIn.action 仅 download|access)。
/// C7(app-polish):迁移 showAppSheet 统一骨架(把手/标题/关闭/滚动/键盘避让);
/// 理由内联 errorText + 内置字数计数(下限 4 字提示),不再 SnackBar 报校验;
/// 提交错误走 errorMessage + 表单固定错误区(AnimatedSize 不跳动);
/// 成功 toast(success) 在 sheet 关闭后呈现。
library;

import 'package:flutter/material.dart';

import '../../core/api/approvals_api.dart';
import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/haptics.dart';
import '../../core/session.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';

/// 打开申请面板。[targetType] 契约枚举:sensitive_folder|asset|project|folder。
/// 返回是否已提交成功。
Future<bool> showRequestAccessSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  required String targetName,
}) async {
  final ok = await showAppSheet<bool>(
    context: context,
    title: '申请 — $targetName',
    child: _RequestAccessSheet(
        targetType: targetType, targetId: targetId, targetName: targetName),
  );
  if (ok == true) {
    if (!context.mounted) return true; // sheet 已连带给页面卸载(路由层)时不再 toast
    toast(context, '申请已提交', tone: ToastTone.success);
  }
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
  String? _reasonError; // C7:理由内联校验(提交拦截+输入即清)
  String? _submitError; // C7:提交失败固定错误区(errorMessage 中文兜底)

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final err = reasonError(_reason.text);
    setState(() {
      _reasonError = err;
      _submitError = null;
    });
    if (err != null) return; // 内联拦截,不发请求
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
      Haptics.light(); // G2:提交成功轻触
      Navigator.of(context).pop(true); // 成功 toast 由 opener 呈现
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 403/400/422 detail 已由 ApiException/extractDetail 透传,errorMessage
        // 中文兜底后进固定错误区(E14:不再 '$e' 直出)
        _submitError = errorMessage(e, '提交失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = allowedActionsOf(widget.targetType);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            spacing: 6, // chip 间微缝,同 Badge 内距比例保留
            runSpacing: Tk.spaceXs,
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
        const SizedBox(height: Tk.spaceSm),
        TextField(
          controller: _reason,
          minLines: 2,
          maxLines: 4,
          maxLength: 2000, // 内置字数计数(C7)
          onChanged: (_) {
            // 已有内联错误时随输入即时复验,合法即清
            if (_reasonError != null && reasonError(_reason.text) == null) {
              setState(() => _reasonError = null);
            }
          },
          decoration: InputDecoration(
            labelText: '申请理由(至少 4 个字)',
            hintText: '说明为什么需要这个权限,管理员会看到',
            errorText: _reasonError,
          ),
        ),
        // C7:固定错误区(AnimatedSize 过渡,不跳版);errorMessage 中文兜底
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topLeft,
          child: _submitError == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: Tk.spaceXs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 16, color: Tk.red),
                      const SizedBox(width: Tk.spaceXs),
                      Expanded(
                        child: Text(
                          _submitError!,
                          style: const TextStyle(
                              fontSize: Tk.fzSm, color: Tk.red),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: Tk.spaceSm),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting ? '提交中…' : '提交申请'),
          ),
        ),
      ],
    );
  }
}
