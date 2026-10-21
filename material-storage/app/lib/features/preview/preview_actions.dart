/// PreviewActions — 预览页操作钮(B2 §8.2;B5 功能点 4 分享/申请点亮):
/// 下载(B4,my_can_download 三态)/ 分享=单资产 ShareModal 同款(恒可点,
/// 后端 403 最终裁决)/ 申请权限=my_can_download==false 时可点(同款申请表单,
/// 点按仍以后端 403 为最终裁决)。独立组件便于单测按钮点亮态。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class PreviewActions extends StatelessWidget {
  const PreviewActions({
    super.key,
    required this.canDownload,
    this.onDownload,
    this.onShare,
    this.onRequest,
  });

  /// 单夹详情 my_can_download 三态:false=下载钮禁用+申请入口点亮;
  /// true/null=中性(null=详情未到/失败,申请入口不亮,详情到了再看)。
  final bool? canDownload;

  /// 下载动作(B4)。入队 TransferQueue kind=download。
  final VoidCallback? onDownload;

  /// 分享动作(B5):单资产 share_create_sheet(无提取码/下载开关)。
  final VoidCallback? onShare;

  /// 申请权限动作(B5):仅 canDownload==false 时点亮入口。
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final noDownload = canDownload == false; // 仅已知无权才亮申请入口
    final downloadEnabled = onDownload != null && !noDownload;
    // P1(mobile-ux-polish):带色 Container 包 SafeArea(top:false)——darkSurface
    // 背景延伸到虚拟导航栏区域,三钮不被遮挡;无导航栏设备视觉不变。
    return Container(
      color: Tk.darkSurface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _btn(
                icon: Icons.download_outlined,
                label: '下载',
                tooltip: noDownload
                    ? '无下载权限 · 可申请'
                    : (downloadEnabled ? '下载到本机(相册 / Download/浣花视界)' : '后续版本开放'),
                enabled: downloadEnabled,
                onTap: downloadEnabled ? onDownload : null,
                highlighted: noDownload, // 无下载权 →「申请权限」入口样式提示
              ),
              _btn(
                icon: Icons.ios_share_outlined,
                label: '分享',
                tooltip: onShare == null ? '后续版本开放' : '分享链接(需登录访问)',
                enabled: onShare != null,
                onTap: onShare,
              ),
              _btn(
                icon: Icons.verified_user_outlined,
                label: '申请权限',
                tooltip: noDownload
                    ? '发起下载权限申请'
                    : (canDownload == null ? '下载权未知 · 详情加载后可申请' : '已有下载权限,无需申请'),
                enabled: noDownload && onRequest != null,
                onTap: noDownload ? onRequest : null,
                highlighted: noDownload,
              ),
            ],
          ),
        ),
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
        onTap: onTap, // null=禁用(占位/无回调/无申请场景)
        child: framed,
      ),
    );
  }
}
