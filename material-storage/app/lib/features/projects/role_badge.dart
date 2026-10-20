/// RoleBadge — 项目行「我的角色」徽标(B2 §8.1,ROLE_META/ROLE_RANK 同 web
/// ProjectsPage.MyRolesBadge):四角色取最高者为主 chip,多角色其余 +N,
/// 空角色 → 「仅访客」(visibility=public 才可见的口径,web 同源)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// role → (chip 文案, 徽标色) — admin→管理/accent、uploader→上传/amber、
/// downloader→下载/emerald、viewer→查看/neutral(web ROLE_META 同色)。
const kRoleMeta = <String, (String, BadgeTone)>{
  'admin': ('管理', BadgeTone.accent),
  'uploader': ('上传', BadgeTone.amber),
  'downloader': ('下载', BadgeTone.green),
  'viewer': ('查看', BadgeTone.neutral),
};

/// 优先级:admin > uploader > downloader > viewer(web ROLE_RANK 同序)。
const kRoleRank = <String>['admin', 'uploader', 'downloader', 'viewer'];

/// 徽标规格纯函数(可单测):主 chip 文案+色 / +N 数 / 是否「仅访客」。
/// 未知角色值(后端未来新增)按 viewer 兜底(web `ROLE_META[top] || ROLE_META.viewer`)。
class RoleChipSpec {
  const RoleChipSpec({
    required this.label,
    required this.tone,
    this.extraCount = 0,
    this.guest = false,
  });

  final String label;
  final BadgeTone tone;
  final int extraCount;
  final bool guest;
}

RoleChipSpec roleChipSpec(List<String> roles) {
  if (roles.isEmpty) {
    return const RoleChipSpec(label: '仅访客', tone: BadgeTone.neutral, guest: true);
  }
  final sorted = [...roles]..sort(
      (a, b) => kRoleRank.indexOf(a).compareTo(kRoleRank.indexOf(b)),
    );
  final top = sorted.first;
  final (label, tone) = kRoleMeta[top] ?? kRoleMeta['viewer']!;
  return RoleChipSpec(label: label, tone: tone, extraCount: sorted.length - 1);
}

/// 项目行徽标:主 chip + 「+N」灰字(多角色);guest 时浅字小徽标(弱化,web 同调)。
class MyRolesBadge extends StatelessWidget {
  const MyRolesBadge({super.key, required this.roles});

  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    final s = roleChipSpec(roles);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Badge(
          label: s.guest ? '仅访客' : s.label,
          tone: s.tone,
        ),
        if (s.extraCount > 0) ...[
          const SizedBox(width: 4),
          Text(
            '+${s.extraCount}',
            style: const TextStyle(color: Tk.subtle, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
