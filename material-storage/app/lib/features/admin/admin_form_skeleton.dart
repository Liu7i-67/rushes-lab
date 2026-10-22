/// 管理后台表单通用骨架(B8 拆件;app-polish F5 扩展):滚动 + 键盘避让 +
/// 错误行 + 提交按钮;建号/编辑等 sheet 共用,内容超视口时可滚(ensureVisible
/// 提交键可达)。可选 [maxHeightFactor] 约束弹层最大高度(视口高度系数),
/// 供模板表单等长表单限高 0.85——不传保持原行为(API 向后兼容)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

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

  /// 视口高度系数上限(如 0.85);null = 不限高(原有调用方行为不变)。
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    Widget body = SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Tk.spaceXl, 0, Tk.spaceXl,
            Tk.spaceLg + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Tk.spaceMd),
              ...children,
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Tk.spaceSm),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: Tk.fzSm)),
                ),
              const SizedBox(height: Tk.spaceLg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: submitting || !submitEnabled ? null : onSubmit,
                  child: Text(submitting ? '提交中…' : submitLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final factor = maxHeightFactor;
    if (factor != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * factor),
        child: body,
      );
    }
    return body;
  }
}

