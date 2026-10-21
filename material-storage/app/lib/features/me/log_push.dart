/// 日志推送入口 — 「推送日志到企业微信」对话框(登录页/首页 AppBar 共用)。
/// 流程:AppLog.dumpFile → WeComPush(先 upload_media 再 file 消息)→
/// 成功清空本地日志并重新起一条推送记录。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../services/app_log.dart';
import '../../services/wecom_push.dart';

Future<void> showLogPushDialog(BuildContext context) {
  return showDialog(context: context, builder: (ctx) => const _LogPushDialog());
}

class _LogPushDialog extends StatefulWidget {
  const _LogPushDialog();

  @override
  State<_LogPushDialog> createState() => _LogPushDialogState();
}

class _LogPushDialogState extends State<_LogPushDialog> {
  Future<({int lines, int bytes})>? _stats;
  bool _pushing = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _stats = AppLog.stats();
  }

  Future<void> _push() async {
    setState(() => _pushing = true);
    try {
      final file = await AppLog.dumpFile();
      final mediaId = await WeComPush().pushLogFile(file);
      // 成功才清空;清空后写一条新记录,留下推送时间锚点
      await AppLog.clear();
      AppLog.info('wecom', '日志已推送并清空(media_id=$mediaId)');
      if (!mounted) return;
      setState(() => _result = '推送成功,本地日志已清空');
    } catch (e) {
      AppLog.error('wecom', '日志推送失败', e);
      if (!mounted) return;
      setState(() => _result = '推送失败:$e\n(本地日志保留,可稍后重试)');
    } finally {
      if (mounted) {
        setState(() => _pushing = false);
        _stats = AppLog.stats();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('推送日志到企业微信'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<({int lines, int bytes})>(
            future: _stats,
            builder: (context, snap) {
              final s = snap.data;
              return Text(
                '本地日志:${s == null ? '…' : '${s.lines} 条 / ${(s.bytes / 1024).toStringAsFixed(1)} KB'}\n'
                '将上传日志文件到企业微信群机器人(file 消息)。',
                style: Theme.of(context).textTheme.bodySmall,
              );
            },
          ),
          // P10:已登录显示当前用户(推送会携带同款身份,未登录只发文件)
          if (session.me != null)
            Text(
              '当前用户:${session.me!.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Text(
              _result!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _pushing ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _pushing ? null : _push,
          child: _pushing
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('推送'),
        ),
      ],
    );
  }
}

/// AppBar 通用按钮(登录页/首页共用)。
IconButton logPushButton(BuildContext context) => IconButton(
  tooltip: '推送日志到企业微信',
  icon: const Icon(Icons.bug_report_outlined),
  onPressed: () => showLogPushDialog(context),
);
