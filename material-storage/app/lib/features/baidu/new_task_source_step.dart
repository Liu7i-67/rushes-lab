/// 新建备份任务·步骤一(选源目录;自 baidu_new_task_page 拆件守 300 行硬顶):
/// 只读授权说明 + 已选来源回显 + 网盘树选择器入口 + 「开始前请了解」告知
/// (限速/单轮上限/同名跳过+覆盖后置警示,web BaiduNewTaskModal 文案口径)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

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
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '从百度网盘选择要备份的目录。将只读拉取文件清单导入所选项目,'
                    '不做修改、删除、分享。',
                    style: const TextStyle(fontSize: 13, color: Tk.muted),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sourceDir == null ? '未选择源目录' : '已选来源:$sourceDir',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color:
                            sourceDir == null ? Tk.subtle : Tk.accentStrong,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: onPick,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(sourceDir == null ? '浏览网盘选目录' : '重选目录'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '开始前请了解:\n'
            '· 非会员限速约 0.08 MiB/s,大目录耗时较长,请耐心等待。\n'
            '· 单轮导入上限约 14GB / 48 小时;超限后任务失败,可用「全部重试失败」'
            '继续下一轮(断点续传)。\n'
            '· 同名文件默认跳过(已存在的不会被改动);之后可在任务详情对跳过文件'
            '执行「覆盖导入」——该操作会永久删除原文件后重新导入,且需要管理权限。',
            style: TextStyle(fontSize: 12, color: Tk.subtle, height: 1.7),
          ),
        ],
      );
}
