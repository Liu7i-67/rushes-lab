/// 绑定页步骤视图件(与 BindCodePage 状态机解耦,§8.10 oob 复制码流程):
/// 步骤卡片壳 / 未启用占位 / 授权链接面板 / 授权码回填面板。纯展示,
/// 回调上抛,不持有业务状态(一次性清空逻辑在页面侧,便于单测)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 步骤卡片壳:标题行(完成态打勾)+ 内容。
class BindStepCard extends StatelessWidget {
  const BindStepCard({
    super.key,
    required this.title,
    required this.done,
    required this.child,
  });

  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18, color: done ? Tk.green : Tk.subtle),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// 开关关闭(baidu_backup_enabled=false / 接口 404)占位。
class BindDisabledView extends StatelessWidget {
  const BindDisabledView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Tk.subtle),
            const SizedBox(height: 12),
            const Text('网盘备份未启用',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '当前部署未开启百度网盘备份功能,如有需要请联系管理员。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Tk.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 第 1 步产物:授权链接展示 + 复制 / 外开系统浏览器 + 操作指引。
class BindUrlPanel extends StatelessWidget {
  const BindUrlPanel({
    super.key,
    required this.url,
    required this.onCopy,
    required this.onOpen,
  });

  final String url;
  final VoidCallback onCopy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        SelectableText(url,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制链接'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('浏览器打开'),
          ),
        ]),
        const SizedBox(height: 8),
        const Text(
          '在浏览器完成百度授权后,页面会显示一串授权码,'
          '复制它回到这里粘贴。授权码单次有效约 10 分钟。',
          style: TextStyle(fontSize: 12, color: Tk.subtle),
        ),
      ],
    );
  }
}

/// 第 2 步:授权码回填(提交走一次性清空状态机,见页面侧)。
class BindCodePanel extends StatelessWidget {
  const BindCodePanel({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          enabled: !busy,
          decoration: const InputDecoration(
            hintText: '粘贴百度返回的授权码',
            helperText:
                '授权码等同账号授权凭证:仅贴本人的,勿外传;提交后即清空,过期需重新获取',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : onSubmit,
          child: Text(busy ? '提交中…' : '绑定'),
        ),
      ],
    );
  }
}
