/// ProjectCard — 项目卡(§6 F6):40×40 金浅底首字标记 + 名称 16/w600 +
/// code 13 + 我的角色徽标 + chevron;已置顶时标题旁金色图钉(B5);整卡
/// onTap 进文件夹,长按由页面层挂项目操作菜单(置顶全员/管理项 admin)。
/// 不展示契约不存在的统计字段。
/// 外观与交互复用 AppCard(P2-10),不再重复卡片容器/水波纹实现。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import 'role_badge.dart';

class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    this.onTap,
    this.onLongPress,
  });

  final Project project;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final name = project.name.isEmpty ? '(未命名)' : project.name;
    final initial = name.characters.first;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tk.goldSoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              initial,
              maxLines: 1,
              style: TextStyle(
                fontSize: 17,
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
                // 标题行:置顶时标题旁挂金色图钉标识(B5,仅 isPinned 显示)
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzBody,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: tk.ink,
                        ),
                      ),
                    ),
                    if (project.isPinned) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.push_pin, size: 14, color: tk.gold),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        project.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                      ),
                    ),
                    const SizedBox(width: Tk.spaceSm),
                    MyRolesBadge(roles: project.myRoles),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Tk.spaceXs),
          Icon(Icons.chevron_right, size: 18, color: tk.ink3),
        ],
      ),
    );
  }
}
