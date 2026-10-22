/// PreviewActions — 预览页操作钮(B2 §8.2;B5 功能点 4 分享/申请点亮):
/// 下载(B4,my_can_download 三态)/ 分享=单资产 ShareModal 同款(恒可点,
/// 后端 403 最终裁决)/ 申请权限=my_can_download==false 时可点(同款申请表单,
/// 点按仍以后端 403 为最终裁决)。独立组件便于单测按钮点亮态。
/// C5(app-polish):[downloadQueued] 入队就地态——短暂「已入队 ✓」(复原由
/// 页面定时驱动),替代暗底白 SnackBar。
/// C4(app-polish):禁用键点按经 [onDisabledTap] 上抛原因文案(页面 toast
/// 呈现),Tooltip 仅作无障碍补充;浮层化=顶部圆角与 MetaPanel 圆角过渡,
/// 底部仍全出血延伸进导航栏(P1 不回退)。
library;

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../theme/tokens.dart';

class PreviewActions extends StatelessWidget {
  const PreviewActions({
    super.key,
    required this.canDownload,
    this.onDownload,
    this.onShare,
    this.onRequest,
    this.downloadQueued = false,
    this.onDisabledTap,
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

  /// C5:入队就地态——true 时下载钮显「已入队 ✓」并暂禁点(防重复入队),
  /// 复原由页面 Timer 驱动。
  final bool downloadQueued;

  /// C4:禁用键点按上抛原因文案(页面 toast 呈现);null=禁用键不可点(单测
  /// 直挂组件场景维持原行为)。
  final ValueChanged<String>? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    final noDownload = canDownload == false; // 仅已知无权才亮申请入口
    final downloadEnabled =
        onDownload != null && !noDownload && !downloadQueued;
    // P1(mobile-ux-polish):带色 Container 包 SafeArea(top:false)——darkSurface
    // 背景延伸到虚拟导航栏区域,三钮不被遮挡;无导航栏设备视觉不变。
    // C4:外层横向留边+顶部圆角(rLg),与 MetaPanel 圆角过渡成浮层,不再直角堆叠。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Tk.rLg)),
        child: Container(
          color: Tk.darkSurface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  Tk.spaceLg, Tk.spaceXs, Tk.spaceLg, Tk.spaceSm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _btn(
                    icon: downloadQueued
                        ? Icons.check_circle_outline
                        : Icons.download_outlined,
                    label: downloadQueued ? '已入队 ✓' : '下载',
                    tooltip: downloadQueued
                        ? '已加入下载队列,可在传输页查看进度'
                        : noDownload
                            ? '无下载权限 · 可申请'
                            : (downloadEnabled
                                ? '下载到本机(相册 / Download/浣花视界)'
                                : '后续版本开放'),
                    enabled: downloadEnabled,
                    onTap: downloadEnabled ? onDownload : null,
                    highlighted: noDownload, // 无下载权 →「申请权限」入口样式提示
                    accent: downloadQueued, // C5:已入队就地态(绿色对勾)
                  ),
                  _btn(
                    icon: Icons.ios_share_outlined,
                    label: '分享',
                    tooltip: onShare == null
                        ? '后续版本开放'
                        : '分享链接(需登录访问)',
                    enabled: onShare != null,
                    onTap: onShare,
                  ),
                  _btn(
                    icon: Icons.verified_user_outlined,
                    label: '申请权限',
                    tooltip: noDownload
                        ? '发起下载权限申请'
                        : (canDownload == null
                            ? '下载权未知 · 详情加载后可申请'
                            : '已有下载权限,无需申请'),
                    enabled: noDownload && onRequest != null,
                    onTap: noDownload ? onRequest : null,
                    highlighted: noDownload,
                  ),
                ],
              ),
            ),
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
    bool accent = false,
  }) {
    final color = enabled
        ? (accent ? Tk.green : Colors.white)
        : (highlighted ? Tk.accentSoft : Colors.white38);
    final btn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 2), // 图标-文字微缝(同容器比例)保留
        Text(label, style: TextStyle(color: color, fontSize: Tk.fzXs)),
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tk.spaceLg, vertical: Tk.spaceXs),
      child: btn,
    );
    final framed = highlighted
        ? Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Tk.spaceLg, vertical: Tk.spaceXs),
            decoration: BoxDecoration(
              border: Border.all(color: Tk.accent.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(Tk.rMd),
            ),
            child: btn,
          )
        : padded;
    // C4:禁用态仍可点——上抛原因给页面 toast(无障碍 Tooltip 保留);
    // onDisabledTap 未注入(单测直挂)维持 null 不可点的原行为。
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(Tk.rMd),
        onTap: enabled
            ? (onTap == null ? null : () {
                Haptics.light();
                onTap();
              })
            : (onDisabledTap == null ? null : () => onDisabledTap!(tooltip)),
        child: framed,
      ),
    );
  }
}
