/// 更新弹窗组(F2-5/6):确认弹窗(标题含新版本号,changelog 空则无正文区,
/// 「立即更新」/「取消」)+ 下载进度弹窗(百分比,总长未知落进行中态,
/// 可取消;PopScope 拦返回键,取消一律走按钮回调由调用方收流)。
/// 视觉:弹层 surface/rXl/标题 20 交 DialogTheme,正文 14/ink2,版本号与
/// 百分比数字等宽(tabular),进度条金色、主按钮金色、取消 ghost、遮罩 scrim。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import 'app_version_info.dart';

/// 数字等宽(版本号/百分比对齐)。
const List<FontFeature> _kTabular = [FontFeature.tabularFigures()];

/// 更新确认弹窗;返回 true = 立即更新,false/ dismiss = 取消。
Future<bool> showUpdateConfirmDialog(
  BuildContext context, {
  required AppVersionInfo info,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: context.tk.scrim,
    builder: (_) => _UpdateConfirmDialog(info: info),
  );
  return confirmed ?? false;
}

class _UpdateConfirmDialog extends StatelessWidget {
  const _UpdateConfirmDialog({required this.info});

  final AppVersionInfo info;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final hasChangelog = info.changelog.trim().isNotEmpty;
    return AlertDialog(
      title: Text(
        '发现新版本 ${info.version}',
        style: const TextStyle(fontFeatures: _kTabular),
      ),
      // changelog 为空 → 不渲染正文区(F2-5 字面口径)
      content: hasChangelog
          ? SingleChildScrollView(
              child: Text(
                info.changelog.trim(),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontSize: 14, height: 1.5, color: tk.ink2),
              ),
            )
          : null,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}

/// 下载进度(0..100;-1 = 总长未知,UI 落进行中态)。
typedef UpdateProgressValueListenable = ValueListenable<int>;

/// 下载进度弹窗(barrier 不可点关、返回键拦截;唯一出口是「取消」回调,
/// 由调用方取消 CancelToken 并关弹窗,保证半成品清理路径单一)。
Future<void> showUpdateProgressDialog(
  BuildContext context, {
  required UpdateProgressValueListenable progress,
  required VoidCallback onCancel,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: context.tk.scrim,
    builder: (_) =>
        _UpdateProgressDialog(progress: progress, onCancel: onCancel),
  );
}

class _UpdateProgressDialog extends StatelessWidget {
  const _UpdateProgressDialog({required this.progress, required this.onCancel});

  final UpdateProgressValueListenable progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (context, percent, _) {
            final tk = context.tk;
            final unknown = percent < 0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Tk.rPill),
                  child: LinearProgressIndicator(
                    value: unknown ? null : percent / 100.0,
                    minHeight: 8,
                    backgroundColor: tk.surface3,
                    valueColor: AlwaysStoppedAnimation<Color>(tk.gold),
                  ),
                ),
                const SizedBox(height: Tk.spaceSm),
                Text(
                  unknown ? '下载中…' : '$percent%',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: tk.goldInk, fontFeatures: _kTabular),
                ),
              ],
            );
          },
        ),
        actions: [TextButton(onPressed: onCancel, child: const Text('取消'))],
      ),
    );
  }
}
