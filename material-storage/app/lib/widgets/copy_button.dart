/// CopyButton — 剪贴板复制按钮,mobile-ux-polish-2 批 R1:
/// sheet/modal 态下 SnackBar 渲染在页面底部,被 bottom sheet 遮挡不可见
/// (temp_password_sheet/artist_account_field/share_create_sheet 三处实证),
/// 反馈改**就地图标切换**:复制成功 copy_outlined → check(绿色)约 1.5s
/// 回切,期间禁点防重复;失败(剪贴板通道异常)记 AppLog、保持原图标,
/// 可选 [onResult] 供调用方接自有降级(如分享 sheet 的「长按手动复制」)。
/// 页面级复制点(bind_code_page/request_link_sheet)SnackBar 可见,不换本件。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import '../theme/tokens.dart';

/// 成功态图标回切时长(web CopyButton 无此件,取「可感知又不打扰」经验值)。
const Duration kCopyFeedbackDuration = Duration(milliseconds: 1500);

class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.label,
    this.tooltip = '复制',
    this.iconSize = 20,
    this.visualDensity,
    this.onResult,
  });

  /// 写入剪贴板的文本(组件自理 Clipboard.setData,调用方只给内容)。
  final String text;

  /// 有值 = 渲染为带文字的 FilledButton.icon(分享 sheet「复制链接」同位);
  /// null = 默认 IconButton(密码/账号行内复制)。
  final String? label;

  final String tooltip;
  final double iconSize;
  final VisualDensity? visualDensity;

  /// 复制结果回调(true 成功/false 失败);失败组件内已记 AppLog,
  /// 调用方仅用于追加降级 UI 或业务日志时挂载。
  final ValueChanged<bool>? onResult;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  var _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    if (_copied) return; // ✓ 展示期禁点(按钮同时置禁用,双保险)
    var ok = false;
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
      ok = true;
    } catch (e) {
      // 剪贴板通道不可用(平台异常/权限拒绝):不静默吞,保持原图标
      AppLog.error('copy', '复制失败(${widget.tooltip})', e);
    }
    if (!mounted) return;
    widget.onResult?.call(ok);
    if (!ok) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(kCopyFeedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      _copied ? Icons.check : Icons.copy_outlined,
      size: widget.iconSize,
      // ✓ 显式 Tk 绿(不随禁用态变灰,反馈可感知);默认态交主题配色
      color: _copied ? Tk.green : null,
    );
    if (widget.label != null) {
      return FilledButton.icon(
        onPressed: _copied ? null : _copy,
        icon: icon,
        label: Text(widget.label!),
      );
    }
    return IconButton(
      visualDensity: widget.visualDensity,
      icon: icon,
      tooltip: widget.tooltip,
      onPressed: _copied ? null : _copy,
    );
  }
}
