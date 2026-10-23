/// PreviewActions — 预览底部五项操作行(F9):下载 / 分享 / 标签 / 申请权限 /
/// 详情。下载保留 `my_can_download` 三态与入队就地态(「已入队 ✓」previewGold,
/// 2s 复原由页面定时驱动);分享恒可点(后端 403 最终裁决);申请权限仅在
/// 已知无权时点亮,并以金色细框提示;标签=打标面板;详情=PreviewDetailSheet。
/// 固定暗色浮层(D8):previewSurface 底 + 顶部圆角 18 + 横向留边,SafeArea
/// 让底色延伸进虚拟导航栏。
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
    this.onTag,
    this.onRequest,
    this.onDetail,
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

  /// 标签动作(打标面板);null=不渲染「标签」项(兼容旧调用/测试)。
  final VoidCallback? onTag;

  /// 申请权限动作(B5):仅 canDownload==false 时点亮入口。
  final VoidCallback? onRequest;

  /// 详情动作(F9 新增);null=不渲染「详情」项(兼容旧调用/测试)。
  final VoidCallback? onDetail;

  /// C5:入队就地态——true 时下载钮显「已入队 ✓」并暂禁点(防重复入队)。
  final bool downloadQueued;

  /// C4:禁用键点按上抛原因文案(页面 toast 呈现);null=禁用键不可点。
  final ValueChanged<String>? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    final noDownload = canDownload == false;
    final downloadEnabled =
        onDownload != null && !noDownload && !downloadQueued;
    final buttons = <Widget>[
      _ActionButton(
        icon: downloadQueued
            ? Icons.check_circle_outline
            : Icons.download_outlined,
        label: downloadQueued ? '已入队 ✓' : '下载',
        tooltip: downloadQueued
            ? '已加入下载队列,可在传输页查看进度'
            : noDownload
            ? '无下载权限 · 可申请'
            : (downloadEnabled ? '下载到本机(相册 / Download/浣花视界)' : '后续版本开放'),
        enabled: downloadEnabled,
        accent: downloadQueued,
        onTap: downloadEnabled ? onDownload : null,
        onDisabledTap: onDisabledTap,
      ),
      _ActionButton(
        icon: Icons.ios_share_outlined,
        label: '分享',
        tooltip: onShare == null ? '后续版本开放' : '分享链接(需登录访问)',
        enabled: onShare != null,
        onTap: onShare,
        onDisabledTap: onDisabledTap,
      ),
      if (onTag != null)
        _ActionButton(
          icon: Icons.sell_outlined,
          label: '标签',
          tooltip: '编辑标签与备注',
          enabled: true,
          onTap: onTag,
          onDisabledTap: onDisabledTap,
        ),
      _ActionButton(
        icon: Icons.verified_user_outlined,
        label: '申请权限',
        tooltip: noDownload
            ? '发起下载权限申请'
            : (canDownload == null ? '下载权未知 · 详情加载后可申请' : '已有下载权限,无需申请'),
        enabled: noDownload && onRequest != null,
        highlighted: noDownload,
        onTap: noDownload ? onRequest : null,
        onDisabledTap: onDisabledTap,
      ),
      if (onDetail != null)
        _ActionButton(
          icon: Icons.info_outline,
          label: '详情',
          tooltip: '查看文件详情',
          enabled: true,
          onTap: onDetail,
          onDisabledTap: onDisabledTap,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Tk.rLg)),
        child: Container(
          color: Tk.previewSurface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Tk.spaceSm),
              child: Row(
                children: [for (final b in buttons) Expanded(child: b)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单项操作:图标 21 + 11 号标签、间距 5;高亮=金色细框(申请权限)。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.enabled,
    this.onTap,
    this.onDisabledTap,
    this.highlighted = false,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool enabled;
  final VoidCallback? onTap;
  final ValueChanged<String>? onDisabledTap;
  final bool highlighted;
  final bool accent;

  Color get _color {
    if (accent) return Tk.previewGold; // 已入队 ✓
    if (!enabled) {
      return highlighted
          ? Tk.previewGold
          : Tk.previewFg2.withValues(alpha: 0.6);
    }
    return highlighted ? Tk.previewGold : Tk.previewFg;
  }

  @override
  Widget build(BuildContext context) {
    final btn = Container(
      padding: const EdgeInsets.symmetric(vertical: Tk.spaceXs, horizontal: 2),
      decoration: highlighted
          ? BoxDecoration(
              border: Border.all(color: Tk.previewGold.withValues(alpha: 0.55)),
              borderRadius: BorderRadius.circular(Tk.rSm),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _color, size: 21),
          const SizedBox(height: 5),
          // P2-1:五等分窄格 + 1.3 字号下「申请权限」允许两行,不再截断。
          Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: TextStyle(color: _color, fontSize: Tk.fzXs, height: 1.2),
          ),
        ],
      ),
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(Tk.rSm),
        onTap: enabled
            ? (onTap == null
                  ? null
                  : () {
                      Haptics.light();
                      onTap!();
                    })
            : (onDisabledTap == null ? null : () => onDisabledTap!(tooltip)),
        child: btn,
      ),
    );
  }
}
