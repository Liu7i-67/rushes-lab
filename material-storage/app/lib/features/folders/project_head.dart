/// ProjectHead — 文件夹页项目头卡(F7/§7.2):`headBg` 渐变 + 右上金晕与
/// 描边圆,内容=code 微标签 / 项目名 19 / meta(文件夹数 · 素材数合计 ·
/// 我的角色)。计数由调用方按已加载文件夹列表求和传入,不新增接口。
/// 同文件附[showProjectMenu]:顶栏「⋯」单层项目操作面板(仅 admin 可见
/// 成员管理/请求链接,复用现有项目面板,不新增后端)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_row.dart';
import '../../widgets/sheet_scaffold.dart';
import '../projects/project_members_sheet.dart';
import '../share/request_link_sheet.dart';

class ProjectHead extends StatelessWidget {
  const ProjectHead({
    super.key,
    required this.name,
    required this.folderCount,
    required this.assetCount,
    required this.roleLabel,
    this.code = '',
  });

  final String name;
  final int folderCount;
  final int assetCount;
  final String roleLabel;

  /// 项目 code;为空时整行微标签不渲染(路由暂未携带 code)。
  final String code;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceXs,
        Tk.spacePage,
        0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: tk.headBg,
        borderRadius: BorderRadius.circular(Tk.rMd),
        border: Border.all(color: tk.line),
        boxShadow: tk.shadow1,
      ),
      child: Stack(
        children: [
          // 右上金晕 + 描边圆(原型 .project-head::after)
          Positioned(
            right: -40,
            top: -50,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: tk.headGlow,
                border: Border.all(color: tk.gold.withValues(alpha: 0.35)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Tk.spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (code.isNotEmpty) ...[
                  Text(
                    code.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Tk.fzXs,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.76, // .16em @ 11
                      color: tk.goldInk,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.19,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: Tk.spaceMd),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _meta(tk, '$folderCount', '个文件夹'),
                    _meta(tk, '$assetCount', '个素材'),
                    Text(
                      roleLabel,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 数字用 ink/600/tabular,单位与连接词复用 ink3。
  Widget _meta(TkColors tk, String value, String label) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            style: TextStyle(
              color: tk.ink,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(
            text: ' $label',
            style: TextStyle(color: tk.ink3),
          ),
        ],
      ),
      style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink3),
    );
  }
}

/// 项目「⋯」操作面板:单层 sheet,仅 admin 可见成员管理/请求链接。
/// [project] 由调用方用已有信息构造(route 未携带 code 时传 '')。
Future<void> showProjectMenu(
  BuildContext context, {
  required Project project,
  required bool canAdmin,
}) async {
  final action = await showAppSheet<String>(
    context: context,
    title: '项目操作',
    child: _ProjectMenuBody(canAdmin: canAdmin),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'members':
      await showProjectMembersSheet(context, project: project);
    case 'link':
      await showRequestLinkSheet(
        context,
        targetType: 'project',
        targetId: project.id,
        targetLabel: project.name,
      );
  }
}

class _ProjectMenuBody extends StatelessWidget {
  const _ProjectMenuBody({required this.canAdmin});

  final bool canAdmin;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    if (!canAdmin) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Tk.spaceLg),
        child: Text(
          '项目操作仅项目管理员可用',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppRow(
          leading: const Icon(Icons.people_outline),
          title: '成员管理',
          showChevron: false,
          onTap: () => Navigator.of(context).pop('members'),
        ),
        Divider(height: 1, thickness: 1, color: tk.line),
        AppRow(
          leading: const Icon(Icons.link_outlined),
          title: '请求链接',
          showChevron: false,
          onTap: () => Navigator.of(context).pop('link'),
        ),
      ],
    );
  }
}
