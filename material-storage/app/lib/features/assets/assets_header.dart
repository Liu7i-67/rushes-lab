/// AssetsHeader — 宫格页头(F8/§7.2):PageHeader(返回 / 标题 / 副标题 /
/// 选择·取消)+ 面包屑(项目 / 文件夹)+ 计数(total)+ 排序 chip。
/// 排序状态归页面所有;本组件只展示与回调。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/page_header.dart';

/// 客户端排序(默认最新优先):按 createdAt 升降序,时间相同保持原序
/// (后端返回序作打平基准);非法/空时间落最早。
List<Asset> sortAssetsByCreatedAt(List<Asset> items, {required bool desc}) {
  if (items.length < 2) return List.of(items);
  DateTime ts(Asset a) =>
      DateTime.tryParse(a.createdAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final keys = [for (var i = 0; i < items.length; i++) (i, ts(items[i]))];
  keys.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    if (c != 0) return desc ? -c : c;
    return a.$1.compareTo(b.$1);
  });
  return [for (final k in keys) items[k.$1]];
}

class AssetsHeader extends StatelessWidget {
  const AssetsHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selecting,
    required this.onToggleSelect,
    required this.total,
    required this.sortDesc,
    required this.onToggleSort,
    this.projectLabel,
    this.folderName,
    this.onProjectTap,
  });

  final String title;
  final String subtitle;

  /// 是否处于多选态(右侧动作「取消」/「选择」)。
  final bool selecting;
  final VoidCallback onToggleSelect;

  final int total;
  final bool sortDesc;
  final VoidCallback onToggleSort;

  /// 面包屑项目段;null = 无路径信息(深链)时只显示当前夹。
  final String? projectLabel;
  final String? folderName;
  final VoidCallback? onProjectTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          back: true,
          title: title,
          subtitle: subtitle,
          actions: [
            _SelectAction(
              label: selecting ? '取消' : '选择',
              onTap: onToggleSelect,
            ),
          ],
        ),
        _crumbs(tk),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            Tk.spaceXs,
            Tk.spacePage,
            Tk.spaceSm,
          ),
          child: Row(
            children: [
              Text(
                '共 $total 个素材',
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  color: tk.ink3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              AppChip(
                label: sortDesc ? '最新优先' : '最早优先',
                icon: Icons.filter_list,
                onTap: onToggleSort,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _crumbs(TkColors tk) {
    final now = folderName;
    if (now == null || now.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
        child: Row(
          children: [
            if (projectLabel != null) ...[
              Flexible(
                child: InkWell(
                  onTap: onProjectTap,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 10,
                    ),
                    child: Text(
                      projectLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ),
                ),
              ),
              Text(
                ' / ',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
            ],
            Flexible(
              flex: 2,
              child: Text(
                now,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选择/取消文字动作:视觉同 TextButton(金墨 15.5/w600、最小 44)。
/// 不用 TextButton 实体,避免与确认框里的 TextButton(取消)撞测试 finder。
class _SelectAction extends StatelessWidget {
  const _SelectAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Tk.rSm),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: Tk.fzRowTitle,
                fontWeight: FontWeight.w600,
                color: tk.goldInk,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
