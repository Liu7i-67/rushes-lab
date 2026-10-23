/// NewProjectNoPermit — 新建项目无权限兜底视图(app-polish-3 自
/// new_project_sheet.dart 拆分;2026-10 墨金重做):文案口径同 web
/// NewProjectModal 无权分支;统一卡片(金浅底锁图标 + 标题 + 说明)+ 吸底
/// 「返回」。关闭一律 pop(false)(未创建),把手/关闭钮都走 onClose。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/handle_strip.dart';
import '../../widgets/sheet_scaffold.dart';

/// 无 is_project_creator 权限时的新建项目面板体(直达兜底)。
class NewProjectNoPermit extends StatelessWidget {
  const NewProjectNoPermit({super.key, required this.onClose});

  /// 关闭(把手下滑/关闭钮/返回):父级传 Navigator.pop(false)。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HandleStrip(onDismiss: onClose),
        SheetScaffold(
          title: '新建项目',
          maxHeightFactor: 0.85, // I3 #5:0.9→0.85,给取消 affordance 留余量
          bottomActions: <Widget>[
            OutlinedButton(onPressed: onClose, child: const Text('返回')),
          ],
          child: AppCard(
            padding: const EdgeInsets.all(Tk.spaceXl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tk.goldSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.lock_outline, size: 24, color: tk.goldInk),
                ),
                const SizedBox(height: Tk.spaceMd),
                Text(
                  '当前账号暂无新建项目权限',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: Tk.fzTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: Tk.spaceSm),
                Text(
                  '需要组织管理员,或加入已开启「允许组成员新建项目」的用户组。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    height: 1.6,
                    color: tk.ink3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
