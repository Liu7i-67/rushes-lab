/// 一次性临时密码展示(B8;web TempPasswordModal 移动版,创建/重置共用):
/// 「唯一一次展示」文案 + 密码本体 + 复制(不写日志/审计,关闭即不再持有)。
/// R1:modal 态 SnackBar 被本 sheet 遮挡不可见,复制反馈改 CopyButton
/// 就地图标切换(「已复制」SnackBar 删除)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/copy_button.dart';

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
        padding: const EdgeInsets.fromLTRB(
            Tk.spaceXl, 0, Tk.spaceXl, Tk.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Tk.spaceSm),
            const Text(
              '这是唯一一次展示,不会写入日志 / 审计。请直接交给对方,首次登录后必须修改。',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted, height: 1.6),
            ),
            const SizedBox(height: Tk.spaceMd),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Tk.spaceMd),
              decoration: BoxDecoration(
                color: Tk.fill,
                borderRadius: BorderRadius.circular(Tk.rSm),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(password,
                        style: const TextStyle(
                            fontSize: Tk.fzTitle,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w600)),
                  ),
                  // R1:复制反馈就地化(✓ 1.5s),替代被 sheet 遮挡的 SnackBar
                  CopyButton(text: password, tooltip: '复制'),
                ],
              ),
            ),
            const SizedBox(height: Tk.spaceLg),
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
