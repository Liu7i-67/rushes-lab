/// NewProjectNoPermit — 新建项目无权限兜底视图(自 new_project_sheet.dart
/// 拆分,app-polish-3):文案口径同 web NewProjectModal 无权分支;关闭一律
/// pop(false)(未创建),把手/关闭钮都走 onClose,由调用方决定去向。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/handle_strip.dart';
import '../../widgets/sheet_scaffold.dart';

/// 无 is_project_creator 权限时的新建项目面板体(直达兜底)。
class NewProjectNoPermit extends StatelessWidget {
  const NewProjectNoPermit({super.key, required this.onClose});

  /// 关闭(把手下滑/关闭钮):父级传 Navigator.pop(false)。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HandleStrip(onDismiss: onClose),
        SheetScaffold(
          title: '新建项目',
          maxHeightFactor: 0.85, // I3 #5:0.9→0.85,给取消 affordance 留余量
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 32, color: Tk.subtle),
              const SizedBox(height: Tk.spaceSm),
              const Text('当前账号暂无新建项目权限',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: Tk.spaceXs),
              const Text(
                  '需要组织管理员,或加入已开启「允许组成员新建项目」的用户组。',
                  style: TextStyle(fontSize: Tk.fzSm, color: Tk.subtle)),
              const SizedBox(height: Tk.spaceLg),
              OutlinedButton(onPressed: onClose, child: const Text('关闭')),
            ],
          ),
        ),
      ],
    );
  }
}
