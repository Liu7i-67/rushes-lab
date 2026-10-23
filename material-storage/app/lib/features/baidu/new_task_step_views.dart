/// 新建备份任务·步骤二视图 + 创建成功结果卡(自 baidu_new_task_page 拆件:
/// 页面只保留状态/导航/提交,本文件只做展示):
/// 源目录回显 + 任务名称(AppTextField)+ 目标项目弹层选择 + 承接夹树
/// (项目根/敏感夹禁选)+ 「仅备份新增与修改」固定开启说明。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/pickers/picker_sheet.dart';
import 'baidu_target_picker.dart';

class NewTaskTargetStep extends StatelessWidget {
  const NewTaskTargetStep({
    super.key,
    required this.sourceDir,
    required this.nameController,
    required this.projectsLoading,
    required this.projectsError,
    required this.projects,
    required this.projectId,
    required this.projectName,
    required this.folders,
    required this.foldersLoading,
    required this.foldersError,
    required this.target,
    required this.onReloadProjects,
    required this.onReloadFolders,
    required this.onPickProject,
    required this.onTargetChanged,
  });

  final String? sourceDir;
  final TextEditingController nameController;
  final bool projectsLoading;
  final String? projectsError;
  final List<Project> projects;
  final String? projectId;
  final String? projectName;
  final List<Folder> folders;
  final bool foldersLoading;
  final String? foldersError;
  final BaiduTarget target;
  final VoidCallback onReloadProjects;
  final VoidCallback onReloadFolders;
  final VoidCallback onPickProject;
  final ValueChanged<BaiduTarget> onTargetChanged;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceLg,
        Tk.spacePage,
        Tk.spaceXl,
      ),
      children: [
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, Tk.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppRow(
                leading: const Icon(Icons.folder_open_outlined),
                goldIcon: true,
                title: '源目录',
                subtitle: sourceDir ?? '',
                showChevron: false,
              ),
              Divider(height: Tk.spaceLg, color: tk.line),
              AppTextField(
                controller: nameController,
                label: '任务名称',
                hint: '默认取源目录名',
              ),
              const SizedBox(height: Tk.spaceSm),
              Text(
                '任务列表按源目录展示;此名称仅用于本页确认。',
                style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
              ),
            ],
          ),
        ),
        const SizedBox(height: Tk.spaceXl),
        Text(
          '选择承接位置',
          style: TextStyle(
            fontSize: Tk.fzRowTitle,
            fontWeight: FontWeight.w600,
            color: tk.ink,
          ),
        ),
        const SizedBox(height: Tk.spaceXs),
        Text(
          '目标项目(仅列出你可上传的项目)',
          style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceSm),
        if (projectsLoading)
          const Padding(
            padding: EdgeInsets.all(Tk.spaceXl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (projectsError != null)
          _ErrorRetry(message: projectsError!, onRetry: onReloadProjects)
        else if (projects.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Tk.spaceXl),
            child: EmptyState(
              icon: Icons.folder_off_outlined,
              message: '无可用项目(需具备项目上传权限)',
            ),
          )
        else if (projectId != null && projectName != null) ...[
          PickerField(
            value: projectName!,
            hint: '选择目标项目',
            onTap: onPickProject,
          ),
          const SizedBox(height: Tk.spaceMd),
          if (foldersLoading)
            const Padding(
              padding: EdgeInsets.all(Tk.spaceXl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (foldersError != null)
            _ErrorRetry(message: foldersError!, onRetry: onReloadFolders)
          else
            BaiduTargetPicker(
              projectId: projectId!,
              projectName: projectName!,
              folders: folders,
              value: target,
              onChanged: onTargetChanged,
            ),
          const SizedBox(height: Tk.spaceSm),
          Text(
            '已选目标:${target.label}',
            style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
          ),
        ],
        const SizedBox(height: Tk.spaceXl),
        AppCard(
          child: Semantics(
            checked: true,
            label: '仅备份新增与修改',
            child: Row(
              children: [
                Icon(Icons.check_box, size: 22, color: tk.gold),
                const SizedBox(width: Tk.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '仅备份新增与修改',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: tk.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '同名文件默认跳过,已备份且未变化的文件不会重复导入',
                        style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
                      ),
                    ],
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

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Tk.spaceSm),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 创建成功结果卡:排队预期(恒有)+ W1 预警(命中时追加段),单「知道了」。
Future<void> showTaskCreatedDialog(BuildContext context, BaiduTask task) {
  final names = task.overlapProjectNames?.join('、');
  final w1 = task.crossProjectPrefixOverlap
      ? (names == null || names.isEmpty
            ? '目标文件夹名与其他项目下的同名文件夹共用存储编号:同名文件将自动加随机'
                  '后缀存储(两处各持独立文件,互不覆盖);目标目录内已存在同名文件'
                  '(含回收站)时该文件仍会失败并保留人工处理出路,如需同键替换请换'
                  '一个目标文件夹名'
            : '目标文件夹名与项目「$names」下的同名文件夹共用存储编号:同名文件将'
                  '自动加随机后缀存储(两处各持独立文件,互不覆盖);目标目录内已存在'
                  '同名文件(含回收站)时该文件仍会失败并保留人工处理出路,如需同键替'
                  '换请换一个目标文件夹名')
      : null;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final tk = ctx.tk;
      return AlertDialog(
        icon: Icon(Icons.check_circle_outline, color: tk.ok, size: 32),
        title: const Text('备份任务已创建'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '清单准备中;已有任务执行中时,新任务将排队,前序完成后约数分钟至'
              '一刻钟内自动开始。',
              style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink2),
            ),
            if (w1 != null) ...[
              const SizedBox(height: Tk.spaceMd),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Tk.spaceMd),
                decoration: BoxDecoration(
                  color: tk.warnSoft,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: Text(
                  w1,
                  style: TextStyle(
                    fontSize: Tk.fzSm,
                    height: 1.6,
                    color: tk.warn,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}
