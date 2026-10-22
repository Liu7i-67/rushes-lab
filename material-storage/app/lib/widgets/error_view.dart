/// ErrorView — 列表页可重试错误统一件(§4.1:GET 失败留手动重试,不自动重放)。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tk.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40, color: Tk.subtle),
            const SizedBox(height: Tk.spaceMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Tk.muted),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: Tk.spaceMd),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
