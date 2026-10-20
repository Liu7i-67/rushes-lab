/// PreviewActions — 预览页操作钮(B2 §8.2 / B4 功能点 4①):下载钮点亮,
/// 分享/申请权限仍占位禁用(B5)。下载权判定=folder.my_can_download(单夹详情
/// 回填):false → 禁用+「申请权限」入口样式提示(申请动作 B5 点亮,点按仍以后端
/// 403 为最终裁决);true/null=中性放行。独立组件便于单测下载禁用态。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class PreviewActions extends StatelessWidget {
  const PreviewActions({super.key, required this.canDownload, this.onDownload});

  /// 单夹详情 my_can_download 三态:false=下载钮禁用+申请提示;true/null=中性。
  final bool? canDownload;

  /// 下载动作(B4 点亮;null=仍占位禁用)。入队 TransferQueue kind=download。
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final noDownload = canDownload == false; // 仅已知无权才提示申请
    final downloadEnabled = onDownload != null && !noDownload;
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
                : (downloadEnabled ? '下载到本机(相册 / Download/浣花视界)' : '后续版本开放'),
            enabled: downloadEnabled,
            onTap: downloadEnabled ? onDownload : null,
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
    VoidCallback? onTap,
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
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: btn,
    );
    final framed = highlighted
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Tk.accent.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: btn,
          )
        : padded;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap, // null=禁用(占位/无权);点亮=入队下载
        child: framed,
      ),
    );
  }
}
