/// 百度绑定状态卡(B9 §8.10,自 baidu_page 拆件守 300 行硬顶;web
/// BindingHeader 移动版):绑定/过期/未绑定徽标 + 账号·授权期 + 绑定/切换
/// 账号 + 新建备份任务闸门(未绑定禁用)+ 解绑 + 授权用途告知文案。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
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
    final account = (binding?.nickname?.isNotEmpty ?? false)
        ? binding!.nickname
        : binding?.baiduUid;
    final expires = binding?.expiresAt;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tk.rXl)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Badge(
                label: _bound ? '已绑定' : (_expired ? '绑定已过期' : '未绑定'),
                tone: _bound
                    ? BadgeTone.green
                    : (_expired ? BadgeTone.amber : BadgeTone.neutral),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loaded && _bound && account != null
                      ? '$account${expires == null ? '' : ' · 授权至 ${fmtDate(expires)}'}'
                      : '',
                  style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted),
                ),
              ),
              if (loaded && (binding != null && (_bound || _expired)))
                TextButton(
                  onPressed: busy ? null : onUnbind,
                  child: const Text('解绑',
                      style: TextStyle(fontSize: Tk.fzSm, color: Tk.red)),
                ),
            ]),
            Row(children: [
              OutlinedButton(
                onPressed: onBind,
                child: Text(_bound ? '切换账号' : (_expired ? '重新绑定' : '绑定百度网盘账号')),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _bound ? onNewTask : null,
                child: const Text('新建备份任务'),
              ),
            ]),
            if (_expired)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '绑定已过期:进行中的任务会失败终止,请重新绑定后用「全部重试失败」继续。',
                  style: TextStyle(fontSize: Tk.fzSm, color: Tk.amber),
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '网盘授权仅用于将所选目录只读备份至应用侧,不做修改、删除、分享。',
                style: TextStyle(fontSize: Tk.fzSm, color: Tk.subtle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
