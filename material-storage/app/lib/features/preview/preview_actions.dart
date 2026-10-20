/// PreviewActions — 预览页操作钮(B2 §8.2):下载/分享/申请权限三钮本批占位禁用
/// (灰置+tooltip「后续版本」);下载权判定=folder.my_can_download(单夹详情回填),
/// 已知 false 时下载钮附「申请权限」入口样式提示——实际申请动作 B5 点亮;
/// null=详情未到/失败(B2 修复 P2-4 三态),提示退回中性「后续版本」不误显可申请。
/// 独立组件便于单测下载禁用态(测试功能点 6)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class PreviewActions extends StatelessWidget {
  const PreviewActions({super.key, required this.canDownload});

  /// 单夹详情 my_can_download 三态:false=下载钮禁用+申请提示;true/null=中性。
  final bool? canDownload;

  @override
  Widget build(BuildContext context) {
    final noDownload = canDownload == false; // 仅已知无权才提示申请
    return Container(
      color: Tk.darkSurface,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _btn(
            icon: Icons.download_outlined,
            label: '下载',
            tooltip: noDownload
                ? '无下载权限 · 可申请(B5 开放申请入口)'
                : '后续版本开放',
            enabled: false, // B2 全批占位禁用,B4/B5 点亮
            highlighted: noDownload, // 无下载权 →「申请权限」入口样式提示
          ),
          _btn(
            icon: Icons.ios_share_outlined,
            label: '分享',
            tooltip: '后续版本开放',
            enabled: false,
          ),
          _btn(
            icon: Icons.verified_user_outlined,
            label: '申请权限',
            tooltip: '后续版本开放',
            enabled: false,
          ),
        ],
      ),
    );
  }

  Widget _btn({
    required IconData icon,
    required String label,
    required String tooltip,
    required bool enabled,
    bool highlighted = false,
  }) {
    final color = enabled
        ? Colors.white
        : (highlighted ? Tk.accentSoft : Colors.white38);
    final btn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
    return Tooltip(
      message: tooltip,
      child: highlighted
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: Tk.accent.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: btn,
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: btn,
            ),
    );
  }
}
