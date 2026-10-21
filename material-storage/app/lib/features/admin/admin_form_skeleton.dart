/// 管理后台表单通用骨架(B8 拆件):滚动 + 键盘避让 + 错误行 + 提交按钮;
/// 建号/编辑等 sheet 共用,内容超视口时可滚(ensureVisible 提交键可达)。
library;

import 'package:flutter/material.dart';

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
  });

  final String title;
  final List<Widget> children;
  final String submitLabel;
  final bool submitting;
  final VoidCallback onSubmit;
  final String? error;
  final bool submitEnabled;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ...children,
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12.5)),
                ),
              const SizedBox(height: 16),
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
  }
}
