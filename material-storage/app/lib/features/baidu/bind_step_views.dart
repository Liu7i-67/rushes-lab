/// 绑定页步骤视图件(与 BindCodePage 状态机解耦,§8.10 oob 复制码流程):
/// 金色步骤徽标卡壳 / 未启用空态 / 授权链接复制框 / 授权码回填面板。
/// 纯展示,回调上抛,不持有业务状态(一次性清空逻辑在页面侧,便于单测)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';

/// 步骤卡片壳:金色「步骤 n / total」徽标 + 标题 + 内容,完成态打勾。
class BindStepCard extends StatelessWidget {
  const BindStepCard({
    super.key,
    required this.step,
    required this.total,
    required this.title,
    required this.done,
    required this.child,
  });

  final int step;
  final int total;
  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Tk.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Badge(label: '步骤 $step / $total', tone: BadgeTone.gold),
              const Spacer(),
              if (done)
                Icon(Icons.check_circle, size: 18, color: tk.ok)
              else
                Icon(Icons.radio_button_unchecked, size: 18, color: tk.ink3),
            ],
          ),
          const SizedBox(height: Tk.spaceMd),
          Text(
            title,
            style: TextStyle(
              fontSize: Tk.fzTitle,
              fontWeight: FontWeight.w600,
              color: tk.ink,
            ),
          ),
          const SizedBox(height: Tk.spaceSm),
          child,
        ],
      ),
    );
  }
}

/// 开关关闭(baidu_backup_enabled=false / 接口 404)占位。
class BindDisabledView extends StatelessWidget {
  const BindDisabledView({super.key});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.cloud_off_outlined,
      title: '网盘备份未启用',
      message: '当前部署未开启百度网盘备份功能,如有需要请联系管理员。',
    );
  }
}

/// 第 1 步产物:授权链接复制框 + 复制 / 外开系统浏览器 + 操作指引。
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
    final tk = context.tk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Tk.spaceSm),
        Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.only(left: Tk.spaceMd, right: Tk.spaceXs),
          decoration: BoxDecoration(
            color: tk.surface2,
            borderRadius: BorderRadius.circular(Tk.rSm),
            // 框内是可选文本 + 复制按钮:按可交互控件描边(controlBorder)。
            border: Border.all(color: tk.controlBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  url,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: Tk.fzSm,
                    fontFamily: 'monospace',
                    color: tk.ink2,
                  ),
                ),
              ),
              const SizedBox(width: Tk.spaceXs),
              TextButton(
                onPressed: onCopy,
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                child: const Text('复制链接'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Tk.spaceSm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('浏览器打开'),
          ),
        ),
        const SizedBox(height: Tk.spaceSm),
        Text(
          '在浏览器完成百度授权后,页面会显示一串授权码,'
          '复制它回到这里粘贴。授权码单次有效约 10 分钟。',
          style: TextStyle(fontSize: Tk.fzSm, height: 1.6, color: tk.ink3),
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
            helperText: '授权码等同账号授权凭证:仅贴本人的,勿外传;提交后即清空,过期需重新获取',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Tk.spaceMd),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: busy ? null : onSubmit,
            child: Text(busy ? '提交中…' : '绑定'),
          ),
        ),
      ],
    );
  }
}
