/// MeHeaderCard — 「我的」身份卡(§6 F12):56 金浅底头像(首字 goldInk)+
/// 姓名 19/w600 + 角色徽标(管理员 gold / 成员 neutral)。Me 契约无邮箱与
/// 统计字段,不渲染无数据支撑的行。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

class MeHeaderCard extends StatelessWidget {
  const MeHeaderCard({super.key, this.me});

  final Me? me;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final name = (me?.name.isNotEmpty ?? false) ? me!.name : '(未登录)';
    final role = me?.roleLabel ?? '';
    final isAdmin = me?.isSystemAdmin ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.spaceSm,
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tk.goldSoft,
              shape: BoxShape.circle,
            ),
            child: Text(
              name == '(未登录)' ? '?' : name.characters.first,
              maxLines: 1,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: tk.goldInk,
              ),
            ),
          ),
          const SizedBox(width: Tk.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
                if (role.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Badge(
                    label: role,
                    tone: isAdmin ? BadgeTone.gold : BadgeTone.neutral,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
