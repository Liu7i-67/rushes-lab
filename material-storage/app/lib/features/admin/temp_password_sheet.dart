/// 一次性临时密码展示(B8;web TempPasswordModal 移动版,创建/重置共用):
/// 「唯一一次展示」文案 + 密码本体 + 复制(不写日志/审计,关闭即不再持有)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';

/// 打开一次性临时密码展示。
Future<void> showTempPasswordSheet(
  BuildContext context, {
  required String password,
  String title = '临时密码',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _TempPasswordSheet(password: password, title: title),
  );
}

class _TempPasswordSheet extends StatelessWidget {
  const _TempPasswordSheet({required this.password, required this.title});

  final String password;
  final String title;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '这是唯一一次展示,不会写入日志 / 审计。请直接交给对方,首次登录后必须修改。',
              style: TextStyle(fontSize: 12.5, color: Tk.muted, height: 1.6),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Tk.fill,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(password,
                        style: const TextStyle(
                            fontSize: 16,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    tooltip: '复制',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: password));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制')));
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
