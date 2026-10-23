/// 一次性临时密码展示(B8;web TempPasswordModal 移动版,创建/重置共用):
/// 「唯一一次展示」文案 + 密码本体 + 复制(不写日志/审计,关闭即不再持有)。
/// R1:modal 态 SnackBar 被本 sheet 遮挡不可见,复制反馈改 CopyButton
/// 就地图标切换(「已复制」SnackBar 删除);墨金重做走 SheetScaffold。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/sheet_scaffold.dart';

/// 打开一次性临时密码展示。
Future<void> showTempPasswordSheet(
  BuildContext context, {
  required String password,
  String title = '临时密码',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TempPasswordSheet(password: password, title: title),
  );
}

class _TempPasswordSheet extends StatelessWidget {
  const _TempPasswordSheet({required this.password, required this.title});

  final String password;
  final String title;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return SheetScaffold(
      title: title,
      // 保持原行为:标题行不带关闭钮(把手/遮罩/返回键关闭)
      showClose: false,
      bottomActions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '这是唯一一次展示,不会写入日志 / 审计。请直接交给对方,首次登录后必须修改。',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3, height: 1.6),
          ),
          const SizedBox(height: Tk.spaceMd),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Tk.spaceMd),
            decoration: BoxDecoration(
              color: tk.surface2,
              borderRadius: BorderRadius.circular(Tk.rSm),
              border: Border.all(color: tk.line),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    password,
                    style: TextStyle(
                      fontSize: Tk.fzTitle,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                      color: tk.ink,
                    ),
                  ),
                ),
                // R1:复制反馈就地化(✓ 1.5s),替代被 sheet 遮挡的 SnackBar
                CopyButton(text: password, tooltip: '复制'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
