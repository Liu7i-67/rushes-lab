/// 新建备份任务·步骤一(选源目录;自 baidu_new_task_page 拆件守 300 行硬顶):
/// AppCard 内 AppRow 源目录入口(选中金色勾)+ 只读授权说明 +
/// 「开始前请了解」告知(限速/单轮上限/同名跳过+覆盖后置警示,web
/// BaiduNewTaskModal 文案口径)。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';

class NewTaskSourceStep extends StatelessWidget {
  const NewTaskSourceStep({
    super.key,
    required this.sourceDir,
    required this.onPick,
  });

  /// 已选网盘目录(null=未选)。
  final String? sourceDir;

  /// 打开网盘树选择器。
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final selected = sourceDir != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceLg,
        Tk.spacePage,
        Tk.spaceXl,
      ),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '从百度网盘选择要备份的目录。将只读拉取文件清单导入所选项目,'
                '不做修改、删除、分享。',
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  height: 1.6,
                  color: tk.ink3,
                ),
              ),
              const SizedBox(height: Tk.spaceMd),
              AppRow(
                leading: const Icon(Icons.folder_open_outlined),
                goldIcon: selected,
                title: '源目录',
                subtitle: sourceDir ?? '尚未选择(不支持整盘根目录)',
                trailing: Icon(
                  selected ? Icons.check_circle : Icons.chevron_right,
                  size: 20,
                  color: selected ? tk.gold : tk.ink3,
                ),
                onTap: onPick,
                showChevron: false,
              ),
              const SizedBox(height: Tk.spaceMd),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text(selected ? '重选目录' : '浏览网盘选目录'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Tk.spaceLg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '开始前请了解',
                style: TextStyle(
                  fontSize: Tk.fzRowTitle,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
              const SizedBox(height: Tk.spaceSm),
              Text(
                '· 非会员限速约 0.08 MiB/s,大目录耗时较长,请耐心等待。\n'
                '· 单轮导入上限约 14GB / 48 小时;超限后任务失败,可用'
                '「全部重试失败」继续下一轮(断点续传)。\n'
                '· 同名文件默认跳过(已存在的不会被改动);之后可在任务详情对'
                '跳过文件执行「覆盖导入」——该操作会永久删除原文件后重新导入,'
                '且需要管理权限。',
                style: TextStyle(
                  fontSize: Tk.fzSm,
                  height: 1.7,
                  color: tk.ink3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
