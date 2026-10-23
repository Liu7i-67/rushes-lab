/// 管理后台表单通用骨架(B8 拆件;app-polish F5 扩展,墨金重做):
/// SheetScaffold 收口(键盘避让 + 限高滚动 + 标题 + 错误行 + 吸底提交键);
/// 建号/编辑/模板等 sheet 共用。可选 [maxHeightFactor] 约束弹层最大高度
/// (缺省 0.9),供模板表单等长表单限高。
library;

import 'package:flutter/material.dart';

import '../../widgets/sheet_scaffold.dart';

/// 必填/长度校验(表单轻校验;后端 422 detail 仍透传兜底)。
/// [min] 最短长度(默认 1 仅要求非空;建号登录名传 2 = web/后端同款 2-64)。
String? requiredValidator(String? v, {int min = 1, int max = 128}) {
  final s = v?.trim() ?? '';
  if (s.isEmpty) return '必填';
  if (s.length < min) return '至少 $min 字符';
  if (s.length > max) return '最长 $max 字符';
  return null;
}

class FormSkeleton extends StatelessWidget {
  const FormSkeleton({
    super.key,
    required this.title,
    required this.children,
    required this.submitLabel,
    required this.submitting,
    required this.onSubmit,
    this.error,
    this.submitEnabled = true,
    this.maxHeightFactor,
  });

  final String title;
  final List<Widget> children;
  final String submitLabel;
  final bool submitting;
  final VoidCallback onSubmit;
  final String? error;
  final bool submitEnabled;

  /// 视口高度系数上限(如 0.85);null = 默认 0.9。
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: title,
      // 保持原行为:表单标题行不带关闭钮(把手/遮罩/返回键关闭)
      showClose: false,
      errorText: error,
      maxHeightFactor: maxHeightFactor ?? 0.9,
      bottomActions: [
        FilledButton(
          onPressed: submitting || !submitEnabled ? null : onSubmit,
          child: Text(submitting ? '提交中…' : submitLabel),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}
