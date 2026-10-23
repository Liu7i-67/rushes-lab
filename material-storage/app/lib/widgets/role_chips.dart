/// RoleChips — 项目角色多选 chips(B6;web RoleChipGroup 移动版):四角色
/// admin/uploader/downloader/viewer 一次授多选,选中态金浅底 + 金边 + 金字
/// (FilterChip),下方 hint 文案随选随变(web 同款文案)。成员管理/新建项目
/// 初始权限两处复用。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

/// 角色枚举与展示序(web ROLE_ORDER 同款;后端 PROJECT_ROLES 同序)。
const kProjectRoles = <String>['admin', 'uploader', 'downloader', 'viewer'];

/// role → 中文标签(web ROLE_META 同款)。
const kRoleLabels = <String, String>{
  'admin': '管理',
  'uploader': '上传',
  'downloader': '下载',
  'viewer': '查看',
};

/// 已选角色串(admin+uploader → 「管理 + 上传」;web roleLabels.join 同构)。
String joinedRoleLabels(Iterable<String> roles) => kProjectRoles
    .where(roles.contains)
    .map((r) => kRoleLabels[r] ?? r)
    .join(' + ');

class RoleChips extends StatelessWidget {
  const RoleChips({super.key, required this.value, required this.onChanged});

  /// 当前选中角色集合(展示序按 kProjectRoles,与传入顺序无关)。
  final Set<String> value;
  final ValueChanged<Set<String>> onChanged;

  void _toggle(String r) {
    final next = <String>{...value};
    if (!next.remove(r)) {
      next.add(r);
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceXs,
          children: [
            for (final r in kProjectRoles)
              FilterChip(
                label: Text(kRoleLabels[r] ?? r),
                selected: value.contains(r),
                onSelected: (_) => _toggle(r),
                showCheckmark: true,
                // 主题 chip 语言:未选 surface2 + controlBorder(可交互描边
                // ≥3:1);选中 goldSoft + gold 边 + goldInk 字(§5.2)。
                backgroundColor: tk.surface2,
                selectedColor: tk.goldSoft,
                checkmarkColor: tk.goldInk,
                side: BorderSide(
                  color: value.contains(r) ? tk.gold : tk.controlBorder,
                ),
                labelStyle: TextStyle(
                  fontSize: Tk.fzMd,
                  fontWeight: value.contains(r)
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: value.contains(r) ? tk.goldInk : tk.ink2,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Tk.rPill),
                ),
              ),
          ],
        ),
        const SizedBox(height: Tk.spaceSm),
        Text(
          value.isEmpty
              ? '至少勾选一个角色'
              : '已选:${joinedRoleLabels(value)}。'
                    '${value.contains('admin') ? '管理:全部权限 + 可管成员 + 可建敏感目录。' : ''}'
                    '${value.contains('uploader') ? '上传:传文件 + 建子目录,自动含查看。' : ''}'
                    '${value.contains('downloader') ? '下载:下载文件,自动含查看。' : ''}'
                    '${value.contains('viewer') ? '查看:仅浏览元数据。' : ''}',
          style: TextStyle(
            fontSize: Tk.fzXs,
            height: 1.6,
            color: value.isEmpty ? tk.warn : tk.ink3,
          ),
        ),
      ],
    );
  }
}
