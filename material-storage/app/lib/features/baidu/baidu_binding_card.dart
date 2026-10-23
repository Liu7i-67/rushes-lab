/// 百度绑定状态卡(B9 §8.10,自 baidu_page 拆件守 300 行硬顶;web
/// BindingHeader 移动版):云图标 + 账号·授权期 + 状态徽标(已绑定 ok /
/// 过期 warn / 未绑定 neutral)+ 绑定/切换(金色浅底)+ 新建任务(金色主钮)
/// + 解绑(红字)+ 过期提示 + 授权用途告知(12/ink3)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';

class BaiduBindingCard extends StatelessWidget {
  const BaiduBindingCard({
    super.key,
    required this.binding,
    required this.loaded,
    required this.busy,
    required this.onBind,
    required this.onNewTask,
    required this.onUnbind,
  });

  final BaiduBindingInfo? binding;
  final bool loaded;
  final bool busy;
  final VoidCallback onBind;
  final VoidCallback onNewTask;
  final VoidCallback onUnbind;

  bool get _bound => binding?.bound ?? false;
  bool get _expired => binding?.status == 'expired';

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final account = (binding?.nickname?.isNotEmpty ?? false)
        ? binding!.nickname
        : binding?.baiduUid;
    final expires = binding?.expiresAt;
    final tone = _bound
        ? BadgeTone.ok
        : (_expired ? BadgeTone.warn : BadgeTone.neutral);
    final statusLabel = _bound ? '已绑定' : (_expired ? '绑定已过期' : '未绑定');
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tk.goldSoft,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: Icon(Icons.cloud_outlined, size: 21, color: tk.goldInk),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '百度网盘',
                      style: TextStyle(
                        fontSize: Tk.fzRowTitle,
                        fontWeight: FontWeight.w600,
                        color: tk.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      loaded && _bound && account != null
                          ? '$account${expires == null ? '' : ' · 授权至 ${fmtDate(expires)}'}'
                          : '将网盘素材目录只读备份至应用侧',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Badge(label: statusLabel, tone: tone),
            ],
          ),
          const SizedBox(height: Tk.spaceLg),
          // P2-1:窄屏/放大字号从固定横排改纵向整宽(每钮最小 ~140 宽的一
          // 半以上),320dp+1.3 字号下「新建备份任务」不截断;宽屏仍双列。
          LayoutBuilder(
            builder: (context, constraints) {
              final bind = OutlinedButton(
                style: _softGold(tk),
                onPressed: busy ? null : onBind,
                child: Text(
                  _bound ? '切换账号' : (_expired ? '重新绑定' : '绑定账号'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
              final newTask = FilledButton(
                onPressed: _bound ? onNewTask : null,
                child: const Text(
                  '新建备份任务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
              if (constraints.maxWidth >= 340) {
                return Row(
                  children: [
                    Expanded(child: bind),
                    const SizedBox(width: Tk.spaceSm),
                    Expanded(child: newTask),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  bind,
                  const SizedBox(height: Tk.spaceSm),
                  newTask,
                ],
              );
            },
          ),
          if (_expired)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: Tk.spaceMd),
              padding: const EdgeInsets.all(Tk.spaceMd),
              decoration: BoxDecoration(
                color: tk.warnSoft,
                borderRadius: BorderRadius.circular(Tk.rSm),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 16, color: tk.warn),
                  const SizedBox(width: Tk.spaceSm),
                  Expanded(
                    child: Text(
                      '绑定已过期:进行中的任务会失败终止,请重新绑定后用'
                      '「全部重试失败」继续。',
                      style: TextStyle(
                        fontSize: Tk.fzSm,
                        height: 1.5,
                        color: tk.warn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (loaded && (binding != null && (_bound || _expired)))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : onUnbind,
                style: TextButton.styleFrom(
                  foregroundColor: tk.danger,
                  minimumSize: const Size(44, 44),
                ),
                child: const Text('解绑'),
              ),
            ),
          const SizedBox(height: Tk.spaceXs),
          Text(
            '网盘授权仅用于将所选目录只读备份至应用侧,不做修改、删除、分享。',
            style: TextStyle(fontSize: Tk.fzSm, height: 1.5, color: tk.ink3),
          ),
        ],
      ),
    );
  }

  /// 金色浅底次按钮(绑定/切换账号):goldSoft 底 + goldInk 字 + gold 描边。
  ButtonStyle _softGold(TkColors tk) => OutlinedButton.styleFrom(
    backgroundColor: tk.goldSoft,
    foregroundColor: tk.goldInk,
    side: BorderSide(color: tk.gold),
    minimumSize: const Size(44, 44),
    padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tk.rSm)),
    textStyle: const TextStyle(fontSize: Tk.fzMd, fontWeight: FontWeight.w600),
  );
}
