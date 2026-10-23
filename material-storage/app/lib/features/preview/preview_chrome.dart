/// PreviewChrome — 预览页固定暗色 chrome 组装(§4.3 / F9 / §7.2):
/// - [PreviewTopBar]:顶部渐变黑条(transparent→previewBg)+ 左关闭 +
///   中 n / N(12.5 / 字距 .08em / previewFg2 / 等宽数字)+ 右更多;
/// - [PreviewBottomChrome]:胶片条 + Metadata 浮层 + 五项操作行三段组装
///   (各自圆角 18 留边,沉浸态由页面统一 Offstage);
/// - [showPreviewMoreSheet]:「更多操作」短面板(详情 / 分享 / 申请权限)。
/// 全部使用 Tk.preview* 静态令牌——预览画布在明暗两种主题下都保持深色(D8)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/sheet_scaffold.dart';
import 'filmstrip.dart';
import 'meta_panel.dart';
import 'preview_actions.dart';

/// 顶栏高度(不含状态栏避让;关闭/更多 44 触控目标落在 48 行内)。
const double kPreviewTopBarHeight = 48;

/// 沉浸过渡时长(C2 规格 ≥150ms)。
const Duration kImmersiveTransition = Duration(milliseconds: 200);

/// 沉浸收合槽:Offstage 保证「树上不可见」,AnimatedSize 负责尺寸过渡,
/// AnimatedOpacity 负责恢复时淡入;top 决定收合对齐方向。
class PreviewChromeSlot extends StatelessWidget {
  const PreviewChromeSlot({
    super.key,
    required this.top,
    required this.immersive,
    required this.child,
  });

  final bool top;
  final bool immersive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: kImmersiveTransition,
      curve: Curves.easeInOutCubic,
      alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
      child: Offstage(
        offstage: immersive,
        child: AnimatedOpacity(
          duration: kImmersiveTransition,
          curve: Curves.easeOut,
          opacity: immersive ? 0.0 : 1.0,
          child: child,
        ),
      ),
    );
  }
}

class PreviewTopBar extends StatelessWidget {
  const PreviewTopBar({
    super.key,
    required this.index,
    required this.total,
    required this.onClose,
    this.onMore,
  });

  final int index;
  final int total;
  final VoidCallback onClose;

  /// 右「更多」入口;null 时保留等宽占位(计数居中不偏移)。
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Tk.previewBg.withValues(alpha: 0.92),
            Tk.previewBg.withValues(alpha: 0),
          ],
        ),
      ),
      child: SizedBox(
        height: kPreviewTopBarHeight,
        child: Row(
          children: [
            _ChromeIcon(icon: Icons.close, tooltip: '关闭预览', onPressed: onClose),
            Expanded(
              child: Text(
                '${index + 1} / $total',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  letterSpacing: 1.0, // .08em @ 12.5
                  color: Tk.previewFg2,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (onMore == null)
              const SizedBox(width: kPreviewTopBarHeight)
            else
              _ChromeIcon(
                icon: Icons.more_horiz,
                tooltip: '更多操作',
                onPressed: onMore!,
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏图标钮:previewFg 前景 + 44 触控目标。
class _ChromeIcon extends StatelessWidget {
  const _ChromeIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 22,
      color: Tk.previewFg,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      icon: Icon(icon),
    );
  }
}

/// 底部三段组装:胶片条(多张才出现)+ MetaPanel + PreviewActions。
/// 三段均为浮层圆角卡(18),由子组件各自留边。
class PreviewBottomChrome extends StatelessWidget {
  const PreviewBottomChrome({
    super.key,
    required this.items,
    required this.index,
    required this.asset,
    required this.onSelect,
    this.onEdit,
    this.onTag,
    this.onDetail,
    required this.canDownload,
    this.downloadQueued = false,
    this.onDownload,
    this.onShare,
    this.onRequest,
    this.onDisabledTap,
  });

  final List<Asset> items;
  final int index;
  final Asset asset;
  final ValueChanged<int> onSelect;
  final VoidCallback? onEdit;
  final VoidCallback? onTag;
  final VoidCallback? onDetail;
  final bool? canDownload;
  final bool downloadQueued;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback? onRequest;
  final ValueChanged<String>? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (items.length > 1)
          Filmstrip(items: items, index: index, onSelect: onSelect),
        MetaPanel(asset: asset, onEdit: onEdit),
        PreviewActions(
          canDownload: canDownload,
          downloadQueued: downloadQueued,
          onDownload: onDownload,
          onShare: onShare,
          onTag: onTag,
          onRequest: onRequest,
          onDetail: onDetail,
          onDisabledTap: onDisabledTap,
        ),
      ],
    );
  }
}

/// 「更多操作」选中项。
enum PreviewMoreAction { detail, share, request }

/// P2-9:预览浮层固定深色(D8)——showAppSheet 读取外层主题,浅色主题下
/// 会出浅底 sheet,与固定暗色画布割裂。此处直落 showModalBottomSheet:
/// previewSurface 底 + 暗色 ThemeData(标题/关闭/行文字取暗色令牌),
/// 标题行/关闭钮/圆角仍由 [SheetScaffold] 统一。
Future<T?> showPreviewSheet<T>({
  required BuildContext context,
  String? title,
  required Widget child,
}) {
  final dark = buildAppTheme(Brightness.dark);
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Tk.previewSurface,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tk.rXl)),
    ),
    builder: (_) => Theme(
      data: dark,
      child: SheetScaffold(title: title, child: child),
    ),
  );
}

/// 打开顶部「更多」短面板;返回 null=取消。
Future<PreviewMoreAction?> showPreviewMoreSheet(
  BuildContext context, {
  required bool canRequest,
}) {
  return showPreviewSheet<PreviewMoreAction>(
    context: context,
    title: '更多操作',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MoreRow(
          icon: Icons.info_outline,
          title: '文件详情',
          subtitle: '类型、大小与所属位置',
          onTap: () => Navigator.of(context).pop(PreviewMoreAction.detail),
        ),
        _MoreRow(
          icon: Icons.ios_share_outlined,
          title: '分享',
          subtitle: '分享链接(需登录访问)',
          onTap: () => Navigator.of(context).pop(PreviewMoreAction.share),
        ),
        if (canRequest)
          _MoreRow(
            icon: Icons.verified_user_outlined,
            title: '申请访问权限',
            subtitle: '发起下载权限申请',
            onTap: () => Navigator.of(context).pop(PreviewMoreAction.request),
          ),
      ],
    ),
  );
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 21),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}
