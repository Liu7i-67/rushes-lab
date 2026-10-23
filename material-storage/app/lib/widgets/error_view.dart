/// ErrorView — 列表页可重试错误统一件(§4.1:GET 失败留手动重试,不自动重放)。
/// 视觉对齐 EmptyState:56 圆底 + 26 图标 + 13.5 说明 + 42 高重试钮。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tk.spacePage),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tk.surface3,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.cloud_off_outlined, size: 26, color: tk.ink3),
            ),
            const SizedBox(height: Tk.spaceLg),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: tk.ink3),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: Tk.spaceLg),
              OutlinedButton(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(44, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
